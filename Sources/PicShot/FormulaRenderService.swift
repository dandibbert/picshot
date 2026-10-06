import Foundation
import Security
import Darwin
import PicShotFormulaRenderCore

/// One short-lived renderer process globally. Closing/editing cancels; no idle JS heap remains.
actor FormulaRenderService {
    static let shared = FormulaRenderService()
    private var working = false

    func render(_ request: FormulaRenderRequest) async throws -> FormulaRenderResult {
        try request.validate(); try Task.checkCancellation()
        guard !working else { throw FormulaRenderError.busy }
        working = true; defer { working = false }
        let control = FormulaRenderProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) {
                try Self.run(request, control: control)
            }.value
        }, onCancel: { control.cancel() })
    }

    private nonisolated static func run(_ request: FormulaRenderRequest, control: FormulaRenderProcessControl) throws -> FormulaRenderResult {
        let executable = try verifiedHelper()
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("picshot-formula-render-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.json"), output = directory.appendingPathComponent("output.json")
        let errors = directory.appendingPathComponent("error.txt")
        guard fm.createFile(atPath: input.path, contents: try JSONEncoder().encode(request), attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteNoPermission) }
        let errorHandle = try FileHandle(forWritingTo: errors); defer { try? errorHandle.close() }
        let process = Process(); process.executableURL = executable
        process.arguments = ["--input", input.path, "--output", output.path]
        process.currentDirectoryURL = directory
        process.environment = ["HOME": NSHomeDirectory(), "TMPDIR": directory.path, "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = errorHandle
        try control.start(process)
        let started = ProcessInfo.processInfo.systemUptime
        var failure: Error?
        while process.isRunning {
            if control.isCancelled { failure = CancellationError(); control.stop() }
            if ProcessInfo.processInfo.systemUptime - started > FormulaRenderLimits.seconds {
                if failure == nil { failure = FormulaRenderError.timeLimit }; control.stop()
            }
            if residentBytes(process.processIdentifier) > FormulaRenderLimits.residentBytes {
                if failure == nil { failure = FormulaRenderError.memoryLimit }; control.stop()
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        if control.isCancelled { throw CancellationError() }
        if let failure { throw failure }
        guard process.terminationStatus == 0 else {
            let handle = try FileHandle(forReadingFrom: errors); defer { try? handle.close() }
            let data = try handle.read(upToCount: 2048) ?? Data()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw FormulaRenderServiceError.failed(message.isEmpty ? "辅助程序异常退出。" : message)
        }
        let values = try output.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= FormulaRenderLimits.resultBytes else { throw FormulaRenderError.invalidOutput }
        let result = try JSONDecoder().decode(FormulaRenderResult.self, from: Data(contentsOf: output))
        try result.validate(for: request)
        return result
    }

    private nonisolated static func verifiedHelper() throws -> URL {
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        guard bundle.pathExtension == "app" else { throw FormulaRenderError.helperUnavailable }
        let helper = bundle.appendingPathComponent("Contents/Helpers/PicShotFormulaRenderHelper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw FormulaRenderError.helperUnavailable }
        guard helper.resolvingSymlinksInPath().path == helper.path, bundle.resolvingSymlinksInPath().path == bundle.path else { throw FormulaRenderError.signature }
        // Deep app validation also authenticates the resource bundle and JS digest, not only the executable.
        for url in [bundle, helper] {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess else { throw FormulaRenderError.signature }
        }
        return helper
    }
    private nonisolated static func residentBytes(_ pid: Int32) -> UInt64 {
        var info = proc_taskinfo()
        let count = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
        return count == Int32(MemoryLayout<proc_taskinfo>.size) ? info.pti_resident_size : 0
    }
}

private enum FormulaRenderServiceError: LocalizedError {
    case failed(String)
    var errorDescription: String? { switch self { case .failed(let detail): return "公式渲染失败：\(detail)" } }
}

/// Internal visibility permits cancellation tests without running a signed release app.
final class FormulaRenderProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    private var stopTime: TimeInterval?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run(); self.process = process
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock(); stop() }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard let process, process.isRunning else { return }
        if let stopTime {
            if ProcessInfo.processInfo.systemUptime - stopTime > 0.5 { kill(process.processIdentifier, SIGKILL) }
        } else {
            stopTime = ProcessInfo.processInfo.systemUptime; process.terminate()
        }
    }
}
