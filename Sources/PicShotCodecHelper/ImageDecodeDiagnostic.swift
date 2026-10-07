import Foundation
import Darwin
import CoreGraphics
import ImageIO
import PicShotCodecCore

/// The explicit diagnostic argument routes here; normal export run() is unchanged.
enum ImageDecodeDiagnostic {
    static func run() -> Int32 {
        _ = signal(SIGPIPE, SIG_IGN); _ = umask(0o077)
        let writer = ImageDecodeDiagnosticWriter()
        let state = ImageDecodeDiagnosticState()
        let parent = getppid(), started = ProcessInfo.processInfo.systemUptime
        let sampler = ImageDecodeMemorySampler(); defer { sampler.stop() }
        DispatchQueue(label: "PicShot.ImageDecodeDiagnostic.HardDeadline").asyncAfter(deadline: .now() + ImageDecodeDiagnosticLimits.childHardSeconds) {
            // Never recursively remove a directory from this backstop while a
            // native worker could still write. The live parent owns cleanup.
            Darwin._exit(70)
        }
        var job: ImageDecodeDiagnosticJob?
        do {
            guard parent > 1 else { throw ImageDecodeDiagnosticError.cancelled }
            for fd in [STDIN_FILENO, STDOUT_FILENO] {
                let flags = fcntl(fd, F_GETFL); guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw ImageDecodeDiagnosticError.invalidProtocol }
            }
            let files = try ImageDecodeDiagnosticJob.validate(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true), expectedParent: parent)
            job = files
            DispatchQueue.global(qos: .utility).async {
                do {
                    let result = try autoreleasepool { try decode(job: files, writer: writer, state: state, sampler: sampler) }
                    try phase("afterDecodePool", writer: writer, sampler: sampler)
                    state.finish(result)
                } catch { state.fail((error as? ImageDecodeDiagnosticError) ?? .failed) }
            }
            var control = Data(), buffer = [UInt8](repeating: 0, count: 64), stdinOpen = true
            while !state.complete {
                let now = ProcessInfo.processInfo.systemUptime
                if now - started >= ImageDecodeDiagnosticLimits.childWorkSeconds { state.cancel(.deadline) }
                if getppid() != parent { state.markParentLost(); state.cancel(.cancelled) }
                let peaks = sampler.snapshot()
                if peaks.residentBytes > ImageDecodeDiagnosticLimits.residentWatchdogBytes || peaks.footprintBytes > ImageDecodeDiagnosticLimits.residentWatchdogBytes { state.cancel(.memoryLimit) }
                if stdinOpen {
                    let n = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                    if n > 0 {
                        control.append(contentsOf: buffer.prefix(n))
                        if control == ImageDecodeDiagnosticLimits.cancelLine { state.cancel(.cancelled); stdinOpen = false }
                        else if control.count >= ImageDecodeDiagnosticLimits.cancelLine.count || !ImageDecodeDiagnosticLimits.cancelLine.starts(with: control) { state.cancel(.invalidProtocol); stdinOpen = false }
                    } else if n == 0 { stdinOpen = false; state.markParentLost(); state.cancel(.cancelled) }
                    else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK { state.cancel(.invalidProtocol); stdinOpen = false }
                }
                if !state.complete { Thread.sleep(forTimeInterval: 0.005) }
            }
            // A fast worker must not outrun an already queued cancel or EOF.
            if stdinOpen {
                let n = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                if n == 0 { state.markParentLost(); state.cancel(.cancelled) }
                else if n > 0 {
                    control.append(contentsOf: buffer.prefix(n))
                    state.cancel(control == ImageDecodeDiagnosticLimits.cancelLine ? .cancelled : .invalidProtocol)
                } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK { state.cancel(.invalidProtocol) }
            }
            if !control.isEmpty && control != ImageDecodeDiagnosticLimits.cancelLine { state.cancel(.invalidProtocol) }
            sampler.stop()
            var terminal = state.terminal
            terminal.peaks = sampler.snapshot(); terminal.childWorkSeconds = ProcessInfo.processInfo.systemUptime - started
            terminal.memory = ImageDecodeMemoryReading.current()
            try writer.send(terminal)
            // Worker completion is established before parent-loss cleanup.
            if state.parentLost { _ = files.removeAfterExit() }
            return terminal.kind == .result ? 0 : 1
        } catch {
            var event = ImageDecodeDiagnosticEvent(kind: .error, phase: "failed", childPID: getpid())
            event.error = (error as? ImageDecodeDiagnosticError) ?? .failed; event.peaks = sampler.snapshot()
            try? writer.send(event)
            if state.complete && state.parentLost { _ = job?.removeAfterExit() }
            return 1
        }
    }
    static func decodePixels(_ data: Data, check: () throws -> Void,
                             phase: (String) throws -> Void) throws -> (Data, Double, Double) {
        try check()
        guard data.count >= 33, data.count <= ImageDecodeDiagnosticLimits.pngBytes,
              data.prefix(8) == Data([137,80,78,71,13,10,26,10]), data[8..<16] == Data([0,0,0,13,73,72,68,82]),
              data.suffix(12) == Data([0,0,0,0,73,69,78,68,174,66,96,130]) else { throw ImageDecodeDiagnosticError.invalidInput }
        let width = data[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let height = data[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard width == ImageDecodeDiagnosticLimits.width, height == ImageDecodeDiagnosticLimits.height else { throw ImageDecodeDiagnosticError.invalidInput }
        let creationStart = ProcessInfo.processInfo.systemUptime
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              CGImageSourceGetType(source) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == ImageDecodeDiagnosticLimits.width,
              properties[kCGImagePropertyPixelHeight] as? Int == ImageDecodeDiagnosticLimits.height,
              properties[kCGImagePropertyDepth] as? Int == 8, (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false, kCGImageSourceShouldAllowFloat: false] as CFDictionary),
              image.width == ImageDecodeDiagnosticLimits.width, image.height == ImageDecodeDiagnosticLimits.height,
              image.bitsPerComponent == 8, image.bytesPerRow <= 4_194_304 / image.height else { throw ImageDecodeDiagnosticError.invalidInput }
        let createSeconds = ProcessInfo.processInfo.systemUptime - creationStart
        try phase("imageCreated"); try check()
        var pixels = Data(count: ImageDecodeDiagnosticLimits.rasterBytes)
        let drawStart = ProcessInfo.processInfo.systemUptime
        try pixels.withUnsafeMutableBytes { raw in
            try autoreleasepool {
                guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw ImageDecodeDiagnosticError.failed }
                context.interpolationQuality = .none; context.setBlendMode(.copy)
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); context.flush()
                // Force readback of all bytes while the source and context live.
                let borrowed = Data(bytesNoCopy: raw.baseAddress!, count: raw.count, deallocator: .none)
                _ = ImageDecodeDiagnosticLimits.digest(borrowed)
                try phase("rasterDrawn")
                withExtendedLifetime(context) { }
            }
        }
        let drawSeconds = ProcessInfo.processInfo.systemUptime - drawStart
        guard CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw ImageDecodeDiagnosticError.invalidInput }
        try phase("afterContextRelease"); try check()
        withExtendedLifetime((image, source)) { }
        return (pixels, createSeconds, drawSeconds)
    }
    private static func decode(job: ImageDecodeDiagnosticJob, writer: ImageDecodeDiagnosticWriter,
                               state: ImageDecodeDiagnosticState, sampler: ImageDecodeMemorySampler) throws -> ImageDecodeDiagnosticEvent {
        let check = { try state.check() }
        try phase("beforePNGRead", writer: writer, sampler: sampler)
        let png = try job.readPNG(check: check)
        let result = try decodePixels(png, check: check) { try phase($0, writer: writer, sampler: sampler) }
        if job.request.mode == .holdAfterDecode {
            var event = ImageDecodeDiagnosticEvent(kind: .ready, phase: "heldAfterDecode", childPID: getpid(), memory: .current())
            event.rawBytes = result.0.count; event.rawSHA256 = ImageDecodeDiagnosticLimits.digest(result.0)
            try writer.send(event)
            while true { try check(); Thread.sleep(forTimeInterval: 0.005) }
        }
        try check()
        let writeStart = ProcessInfo.processInfo.systemUptime
        try job.writeRaw(result.0, check: check)
        let writeSeconds = ProcessInfo.processInfo.systemUptime - writeStart
        try phase("outputClosed", writer: writer, sampler: sampler)
        var event = ImageDecodeDiagnosticEvent(kind: .result, phase: "complete", childPID: getpid())
        event.rawBytes = result.0.count; event.rawSHA256 = ImageDecodeDiagnosticLimits.digest(result.0)
        event.imageCreationSeconds = result.1; event.drawSeconds = result.2; event.writeSeconds = writeSeconds
        return event
    }
    private static func phase(_ name: String, writer: ImageDecodeDiagnosticWriter, sampler: ImageDecodeMemorySampler) throws {
        let reading = ImageDecodeMemoryReading.current(); guard reading.usable else { throw ImageDecodeDiagnosticError.failed }
        sampler.record(reading); try writer.send(.init(kind: .phase, phase: name, childPID: getpid(), memory: reading))
    }
}
private final class ImageDecodeDiagnosticState: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ImageDecodeDiagnosticEvent?, cancellation: ImageDecodeDiagnosticError?, lost = false
    var complete: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }
    var parentLost: Bool { lock.lock(); defer { lock.unlock() }; return lost }
    func markParentLost() { lock.lock(); lost = true; lock.unlock() }
    func cancel(_ error: ImageDecodeDiagnosticError) { lock.lock(); if cancellation == nil { cancellation = error }; lock.unlock() }
    func check() throws { lock.lock(); let error = cancellation; lock.unlock(); if let error { throw error } }
    func finish(_ event: ImageDecodeDiagnosticEvent) { lock.lock(); defer { lock.unlock() }; if let cancellation { result = failure(cancellation) } else { result = event } }
    func fail(_ error: ImageDecodeDiagnosticError) { lock.lock(); result = failure(cancellation ?? error); lock.unlock() }
    var terminal: ImageDecodeDiagnosticEvent { lock.lock(); defer { lock.unlock() }; return cancellation.map(failure) ?? result ?? failure(.failed) }
    private func failure(_ error: ImageDecodeDiagnosticError) -> ImageDecodeDiagnosticEvent {
        var e = ImageDecodeDiagnosticEvent(kind: .error, phase: "failed", childPID: getpid()); e.error = error; return e
    }
}
private final class ImageDecodeDiagnosticWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0, bytes = 0, terminal = false
    func send(_ event: ImageDecodeDiagnosticEvent) throws {
        lock.lock(); defer { lock.unlock() }
        guard !terminal, count < ImageDecodeDiagnosticLimits.maximumEvents else { throw ImageDecodeDiagnosticError.invalidProtocol }
        var data = try JSONEncoder().encode(event); data.append(10)
        guard data.count <= ImageDecodeDiagnosticLimits.eventBytes, data.count <= ImageDecodeDiagnosticLimits.stdoutBytes - bytes else { throw ImageDecodeDiagnosticError.invalidProtocol }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw ImageDecodeDiagnosticError.deadline }
                let n = Darwin.write(STDOUT_FILENO, raw.baseAddress!.advanced(by: offset), data.count - offset)
                if n > 0 { offset += n }
                else if n < 0 && errno == EINTR { continue }
                else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { var p = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0); _ = poll(&p, 1, 5) }
                else { throw ImageDecodeDiagnosticError.invalidProtocol }
            }
        }
        count += 1; bytes += data.count; terminal = event.kind == .result || event.kind == .error
    }
}
