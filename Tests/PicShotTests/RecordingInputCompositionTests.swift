import XCTest
import AppKit
import AVFoundation
import CoreImage
@testable import PicShot

@MainActor
final class RecordingInputCompositionTests: XCTestCase {
    func testDefaultOffPreservesSourceIdentityAndDoesNotRefresh() throws {
        let state = RecordingCompositionState(), source = try sample()
        let token = state.inputEffects.beginSession(options: RecordingInputEffectsOptions(), at: 10)
        XCTAssertFalse(state.inputEffects.recordClick(button: .left, normalizedPoint: .zero, at: 10, token: token))
        XCTAssertFalse(state.inputEffects.recordScroll(deltaX: 0, deltaY: 10, normalizedPoint: .zero, at: 10, token: token))
        XCTAssertFalse(state.inputEffects.recordShortcut(keyCode: 40, modifiers: [.command], at: 10, token: token))
        let compositor = try RecordingFrameCompositor(size: CGSize(width: 320, height: 180), state: state, clock: { 10 })
        let output = try XCTUnwrap(compositor.composite(source))
        XCTAssertTrue(output === source)
        XCTAssertFalse(compositor.needsRefresh)
        XCTAssertTrue(state.snapshot(at: 10).inputEffects.events.isEmpty)
    }

    func testExpiryRequestsOneCleanStaticFrameThenSettles() throws {
        let state = RecordingCompositionState(), clock = InputCompositionClock(10), source = try sample()
        let token = state.inputEffects.beginSession(options: RecordingInputEffectsOptions(clicks: true), at: 10)
        let compositor = try RecordingFrameCompositor(size: CGSize(width: 320, height: 180), state: state, clock: { clock.now })
        XCTAssertTrue(try XCTUnwrap(compositor.composite(source)) === source)
        XCTAssertFalse(compositor.needsRefresh)
        XCTAssertTrue(state.inputEffects.recordClick(button: .left, normalizedPoint: CGPoint(x: 0.25, y: 0.6), at: 10, token: token))
        XCTAssertTrue(compositor.needsRefresh)
        let drawn = try bytes(XCTUnwrap(compositor.composite(source)))
        XCTAssertNotEqual(drawn, try bytes(source))
        XCTAssertTrue(compositor.needsRefresh, "Live effects need time-based refresh even without new input")
        clock.set(10.701)
        XCTAssertTrue(compositor.needsRefresh, "Expiry must request a clean frame on a static desktop")
        XCTAssertTrue(try XCTUnwrap(compositor.composite(source)) === source)
        XCTAssertFalse(compositor.needsRefresh, "Cleared input must not keep the timer busy")
    }

    func testStopFreezesSampleTimeAndValuesAcrossTeardownAndReplacement() throws {
        let state = RecordingCompositionState(), clock = InputCompositionClock(10), source = try sample()
        let options = RecordingInputEffectsOptions(clicks: true, scrolls: true, shortcuts: true)
        let token = state.inputEffects.beginSession(options: options, at: 10)
        XCTAssertTrue(state.inputEffects.recordClick(button: .right, normalizedPoint: CGPoint(x: 0.25, y: 0.6), at: 10, token: token))
        XCTAssertTrue(state.inputEffects.recordShortcut(keyCode: 40, modifiers: [.command], at: 10, token: token))
        let compositor = try RecordingFrameCompositor(size: CGSize(width: 320, height: 180), state: state, clock: { clock.now })
        clock.set(10.1)
        XCTAssertEqual(state.snapshot(at: clock.now).inputEffects.sampledAt, 10.1)
        compositor.freeze()
        let frozen = try bytes(XCTUnwrap(compositor.composite(source)))
        XCTAssertNotEqual(frozen, try bytes(source))
        state.inputEffects.endSession(); clock.set(500)
        let replacement = state.inputEffects.beginSession(options: options, at: 500)
        XCTAssertTrue(state.inputEffects.recordClick(button: .left, normalizedPoint: CGPoint(x: 0.8, y: 0.8), at: 500, token: replacement))
        XCTAssertEqual(try bytes(XCTUnwrap(compositor.composite(source))), frozen,
                       "Stop must freeze fade age as well as event values")
        XCTAssertFalse(compositor.needsRefresh)
        compositor.releaseFrozenSnapshot()
        XCTAssertNotEqual(try bytes(XCTUnwrap(compositor.composite(source))), frozen)
    }

    func testPauseClearsCompositorAndRejectsQueuedInputAfterResume() throws {
        let state = RecordingCompositionState(), clock = InputCompositionClock(10), source = try sample()
        let token = state.inputEffects.beginSession(options: RecordingInputEffectsOptions(clicks: true, shortcuts: true), at: 10)
        let compositor = try RecordingFrameCompositor(size: CGSize(width: 320, height: 180), state: state, clock: { clock.now })
        XCTAssertTrue(state.inputEffects.recordClick(button: .left, normalizedPoint: CGPoint(x: 0.25, y: 0.6), at: 10, token: token))
        _ = try bytes(XCTUnwrap(compositor.composite(source)))
        clock.set(10.1); state.inputEffects.setPaused(true, at: clock.now)
        XCTAssertTrue(compositor.needsRefresh)
        XCTAssertTrue(try XCTUnwrap(compositor.composite(source)) === source)
        XCTAssertFalse(state.inputEffects.recordShortcut(keyCode: 40, modifiers: [.command], at: 10.2, token: token))
        clock.set(11.1); state.inputEffects.setPaused(false, at: clock.now)
        XCTAssertFalse(state.inputEffects.recordClick(button: .right, normalizedPoint: .zero, at: 10.5, token: token))
        XCTAssertTrue(try XCTUnwrap(compositor.composite(source)) === source)
        XCTAssertFalse(compositor.needsRefresh)
    }

    /// Actual native H.264 write and independent decode. This does not test
    /// global input monitoring, Secure Input or delivery from another app.
    func testSyntheticExportVerifiesPixelsTimingBoundsAndCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PicShot-Input-Export-Test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report: [String: Any]
        do { report = try await RecordingInputSmokeFixture.verify(evidenceDirectory: directory) }
        catch {
            if let json = try? String(contentsOf: directory.appendingPathComponent("recording-input.json"), encoding: .utf8) {
                print("Input smoke failure evidence: \(json.prefix(32_768))")
            }
            throw error
        }
        XCTAssertEqual(report["status"] as? String, "passed")
        XCTAssertEqual(report["decodedFrames"] as? Int, 22)
        XCTAssertGreaterThan(try XCTUnwrap(report["decodedPixelChecks"] as? Int), 80)
        XCTAssertEqual(report["temporaryDirectoryRemoved"] as? Bool, true)
        for key in ["captureStarted", "permissionRequested", "globalInputPosted"] {
            XCTAssertEqual(report[key] as? Bool, false, key)
        }
        let assertions = try XCTUnwrap(report["functionalAssertions"] as? [String: Bool])
        XCTAssertEqual(assertions.count, 13)
        XCTAssertTrue(assertions.values.allSatisfy { $0 })
        let timing = try XCTUnwrap(report["storedPacketTiming"] as? [String: Any])
        XCTAssertEqual(timing["packets"] as? Int, 22)
        XCTAssertEqual(timing["adjacent"] as? Bool, true)
        XCTAssertEqual(timing["positiveDurations"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(timing["endSeconds"] as? Double), 2.2, accuracy: 0.02)
        let state = try XCTUnwrap(report["stateChecks"] as? [String: Any])
        XCTAssertEqual(state["injectedEvents"] as? Int, 4_096)
        XCTAssertEqual(state["maximumRetainedEvents"] as? Int, 48)
        for key in ["releasedExportObjects", "releasedCancellationObjects"] {
            let objects = try XCTUnwrap(report[key] as? [String: Bool])
            XCTAssertEqual(objects.count, 4); XCTAssertTrue(objects.values.allSatisfy { !$0 })
        }
        let cancellation = try XCTUnwrap(report["cancellation"] as? [String: Any])
        XCTAssertEqual(cancellation["cancelledWhilePaused"] as? Bool, true)
        XCTAssertEqual(cancellation["repeatDiscardSucceeded"] as? Bool, true)
        XCTAssertEqual(cancellation["writerRetainedFrames"] as? Int, 0)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       Set(["recording-input.json", "recording-input.mp4", "recording-input.png"]))
        for name in ["recording-input.mp4", "recording-input.png"] {
            let bytes = try XCTUnwrap(directory.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize)
            XCTAssertGreaterThan(bytes, 0); XCTAssertLessThanOrEqual(bytes, 4 * 1_024 * 1_024)
        }
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("recording-input.json"))) as? [String: Any])
        XCTAssertEqual(stored["status"] as? String, "passed")
    }

    func testCancelledFixtureWritesFailureAndRemovesItsOwnedRoot() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PicShot-Input-Cancel-Test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await RecordingInputSmokeFixture.verify(evidenceDirectory: directory)
        }
        do { _ = try await task.value; XCTFail("Cancelled fixture unexpectedly passed") }
        catch is CancellationError { }
        let json = try Data(contentsOf: directory.appendingPathComponent("recording-input.json"))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(report["status"] as? String, "failed")
        XCTAssertEqual(report["temporaryDirectoryRemoved"] as? Bool, true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["recording-input.json"])
    }

    func testFixtureRefusesToReplaceExistingWitness() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PicShot-Input-Preserve-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recording-input.mp4"), sentinel = Data("existing evidence".utf8)
        try sentinel.write(to: url)
        do { _ = try await RecordingInputSmokeFixture.verify(evidenceDirectory: directory); XCTFail("Existing witness was accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Refusing to replace")) }
        XCTAssertEqual(try Data(contentsOf: url), sentinel)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["recording-input.mp4"])
    }

    private func sample() throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA, attributes, &pixels), kCVReturnSuccess)
        let image = try XCTUnwrap(pixels), srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        CIContext(options: [.useSoftwareRenderer: true]).render(CIImage(color: CIColor(red: 0, green: 0, blue: 0)),
            to: image, bounds: CGRect(x: 0, y: 0, width: 320, height: 180), colorSpace: srgb)
        CVBufferSetAttachment(image, kCVImageBufferCGColorSpaceKey, srgb, .shouldPropagate)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 10), presentationTimeStamp: CMTime(seconds: 10, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &result), noErr)
        return try XCTUnwrap(result)
    }

    private func bytes(_ sample: CMSampleBuffer) throws -> [UInt8] {
        let image = CIImage(cvPixelBuffer: try XCTUnwrap(CMSampleBufferGetImageBuffer(sample)))
        var output = [UInt8](repeating: 0, count: 320 * 180 * 4)
        output.withUnsafeMutableBytes {
            CIContext(options: [.useSoftwareRenderer: true]).render(image, toBitmap: $0.baseAddress!, rowBytes: 320 * 4,
                bounds: CGRect(x: 0, y: 0, width: 320, height: 180), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return output
    }
}

private final class InputCompositionClock {
    private let lock = NSLock()
    private var value: Double
    init(_ value: Double) { self.value = value }
    var now: Double { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Double) { lock.lock(); defer { lock.unlock() }; self.value = value }
}
