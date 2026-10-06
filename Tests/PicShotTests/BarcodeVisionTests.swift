import XCTest
import AppKit
@testable import PicShot

final class BarcodeVisionTests: XCTestCase {
    @MainActor func testQRNativeGeneratorDecodesExactPayload() async throws { try await verify("qr") }
    @MainActor func testCode128NativeGeneratorDecodesExactPayload() async throws { try await verify("code128") }
    @MainActor func testEAN13OriginalReportLabVectorDecodesWithChecksum() async throws { try await verify("ean13") }
    @MainActor func testUPCAOriginalVectorRemainsNativeEAN13WithExplicitAlias() async throws { try await verify("upca-as-ean13") }
    @MainActor func testCode39OriginalReportLabVectorDecodesExactPayload() async throws { try await verify("code39") }
    @MainActor func testDataMatrixOriginalECC200C40VectorDecodesExactPayload() async throws { try await verify("data-matrix") }
    @MainActor func testPDF417NativeGeneratorDecodesExactPayload() async throws { try await verify("pdf417") }
    @MainActor private func verify(_ name: String) async throws {
        let input = try XCTUnwrap(BarcodeAcceptanceFixture.inputs().first { $0.name == name })
        let supported = try RecognitionService.supportedBarcodeSymbologies()
        try XCTSkipUnless(supported.contains(input.symbology), "Actual OS Vision request does not support \(input.symbology.title)")
        let document = try await RecognitionService.recognizeBarcodes(input.image)
        XCTAssertEqual(document.supportedSymbologies, supported)
        let result = try XCTUnwrap(document.results.first { $0.payload == input.payload }, document.results.map { $0.title + ": " + $0.payload }.joined(separator: ", "))
        let quad = try XCTUnwrap(result.quad)
        XCTAssertGreaterThan(quad.bounds.width, 0.05); XCTAssertGreaterThan(quad.bounds.height, 0.01)
        XCTAssertTrue(quad.points.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        XCTAssertEqual(document.omittedCount, 0)
        if name == "upca-as-ean13" {
            XCTAssertEqual(result.symbology, .ean13); XCTAssertEqual(result.payload, "0012345678905")
            XCTAssertEqual(result.upcaEquivalent, "012345678905")
        } else if name != "code39" { XCTAssertEqual(result.symbology, input.symbology) }
    }
    @MainActor func testMultipleDistinctAndRotatedCodesReturnSeparateGeometry() async throws {
        let input = try BarcodeAcceptanceFixture.multipleRaster()
        for image in [input.image, try XCTUnwrap(PinImageRenderer.render(image: input.image, transform: .rotateClockwise))] {
            let document = try await RecognitionService.recognizeBarcodes(image)
            XCTAssertTrue(Set(input.payloads).isSubset(of: Set(document.results.map(\.payload))), document.results.map(\.payload).description)
            let results = try input.payloads.map { value in try XCTUnwrap(document.results.first { $0.payload == value }) }
            for first in results.indices {
                let a = try XCTUnwrap(results[first].quad)
                for second in results.indices where first < second {
                    let b = try XCTUnwrap(results[second].quad)
                    XCTAssertFalse(a.bounds.intersects(b.bounds), "Distinct code geometry overlaps")
                }
            }
        }
    }
    @MainActor func testRepeatedPayloadAtDifferentLocationsIsNotDeduplicated() async throws {
        let code = try BarcodeAcceptanceFixture.nativeCode("CIQRCodeGenerator", payload: "PICSHOT-REPEATED", scale: 6)
        let width = code.width * 2 + 150, height = code.height + 80
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(code, in: CGRect(x: 30, y: 40, width: code.width, height: code.height))
        context.draw(code, in: CGRect(x: code.width + 100, y: 40, width: code.width, height: code.height))
        let document = try await RecognitionService.recognizeBarcodes(try XCTUnwrap(context.makeImage()))
        let matches = document.results.filter { $0.payload == "PICSHOT-REPEATED" }
        XCTAssertEqual(matches.count, 2); XCTAssertNotEqual(matches.first?.id, matches.last?.id)
        XCTAssertNotEqual(matches.first?.quad, matches.last?.quad)
    }
    @MainActor func testExplicitOrientationRestoresSourceCoordinateSystem() async throws {
        let image = try BarcodeAcceptanceFixture.nativeCode("CIQRCodeGenerator", payload: "PICSHOT-ORIENTATION", scale: 7)
        let rotated = try XCTUnwrap(PinImageRenderer.render(image: image, transform: .rotateCounterclockwise))
        let first = try await RecognitionService.recognizeBarcodes(image)
        let corrected = try await RecognitionService.recognizeBarcodes(rotated, options: RecognitionOptions(orientation: .right))
        let a = try XCTUnwrap(first.results.first?.quad), b = try XCTUnwrap(corrected.results.first?.quad)
        XCTAssertEqual(first.results.first?.payload, corrected.results.first?.payload)
        for (p, q) in zip(a.points, b.points) { XCTAssertEqual(p.x, q.x, accuracy: 0.02); XCTAssertEqual(p.y, q.y, accuracy: 0.02) }
    }
    @MainActor func testNearMissBarcodeLikePatternProducesNoDecodedValues() async throws {
        let result = try await RecognitionService.recognizeBarcodes(BarcodeAcceptanceFixture.nearMissRaster())
        XCTAssertTrue(result.results.isEmpty, result.results.map(\.payload).description)
    }
    @MainActor func testCancelledBarcodeJobSharesAndReleasesBoundedAdmission() async throws {
        let image = try BarcodeAcceptanceFixture.nativeCode("CIQRCodeGenerator", payload: "PICSHOT-CANCEL", scale: 7)
        let baseline = await RecognitionService.resourceSnapshot()
        let task = Task { try await RecognitionService.recognizeBarcodes(image) }; task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request returned success") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        let after = await RecognitionService.resourceSnapshot()
        XCTAssertEqual(after.activeJobs, baseline.activeJobs); XCTAssertEqual(after.waitingJobs, baseline.waitingJobs)
    }
}
