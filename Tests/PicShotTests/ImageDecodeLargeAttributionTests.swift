import XCTest
import AppKit
import PicShotCodecCore
@testable import PicShot

@MainActor
final class ImageDecodeLargeAttributionTests: XCTestCase {
    func testClosedProfilesSelectorsAndNoOverrides() throws {
        XCTAssertNil(try ImageDecodeLargeAttributionFixture.request([:]))
        for profile in ImageDecodeDiagnosticProfile.allCases {
            let prepare = try ImageDecodeLargeAttributionFixture.request(["PICSHOT_IMAGE_DECODE_LARGE_MODE": "prepare", "PICSHOT_IMAGE_DECODE_LARGE_PROFILE": profile.rawValue])
            XCTAssertEqual(prepare?.profile, profile); XCTAssertNil(prepare?.inputDirectory)
            for mode in ["production-control", "isolated-decode"] {
                XCTAssertEqual(try ImageDecodeLargeAttributionFixture.request(["PICSHOT_IMAGE_DECODE_LARGE_MODE": mode,
                    "PICSHOT_IMAGE_DECODE_LARGE_PROFILE": profile.rawValue, "PICSHOT_IMAGE_DECODE_LARGE_INPUT_DIRECTORY": "/tmp/prepared"])?.mode.rawValue, mode)
            }
        }
        for key in ["PICSHOT_IMAGE_DECODE_LARGE_WIDTH", "PICSHOT_IMAGE_DECODE_LARGE_CYCLES", "PICSHOT_IMAGE_DECODE_LARGE_EXECUTABLE",
                    "PICSHOT_IMAGE_DRAW_HELPER_MODE", "PICSHOT_IMAGE_RELIEF_MODE", "PICSHOT_IMAGE_BACKING_MODE", "PICSHOT_CODEC_ATTRIBUTION_MODE"] {
            XCTAssertThrowsError(try ImageDecodeLargeAttributionFixture.request(["PICSHOT_IMAGE_DECODE_LARGE_MODE": "isolated-decode",
                "PICSHOT_IMAGE_DECODE_LARGE_PROFILE": "4k", "PICSHOT_IMAGE_DECODE_LARGE_INPUT_DIRECTORY": "/tmp/prepared", key: "1"]))
        }
        XCTAssertThrowsError(try ImageDecodeLargeAttributionFixture.request(["PICSHOT_IMAGE_DECODE_LARGE_MODE": "native-ui-isolated", "PICSHOT_IMAGE_DECODE_LARGE_PROFILE": "4k", "PICSHOT_IMAGE_DECODE_LARGE_INPUT_DIRECTORY": "/tmp/prepared"]))
        XCTAssertThrowsError(try ImageDecodeLargeAttributionFixture.request(["PICSHOT_IMAGE_DECODE_LARGE_MODE": "isolated-decode", "PICSHOT_IMAGE_DECODE_LARGE_PROFILE": "5k", "PICSHOT_IMAGE_DECODE_LARGE_INPUT_DIRECTORY": "relative"]))
        XCTAssertThrowsError(try ImageDecodeLargeAttributionFixture.request(["PICSHOT_IMAGE_DECODE_LARGE_MODE": "prepare", "PICSHOT_IMAGE_DECODE_LARGE_PROFILE": "8k"]))
    }
    func testLargeOwnedProviderActuallyDrawsExactPixelsAndReleases() throws {
        let profile = ImageDecodeDiagnosticProfile.fiveK
        var raw = Data(count: profile.rasterBytes)
        raw.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for offset in stride(from: 0, to: bytes.count, by: 4) { bytes[offset] = 128; bytes[offset + 3] = 128 }
        }
        let providers = ImageDrawAllocationTracker(maximumAllocations: 2, allocationBytes: profile.rasterBytes)
        let destinations = ImageDrawAllocationTracker(maximumAllocations: 1, allocationBytes: profile.rasterBytes)
        let destination = try ImageDrawDestination(width: profile.previewWidth, height: profile.previewHeight, tracker: destinations)
        for _ in 0..<2 {
            try autoreleasepool {
                let image = try ImageDecodeLargeRaster.ownedImage(raw, profile: profile, tracker: providers)
                let drawn = try destination.drawAndValidate(image, reference: raw, tolerance: 0)
                XCTAssertEqual(drawn.maximumDifference, 0); XCTAssertEqual(drawn.sha256, ImageDecodeDiagnosticLimits.digest(raw))
            }
        }
        destination.close()
        XCTAssertEqual(providers.snapshot().allocations, 2); XCTAssertEqual(providers.snapshot().releaseCallbacks, 2)
        XCTAssertEqual(providers.snapshot().deallocations, 2); XCTAssertEqual(providers.snapshot().activeBytes, 0)
        XCTAssertEqual(destinations.snapshot().deallocations, 1)
        XCTAssertThrowsError(try ImageDecodeLargeRaster.ownedImage(Data([0]), profile: profile, tracker: providers))
    }
    func testPreviewObserverUsesValuesAndClearsAtDetach() throws {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 120, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = ImageExportPreviewView(frame: .init(x: 0, y: 0, width: 100, height: 60))
        window.contentView!.addSubview(view)
        var callbacks = 0
        view.diagnosticDrawObserver = { _ in callbacks += 1 }
        XCTAssertNotNil(view.diagnosticDrawObserver)
        view.removeFromSuperview()
        XCTAssertNil(view.diagnosticDrawObserver)
        XCTAssertEqual(callbacks, 0)
        window.close()
    }
    func testMainQueueProbeDrainsWithoutAnUnboundedCallbackQueue() async throws {
        let probe = ImageDecodeMainQueueProbe()
        try await Task.sleep(nanoseconds: 80_000_000)
        probe.stop()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { c.resume() } }
        let result = probe.snapshot()
        XCTAssertGreaterThan(result.samples, 0); XCTAssertEqual(result.outstandingCallbacks, 0)
        XCTAssertEqual(result.histogramTenMillisecondBins.count, 64)
        XCTAssertEqual(result.histogramTenMillisecondBins.reduce(0, +), result.samples)
        XCTAssertTrue(result.maximumDelaySeconds.isFinite)
    }
    func testUIWorkerStateIsBoundedAndStoresNoImageInRecords() throws {
        let state = ImageDecodeUIState()
        for index in 0..<16 {
            state.plan(.normal, requestedAt: Double(index))
            let begun = try state.begin(); XCTAssertEqual(begun.0, index)
            state.stage(index, "pixelsValidated", Double(index + 1))
            state.finish(index, outcome: "completed", process: nil, imageIdentity: "scalar-\(index)", pixelsSHA256: String(repeating: "0", count: 64))
        }
        XCTAssertThrowsError(try state.begin())
        XCTAssertEqual(state.snapshot().records.count, 16)
        let data = try JSONEncoder().encode(state.snapshot().records)
        XCTAssertLessThan(data.count, 32_768)
        XCTAssertFalse(state.lateResultReleased()); state.releaseLateResult(); XCTAssertTrue(state.lateResultReleased())
    }
    func testBoundedLargestUIReportShapeAndExplicitOverflowRejection() throws {
        let live = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ImageDecodeMemoryReading.current())) as? [String: Any])
        func stress(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] { return dictionary.mapValues(stress) }
            if value is NSNumber { return UInt64.max }
            return value
        }
        let sample = stress(live)
        let child: [String: Any] = ["memory": sample, "profile": "5k", "schema": ImageDecodeDiagnosticLimits.largeSchema,
            "rawSHA256": String(repeating: "f", count: 64), "helperEntryUptimeSeconds": Double.greatestFiniteMagnitude,
            "responsePreparedUptimeSeconds": Double.greatestFiniteMagnitude]
        let pair: [String: Any] = ["child": child, "parentAtReceipt": sample, "receiptSkewSeconds": Double.greatestFiniteMagnitude]
        let process: [String: Any] = ["phases": Array(repeating: pair, count: 12), "terminal": child,
            "parentBoundaries": Dictionary(uniqueKeysWithValues: (0..<10).map { ("boundary\($0)", sample) }),
            "jobDirectory": String(repeating: "p", count: 1024)]
        let worker: [String: Any] = ["process": process, "imageIdentity": String(repeating: "i", count: 64)]
        let report: [String: Any] = ["workers": Array(repeating: worker, count: 16), "scope": String(repeating: "s", count: 16_384)]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("image-large-report-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ImageDecodeLargeSupport.write(report, to: url)
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, ImageDecodeLargeSupport.reportBytes)
        XCTAssertThrowsError(try ImageDecodeLargeSupport.write(["tooLarge": String(repeating: "x", count: ImageDecodeLargeSupport.reportBytes)], to: url))
    }
    func testVerifierTimingRejectsSameInvalidBundleWithAndWithoutObserver() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("decode-invalid-\(UUID().uuidString).app")
        XCTAssertThrowsError(try CodecHelperExecutable.verified(bundleURL: root))
        let count = ImageDecodeValidationCallbackCounter()
        XCTAssertThrowsError(try CodecHelperExecutable.verified(bundleURL: root, timing: { _ in count.record() }))
        XCTAssertEqual(count.value, 0)
    }
}
private final class ImageDecodeValidationCallbackCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func record() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
