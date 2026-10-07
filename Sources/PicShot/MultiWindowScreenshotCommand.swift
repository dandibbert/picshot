import Foundation
import CoreGraphics
import ImageIO
import Darwin
import PicShotCore

private final class MultiWindowCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func check() throws { lock.lock(); let value = stopped; lock.unlock(); if value { throw CancellationError() } }
}

/// A system screenshot process is owned until reaped. Unlike an uncancellable
/// SCScreenshotManager request, timeout/cancel can stop work before a new session.
/// No user-controlled text is interpreted by the shell: the script is fixed and
/// window ID/path are positional arguments. POSIX ulimit -f uses 512-byte blocks.
struct MultiWindowCommandConfiguration: @unchecked Sendable {
    let temporaryRoot: URL
    let arguments: @Sendable (MultiWindowDescriptor, URL) -> [String]
    var didLaunch: @Sendable (Int32) -> Void = { _ in }
    static var live: Self {
        Self(temporaryRoot: FileManager.default.temporaryDirectory, arguments: { window, output in
            ["-c", MultiWindowScreenshotCommand.fileLimitPrelude(blocks: MultiWindowCaptureLimits.temporaryBytes / 512) +
                "exec /usr/sbin/screencapture -x -o -t png -l \"$1\" \"$2\"",
             "PicShot-window-capture", String(window.id), output.path]
        })
    }
}

enum MultiWindowScreenshotCommand {
    // Explicit POSIX shell mode fixes `ulimit -f` to 512-byte blocks on macOS.
    // The native shell-limit test verifies the actual installed /bin/sh behavior.
    static func fileLimitPrelude(blocks: Int) -> String {
        "set -o posix || exit 72; ulimit -f \(blocks) || exit 72; "
    }

    static func capture(_ window: MultiWindowDescriptor, deadline: TimeInterval,
                        configuration: MultiWindowCommandConfiguration = .live) async throws -> CGImage {
        try Task.checkCancellation()
        let cancellation = MultiWindowCancellation()
        let work = Task.detached(priority: .userInitiated) {
            try run(window, deadline: deadline, cancellation: cancellation, configuration: configuration)
        }
        return try await withTaskCancellationHandler {
            let image = try await work.value
            try Task.checkCancellation()
            return image
        } onCancel: { cancellation.cancel(); work.cancel() }
    }

    private static func run(_ window: MultiWindowDescriptor, deadline: TimeInterval,
                            cancellation: MultiWindowCancellation, configuration: MultiWindowCommandConfiguration) throws -> CGImage {
        func check() throws {
            try cancellation.check(); try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw MultiWindowCaptureError.deadline }
        }
        try check()
        let manager = FileManager.default, root = configuration.temporaryRoot
        let free = (try manager.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free >= Int64(MultiWindowCaptureLimits.temporaryBytes + 16 * 1_024 * 1_024) else { throw MultiWindowCaptureError.diskLimit }
        let directory = root.appendingPathComponent("PicShot-MultiWindow-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let result = try captureFile(window, directory: directory, deadline: deadline, cancellation: cancellation, configuration: configuration)
            try manager.removeItem(at: directory)
            return result
        } catch {
            let captureFailure = error
            do { if manager.fileExists(atPath: directory.path) { try manager.removeItem(at: directory) } }
            catch { throw CaptureError.failed("Window capture failed (\(captureFailure.localizedDescription)); temporary cleanup also failed: \(error.localizedDescription)") }
            throw captureFailure
        }
    }

    private static func captureFile(_ window: MultiWindowDescriptor, directory: URL, deadline: TimeInterval,
                                    cancellation: MultiWindowCancellation, configuration: MultiWindowCommandConfiguration) throws -> CGImage {
        func check() throws {
            try cancellation.check(); try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw MultiWindowCaptureError.deadline }
        }
        let manager = FileManager.default
        let output = directory.appendingPathComponent("window.png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = configuration.arguments(window, output)
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try check()
        try process.run()
        configuration.didLaunch(process.processIdentifier)
        func reap() {
            guard process.isRunning else { process.waitUntilExit(); return }
            process.terminate()
            let until = ProcessInfo.processInfo.systemUptime + 0.15
            while process.isRunning && ProcessInfo.processInfo.systemUptime < until { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        do {
            while process.isRunning {
                try check()
                let size = (try? manager.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size <= MultiWindowCaptureLimits.temporaryBytes else { throw MultiWindowCaptureError.diskLimit }
                Thread.sleep(forTimeInterval: 0.02)
            }
            process.waitUntilExit()
            try check()
        } catch { reap(); throw error }
        guard process.terminationStatus == 0 else {
            throw CaptureError.failed("The window screenshot command exited with status \(process.terminationStatus) (\(process.terminationReason == .uncaughtSignal ? "signal" : "exit")). No partial image was saved.")
        }
        let attributes = try manager.attributesOfItem(atPath: output.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0, size <= MultiWindowCaptureLimits.temporaryBytes else { throw MultiWindowCaptureError.diskLimit }
        try check()
        guard let source = CGImageSourceCreateWithURL(output as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue == 8 else { throw MultiWindowCaptureError.incomplete }
        try window.validateRaster(width: width, height: height)
        try check()
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == width, image.height == height, image.bitsPerComponent == 8, image.bitsPerPixel <= 32,
              image.bytesPerRow <= MultiWindowCaptureLimits.framePixels * 4 / height else { throw MultiWindowCaptureError.incomplete }
        try check()
        return image
    }
}
