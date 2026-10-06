import Foundation
import PicShotFormulaCore

/// No initializer, status check or recognition attempt downloads a model. Only
/// the model window's explicit user action calls install(_:progress:).
actor ModelPackService {
    static let shared = ModelPackService()
    private var downloading = false
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PicShot/Models", isDirectory: true)
    }

    func directory(for manifest: ModelPackManifest) -> URL { root.appendingPathComponent(manifest.id, isDirectory: true) }

    func verifiedDirectory(for manifest: ModelPackManifest) throws -> URL {
        let directory = directory(for: manifest)
        guard FileManager.default.fileExists(atPath: directory.path) else { throw ModelValidationError.missing(manifest.title) }
        try ModelAssetVerifier.verify(manifest, in: directory)
        return directory
    }

    func install(_ manifest: ModelPackManifest, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        try manifest.validateLayout()
        guard !downloading else { throw ModelPackError.busy }
        downloading = true
        defer { downloading = false }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = root.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        var finished: Int64 = 0
        for asset in manifest.assets {
            try Task.checkCancellation()
            let previous = finished
            let destination = staging.appendingPathComponent(asset.name)
            let transfer = BoundedModelDownload(asset: asset, destination: destination) { received in
                progress(previous + received, manifest.totalBytes)
            }
            try await transfer.run()
            try ModelAssetVerifier.verify(asset, at: destination)
            finished += asset.bytes
            progress(finished, manifest.totalBytes)
        }
        try Task.checkCancellation()
        try ModelAssetVerifier.verify(manifest, in: staging)
        let final = directory(for: manifest)
        // A fully valid existing install wins. Invalid/incomplete copies are
        // recoverable model cache, never user documents, and replaced on request.
        if fm.fileExists(atPath: final.path) {
            if (try? ModelAssetVerifier.verify(manifest, in: final)) != nil { return final }
            try fm.removeItem(at: final)
        }
        try fm.moveItem(at: staging, to: final)
        return final
    }
}

enum ModelPackError: LocalizedError {
    case busy, response, size, redirect
    var errorDescription: String? {
        switch self {
        case .busy: return "已有模型下载正在进行。"
        case .response: return "模型服务器未返回有效文件。请检查网络后重试。"
        case .size: return "模型下载大小与固定版本不符，已停止下载。"
        case .redirect: return "模型下载重定向到未经许可的地址，已停止。"
        }
    }
}

/// Streams directly to a 0600 file and rejects oversized bodies before writing.
/// Redirects are limited to each pinned asset's exact HTTPS delivery hosts.
private final class BoundedModelDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let asset: ModelAsset
    let destination: URL
    let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var failure: Error?

    init(asset: ModelAsset, destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.asset = asset; self.destination = destination; self.progress = progress
    }

    func run() async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                do {
                    guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteNoPermission) }
                    handle = try FileHandle(forWritingTo: destination)
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.httpCookieStorage = nil
                    configuration.urlCredentialStorage = nil
                    configuration.urlCache = nil
                    configuration.timeoutIntervalForRequest = 30
                    configuration.timeoutIntervalForResource = 600
                    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                    self.session = session
                    var request = URLRequest(url: asset.url)
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    let task = session.dataTask(with: request)
                    self.task = task
                    task.resume()
                    lock.unlock()
                } catch {
                    self.continuation = nil
                    lock.unlock()
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: { self.cancel() })
    }

    private func cancel() {
        lock.lock(); cancelled = true; let current = task; lock.unlock()
        current?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard asset.permitsDownloadURL(request.url) else {
            failure = ModelPackError.redirect; completionHandler(nil); task.cancel(); return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            failure = ModelPackError.response; completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= asset.bytes else {
            failure = ModelPackError.size; completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard received + Int64(data.count) <= asset.bytes else { failure = ModelPackError.size; dataTask.cancel(); return }
        do { try handle?.write(contentsOf: data); received += Int64(data.count); progress(received) }
        catch { failure = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do { try handle?.close() } catch { if failure == nil { failure = error } }
        handle = nil
        lock.lock()
        let completion = continuation; continuation = nil
        let wasCancelled = cancelled
        self.task = nil; self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if wasCancelled { completion?.resume(throwing: CancellationError()) }
        else if let error = failure ?? error { completion?.resume(throwing: error) }
        else if received != asset.bytes { completion?.resume(throwing: ModelPackError.size) }
        else { completion?.resume() }
    }
}
