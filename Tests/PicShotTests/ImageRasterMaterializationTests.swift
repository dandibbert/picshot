import XCTest
import Foundation
import CoreGraphics
@testable import PicShot

@MainActor
final class ImageRasterMaterializationTests: XCTestCase {
    func testExplicitSelectorsAndFixedBounds() async throws {
        XCTAssertNil(try ImageRasterMaterializationFixture.request(environment: [:]))
        XCTAssertNil(try await ImageRasterMaterializationFixture.runIfRequested(evidenceDirectory: FileManager.default.temporaryDirectory, environment: [:]))
        XCTAssertEqual(ImageRasterMaterializationFixture.width, 768)
        XCTAssertEqual(ImageRasterMaterializationFixture.height, 576)
        XCTAssertEqual(ImageRasterMaterializationFixture.rasterBytes, 1_769_472)
        XCTAssertEqual(ImageRasterMaterializationFixture.warmupCycles, 2)
        XCTAssertEqual(ImageRasterMaterializationFixture.measuredCycles, 12)
        XCTAssertEqual(ImageRasterMaterializationFixture.pixelTolerance, 2)
        XCTAssertEqual(ImageRasterMaterializationFixture.cooperativeDeadlineSeconds, 45)
        XCTAssertEqual(ImageRasterMaterializationFixture.requiredOuterDeadlineSeconds, 60)
        XCTAssertEqual(ImageRasterMaterializationFixture.Mode.allCases.map(\.rawValue), ["prepare-inputs", "production-draw", "imageio-no-cache-draw", "owned-rgba-draw"])
        for mode in ImageRasterMaterializationFixture.Mode.allCases {
            var env = ["PICSHOT_IMAGE_DRAW_MODE": mode.rawValue]
            if mode != .prepareInputs { env["PICSHOT_IMAGE_DRAW_INPUT_DIRECTORY"] = "/tmp/prepared" }
            XCTAssertEqual(try ImageRasterMaterializationFixture.request(environment: env)?.mode, mode)
        }
        for key in ["PICSHOT_IMAGE_DRAW_WIDTH", "PICSHOT_IMAGE_DRAW_CYCLES", "PICSHOT_IMAGE_DRAW_TOLERANCE",
                    "PICSHOT_IMAGE_RELIEF_MODE", "PICSHOT_IMAGE_BACKING_MODE", "PICSHOT_CODEC_ATTRIBUTION_MODE",
                    "PICSHOT_GIF_DIAGNOSTIC_MODE", "PICSHOT_UI_PREVIEW_ONLY", "PICSHOT_SMOKE_GIF_RESOURCES"] {
            XCTAssertThrowsError(try ImageRasterMaterializationFixture.request(environment:
                ["PICSHOT_IMAGE_DRAW_MODE": "production-draw", "PICSHOT_IMAGE_DRAW_INPUT_DIRECTORY": "/tmp/prepared", key: "1"]))
        }
        XCTAssertThrowsError(try ImageRasterMaterializationFixture.request(environment: ["PICSHOT_IMAGE_DRAW_MODE": "lazy-no-draw"]))
        XCTAssertThrowsError(try ImageRasterMaterializationFixture.request(environment: ["PICSHOT_IMAGE_DRAW_MODE": "production-draw"]))
    }

    func testEveryVariantActuallyDrawsAndReadsAllPixelsIntoOneDestination() throws {
        let artifact = try preparedArtifact()
        let raw = try CodecExportResourceFixture.raster(artifact.firstPreview)
        for mode in [ImageRasterMaterializationFixture.Mode.productionDraw, .imageIONoCacheDraw, .ownedRGBADraw] {
            let destinationTracker = ImageDrawAllocationTracker(maximumAllocations: 1, allocationBytes: raw.count)
            let sourceTracker = ImageDrawAllocationTracker(maximumAllocations: 2, allocationBytes: raw.count)
            let destination = try ImageDrawDestination(width: 768, height: 576, tracker: destinationTracker)
            defer { destination.close() }
            for _ in 0..<2 {
                let result = try autoreleasepool { try ImageRasterMaterializationFixture.perform(mode: mode, png: artifact.data,
                    raw: raw, destination: destination, providers: sourceTracker) }
                XCTAssertEqual(result.actualDrawCount, 1)
                XCTAssertEqual(result.validatedRGBABytes, raw.count)
                XCTAssertTrue(result.pixelsWithinTolerance)
                XCTAssertLessThanOrEqual(result.maximumAbsoluteChannelDifference, 2)
                XCTAssertEqual(result.pixelsSHA256.count, 64)
                XCTAssertGreaterThanOrEqual(result.workloadWallSeconds, result.totalOperationSeconds)
                XCTAssertGreaterThan(result.drawAndFlushSeconds, 0)
                XCTAssertGreaterThan(result.pixelValidationSeconds, 0)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
                XCTAssertNotNil(json["afterDrawAndReadbackImageLive"])
                XCTAssertNil(json["fixed"]); XCTAssertNil(json["zeroCost"])
            }
            XCTAssertEqual(destinationTracker.snapshot().allocations, 1)
            XCTAssertEqual(sourceTracker.snapshot().allocations, mode == .ownedRGBADraw ? 2 : 0)
            destination.close()
            XCTAssertEqual(destinationTracker.snapshot().releaseCallbacks, 1)
            XCTAssertEqual(destinationTracker.snapshot().deallocations, 1)
            XCTAssertEqual(destinationTracker.snapshot().activeBytes, 0)
        }
    }

    func testOwnedProviderReleaseAndAllocationBudgetWithoutDrawing() throws {
        let raw = Data(repeating: 0, count: ImageRasterMaterializationFixture.rasterBytes)
        let tracker = ImageDrawAllocationTracker(maximumAllocations: 1, allocationBytes: raw.count)
        try autoreleasepool {
            let image = try ImageRasterMaterializationFixture.ownedImage(raw, tracker: tracker)
            XCTAssertEqual(tracker.snapshot().allocations, 1)
            // Core Graphics may copy the bytes early; don't assume the provider
            // must remain live for the entire CGImage object's lifetime.
            let live = tracker.snapshot()
            XCTAssertLessThanOrEqual(live.activeBytes, raw.count)
            XCTAssertEqual(live.activeBytes + live.deallocations * raw.count, raw.count)
            XCTAssertEqual(image.width, 768)
            withExtendedLifetime(image) { }
        }
        XCTAssertEqual(tracker.snapshot().releaseCallbacks, 1)
        XCTAssertEqual(tracker.snapshot().deallocations, 1)
        XCTAssertEqual(tracker.snapshot().activeBytes, 0)
        XCTAssertTrue(tracker.snapshot().callbackSizesMatch)
        XCTAssertThrowsError(try ImageRasterMaterializationFixture.ownedImage(raw, tracker: tracker))
        XCTAssertEqual(tracker.snapshot().allocations, 1)
    }

    func testBoundsAndWrongPixelReferenceFailRatherThanAcceptLazyObjects() throws {
        let tracker = ImageDrawAllocationTracker(maximumAllocations: 1, allocationBytes: ImageRasterMaterializationFixture.rasterBytes)
        XCTAssertThrowsError(try ImageRasterMaterializationFixture.ownedImage(Data([0]), tracker: tracker))
        XCTAssertEqual(tracker.snapshot().allocations, 0)
        XCTAssertThrowsError(try ImageDrawDestination(width: 4096, height: 4096, tracker: tracker))
        let small = try CodecExportResourceFixture.fixture(width: 64, height: 48)
        let smallPNG = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: small), options: ImageExportOptions(format: .png))
        XCTAssertThrowsError(try ImageRasterMaterializationFixture.noCacheImage(smallPNG.data))
        XCTAssertThrowsError(try ImageRasterMaterializationFixture.noCacheImage(Data("not PNG".utf8)))
        let artifact = try preparedArtifact()
        let destination = try ImageDrawDestination(width: 768, height: 576, tracker: tracker)
        defer { destination.close() }
        XCTAssertThrowsError(try destination.drawAndValidate(artifact.firstPreview,
            reference: Data(repeating: 0, count: ImageRasterMaterializationFixture.rasterBytes), tolerance: 2))
        destination.close()
        XCTAssertThrowsError(try destination.drawAndValidate(artifact.firstPreview,
            reference: Data(repeating: 0, count: ImageRasterMaterializationFixture.rasterBytes), tolerance: 2))
    }

    private func preparedArtifact() throws -> ImageExportArtifact {
        let source = try CodecExportResourceFixture.fixture(width: 768, height: 576)
        return try ImageExportService.encode(snapshot: ImageExportSnapshot(image: source), options: ImageExportOptions(format: .png))
    }
}
