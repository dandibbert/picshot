import XCTest
import AppKit
import ImageIO
import PicShotCore
@testable import PicShot

@MainActor
final class ScrollSequencePreviewTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let sequence: ScrollCaptureSequence
        let layout: ScrollSequenceLayout
        let sources: [StoredScrollSource]
        let documents: [Int]
    }
    private func fixture(_ axis: ScrollAxis) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var sources: [StoredScrollSource] = []
        var sequence: ScrollCaptureSequence?
        for index in 0..<7 {
            let id = UUID(), offset = index * 300
            let image = try coordinateImage(axis, documents: Array(offset..<(offset + 400)))
            let url = root.appendingPathComponent("\(index).png")
            try ScrollImageIO.writePNG(image, to: url)
            sources.append(StoredScrollSource(id: id, url: url, width: image.width, height: image.height,
                                              byteCount: Int64(try Data(contentsOf: url).count)))
            if sequence == nil { sequence = try ScrollCaptureSequence(axis: axis, width: image.width, height: image.height, sourceID: id) }
            else { try sequence?.accept(advance: 300, sourceID: id) }
        }
        let original = try XCTUnwrap(sequence)
        let cuts = [187..<263, 759..<901, 1_603..<1_667]
        let removed = original.blocks[3]
        let documents = (0..<2_200).filter { pixel in
            !cuts.contains { $0.contains(pixel) } && !(removed.documentStart..<(removed.documentStart + removed.length)).contains(pixel)
        }
        let layout = try original.layout(removing: [removed.id], excluding: cuts)
        return Fixture(root: root, sequence: original, layout: layout, sources: sources, documents: documents)
    }
    private func coordinateImage(_ axis: ScrollAxis, documents: [Int]) throws -> CGImage {
        let width = axis == .vertical ? 96 : documents.count, height = axis == .vertical ? documents.count : 96
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let along = documents[axis == .vertical ? y : x], cross = axis == .vertical ? x : y
            let index = (y * width + x) * 4
            bytes[index] = UInt8((along * 3 + cross * 7) % 251)
            bytes[index + 1] = UInt8((along / 7 + cross * 3) % 253)
            bytes[index + 2] = UInt8((along / 29 + cross * 11) % 247)
        } }
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.interpolationQuality = .none; context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    private func referenceTile(_ reference: CGImage, request: ScrollPreviewTileRequest) throws -> CGImage {
        // Independent oracle: assemble the edited document pixel-by-pixel, then crop it
        // once and sample that crop. This does not use strips or source drawing transforms.
        let crop = try XCTUnwrap(reference.cropping(to: request.outputRect))
        let context = try XCTUnwrap(CGContext(data: nil, width: request.pixelWidth, height: request.pixelHeight,
            bitsPerComponent: 8, bytesPerRow: request.pixelWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.interpolationQuality = .none; context.setBlendMode(.copy)
        context.draw(crop, in: CGRect(x: 0, y: 0, width: request.pixelWidth, height: request.pixelHeight))
        return try XCTUnwrap(context.makeImage())
    }

    func testLongSampledTilesMatchIndependentEditedPixelsBothAxesAndFractionalScale() throws {
        for axis in ScrollAxis.allCases {
            let fixture = try fixture(axis)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let before = try fixture.sources.map { try Data(contentsOf: $0.url) }
            let reference = try coordinateImage(axis, documents: fixture.documents)
            XCTAssertGreaterThan(fixture.documents.count, 800)
            for start in [0, 620, fixture.documents.count - 300] {
                for sampleScale in [CGFloat(1), 0.625, 0.333] {
                    let visible = axis == .vertical
                        ? CGRect(x: 3.25, y: CGFloat(start) + 0.25, width: 89.5, height: 273.5)
                        : CGRect(x: CGFloat(start) + 0.25, y: 3.25, width: 273.5, height: 89.5)
                    let request = try ScrollPreviewTileRequest(outputSize: CGSize(width: fixture.layout.width, height: fixture.layout.height),
                                                              visibleRect: visible, displayScale: sampleScale)
                    let actual = try ScrollImageIO.sequencePreviewTile(fixture.sources, layout: fixture.layout, axis: axis, request: request)
                    let expected = try referenceTile(reference, request: request)
                    let actualBytes = try pixels(actual), expectedBytes = try pixels(expected)
                    XCTAssertEqual(actualBytes.count, expectedBytes.count)
                    let mismatch = actualBytes.indices.first { actualBytes[$0] != expectedBytes[$0] }
                    XCTAssertNil(mismatch, "\(axis.rawValue), start \(start), scale \(sampleScale), first differing byte \(mismatch ?? -1)")
                    XCTAssertLessThanOrEqual(actual.width * actual.height, ScrollPreviewTileRequest.maximumTilePixels)
                }
            }
            for (index, source) in fixture.sources.enumerated() { XCTAssertEqual(try Data(contentsOf: source.url), before[index]) }
        }
    }

    func testSourceSampleCapAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Large-Preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try coordinateImage(.vertical, documents: Array(0..<3_001)), id = UUID()
        let url = root.appendingPathComponent("source.png"); try ScrollImageIO.writePNG(image, to: url)
        let source = StoredScrollSource(id: id, url: url, width: image.width, height: image.height, byteCount: 0)
        let sequence = try ScrollCaptureSequence(axis: .vertical, width: image.width, height: image.height, sourceID: id)
        let layout = try sequence.layout()
        let request = try ScrollPreviewTileRequest(outputSize: CGSize(width: image.width, height: image.height),
                                                  visibleRect: CGRect(x: 0, y: 0, width: image.width, height: image.height), displayScale: 2)
        let tile = try ScrollImageIO.sequencePreviewTile([source], layout: layout, axis: .vertical, request: request)
        XCTAssertLessThanOrEqual(max(tile.width, tile.height), 1_024)
        let task = Task { () throws -> CGImage in
            try Task.checkCancellation()
            return try ScrollImageIO.sequencePreviewTile([source], layout: layout, axis: .vertical, request: request)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled tile should not publish") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testOwnedWindowNavigationSelectionAndCloseDiscardsPendingTiles() async throws {
        for axis in ScrollAxis.allCases {
            let fixture = try fixture(axis)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let window = NSWindow(contentRect: CGRect(x: -400, y: 10, width: 380, height: 230),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            defer { window.close() }
            let preview = ScrollSequencePreview(frame: CGRect(x: 0, y: 0, width: 380, height: 230))
            window.contentView = preview
            let thumbnail = try ScrollImageIO.sequenceThumbnail(fixture.sources, layout: fixture.layout, axis: axis)
            preview.image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
            let latest = fixture.sequence.viewportOffset..<(fixture.sequence.viewportOffset + 400)
            preview.updateProjection(layout: fixture.layout, axis: axis, sources: fixture.sources, viewport: latest)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                let beginning = try button("beginning", in: preview); beginning.performClick(nil)
                XCTAssertEqual(axis == .vertical ? preview.visibleOutputRect.minY : preview.visibleOutputRect.minX, 0, accuracy: 0.000001)
                try button("end", in: preview).performClick(nil)
                XCTAssertEqual(axis == .vertical ? preview.visibleOutputRect.maxY : preview.visibleOutputRect.maxX,
                               CGFloat(fixture.documents.count), accuracy: 0.000001)
                try button("middle", in: preview).performClick(nil)
                let middle = preview.visibleOutputRect
                XCTAssertEqual(axis == .vertical ? middle.midY : middle.midX, CGFloat(fixture.documents.count) / 2, accuracy: 0.000001)
                try button("latest", in: preview).performClick(nil)
                XCTAssertFalse(preview.latestOutputRanges.isEmpty)
                try button("zoomIn", in: preview).performClick(nil)
                preview.panPreview(by: CGPoint(x: -23.5, y: -41.25))
                await preview.waitForDetailForVerification()
                XCTAssertNotNil(preview.detailImageForVerification)
                XCTAssertTrue((preview.snapshotForVerification["resolutionLabel"] as? String)?.contains("采样") == true)
                // Draw the owned view in both appearances; no screen capture or posted events.
                if let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) {
                    preview.cacheDisplay(in: preview.bounds, to: bitmap)
                    XCTAssertGreaterThan(bitmap.pixelsWide, 0)
                } else { XCTFail("Cannot render owned preview view") }
            }
            preview.showFit(); preview.allowsSelection = true
            let first = fixture.layout.strips[0]
            let pixel = first.outputStart + first.block.length / 2
            let rect = preview.imageRect
            let point = axis == .vertical
                ? CGPoint(x: rect.midX, y: rect.minY + (CGFloat(pixel) + 0.5) / CGFloat(fixture.layout.height) * rect.height)
                : CGPoint(x: rect.minX + (CGFloat(pixel) + 0.5) / CGFloat(fixture.layout.width) * rect.width, y: rect.midY)
            XCTAssertEqual(preview.block(at: point), first.block.id)
            var selected: UUID?, band: Range<Int>?
            preview.onSelect = { selected = $0 }; preview.onBandSelect = { band = $0 }
            preview.mouseDown(with: try event(.leftMouseDown, point: point, view: preview, window: window))
            let endPoint = axis == .vertical ? CGPoint(x: point.x, y: point.y + 12) : CGPoint(x: point.x + 12, y: point.y)
            preview.mouseDragged(with: try event(.leftMouseDragged, point: endPoint, view: preview, window: window))
            preview.mouseUp(with: try event(.leftMouseUp, point: endPoint, view: preview, window: window))
            XCTAssertEqual(selected, first.block.id); XCTAssertNotNil(band)
            let selectedBand = preview.selectedRange
            preview.mouseDown(with: try event(.leftMouseDown, point: point, view: preview, window: window, flags: .option))
            preview.mouseDragged(with: try event(.leftMouseDragged, point: endPoint, view: preview, window: window, flags: .option))
            preview.mouseUp(with: try event(.leftMouseUp, point: endPoint, view: preview, window: window, flags: .option))
            XCTAssertEqual(preview.selectedRange, selectedBand)
            for index in 0..<40 { preview.navigate(to: index % 2 == 0 ? .beginning : .end) }
            preview.clearDetail(); preview.layout = nil; preview.image = nil
            await preview.waitForDetailForVerification()
            XCTAssertNil(preview.detailImageForVerification)
            XCTAssertEqual(preview.snapshotForVerification["sourceReferences"] as? Int, 0)
            XCTAssertEqual(preview.snapshotForVerification["activeJobs"] as? Int, 0)
            XCTAssertEqual(preview.snapshotForVerification["cachedTiles"] as? Int, 0)
        }
    }
    private func button(_ name: String, in view: NSView) throws -> NSButton {
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        return try XCTUnwrap(descendants(view).first { $0.identifier?.rawValue == "scroll.preview." + name } as? NSButton)
    }
    private func event(_ type: NSEvent.EventType, point: CGPoint, view: NSView, window: NSWindow,
                       flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: flags,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
