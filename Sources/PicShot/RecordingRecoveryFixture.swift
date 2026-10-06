import Foundation
import AVFoundation
import CoreMedia
import Darwin
import PicShotCore

/// Explicit, permission-free synthetic fixture. No shell, external program,
/// camera, microphone or screen capture is used. The parent can SIGKILL only
/// the Process it just launched, after a matching token/PID readiness handshake.
enum RecordingRecoveryFixture {
    static let modeKey = "PICSHOT_RECOVERY_FIXTURE_MODE"
    static let reportKey = "PICSHOT_RECOVERY_FIXTURE_REPORT"
    static func runIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment[modeKey], ["verify", "child"].contains(mode) else { return false }
        Task.detached {
            do {
                if mode == "child" { try await runChild(environment: environment) }
                else {
                    guard let executable = Bundle.main.executableURL, let path = environment[reportKey] else {
                        throw RecordingRecoveryError.io("The fixture requires its own executable and a report destination.")
                    }
                    let report = try await verifyAbruptTermination(executable: executable)
                    let data = try JSONEncoder().encode(report)
                    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10])); exit(0)
                }
            } catch {
                FileHandle.standardError.write(Data(("Recording recovery fixture failed: \(error)\n").utf8)); exit(1)
            }
        }
        dispatchMain()
    }

    struct Report: Codable, Sendable {
        let status: String
        let sourceCommit: String
        let bundlePath: String
        let captureStarted: Bool
        let cameraStarted: Bool
        let microphoneStarted: Bool
        let ownChildExitConfirmed: Bool
        let temporaryDirectoryRemoved: Bool
        let killedOwnProcess: Bool
        let terminationSignal: Int32
        let discoveredCaptures: Int
        let recoveredDuration: Double
        let decodedVideoFrames: Int
        let decodedAudioFrames: Int
        let sourceUnchanged: Bool
        let fragmentCount: Int
        let previewJournalRecovered: Bool
    }
    private struct Ready: Codable {
        let token: UUID
        let pid: Int32
        let frames: Int
    }
    static func verifyAbruptTermination(executable: URL) async throws -> Report {
        let token = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-RecoveryFixture-" + token.uuidString, isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Only this freshly generated, token-named tree is fixture cleanup scope.
        // Error cleanup below waits for confirmed child exit before removal.
        let process = Process()
        process.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment[modeKey] = "child"
        environment["PICSHOT_RECOVERY_FIXTURE_ROOT"] = root.path
        environment["PICSHOT_RECOVERY_FIXTURE_TOKEN"] = token.uuidString
        environment.removeValue(forKey: "PICSHOT_SMOKE_REPORT")
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        var launchedPID: Int32?
        do {
        try process.run()
        let ownPID = process.processIdentifier
        launchedPID = ownPID
        var killed = false
        let readyURL = root.appendingPathComponent("fixture-ready.json")
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        var ready: Ready?
        while ProcessInfo.processInfo.systemUptime < deadline, process.isRunning {
            try Task.checkCancellation()
            if let data = try? boundedData(readyURL, maximum: 1_024),
               let decoded = try? JSONDecoder().decode(Ready.self, from: data) { ready = decoded; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let ready, ready.token == token, ready.pid == ownPID, ready.frames == 60,
              process.isRunning, process.processIdentifier == ownPID else { throw RecordingRecoveryError.io("Child readiness handshake failed.") }
        guard kill(ownPID, SIGKILL) == 0 else { throw RecordingRecoveryError.io("Could not stop the fixture child.") }
        killed = true
        let exitDeadline = ProcessInfo.processInfo.systemUptime + 5
        while process.isRunning, ProcessInfo.processInfo.systemUptime < exitDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard !process.isRunning, process.terminationReason == .uncaughtSignal, process.terminationStatus == SIGKILL else {
            throw RecordingRecoveryError.io("The child did not terminate with the requested fixture signal.")
        }
        let store = try RecordingRecoveryStore(root: root)
        let scan = try store.discover()
        guard scan.candidates.count == 1, let candidate = scan.candidates.first, candidate.journal.phase == .capturing else {
            throw RecordingRecoveryError.io("The killed capture was not discovered.")
        }
        let original = try boundedData(candidate.sourceURL, maximum: 4_194_304)
        let result = try await RecordingRecoveryEngine.recover(candidate, store: store)
        let counts = try await decodeAllSyntheticMedia(result.url)
        guard counts.video >= 20, counts.audio >= 48_000, result.recoveredDuration >= 2,
              result.recoveredDuration <= 6.2, try boundedData(candidate.sourceURL, maximum: 4_194_304) == original else {
            throw RecordingRecoveryError.noRecoverableMedia
        }
        // Separate preview transaction: intentionally leave it undismissed,
        // reopen a new store as a relaunch would, then dismiss it explicitly.
        let previewStage = try RecordingFileStorage.makeStagingDirectory(in: root)
        let previewSource = previewStage.appendingPathComponent("recording.mp4")
        try FileManager.default.copyItem(at: result.url, to: previewSource)
        let previewLease = try store.begin(stagingDirectory: previewStage)
        let previewURL = try previewLease.publishFinalized(); previewLease.closeLease()
        let reopenedStore = try RecordingRecoveryStore(root: root)
        guard let preview = try reopenedStore.discover().candidates.first(where: { $0.sourceURL == previewURL }), preview.isPreview else {
            throw RecordingRecoveryError.io("Preview journal did not survive reopening.")
        }
        let reopened = try reopenedStore.open(preview); try reopened.dismissPreview(); reopened.closeLease()
        guard FileManager.default.fileExists(atPath: previewURL.path) else { throw RecordingRecoveryError.sourceChanged }
        try FileManager.default.removeItem(at: root)
        let removed = !FileManager.default.fileExists(atPath: root.path)
        guard removed else { throw RecordingRecoveryError.io("Fixture temporary directory was not removed.") }
        return Report(status: "passed", sourceCommit: Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            bundlePath: Bundle.main.bundlePath, captureStarted: false, cameraStarted: false, microphoneStarted: false,
            ownChildExitConfirmed: !process.isRunning, temporaryDirectoryRemoved: removed, killedOwnProcess: killed, terminationSignal: process.terminationStatus, discoveredCaptures: scan.candidates.count,
            recoveredDuration: result.recoveredDuration, decodedVideoFrames: counts.video, decodedAudioFrames: counts.audio,
            sourceUnchanged: true, fragmentCount: result.completeFragments, previewJournalRecovered: true)
        } catch {
            let originalError = error
            if let pid = launchedPID, process.isRunning, process.processIdentifier == pid {
                // Only the still-running Process spawned above can be signalled.
                _ = kill(pid, SIGKILL)
            }
            let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 5
            while process.isRunning, ProcessInfo.processInfo.systemUptime < cleanupDeadline {
                // A cancelled caller must still allow bounded child cleanup.
                _ = await Task.detached { try? await Task.sleep(nanoseconds: 20_000_000) }.value
            }
            guard !process.isRunning else {
                throw RecordingRecoveryError.io("Fixture child exit could not be confirmed; temporary media retained at \(root.path). Original failure: \(originalError)")
            }
            do { if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) } }
            catch { throw RecordingRecoveryError.io("Fixture temporary cleanup failed: \(error). Original failure: \(originalError)") }
            throw originalError
        }
    }

    private static func boundedData(_ url: URL, maximum: Int) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard size >= 0, size <= maximum else { throw RecordingRecoveryError.limitExceeded }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: maximum + 1) ?? Data()
        guard data.count == size else { throw RecordingRecoveryError.sourceChanged }
        return data
    }

    private static func runChild(environment: [String: String]) async throws {
        guard let raw = environment["PICSHOT_RECOVERY_FIXTURE_TOKEN"], let token = UUID(uuidString: raw), token.uuidString == raw,
              let path = environment["PICSHOT_RECOVERY_FIXTURE_ROOT"] else { throw RecordingRecoveryError.unsafePath }
        let expected = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-RecoveryFixture-" + token.uuidString).resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: path).standardizedFileURL
        guard root == expected else { throw RecordingRecoveryError.unsafePath }
        let movie = try await RecordingRecoverySyntheticMovie.make(in: root)
        // Wait for encoder output to contain multiple closed fragments before
        // announcing ready. Neither finishWriting nor cancelWriting is called.
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var fragments = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let prefix = try? RecordingRecoverySyntheticMovie.prefix(at: movie.url) { fragments = prefix.completeFragments }
            if fragments >= 3 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard fragments >= 3 else { throw RecordingRecoveryError.noRecoverableMedia }
        let ready = Ready(token: token, pid: ProcessInfo.processInfo.processIdentifier, frames: 60)
        try JSONEncoder().encode(ready).write(to: root.appendingPathComponent("fixture-ready.json"), options: .atomic)
        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            withExtendedLifetime(movie) {}
        }
    }

    /// Full native decode is practical for this <=6-second generated fixture.
    /// Output arrays are not retained; verify each track independently.
    static func decodeAllSyntheticMedia(_ url: URL) async throws -> (video: Int, audio: Int) {
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard videos.count == 1, audios.count == 1 else { throw RecordingRecoveryError.noRecoverableMedia }
        var videoCount = 0, audioCount = 0, audibleSample = false
        for track in videos + audios {
            let video = track.mediaType == .video
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: video
                ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                : [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
                   AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw RecordingRecoveryError.noRecoverableMedia }; reader.add(output)
            guard reader.startReading() else { throw reader.error ?? RecordingRecoveryError.noRecoverableMedia }
            var previous = CMTime.invalid, buffers = 0
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation(); buffers += 1
                guard buffers <= 2_000 else { reader.cancelReading(); throw RecordingRecoveryError.limitExceeded }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                guard time.isNumeric, !previous.isNumeric || CMTimeCompare(time, previous) > 0 else { throw RecordingRecoveryError.noRecoverableMedia }
                previous = time
                if video {
                    guard let pixel = CMSampleBufferGetImageBuffer(sample) else { throw RecordingRecoveryError.noRecoverableMedia }
                    CVPixelBufferLockBaseAddress(pixel, .readOnly)
                    let matches: Bool
                    if let base = CVPixelBufferGetBaseAddress(pixel) {
                        let location = base.advanced(by: (CVPixelBufferGetHeight(pixel) / 2) * CVPixelBufferGetBytesPerRow(pixel) + (CVPixelBufferGetWidth(pixel) / 2) * 4).assumingMemoryBound(to: UInt8.self)
                        matches = time.seconds < 3 ? Int(location[2]) > Int(location[0]) + 80 : Int(location[0]) > Int(location[2]) + 80
                    } else { matches = false }
                    CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
                    guard matches else { throw RecordingRecoveryError.io("Recovered synthetic frame color differs from its timestamped source pattern.") }
                    videoCount += 1
                } else {
                    audioCount += CMSampleBufferGetNumSamples(sample)
                    if let block = CMSampleBufferGetDataBuffer(sample) {
                        var length = 0, bytes: UnsafeMutablePointer<Int8>?
                        if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &bytes) == noErr,
                           let bytes {
                            for index in 0..<min(512, length / MemoryLayout<Float>.size) {
                                let value = UnsafeRawPointer(bytes).loadUnaligned(fromByteOffset: index * MemoryLayout<Float>.size, as: Float.self)
                                if value.isFinite, abs(value) > 0.01 { audibleSample = true; break }
                            }
                        }
                    }
                }
            }
            guard reader.status == .completed else { throw reader.error ?? RecordingRecoveryError.noRecoverableMedia }
        }
        guard audibleSample else { throw RecordingRecoveryError.io("Recovered synthetic audio decoded as silent or unreadable PCM.") }
        return (videoCount, audioCount)
    }
}

/// Shared fixture media generator. Finite synthetic red/blue video and audible
/// sine PCM feed the same AVAssetWriter fragment configuration as the real writer.
struct RecordingRecoverySyntheticMovie {
    let writer: AVAssetWriter
    let lease: RecordingRecoveryLease
    let url: URL
    static func make(in root: URL) async throws -> Self {
        let stage = try RecordingFileStorage.makeStagingDirectory(in: root)
        let url = stage.appendingPathComponent("recording.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 48, AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 128_000, AVVideoMaxKeyFrameIntervalKey: 10, AVVideoAllowFrameReorderingKey: false]])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
        video.expectsMediaDataInRealTime = true; audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(video), writer.canAdd(audio) else { throw RecordingRecoveryError.noRecoverableMedia }
        writer.add(video); writer.add(audio); RecordingRecoveryWriterSupport.configure(writer)
        guard writer.startWriting() else { throw writer.error ?? RecordingRecoveryError.noRecoverableMedia }
        let store = try RecordingRecoveryStore(root: root)
        let lease = try store.begin(stagingDirectory: stage, byteLimit: 16_777_216, durationLimit: 10)
        writer.startSession(atSourceTime: .zero)
        for index in 0..<60 {
            try Task.checkCancellation()
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !(video.isReadyForMoreMediaData && audio.isReadyForMoreMediaData) {
                guard writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline else { throw RecordingRecoveryError.noRecoverableMedia }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let time = CMTime(value: Int64(index), timescale: 10)
            guard video.append(try frame(time: time, index: index)), audio.append(try sound(time: time)) else {
                throw writer.error ?? RecordingRecoveryError.noRecoverableMedia
            }
            // Give hardware/software encoders real opportunities to flush.
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return Self(writer: writer, lease: lease, url: url)
    }
    static func prefix(at url: URL) throws -> RecordingRecoveryPrefix {
        let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        return try RecordingRecoveryMP4.completePrefix(fileSize: size) { offset, count in
            try file.seek(toOffset: UInt64(offset)); return try file.read(upToCount: count) ?? Data()
        }
    }
    private static func frame(time: CMTime, index: Int) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
              let buffer else { throw RecordingRecoveryError.noRecoverableMedia }
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let data = CVPixelBufferGetBaseAddress(buffer) else { CVPixelBufferUnlockBaseAddress(buffer, []); throw RecordingRecoveryError.noRecoverableMedia }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<48 { for x in 0..<64 {
            let pixel = data.advanced(by: y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
            pixel[0] = index < 30 ? 10 : 220; pixel[1] = UInt8(x * 2); pixel[2] = index < 30 ? 220 : 10; pixel[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) == noErr,
              let format else { throw RecordingRecoveryError.noRecoverableMedia }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 10), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { throw RecordingRecoveryError.noRecoverableMedia }
        return sample
    }
    private static func sound(time: CMTime) throws -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr,
              let description else { throw RecordingRecoveryError.noRecoverableMedia }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 19_200,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 19_200,
            flags: 0, blockBufferOut: &block) == noErr, let block else { throw RecordingRecoveryError.noRecoverableMedia }
        let values: [Float] = (0..<4_800).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000) * 0.25) }
        let status = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }
        guard status == noErr else { throw RecordingRecoveryError.noRecoverableMedia }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleSize = 4, sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
            sampleCount: 4_800, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr, let sample else { throw RecordingRecoveryError.noRecoverableMedia }
        return sample
    }
}
