import XCTest
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
@testable import PicShot

final class GIFFrameExtractionTests: XCTestCase {
    func testDiagnosticStrategyNamesRemainExplicit() {
        XCTAssertEqual(GIFFrameExtraction.allCases.map(\.rawValue), ["async-baseline", "scoped-sync-candidate"])
        XCTAssertNil(GIFFrameExtraction(rawValue: "sync"))
    }

    func testSamplingTimeKeepsDecimalFrameBoundariesOnTheNearestExactTick() throws {
        // Native regression: the legacy Double constructor converted nominal
        // 0.1/0.2 seconds to 59/119 ticks, selecting the preceding video frame.
        // Require exact request ticks independently of decoder tolerance.
        let cases: [(duration: Double, frames: Int, indices: [Int])] = [
            (2.4, 24, [1, 2, 8, 16]), (1.2, 12, [1, 2, 8])
        ]
        for test in cases {
            let options = GIFExportOptions(frameRate: 10, maximumDimension: 40,
                maximumDuration: test.duration, maximumFrames: test.frames)
            let plan = try GIFFramePlan(duration: test.duration, options: options)
            XCTAssertEqual(plan.frameCount, test.frames)
            for index in test.indices {
                let requested = plan.samplingTime(for: index)
                XCTAssertEqual(requested.timescale, 600)
                XCTAssertEqual(requested.value, Int64(index * 60), "Boundary frame \(index) in \(test.duration)-second plan")
                XCTAssertEqual(CMTimeCompare(requested, CMTime(value: Int64(index), timescale: 10)), 0)
                XCTAssertFalse(requested.flags.contains(.hasBeenRounded))
            }
            XCTAssertEqual((0..<plan.frameCount).map { plan.delay(for: $0) }, Array(repeating: 0.1, count: test.frames),
                "Fixing request precision must not change GIF playback delays")
        }
    }

    func testSamplingTimePreservesFractionalCappedAndTrimmedPlanBounds() throws {
        let cases: [(duration: Double, options: GIFExportOptions, frames: Int)] = [
            (1_001.0 / 300, .init(frameRate: 30_000.0 / 1_001, maximumDimension: 40, maximumDuration: 60, maximumFrames: 600), 100),
            (7.3, .init(frameRate: 24, maximumDimension: 40, maximumDuration: 1.25, maximumFrames: 600), 30),
            (90, .init(frameRate: 30, maximumDimension: 40, maximumDuration: 59.97, maximumFrames: 7), 7),
            (0.101, .init(frameRate: 30, maximumDimension: 40, maximumDuration: 1, maximumFrames: 600), 4)
        ]
        for test in cases {
            let plan = try GIFFramePlan(duration: test.duration, options: test.options)
            XCTAssertEqual(plan.frameCount, test.frames)
            XCTAssertEqual(plan.duration, min(test.duration, test.options.maximumDuration))
            var previous: CMTime?
            for index in 0..<plan.frameCount {
                let requested = plan.samplingTime(for: index)
                XCTAssertTrue(requested.isNumeric)
                XCTAssertEqual(requested.timescale, 600)
                XCTAssertGreaterThanOrEqual(requested.seconds, 0)
                XCTAssertLessThan(requested.seconds, plan.duration, "The final request must stay within the source interval")
                XCTAssertEqual(requested.seconds, plan.time(for: index), accuracy: 1.0 / 1_200 + 1e-12)
                if let previous { XCTAssertGreaterThan(CMTimeCompare(requested, previous), 0) }
                previous = requested
            }
            let playback = (0..<plan.frameCount).reduce(0.0) { $0 + plan.delay(for: $1) }
            XCTAssertEqual(playback, (plan.duration * 100).rounded() / 100, accuracy: 1e-12)
        }
        let fractional = try GIFFramePlan(duration: 1_001.0 / 300, options: cases[0].options)
        XCTAssertEqual(fractional.samplingTime(for: 1).value, 20)
        XCTAssertEqual(fractional.samplingTime(for: 26).value, 521)
        XCTAssertEqual(fractional.samplingTime(for: 50).value, 1_001)
    }

    func testScopedExtractionPreservesFramePixelsTimingAndDownscaleForPreferredTransforms() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transforms: [(String, CGAffineTransform, Int, Int)] = [
            ("identity", .identity, 32, 24),
            ("rotate90", CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 48, ty: 0), 24, 32),
            ("mirror", CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 64, ty: 0), 32, 24)
        ]
        let options = GIFExportOptions(frameRate: 12, maximumDimension: 32, maximumDuration: 2, maximumFrames: 24)
        for (name, transform, width, height) in transforms {
            let source = try await makeMovie(in: root, transform: transform)
            let baselineURL = root.appendingPathComponent(name + "-baseline.gif")
            let candidateURL = root.appendingPathComponent(name + "-candidate.gif")
            let baselineProgress = GIFExtractionProbe()
            let candidateProgress = GIFExtractionProbe()
            _ = try await GIFInProcessEngine.exportDirect(sourceURL: source, destinationURL: baselineURL, options: options,
                                              frameExtraction: .asynchronous) { baselineProgress.record($0) }
            _ = try await GIFInProcessEngine.exportDirect(sourceURL: source, destinationURL: candidateURL, options: options,
                                              frameExtraction: .scopedSynchronous) { candidateProgress.record($0) }
            let baseline = try decoded(baselineURL)
            let candidate = try decoded(candidateURL)
            XCTAssertEqual(candidate.width, width, name)
            XCTAssertEqual(candidate.height, height, name)
            XCTAssertEqual(candidate.frames.count, 24, name)
            XCTAssertEqual(candidate, baseline, "Frame/time/transform semantics changed for \(name)")
            XCTAssertEqual(candidate.delays.reduce(0, +), 2, accuracy: 0.02)
            XCTAssertGreaterThan(Set(candidate.frames).count, 12, "Authored frames must actually change")
            try assertProgress(baselineProgress.values, frames: 24)
            try assertProgress(candidateProgress.values, frames: 24)
            try assertNoStaging(root)
        }
    }

    func testScopedExtractionKeepsFrameCapDurationTrimAndDefaultBaselineSemantics() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await makeMovie(in: root)
        let options = GIFExportOptions(frameRate: 12, maximumDimension: 32, maximumDuration: 1, maximumFrames: 3)
        let expectedPlan = try GIFFramePlan(duration: 2, options: options)
        var outputs: [GIFExtractedFrames] = []
        for strategy in GIFFrameExtraction.allCases {
            let url = root.appendingPathComponent(strategy.rawValue + ".gif")
            _ = try await GIFInProcessEngine.exportDirect(sourceURL: source, destinationURL: url, options: options, frameExtraction: strategy)
            outputs.append(try decoded(url))
        }
        let defaultURL = root.appendingPathComponent("default.gif")
        _ = try await GIFInProcessEngine.exportDirect(sourceURL: source, destinationURL: defaultURL, options: options)
        XCTAssertEqual(try decoded(defaultURL), outputs[0], "The unmeasured candidate must not silently replace the helper engine default")
        XCTAssertEqual(outputs[0], outputs[1])
        XCTAssertEqual(outputs[1].frames.count, 3)
        XCTAssertEqual(outputs[1].delays, (0..<3).map { expectedPlan.delay(for: $0) })
        XCTAssertEqual(outputs[1].delays.reduce(0, +), 1, accuracy: 0.001)
        try assertNoStaging(root)
    }

    func testBothStrategiesCancelAtFirstAndLastFrameWithoutPublishingPartialGIF() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await makeMovie(in: root)
        let sourceBefore = try Data(contentsOf: source)
        let options = GIFExportOptions(frameRate: 12, maximumDimension: 32, maximumDuration: 2, maximumFrames: 24)
        for strategy in GIFFrameExtraction.allCases {
            for frame in [1, 24] {
                let output = root.appendingPathComponent("cancel-\(strategy.rawValue)-\(frame).gif")
                let progress = GIFExtractionProbe()
                let task = Task {
                    try await GIFInProcessEngine.exportDirect(sourceURL: source, destinationURL: output, options: options,
                                                  frameExtraction: strategy) { value in
                        progress.record(value)
                        if value >= Double(frame) / 25, value < 1 { withUnsafeCurrentTask { $0?.cancel() } }
                    }
                }
                do { _ = try await task.value; XCTFail("Cancelled \(strategy) export published") }
                catch is CancellationError { }
                XCTAssertEqual(progress.values.count, frame + 1)
                XCTAssertEqual(progress.values.last, Double(frame) / 25)
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
                XCTAssertEqual(try Data(contentsOf: source), sourceBefore)
                try assertNoStaging(root)
            }
        }
        XCTAssertFalse(Task.isCancelled)
    }

    func testScopedExtractionHonorsCancellationBeforeAnyFrameAndRejectsLateDestinationCollision() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await makeMovie(in: root)
        let options = GIFExportOptions(frameRate: 12, maximumDimension: 32, maximumDuration: 2, maximumFrames: 24)
        let cancelled = root.appendingPathComponent("cancel-before-frame.gif")
        let task = Task {
            try await GIFInProcessEngine.exportDirect(sourceURL: source, destinationURL: cancelled, options: options,
                                          frameExtraction: .scopedSynchronous) { value in
                if value == 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("Pre-frame cancellation must fail") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))
        try assertNoStaging(root)

        let collision = root.appendingPathComponent("concurrent.gif")
        let original = Data("independent destination must survive".utf8)
        let probe = GIFExtractionCollision()
        do {
            _ = try await GIFInProcessEngine.exportDirect(sourceURL: source, destinationURL: collision, options: options,
                                              frameExtraction: .scopedSynchronous) { value in
                if value > 0, value < 1, probe.claim() {
                    do { try original.write(to: collision, options: .atomic) }
                    catch { probe.record(error) }
                }
            }
            XCTFail("A destination created during export must not be overwritten")
        } catch {
            XCTAssertNil(probe.failure)
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, CocoaError.Code.fileWriteFileExists.rawValue)
        }
        XCTAssertTrue(probe.claimed)
        XCTAssertEqual(try Data(contentsOf: collision), original)
        try assertNoStaging(root)
    }

    @MainActor
    func testMainActorCallerKeepsCandidateFrameCallbacksOffTheMainThread() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await makeMovie(in: root)
        let output = root.appendingPathComponent("off-main.gif")
        let progress = GIFExtractionProbe()
        _ = try await GIFInProcessEngine.exportDirect(sourceURL: source, destinationURL: output,
            options: .init(frameRate: 12, maximumDimension: 32, maximumDuration: 2, maximumFrames: 24),
            frameExtraction: .scopedSynchronous) { progress.record($0) }
        XCTAssertEqual(progress.frameCallbackCount, 24)
        XCTAssertEqual(progress.mainThreadFrameCallbackCount, 0,
                       "Synchronous extraction must not inherit the UI caller's executor")
        XCTAssertEqual(try decoded(output).frames.count, 24)
    }

    private func assertProgress(_ values: [Double], frames: Int) throws {
        XCTAssertEqual(values.count, frames + 2)
        XCTAssertEqual(values.first, 0); XCTAssertEqual(values.last, 1)
        XCTAssertTrue(values.allSatisfy { $0.isFinite && (0...1).contains($0) })
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0.0 <= $0.1 })
        XCTAssertEqual(values.filter { $0 == 1 }.count, 1)
    }
    private func assertNoStaging(_ root: URL) throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".picshot-") })
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-GIF-Extraction-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func decoded(_ url: URL) throws -> GIFExtractedFrames {
        try autoreleasepool {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, options))
            var frames: [Data] = [], delays: [Double] = []
            var width = 0, height = 0
            for index in 0..<CGImageSourceGetCount(source) {
                try autoreleasepool {
                    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, options))
                    width = image.width; height = image.height
                    var pixels = [UInt8](repeating: 0, count: width * height * 4)
                    try pixels.withUnsafeMutableBytes { storage in
                        let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                    }
                    frames.append(Data(pixels))
                    let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, options) as? [CFString: Any])
                    let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
                    delays.append(try XCTUnwrap((gif[kCGImagePropertyGIFUnclampedDelayTime] ?? gif[kCGImagePropertyGIFDelayTime]) as? NSNumber).doubleValue)
                }
            }
            return GIFExtractedFrames(width: width, height: height, frames: frames, delays: delays)
        }
    }

    /// Original asymmetric, changing 64x48 fixture, with explicit track transform.
    /// Short-GOP H.264 and exact 12-FPS timestamps let both APIs sample the same
    /// requested frames without changing the production tolerance policy.
    private func makeMovie(in directory: URL, transform: CGAffineTransform = .identity) async throws -> URL {
        let url = directory.appendingPathComponent("asymmetric-" + UUID().uuidString + ".mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 12, AVVideoAllowFrameReorderingKey: false]
        ])
        input.transform = transform
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else { throw GIFExportError.failed("Authored source input is unavailable") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? GIFExportError.noVideo }
        writer.startSession(atSourceTime: .zero)
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        for index in 0..<24 {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline else {
                    throw writer.error ?? GIFExportError.failed("Authored source writer timed out")
                }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            try autoreleasepool {
                var optional: CVPixelBuffer?
                XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
                    attributes as CFDictionary, &optional), kCVReturnSuccess)
                let buffer = try XCTUnwrap(optional)
                guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw GIFExportError.noVideo }
                do {
                    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                    let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
                    let stride = CVPixelBufferGetBytesPerRow(buffer)
                    for y in 0..<48 { for x in 0..<64 {
                        let offset = y * stride + x * 4
                        pixels[offset] = UInt8((y * 3 + index * 7) % 256)
                        pixels[offset + 1] = UInt8((x * 2 + index * 5) % 256)
                        pixels[offset + 2] = UInt8((x + y + index * 11) % 256)
                        pixels[offset + 3] = 255
                        if x < 12, y < 18 { pixels[offset] = 0; pixels[offset + 1] = 0; pixels[offset + 2] = 255 }
                        if x > 45, y > 28 { pixels[offset] = 255; pixels[offset + 1] = 0; pixels[offset + 2] = 0 }
                    } }
                }
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 12)) else {
                    throw writer.error ?? GIFExportError.noVideo
                }
            }
        }
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
        input.markAsFinished(); writer.finishWriting { }
        while writer.status == .writing {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw GIFExportError.failed("Source finalization timed out") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard writer.status == .completed else { throw writer.error ?? GIFExportError.noVideo }
        return url
    }
}

private struct GIFExtractedFrames: Equatable {
    let width: Int
    let height: Int
    let frames: [Data]
    let delays: [Double]
}
private final class GIFExtractionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []
    private var frameCallbacks = 0
    private var mainFrameCallbacks = 0
    func record(_ value: Double) {
        lock.lock(); defer { lock.unlock() }; recorded.append(value)
        if value > 0, value < 1 { frameCallbacks += 1; if Thread.isMainThread { mainFrameCallbacks += 1 } }
    }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return recorded }
    var frameCallbackCount: Int { lock.lock(); defer { lock.unlock() }; return frameCallbacks }
    var mainThreadFrameCallbackCount: Int { lock.lock(); defer { lock.unlock() }; return mainFrameCallbacks }
}
private final class GIFExtractionCollision: @unchecked Sendable {
    private let lock = NSLock()
    private var didClaim = false
    private var error: Error?
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if didClaim { return false }; didClaim = true; return true }
    func record(_ value: Error) { lock.lock(); defer { lock.unlock() }; error = value }
    var failure: Error? { lock.lock(); defer { lock.unlock() }; return error }
    var claimed: Bool { lock.lock(); defer { lock.unlock() }; return didClaim }
}
