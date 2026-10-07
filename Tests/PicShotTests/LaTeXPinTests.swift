import XCTest
import AppKit
import ImageIO
import SwiftUI
import PicShotCore
import PicShotFormulaRenderCore
@testable import PicShot

final class LaTeXPinTests: XCTestCase {
    @MainActor func testFormulaPNGKeepsOriginalPixelRasterAcrossDisplayScalesResizeAndCommit() throws {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        for scale in 1...3 {
            let request = FormulaRenderRequest(latex: "x", scale: scale)
            let prepared = try PreparedRichPin(formula: request, result: Self.result(request, width: 96))
            let pin = try RichPinController(asset: prepared.asset, data: prepared.data, title: "Scale", renderedImage: prepared.poster)
            defer { pin.close() }
            XCTAssertTrue(pin.displayedLaTeXRaster === prepared.poster, "Point-size presentation must retain the actual decoded raster")
            var presentation = pin.presentation; presentation.frame.width = 193; presentation.frame.height = 85
            pin.applyPresentation(presentation)
            XCTAssertTrue(pin.displayedLaTeXRaster === prepared.poster)
            pin.copyLaTeXPNG(to: board)
            let data = try XCTUnwrap(board.data(forType: .png))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let copied = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(copied.width, prepared.poster.width); XCTAssertEqual(copied.height, prepared.poster.height)
            pin.onRichChange = { _ in }
            let replacementRequest = FormulaRenderRequest(latex: "y", scale: scale)
            let replacement = try PreparedRichPin(formula: replacementRequest, result: Self.result(replacementRequest, width: 132))
            try XCTUnwrap(pin.latexModel?.onCommit)(replacement)
            XCTAssertTrue(pin.displayedLaTeXRaster === replacement.poster)
            pin.close(); XCTAssertNil(pin.displayedLaTeXRaster)
        }
    }

    @MainActor func testLargeFormulaCanUseExactCompactViewportWithFullResolutionRepresentation() throws {
        _ = NSApplication.shared
        let request = FormulaRenderRequest(latex: "x", scale: 2)
        let prepared = try PreparedRichPin(formula: request, result: Self.result(request, width: 489, height: 223))
        let pin = try RichPinController(asset: prepared.asset, data: prepared.data, title: "Compact", renderedImage: prepared.poster)
        defer { pin.close() }
        let window = try XCTUnwrap(pin.window)
        var value = pin.presentation; value.frame = PinWindowFrame(x: 80, y: 80, width: 180, height: 72)
        pin.applyPresentation(value); window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.frame, value.frame.rect, "Natural bitmap size must not force a larger pin viewport")
        let view = try XCTUnwrap(imageView(in: window.contentView))
        XCTAssertEqual(view.intrinsicContentSize.width, NSView.noIntrinsicMetric)
        XCTAssertEqual(view.intrinsicContentSize.height, NSView.noIntrinsicMetric)
        let image = try XCTUnwrap(view.image)
        let rep = try XCTUnwrap(image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        XCTAssertEqual(rep.pixelsWide, 489); XCTAssertEqual(rep.pixelsHigh, 223)
        XCTAssertEqual(image.size, NSSize(width: 244.5, height: 111.5))
        XCTAssertEqual(rep.size, image.size)
        XCTAssertTrue(pin.displayedLaTeXRaster === prepared.poster)
    }

    @MainActor func testNativeScaledDrawingUsesFullSourceBitmapWithoutReplacingIt() throws {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 96, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 48, y: 0, width: 48, height: 48))
        let raster = try XCTUnwrap(context.makeImage())
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: raster).representation(using: .png, properties: [:]))
        let request = FormulaRenderRequest(latex: "x", scale: 3)
        let result = FormulaRenderResult(latex: "x", svg: "<svg />", mathML: "<math ><mi>x</mi></math>", png: png,
            pdf: Data("%PDF-scaled-drawing-fixture".utf8), width: 96, height: 48, pointWidth: 32, pointHeight: 16)
        let prepared = try PreparedRichPin(formula: request, result: result)
        let pin = try RichPinController(asset: prepared.asset, data: prepared.data, title: "Drawing", renderedImage: prepared.poster)
        defer { pin.close() }
        let image = try XCTUnwrap(imageView(in: pin.window?.contentView)?.image)
        let source = try XCTUnwrap(image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        let target = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 64, bitsPerPixel: 32))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: target))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: 0, y: 0, width: 16, height: 8), from: .zero, operation: .copy, fraction: 1)
        graphics.flushGraphics()
        let left = try XCTUnwrap(target.colorAt(x: 2, y: 4)?.usingColorSpace(.deviceRGB))
        let right = try XCTUnwrap(target.colorAt(x: 13, y: 4)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(left.redComponent, 0.9); XCTAssertLessThan(left.blueComponent, 0.1)
        XCTAssertGreaterThan(right.blueComponent, 0.9); XCTAssertLessThan(right.redComponent, 0.1)
        XCTAssertEqual(source.pixelsWide, 96); XCTAssertEqual(source.pixelsHigh, 48)
        XCTAssertTrue(image.representations.contains { $0 === source })
        XCTAssertTrue(pin.displayedLaTeXRaster === prepared.poster)
    }

    @MainActor private func imageView(in view: NSView?) -> NSImageView? {
        guard let view else { return nil }
        if let image = view as? NSImageView { return image }
        return view.subviews.compactMap { imageView(in: $0) }.first
    }

    @MainActor func testAtomicSourceRasterReplacementAndRestore() throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let first = try prepared("x"), second = try prepared("y", width: 6)
        let saved = try store.add(rich: first)
        try store.replaceRich(second, id: saved.id)
        let updated = try XCTUnwrap(store.entry(id: saved.id))
        XCTAssertEqual(updated.original, updated.current); XCTAssertEqual(updated.current.width, 6)
        XCTAssertNotEqual(updated.richContent?.filename, saved.richContent?.filename)
        for name in saved.assetFilenames { XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)) }
        let restored = try PinSessionStore(directory: directory)
        XCTAssertEqual(try document(restored, saved.id).latex?.source, "y")
        XCTAssertEqual(restored.image(id: saved.id)?.width, 6)
        XCTAssertEqual(restored.entry(id: saved.id)?.id, saved.id)
    }
    @MainActor func testQuotaFailureKeepsSourceAndRasterAndCleansNewAssets() throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory, policy: PinSessionPolicy(maxPixelCount: 4))
        let saved = try store.add(rich: prepared("x"))
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertThrowsError(try store.replaceRich(prepared("y", width: 6), id: saved.id))
        XCTAssertEqual(store.entry(id: saved.id), saved)
        XCTAssertEqual(try document(store, saved.id).latex?.source, "x")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), before)
    }
    @MainActor func testDiskQuotaAccountsForSourceAndActualRaster() throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = try prepared("x")
        let sourceBytes = Int64(first.data.count)
        let probe = temporary().appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: probe) }
        try first.poster.writePNG(to: probe)
        let pngBytes = Int64(try Data(contentsOf: probe).count)
        let store = try PinSessionStore(directory: directory, policy: PinSessionPolicy(maxDiskBytes: pngBytes + sourceBytes))
        let saved = try store.add(rich: first)
        XCTAssertEqual(saved.storedByteCount, pngBytes + sourceBytes)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertThrowsError(try store.replaceRich(prepared(String(repeating: "x", count: 8_192)), id: saved.id))
        XCTAssertEqual(store.entry(id: saved.id), saved)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), before)
    }
    @MainActor func testManifestFailureRollsBackBothNewFiles() throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let saved = try store.add(rich: prepared("x"))
        let manifest = directory.appendingPathComponent("index.json")
        let original = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.replaceRich(prepared("y"), id: saved.id))
        XCTAssertEqual(store.entry(id: saved.id), saved)
        XCTAssertEqual(try document(store, saved.id).latex?.source, "x")
        let assets = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != "index.json" }
        XCTAssertEqual(Set(assets), Set(saved.assetFilenames))
        try FileManager.default.removeItem(at: manifest); try original.write(to: manifest)
        XCTAssertEqual(try PinSessionStore(directory: directory).entries, [saved])
    }
    @MainActor func testInvalidEditsAndFailedCommitPreserveCommittedSource() async throws {
        let model = LaTeXPinModel(content: PinLaTeXContent(source: "x")) { request in
            if request.latex == #"\frac{"# { throw FormulaRenderError.syntax }
            return Self.result(request)
        }
        var count = 0
        model.onCommit = { _ in count += 1; throw PinSessionError.capacityExceeded }
        model.source = #"\frac{"#; model.apply(); await model.waitUntilIdle()
        XCTAssertEqual(model.source, #"\frac{"#); XCTAssertEqual(model.committed?.source, "x"); XCTAssertEqual(count, 0)
        model.source = "y"; model.apply(); await model.waitUntilIdle()
        XCTAssertEqual(model.source, "y"); XCTAssertEqual(model.committed?.source, "x"); XCTAssertTrue(model.undoSources.isEmpty)
        XCTAssertEqual(count, 1)
        model.source = String(repeating: "x", count: FormulaRenderLimits.latexBytes + 1)
        XCTAssertFalse(model.canApply)
        model.discardDraft(); XCTAssertEqual(model.source, "x")
    }
    @MainActor func testSourceUndoIsBoundedAndUndoFailureIsNonDestructive() async throws {
        let model = LaTeXPinModel(content: PinLaTeXContent(source: "x")) { Self.result($0) }
        model.onCommit = { _ in }
        for number in 0..<18 { model.source = "x_\(number)"; model.apply(); await model.waitUntilIdle() }
        XCTAssertEqual(model.undoSources.count, LaTeXPinModel.maximumUndoEntries)
        let before = model.committed, history = model.undoSources
        model.onCommit = { _ in throw PinSessionError.capacityExceeded }
        model.undo(); await model.waitUntilIdle()
        XCTAssertEqual(model.committed, before); XCTAssertEqual(model.undoSources, history)
        model.onCommit = { _ in }; model.undo(); await model.waitUntilIdle()
        XCTAssertEqual(model.committed?.source, "x_16"); XCTAssertEqual(model.undoSources.count, 9)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        model.source = "unsaved draft"; model.copySource(to: board)
        XCTAssertEqual(board.string(forType: .string), "x_16")
    }
    @MainActor func testCancelEditAndCloseRejectLateCompletions() async throws {
        let model = LaTeXPinModel(content: PinLaTeXContent(source: "x")) { request in
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { continuation.resume() }
            }
            return Self.result(request)
        }
        var commits = 0; model.onCommit = { _ in commits += 1 }
        model.source = "y"; model.apply(); await Task.yield(); model.cancel()
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(commits, 0); XCTAssertEqual(model.committed?.source, "x")
        model.apply(); await Task.yield(); model.source = "z"
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(commits, 0)
        model.apply(); await Task.yield(); model.close()
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(commits, 0); XCTAssertNil(model.committed); XCTAssertTrue(model.undoSources.isEmpty)
        XCTAssertEqual(model.source, ""); XCTAssertFalse(model.canApply); XCTAssertFalse(model.working)
    }
    @MainActor func testRapidReplacementDrainsCancelledWorkBeforeNextRender() async throws {
        let tracker = LaTeXPinConcurrencyProbe()
        let model = LaTeXPinModel(content: PinLaTeXContent(source: "original")) { request in
            await tracker.begin()
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { continuation.resume() }
            }
            await tracker.end()
            return Self.result(request)
        }
        model.onCommit = { _ in }
        model.source = "x"; model.apply()
        for _ in 0..<100 { if await tracker.started > 0 { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        model.source = "y"; model.apply(); model.source = "z"; model.apply()
        await model.waitUntilIdle()
        XCTAssertEqual(model.committed?.source, "z")
        let maximum = await tracker.maximum
        XCTAssertEqual(maximum, 1)
    }
    @MainActor func testExportUsesCommittedSourceAndCloseSuppressesDelivery() async throws {
        let model = LaTeXPinModel(content: PinLaTeXContent(source: "x")) { request in
            try? await Task.sleep(nanoseconds: 20_000_000)
            return Self.result(request)
        }
        model.source = "draft"
        var copied: Data?
        model.export(.mathML) { copied = $0 }; await model.waitUntilIdle()
        XCTAssertEqual(copied, Data("<math ><mi>x</mi></math>".utf8))
        copied = nil; model.export(.pdf) { copied = $0 }; model.close()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(copied)
    }
    @MainActor func testManagedHideRestoreArchiveRepeatedCyclesAndRelease() async throws {
        _ = NSApplication.shared
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let coordinator = PinSessionCoordinator(store: store, presentWindows: false)
        let id = try coordinator.add(rich: prepared("x"))
        let files = try XCTUnwrap(store.entry(id: id)?.assetFilenames)
        weak var closedModel: LaTeXPinModel?
        for _ in 0..<12 {
            closedModel = coordinator.richControllers[id]?.latexModel
            try coordinator.hideCurrentGroup()
            XCTAssertNil(closedModel); XCTAssertTrue(coordinator.richControllers.isEmpty)
            try coordinator.showCurrentGroup()
            XCTAssertEqual(coordinator.richControllers[id]?.richDocument?.latex?.source, "x")
            coordinator.richControllers[id]?.close()
            XCTAssertFalse(try XCTUnwrap(store.entry(id: id)).isVisible)
            try coordinator.openPin(id: id)
            XCTAssertEqual(coordinator.livePinCount, 1)
            XCTAssertEqual(store.entry(id: id)?.assetFilenames, files)
        }
        try coordinator.prepareForTermination()
        let restored = PinSessionCoordinator(store: try PinSessionStore(directory: directory), presentWindows: false)
        try restored.restoreOnLaunch(enabled: true, isSmoke: false)
        XCTAssertEqual(restored.richControllers[id]?.richDocument?.latex?.source, "x")
        try restored.prepareForTermination()
    }
    @MainActor func testFormulaPreviewPinActionUsesManagedSourceAndRejectsStalePreview() async throws {
        _ = NSApplication.shared
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let coordinator = PinSessionCoordinator(store: store, presentWindows: false)
        defer { try? coordinator.prepareForTermination() }
        let model = FormulaRenderModel(latex: "x") { Self.result($0) }
        model.onPin = { request, result in _ = try coordinator.add(rich: PreparedRichPin(formula: request, result: result)) }
        _ = try await model.renderAndWait(); model.pin()
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(coordinator.richControllers.values.first?.richDocument?.latex?.source, "x")
        model.latex = "unsaved preview"; model.pin()
        XCTAssertEqual(store.entries.count, 1)
        model.close(); XCTAssertNil(model.onPin)
    }
    @MainActor func testNativeEditorRejectsOversizedPasteBeforeInsertion() {
        _ = NSApplication.shared
        var source = "x"
        let coordinator = BoundedLaTeXEditor.Coordinator(text: Binding(get: { source }, set: { source = $0 }))
        let editor = NSTextView(); editor.string = "x"
        XCTAssertFalse(coordinator.textView(editor, shouldChangeTextIn: NSRange(location: 0, length: 1), replacementString: String(repeating: "x", count: 8_193)))
        XCTAssertFalse(coordinator.textView(editor, shouldChangeTextIn: NSRange(location: 0, length: 1), replacementString: "x\0"))
        XCTAssertTrue(coordinator.textView(editor, shouldChangeTextIn: NSRange(location: 0, length: 1), replacementString: String(repeating: "x", count: 8_192)))
        XCTAssertEqual(editor.string, "x")
    }
    @MainActor func testUntrustedSavedSourceIsRestoredWithoutExecution() throws {
        _ = NSApplication.shared
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let malicious = #"\input{https://example.invalid/private.tex}"#
        let store = try PinSessionStore(directory: directory)
        let entry = try store.add(rich: prepared(malicious)) // Stub pairs source with a safe raster, not an actual render.
        let restored = PinSessionCoordinator(store: try PinSessionStore(directory: directory), presentWindows: false)
        try restored.restoreOnLaunch(enabled: true, isSmoke: false)
        let model = try XCTUnwrap(restored.richControllers[entry.id]?.latexModel)
        XCTAssertEqual(model.committed?.source, malicious); XCTAssertFalse(model.working)
        XCTAssertNotNil(restored.richControllers[entry.id]?.displayedLaTeXRaster)
        try restored.prepareForTermination()
    }
    @MainActor func testPreparedRejectsMismatchedRasterAndSource() throws {
        let request = FormulaRenderRequest(latex: "x")
        XCTAssertThrowsError(try PreparedRichPin(formula: request, result: Self.result(FormulaRenderRequest(latex: "y"))))
        let result = Self.result(request)
        let mismatch = FormulaRenderResult(latex: result.latex, svg: result.svg, mathML: result.mathML, png: result.png, pdf: result.pdf,
                                          width: 4, height: 2, pointWidth: 2, pointHeight: 1)
        XCTAssertThrowsError(try PreparedRichPin(formula: request, result: mismatch))
        XCTAssertThrowsError(try PreparedRichPin(document: PinRichDocument(latex: PinLaTeXContent(source: "x")), title: "formula"))
        XCTAssertEqual(PinLaTeXContent.maximumUTF8Bytes, FormulaRenderLimits.latexBytes)
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("LaTeXPinTest-" + UUID().uuidString) }
    @MainActor private func document(_ store: PinSessionStore, _ id: UUID) throws -> PinRichDocument { try JSONDecoder().decode(PinRichDocument.self, from: store.richData(id: id)) }
    private func prepared(_ source: String, width: Int = 2) throws -> PreparedRichPin {
        let request = FormulaRenderRequest(latex: source)
        return try PreparedRichPin(formula: request, result: Self.result(request, width: width))
    }
    /// UI/storage stub only. The native smoke fixture uses actual signed MathJax output.
    private static func result(_ request: FormulaRenderRequest, width: Int = 2, height: Int = 2) -> FormulaRenderResult {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
        let png = bitmap.representation(using: .png, properties: [:])!
        return FormulaRenderResult(latex: request.latex, svg: "<svg />", mathML: "<math ><mi>\(request.latex)</mi></math>", png: png,
                                   pdf: Data("%PDF-stub".utf8), width: width, height: height,
                                   pointWidth: Double(width) / Double(request.scale), pointHeight: Double(height) / Double(request.scale))
    }
}

private actor LaTeXPinConcurrencyProbe {
    private var active = 0
    private(set) var started = 0
    private(set) var maximum = 0
    func begin() { active += 1; started += 1; maximum = max(maximum, active) }
    func end() { active -= 1 }
}
