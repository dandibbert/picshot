import Foundation
import Darwin
import CoreGraphics
import ImageIO
import PicShotCodecCore

/// The explicit diagnostic argument routes here; normal export run() is unchanged.
enum ImageDecodeDiagnostic {
    static func run(allowedSchema: String = ImageDecodeDiagnosticLimits.schema) -> Int32 {
        let started = ProcessInfo.processInfo.systemUptime
        _ = signal(SIGPIPE, SIG_IGN); _ = umask(0o077)
        let writer = ImageDecodeDiagnosticWriter()
        let state = ImageDecodeDiagnosticState()
        let parent = getppid()
        let sampler = ImageDecodeMemorySampler(); defer { sampler.stop() }
        DispatchQueue(label: "PicShot.ImageDecodeDiagnostic.HardDeadline").asyncAfter(deadline: .now() + ImageDecodeDiagnosticLimits.childHardSeconds) {
            // Never recursively remove a directory from this backstop while a
            // native worker could still write. The live parent owns cleanup.
            Darwin._exit(70)
        }
        var job: ImageDecodeDiagnosticJob?
        do {
            guard [ImageDecodeDiagnosticLimits.schema, ImageDecodeDiagnosticLimits.largeSchema].contains(allowedSchema) else { throw ImageDecodeDiagnosticError.invalidProtocol }
            guard parent > 1 else { throw ImageDecodeDiagnosticError.cancelled }
            for fd in [STDIN_FILENO, STDOUT_FILENO] {
                let flags = fcntl(fd, F_GETFL); guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw ImageDecodeDiagnosticError.invalidProtocol }
            }
            let files = try ImageDecodeDiagnosticJob.validateCurrentWorkingDirectory(expectedParent: parent)
            job = files
            guard files.request.schema == allowedSchema else { throw ImageDecodeDiagnosticError.invalidProtocol }
            state.admit(profile: files.request.profile)
            DispatchQueue.global(qos: .utility).async {
                do {
                    let result = try autoreleasepool { try decode(job: files, writer: writer, state: state, sampler: sampler) }
                    try phase("afterDecodePool", writer: writer, sampler: sampler, profile: files.request.profile)
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
            terminal.helperEntryUptimeSeconds = started
            terminal.responsePreparedUptimeSeconds = ProcessInfo.processInfo.systemUptime
            terminal.uptimeSeconds = terminal.responsePreparedUptimeSeconds!
            try writer.send(terminal)
            // Worker completion is established before parent-loss cleanup.
            if state.parentLost { _ = files.removeAfterExit() }
            return terminal.kind == .result ? 0 : 1
        } catch {
            var event = ImageDecodeDiagnosticEvent(kind: .error, phase: "failed", childPID: getpid(), profile: job?.request.profile)
            event.error = (error as? ImageDecodeDiagnosticError) ?? .failed; event.peaks = sampler.snapshot()
            event.helperEntryUptimeSeconds = started
            event.responsePreparedUptimeSeconds = ProcessInfo.processInfo.systemUptime
            event.uptimeSeconds = event.responsePreparedUptimeSeconds!
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
    /// Mirrors the production ImageIO thumbnail options. Only the returned
    /// 1024x576 image is drawn into RGBA; no full-size bitmap is requested.
    static func decodeThumbnailPixels(_ data: Data, profile: ImageDecodeDiagnosticProfile,
                                      check: () throws -> Void, phase: (String) throws -> Void) throws -> (Data, Double, Double) {
        try check()
        try validateLargePNG(data, profile: profile, check: check)
        let creationStart = ProcessInfo.processInfo.systemUptime
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              CGImageSourceGetType(source) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == profile.sourceWidth,
              properties[kCGImagePropertyPixelHeight] as? Int == profile.sourceHeight,
              properties[kCGImagePropertyDepth] as? Int == 8,
              (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1 else { throw ImageDecodeDiagnosticError.invalidInput }
        try check()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: profile.previewWidth,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == profile.previewWidth, image.height == profile.previewHeight,
              image.bitsPerComponent == 8, image.bytesPerRow <= 4_194_304 / image.height else { throw ImageDecodeDiagnosticError.invalidInput }
        let createSeconds = ProcessInfo.processInfo.systemUptime - creationStart
        try phase("imageCreated"); try check()
        var pixels = Data(count: profile.rasterBytes)
        let drawStart = ProcessInfo.processInfo.systemUptime
        try pixels.withUnsafeMutableBytes { raw in
            try autoreleasepool {
                guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw ImageDecodeDiagnosticError.failed }
                context.interpolationQuality = .none; context.setBlendMode(.copy)
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); context.flush()
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
    private static func validateLargePNG(_ data: Data, profile: ImageDecodeDiagnosticProfile, check: () throws -> Void) throws {
        guard data.count >= 45, data.count <= ImageDecodeDiagnosticLimits.pngBytes,
              data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
              data[8..<16] == Data([0, 0, 0, 13, 73, 72, 68, 82]) else { throw ImageDecodeDiagnosticError.invalidInput }
        func word(_ offset: Int) -> UInt32 { data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
        guard word(16) == profile.sourceWidth, word(20) == profile.sourceHeight,
              data[24] == 8, [UInt8(0), 2, 3, 4, 6].contains(data[25]), data[26] == 0, data[27] == 0,
              data[28] <= 1 else { throw ImageDecodeDiagnosticError.invalidInput }
        var offset = 8, sawPixels = false
        while offset <= data.count - 12 {
            try check()
            let length = Int(word(offset))
            guard length <= data.count - offset - 12 else { throw ImageDecodeDiagnosticError.invalidInput }
            let end = offset + 12 + length, type = word(offset + 4)
            var crc = UInt32.max
            for index in (offset + 4)..<(end - 4) {
                if index & 0xffff == 0 { try check() }
                crc = (crc >> 8) ^ pngCRCTable[Int((crc ^ UInt32(data[index])) & 0xff)]
            }
            guard crc ^ UInt32.max == word(end - 4), offset == 8 || type != 0x49484452 else { throw ImageDecodeDiagnosticError.invalidInput }
            if type == 0x49444154 { sawPixels = true }
            if type == 0x49454e44 {
                guard length == 0, sawPixels, end == data.count else { throw ImageDecodeDiagnosticError.invalidInput }
                return
            }
            offset = end
        }
        throw ImageDecodeDiagnosticError.invalidInput
    }
    private static let pngCRCTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        return crc
    }
    private static func decode(job: ImageDecodeDiagnosticJob, writer: ImageDecodeDiagnosticWriter,
                               state: ImageDecodeDiagnosticState, sampler: ImageDecodeMemorySampler) throws -> ImageDecodeDiagnosticEvent {
        let check = { try state.check() }
        let profile = job.request.profile
        try phase("beforePNGRead", writer: writer, sampler: sampler, profile: profile)
        let readStart = ProcessInfo.processInfo.systemUptime
        let png = try job.readPNG(check: check)
        let readSeconds = ProcessInfo.processInfo.systemUptime - readStart
        let reportPhase: (String) throws -> Void = { try phase($0, writer: writer, sampler: sampler, profile: profile) }
        let result: (Data, Double, Double)
        if let profile { result = try decodeThumbnailPixels(png, profile: profile, check: check, phase: reportPhase) }
        else { result = try decodePixels(png, check: check, phase: reportPhase) }
        if job.request.mode == .holdAfterDecode {
            var event = ImageDecodeDiagnosticEvent(kind: .ready, phase: "heldAfterDecode", childPID: getpid(), memory: .current(), profile: profile)
            event.rawBytes = result.0.count; event.rawSHA256 = ImageDecodeDiagnosticLimits.digest(result.0)
            event.pngReadAndHashSeconds = readSeconds
            try writer.send(event)
            while true { try check(); Thread.sleep(forTimeInterval: 0.005) }
        }
        try check()
        let writeStart = ProcessInfo.processInfo.systemUptime
        try job.writeRaw(result.0, check: check)
        let writeSeconds = ProcessInfo.processInfo.systemUptime - writeStart
        try phase("outputClosed", writer: writer, sampler: sampler, profile: profile)
        var event = ImageDecodeDiagnosticEvent(kind: .result, phase: "complete", childPID: getpid(), profile: profile)
        event.rawBytes = result.0.count; event.rawSHA256 = ImageDecodeDiagnosticLimits.digest(result.0)
        event.imageCreationSeconds = result.1; event.drawSeconds = result.2; event.writeSeconds = writeSeconds
        event.pngReadAndHashSeconds = readSeconds
        return event
    }
    private static func phase(_ name: String, writer: ImageDecodeDiagnosticWriter, sampler: ImageDecodeMemorySampler,
                              profile: ImageDecodeDiagnosticProfile? = nil) throws {
        let reading = ImageDecodeMemoryReading.current(); guard reading.usable else { throw ImageDecodeDiagnosticError.failed }
        sampler.record(reading); try writer.send(.init(kind: .phase, phase: name, childPID: getpid(), memory: reading, profile: profile))
    }
}
private final class ImageDecodeDiagnosticState: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ImageDecodeDiagnosticEvent?, cancellation: ImageDecodeDiagnosticError?, lost = false
    private var profile: ImageDecodeDiagnosticProfile?
    func admit(profile: ImageDecodeDiagnosticProfile?) { lock.lock(); self.profile = profile; lock.unlock() }
    var complete: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }
    var parentLost: Bool { lock.lock(); defer { lock.unlock() }; return lost }
    func markParentLost() { lock.lock(); lost = true; lock.unlock() }
    func cancel(_ error: ImageDecodeDiagnosticError) { lock.lock(); if cancellation == nil { cancellation = error }; lock.unlock() }
    func check() throws { lock.lock(); let error = cancellation; lock.unlock(); if let error { throw error } }
    func finish(_ event: ImageDecodeDiagnosticEvent) { lock.lock(); defer { lock.unlock() }; if let cancellation { result = failure(cancellation) } else { result = event } }
    func fail(_ error: ImageDecodeDiagnosticError) { lock.lock(); result = failure(cancellation ?? error); lock.unlock() }
    var terminal: ImageDecodeDiagnosticEvent { lock.lock(); defer { lock.unlock() }; return cancellation.map(failure) ?? result ?? failure(.failed) }
    private func failure(_ error: ImageDecodeDiagnosticError) -> ImageDecodeDiagnosticEvent {
        var e = ImageDecodeDiagnosticEvent(kind: .error, phase: "failed", childPID: getpid(), profile: profile); e.error = error; return e
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
