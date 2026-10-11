import XCTest
import AppKit
@testable import PicShot

/// Structural/native-byte tests only. They are not the 2+8 release resource run.
@MainActor
final class LiveScrollResourceFixtureTests: XCTestCase {
    private func input() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-LiveResourceTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let canonicalRoot = root.resolvingSymlinksInPath()
        let raw = canonicalRoot.appendingPathComponent("fixture.bgra")
        do { try LiveScrollResourceFixture.prepareForVerification(raw); return (canonicalRoot, raw) }
        catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    func testFixedWorkloadHasExactReversalFinalRemainderAndBytes() {
        let offsets = LiveScrollResourceFixture.offsets
        XCTAssertEqual(offsets.count, 218)
        XCTAssertEqual(zip(offsets.dropLast(), offsets.dropFirst()).filter { $0.1 < $0.0 }.count, 12)
        XCTAssertEqual(offsets.first, 0); XCTAssertEqual(offsets.last, 6176)
        XCTAssertEqual(Array(offsets.suffix(2)), [6144, 6176])
        XCTAssertEqual(LiveScrollResourceFixture.viewportBytes, 4_915_200)
        XCTAssertEqual(LiveScrollResourceFixture.outputBytes, 36_536_320)
    }

    func testOwnedSourceBytesMatchExistingNativeNormalizersAndIndependentChannelOracle() async throws {
        let (root, raw) = try input(); defer { try? FileManager.default.removeItem(at: root) }
        let report = try await LiveScrollResourceFixture.byteConversionFidelity(raw)
        XCTAssertEqual(report["passed"] as? Bool, true)
        XCTAssertEqual(report["bytesCompared"] as? Int, 4_915_200)
    }

    func testStopDuringReadConfirmsDrainWithoutDeliveringAnotherGeneration() async throws {
        let (root, raw) = try input(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = LiveScrollResourceAllocationLedger()
        let source = try LiveScrollResourceFrameSource(input: raw, screen: XCTUnwrap(NSScreen.main), ledger: ledger)
        try await source.start()
        let read = Task { try await source.nextFrame(timeout: 0.75) }
        for _ in 0..<1000 where source.snapshot.activeReads == 0 { await Task.yield() }
        XCTAssertEqual(source.snapshot.activeReads, 1)
        try await source.stop()
        do { _ = try await read.value; XCTFail("Stopped generation delivered a frame") }
        catch is CancellationError { }
        XCTAssertEqual(source.snapshot.state, "stopped")
        XCTAssertEqual(source.snapshot.activeReads, 0)
        XCTAssertTrue(source.snapshot.descriptorCloseConfirmed)
        XCTAssertFalse(source.snapshot.descriptorOpen)
        XCTAssertEqual(source.snapshot.successfulFrames, 0)
        XCTAssertEqual(ledger.snapshot().liveImages, 0)
        try await source.stop()
        XCTAssertEqual(source.snapshot.confirmedStops, 1)
    }

    func testProviderLifetimeContinuesAcrossStopUntilLastImageOwnerReleases() async throws {
        let (root, raw) = try input(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = LiveScrollResourceAllocationLedger()
        var source: LiveScrollResourceFrameSource? = try LiveScrollResourceFrameSource(input: raw,
            screen: XCTUnwrap(NSScreen.main), ledger: ledger)
        weak var weakSource = source
        try await source!.start()
        var frame = try await source!.nextFrame(timeout: 0.75)
        XCTAssertEqual(frame?.image.width, 1280)
        XCTAssertEqual(ledger.snapshot().liveBytes, 4_915_200)
        try await source!.stop()
        source = nil
        XCTAssertNil(weakSource)
        XCTAssertEqual(ledger.snapshot().liveImages, 1, "Stop must not invalidate handed-off immutable pixels")
        frame = nil
        XCTAssertEqual(ledger.snapshot().liveImages, 0)
        XCTAssertEqual(ledger.snapshot().liveBytes, 0)
        XCTAssertEqual(ledger.snapshot().allocatedImages, ledger.snapshot().releasedImages)
    }
}
