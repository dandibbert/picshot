import AppKit
import XCTest
import PicShotCore
@testable import PicShot

@MainActor final class EditableAnnotationMosaicTests: XCTestCase {
    func testRealMatchingAfterCropSearchesVisibleSourceAndMapsLinkedRegionsBackToBase() async throws {
        let source = try repeatedSource()
        let editor = EditableUIFixtures.editor(source); defer { editor.close() }
        let viewport = CGRect(x: 40, y: 30, width: 220, height: 160)
        editor.annotationCanvas.cropRect = viewport; EditableUIFixtures.action("applyCrop", editor)
        let seedRect = CGRect(x: 64, y: 52, width: 24, height: 20)
        let target = CGRect(x: 180, y: 140, width: 24, height: 20)
        let seed = ImageAnnotation(tool: .redact, points: [seedRect.origin, CGPoint(x: seedRect.maxX, y: seedRect.maxY)])
        editor.annotationCanvas.add(seed)
        var observedSize: CGSize?, observedSeed: RepeatedRegionPixelRect?
        let matcher = AutomaticMosaicMatcher()
        editor.automaticMosaicFind = { image, rect in
            observedSize = CGSize(width: image.width, height: image.height); observedSeed = rect
            return try await matcher.findMatches(in: image, seed: rect)
        }
        editor.beginAutomaticMosaic(seed: seed, replacing: seed.id)
        try await wait { !editor.automaticMosaicIsComputing }
        XCTAssertEqual(observedSize, viewport.size)
        XCTAssertEqual(observedSeed, RepeatedRegionPixelRect(x: 24, y: 118, width: 24, height: 20))
        let ready = try XCTUnwrap(editor.automaticMosaicReviewState)
        XCTAssertEqual(ready.phase, .ready)
        XCTAssertTrue(ready.candidates.contains { $0.rect == target })
        XCTAssertTrue(ready.candidates.allSatisfy { viewport.contains($0.rect) })
        XCTAssertFalse(ready.candidates.contains { $0.rect == CGRect(x: 4, y: 4, width: 24, height: 20) })
        editor.applyAutomaticMosaic()
        let marks = editor.annotationCanvas.annotations
        XCTAssertTrue(marks.contains { $0.mosaicLink?.target == target })
        XCTAssertTrue(marks.allSatisfy { $0.mosaicLink?.includedTargets.contains(target) == true })
        let expected = try XCTUnwrap(ImageEditorRenderer.crop(image: XCTUnwrap(ImageEditorRenderer.render(image: source, annotations: marks)), to: viewport))
        XCTAssertEqual(try EditableUIFixtures.bytes(XCTUnwrap(editor.annotationCanvas.flattened())), try EditableUIFixtures.bytes(expected))
        let payload = try editor.editablePayload()
        let reopened = EditableUIFixtures.editor(source); defer { reopened.close() }
        try reopened.restoreEditablePayload(payload)
        XCTAssertEqual(try EditableAnnotationDocumentCodec.encode(reopened.editablePayload().document),
            try EditableAnnotationDocumentCodec.encode(payload.document))
        EditableUIFixtures.action("undoEdit", editor)
        XCTAssertEqual(editor.annotationCanvas.annotations.map(\.id), [seed.id])
        XCTAssertEqual(editor.annotationCanvas.cropViewportInBase, viewport)
    }

    func testLateMatchCannotRestoreOldViewportReviewAfterNestedCrop() async throws {
        let source = try repeatedSource()
        let editor = EditableUIFixtures.editor(source); defer { editor.close() }
        editor.annotationCanvas.cropRect = CGRect(x: 40, y: 30, width: 220, height: 160)
        EditableUIFixtures.action("applyCrop", editor)
        let rect = CGRect(x: 64, y: 52, width: 24, height: 20)
        let seed = ImageAnnotation(tool: .pixelate, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)])
        editor.annotationCanvas.add(seed)
        var continuation: CheckedContinuation<RepeatedRegionMatchResult, Error>?
        var observedSeed: RepeatedRegionPixelRect?
        editor.automaticMosaicFind = { _, pixelSeed in
            observedSeed = pixelSeed
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        editor.beginAutomaticMosaic(seed: seed, replacing: seed.id)
        try await wait { continuation != nil }
        let revision = editor.annotationCanvas.contentRevision
        editor.annotationCanvas.cropRect = CGRect(x: 52, y: 40, width: 140, height: 100)
        EditableUIFixtures.action("applyCrop", editor)
        XCTAssertGreaterThan(editor.annotationCanvas.contentRevision, revision)
        let pixelSeed = try XCTUnwrap(observedSeed)
        continuation?.resume(returning: RepeatedRegionMatchResult(seed: pixelSeed, candidates: [], examinedOrigins: 1, truncated: false))
        continuation = nil
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(editor.automaticMosaicReviewState)
        XCTAssertFalse(editor.automaticMosaicIsComputing)
        XCTAssertEqual(editor.annotationCanvas.cropViewportInBase, CGRect(x: 52, y: 40, width: 140, height: 100))
        XCTAssertEqual(editor.annotationCanvas.annotations.map(\.id), [seed.id])
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !predicate() && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(predicate())
    }
    private func repeatedSource() throws -> CGImage {
        let width = 320, height = 240
        var bytes = [UInt8](repeating: 245, count: width * height * 4)
        for index in stride(from: 3, to: bytes.count, by: 4) { bytes[index] = 255 }
        for origin in [CGPoint(x: 64, y: 52), CGPoint(x: 180, y: 140), CGPoint(x: 4, y: 4)] {
            for y in 0..<20 { for x in 0..<24 {
                let destination = ((height - 1 - Int(origin.y) - y) * width + Int(origin.x) + x) * 4
                for channel in 0..<3 { bytes[destination + channel] = UInt8((x * 71 + y * 39 + x * y * 13 + channel * 43) % 231) }
            } }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}
