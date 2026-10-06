import AppKit
import CoreImage
import PicShotCore

/// Original clean-label acceptance inputs. This proves specific local Vision paths only,
/// not all industrial standards, damaged labels, GS1 parsing, or real-camera performance.
@MainActor enum BarcodeAcceptanceFixture {
    struct Input {
        let name: String
        let symbology: BarcodeSymbology
        let payload: String
        let image: CGImage
    }
    static func inputs() throws -> [Input] {
        [
            Input(name: "qr", symbology: .qr, payload: "https://example.invalid/picshot/qr?value=one", image: try nativeCode("CIQRCodeGenerator", payload: "https://example.invalid/picshot/qr?value=one", scale: 7)),
            Input(name: "code128", symbology: .code128, payload: "PICSHOT-C128-2026", image: try nativeCode("CICode128BarcodeGenerator", payload: "PICSHOT-C128-2026", scale: 3)),
            Input(name: "ean13", symbology: .ean13, payload: "5901234123457", image: try modules(BarcodeModuleVectors.ean13, module: 5)),
            Input(name: "upca-as-ean13", symbology: .ean13, payload: "0012345678905", image: try modules(BarcodeModuleVectors.upca, module: 5)),
            Input(name: "code39", symbology: .code39, payload: "PICSHOT39", image: try modules(BarcodeModuleVectors.code39, module: 4)),
            Input(name: "data-matrix", symbology: .dataMatrix, payload: "PICSHOTDM123", image: try modules(BarcodeModuleVectors.dataMatrix, module: 7)),
            Input(name: "pdf417", symbology: .pdf417, payload: "PICSHOT-PDF417-LOCAL-2026", image: try nativeCode("CIPDF417BarcodeGenerator", payload: "PICSHOT-PDF417-LOCAL-2026", scale: 4))
        ]
    }
    static func nativeCode(_ name: String, payload: String, scale: CGFloat) throws -> CGImage {
        guard let filter = CIFilter(name: name) else { throw failure("Native generator unavailable: " + name) }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        if name == "CIQRCodeGenerator" { filter.setValue("M", forKey: "inputCorrectionLevel") }
        guard let code = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { throw failure("Generator returned no image: " + name) }
        let extent = code.extent.insetBy(dx: -32, dy: -32).integral
        let white = CIImage(color: .white).cropped(to: extent)
        guard let result = CIContext(options: [.cacheIntermediates: false]).createCGImage(code.composited(over: white), from: extent) else { throw failure("Generator rendering failed") }
        return result
    }
    static func modules(_ rows: [String], module: Int) throws -> CGImage {
        guard let first = rows.first, !first.isEmpty, rows.allSatisfy({ $0.count == first.count && $0.allSatisfy { $0 == "0" || $0 == "1" } }) else { throw failure("Malformed module vector") }
        let quiet = 12 * module, bodyHeight = rows.count == 1 ? 180 : rows.count * module
        let width = first.count * module + quiet * 2, height = bodyHeight + quiet * 2
        let context = try context(width: width, height: height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        // ReportLab ECC200DataMatrix.encode() already reverses its matrix for a
        // bottom-left drawing origin; row 0 is the solid bottom finder edge.
        // Draw it at low CoreGraphics y without a second reversal.
        for (row, bits) in rows.enumerated() {
            for (column, bit) in bits.enumerated() where bit == "1" {
                context.fill(CGRect(x: quiet + column * module, y: quiet + row * module, width: module, height: rows.count == 1 ? bodyHeight : module))
            }
        }
        return try required(context.makeImage(), "Module raster failed")
    }
    static func multipleRaster() throws -> (image: CGImage, payloads: [String]) {
        let payloads = ["PICSHOT-MULTI-A", "PICSHOT-MULTI-B", "PICSHOT-C128-MULTI"]
        let a = try nativeCode("CIQRCodeGenerator", payload: payloads[0], scale: 7)
        let b = try nativeCode("CIQRCodeGenerator", payload: payloads[1], scale: 7)
        let c = try nativeCode("CICode128BarcodeGenerator", payload: payloads[2], scale: 3)
        let width = max(a.width + b.width + 160, c.width + 100)
        let height = max(a.height, b.height) + c.height + 160
        let context = try context(width: width, height: height)
        context.interpolationQuality = .none
        context.draw(a, in: CGRect(x: 40, y: c.height + 100, width: a.width, height: a.height))
        context.draw(b, in: CGRect(x: width - b.width - 40, y: c.height + 100, width: b.width, height: b.height))
        context.draw(c, in: CGRect(x: (width - c.width) / 2, y: 40, width: c.width, height: c.height))
        return (try required(context.makeImage(), "Multiple-code raster failed"), payloads)
    }
    static func nearMissRaster() throws -> CGImage {
        let context = try context(width: 600, height: 320)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        // Deliberate barcode-like noise with no start/stop patterns or valid checksum.
        for index in 0..<30 { context.fill(CGRect(x: 40 + index * 16, y: 40, width: 8, height: 90)) }
        for row in 0..<8 { for column in 0..<16 where (row + column).isMultiple(of: 2) {
            context.fill(CGRect(x: 100 + column * 16, y: 160 + row * 16, width: 16, height: 16))
        } }
        return try required(context.makeImage(), "Near-miss raster failed")
    }
    static func deterministicDocument() -> RecognizedBarcodeDocument {
        RecognizedBarcodeDocument(candidates: [
            RecognizedBarcode(symbology: .qr, payload: "https://example.invalid/explicit-open?x=1", quad: RecognizedTextQuad(rect: CGRect(x: 0.08, y: 0.2, width: 0.30, height: 0.60))),
            RecognizedBarcode(symbology: .dataMatrix, payload: "中文 e\u{301} 👩🏽‍💻\n exact ", quad: RecognizedTextQuad(rect: CGRect(x: 0.60, y: 0.25, width: 0.28, height: 0.5)))
        ], supportedSymbologies: RecognizedBarcodeDocument.acceptanceSymbologies)
    }
    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let baseline = await RecognitionService.resourceSnapshot()
        let supported = try RecognitionService.supportedBarcodeSymbologies()
        var accepted: [[String: Any]] = [], skipped: [String] = [], evidence: [String] = []
        for input in try inputs() {
            guard supported.contains(input.symbology) else { skipped.append(input.name); continue }
            let file = "barcode-\(input.name)-input.png"
            try input.image.writePNG(to: evidenceDirectory.appendingPathComponent(file)); evidence.append(file)
            let document = try await RecognitionService.recognizeBarcodes(input.image)
            guard let result = document.results.first(where: { $0.payload == input.payload }) else {
                throw failure("\(input.name) did not decode exact payload. Returned: " + document.results.map { $0.title + ":" + $0.payload }.joined(separator: ", "))
            }
            try require(result.quad != nil, "\(input.name) returned no valid source polygon")
            if input.name == "upca-as-ean13" { try require(result.symbology == .ean13 && result.upcaEquivalent == "012345678905", "UPC-A/EAN-13 distinction lost") }
            else { try require(result.symbology == input.symbology || (input.symbology == .code39 && [.code39FullASCII, .code39Checksum, .code39FullASCIIChecksum].contains(result.symbology)), "Unexpected native symbology for " + input.name) }
            accepted.append(["fixture": input.name, "nativeSymbology": result.symbology.title, "exactPayload": result.payload, "hasGeometry": result.quad != nil])
        }
        let multi = try multipleRaster()
        try multi.image.writePNG(to: evidenceDirectory.appendingPathComponent("barcode-multiple-input.png")); evidence.append("barcode-multiple-input.png")
        let document = try await RecognitionService.recognizeBarcodes(multi.image)
        try require(Set(multi.payloads).isSubset(of: Set(document.results.map(\.payload))), "Multiple-code fixture lost an exact value")
        let rotated = try required(PinImageRenderer.render(image: multi.image, transform: .rotateClockwise), "Rotate failed")
        let rotatedDocument = try await RecognitionService.recognizeBarcodes(rotated)
        try require(Set(multi.payloads).isSubset(of: Set(rotatedDocument.results.map(\.payload))), "Rotated multiple-code fixture lost a value")
        let nearMiss = try await RecognitionService.recognizeBarcodes(nearMissRaster())
        try require(nearMiss.results.isEmpty, "Barcode-like near-miss returned a value")
        let checks = try verifyInteractions(image: multi.image)
        try await verifyStaleResults(image: multi.image, document: document)
        let pin = PinController(originalImage: rotated, currentImage: rotated, isModified: true, recognizeCodes: { _ in rotatedDocument })
        defer { pin.close() }
        pin.bringForward(); pin.setBarcodeSelectionEnabled(true); try await waitForPin(pin)
        let browser = try required(pin.barcodeWindow, "Result browser missing")
        browser.selectResult(at: min(1, rotatedDocument.results.count - 1))
        try snapshot(try required(browser.window, "Browser window missing"), to: evidenceDirectory.appendingPathComponent("barcode-result-browser.png")); evidence.append("barcode-result-browser.png")
        try snapshot(try required(pin.window, "Pin missing"), to: evidenceDirectory.appendingPathComponent("barcode-pin-regions.png")); evidence.append("barcode-pin-regions.png")
        var presentation = pin.presentation; presentation.zoom = 2; pin.applyPresentation(presentation)
        let imageFrame = try required(pin.annotationPresentation?.imageFrame, "Pin image rect missing")
        let overlay = pin.barcodeSelectionOverlay
        let overlayFrame = try required(pin.window, "Pin missing").convertToScreen(overlay.convert(overlay.imageRect, to: nil))
        try require(abs(imageFrame.minX - overlayFrame.minX) < 0.01 && abs(imageFrame.minY - overlayFrame.minY) < 0.01 &&
                    abs(imageFrame.width - overlayFrame.width) < 0.01 && abs(imageFrame.height - overlayFrame.height) < 0.01, "Transformed/zoomed geometry mismatch")
        try pin.applyTransform(.flipHorizontal)
        try require(!pin.barcodeSelectionEnabled && overlay.document == nil && pin.barcodeWindow == nil, "Pixel edit retained stale results")
        pin.close()
        var probes: [BarcodeReleaseProbe] = []
        for _ in 0..<12 { probes.append(try await releaseCycle(image: multi.image, document: document)) }
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !probes.allSatisfy(\.released), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try require(probes.allSatisfy(\.released), "Closed barcode surfaces retained")
        let task = Task { try await RecognitionService.recognizeBarcodes(multi.image) }; task.cancel()
        do { _ = try await task.value; throw failure("Cancelled barcode job returned success") } catch is CancellationError {}
        let settled = await RecognitionService.resourceSnapshot()
        try require(settled.activeJobs <= baseline.activeJobs && settled.waitingJobs <= baseline.waitingJobs, "Barcode jobs did not release admission")
        return ["status": "passed", "realAppleVisionRan": true, "acceptedFixtures": accepted, "unsupportedFixtures": skipped,
                "runtimeSupportedSymbologies": supported.map(\.title), "multipleAndRotatedExactPayloads": true, "nearMissRejected": true,
                "interactionChecks": checks, "staleRestartHideCloseResultsRejected": true, "transformedZoomedGeometry": true, "editInvalidatesResults": true,
                "releaseCycles": probes.count, "retainedBarcodeSurfaces": probes.filter { !$0.released }.count,
                "activeJobsAfter": settled.activeJobs, "waitingJobsAfter": settled.waitingJobs,
                "generalPasteboardChanged": false, "externalURLActuallyOpened": false, "captureStarted": false, "captureUploaded": false,
                "globalInputPosted": false, "physicalExternalApplicationVerified": false,
                "evidenceFiles": evidence, "scope": "Original clean synthetic labels; listed formats only. No broad industrial quality, GS1 semantics, damaged-label, external-app or camera claim."]
    }
    static func verifyInteractions(image: CGImage) throws -> [String: Any] {
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        let document = deterministicDocument(); var opened: [URL] = [], selection: [Int] = []
        let browser = BarcodeResultController(image: image, document: document, pasteboard: pasteboard, openURL: { opened.append($0) })
        defer { browser.close() }
        browser.onSelect = { selection.append($0) }; browser.showWindow(nil)
        try require(opened.isEmpty, "Constructing results opened content")
        browser.selectResult(at: 1)
        try require(browser.copySelected(to: pasteboard) && pasteboard.string(forType: .string) == document.results[1].payload, "Full Unicode payload copy changed bytes")
        try require(!browser.offersOpen && opened.isEmpty, "Plain text offered Open")
        browser.openSelected(nil); try require(opened.isEmpty, "Disallowed payload opened")
        browser.selectResult(at: 0); try require(opened.isEmpty, "Selecting a URL opened it automatically")
        browser.openSelected(nil); try require(opened.count == 1 && opened[0] == document.results[0].safeURL, "Explicit Open did not use validated URL")
        let view = browser.preview.overlay
        browser.window?.contentView?.layoutSubtreeIfNeeded(); browser.preview.layoutSubtreeIfNeeded()
        let box = try required(document.results[1].quad?.bounds, "Missing test polygon")
        let point = CGPoint(x: view.imageRect.minX + box.midX * view.imageRect.width, y: view.imageRect.minY + box.midY * view.imageRect.height)
        view.mouseDown(with: try PinTextSelectionSmokeFixture.mouse(.leftMouseDown, point: point, view: view))
        try require(browser.selectedIndex == 1 && view.selectedIndex == 1, "Native source-region click did not select matching result")
        _ = view.handleKeyDown(try PinTextSelectionSmokeFixture.key("c", code: 8, flags: [.command], window: try required(browser.window, "Window missing")))
        try require(pasteboard.string(forType: .string) == document.results[1].payload, "Native copy key did not preserve exact payload")
        _ = view.handleKeyDown(try PinTextSelectionSmokeFixture.key("", code: 123, flags: [], window: try required(browser.window, "Window missing")))
        try require(browser.selectedIndex == 0, "Keyboard previous-result navigation failed")
        try require(opened.count == 1, "Navigation opened a URL")
        _ = view.handleKeyDown(try PinTextSelectionSmokeFixture.key("", code: 53, flags: [], window: try required(browser.window, "Window missing")))
        try require(browser.document == nil && browser.preview.image == nil && browser.window?.contentView == nil, "Escape did not release standalone results")
        browser.openSelected(nil); try require(opened.count == 1 && !browser.copySelected(to: pasteboard), "Closed results still performed actions")
        return ["nativeRegionSelection": true, "listSelectionSync": selection.contains(1), "keyboardNavigation": true,
                "exactUnicodeCopy": true, "nativeCopyShortcut": true, "escapeReleasesResults": true, "explicitValidatedOpenOnly": true, "injectedOpenerCallCount": opened.count,
                "isolatedPasteboard": true]
    }
    private static func verifyStaleResults(image: CGImage, document: RecognizedBarcodeDocument) async throws {
        let gate = BarcodeFixtureGate()
        let pin = PinController(originalImage: image, currentImage: image, isModified: false, recognizeCodes: { _ in await gate.wait() })
        defer { pin.close(); Task { await gate.finishAll(document) } }
        pin.setBarcodeSelectionEnabled(true); try await waitForGate(gate, count: 1)
        pin.setBarcodeSelectionEnabled(false); pin.setBarcodeSelectionEnabled(true); try await waitForGate(gate, count: 2)
        await gate.finishFirst(document); try await Task.sleep(nanoseconds: 20_000_000)
        try require(pin.barcodeIsRecognizing && pin.barcodeWindow == nil && pin.barcodeSelectionOverlay.document == nil, "Stale completion replaced the newer request")
        await gate.finishFirst(document); try await waitForPin(pin)
        pin.setBarcodeSelectionEnabled(false); pin.setBarcodeSelectionEnabled(true); try await waitForGate(gate, count: 1)
        pin.hideTemporarily(); await gate.finishFirst(document); try await Task.sleep(nanoseconds: 20_000_000)
        try require(!pin.barcodeSelectionEnabled && pin.barcodeWindow == nil, "Hidden pin resurrected barcode results")
        pin.bringForward(); pin.setBarcodeSelectionEnabled(true); try await waitForGate(gate, count: 1)
        pin.close(); await gate.finishFirst(document); try await Task.sleep(nanoseconds: 20_000_000)
        try require(pin.window?.contentView == nil && pin.barcodeWindow == nil && pin.barcodeSelectionOverlay.document == nil, "Closed pin resurrected results")
    }
    private static func waitForGate(_ gate: BarcodeFixtureGate, count: Int) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while (await gate.count) != count, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        let actual = await gate.count
        try require(actual == count, "Recognition race gate did not arrive")
    }
    static func waitForPin(_ pin: PinController) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while pin.barcodeIsRecognizing, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(!pin.barcodeIsRecognizing && pin.barcodeWindow != nil, "Pin barcode mode did not finish")
    }
    private static func releaseCycle(image: CGImage, document: RecognizedBarcodeDocument) async throws -> BarcodeReleaseProbe {
        let controller = autoreleasepool { PinController(originalImage: image, currentImage: image, isModified: false, recognizeCodes: { _ in document }) }
        controller.setBarcodeSelectionEnabled(true); try await waitForPin(controller)
        return autoreleasepool {
            let probe = BarcodeReleaseProbe(controller)
            controller.setBarcodeSelectionEnabled(false); controller.setBarcodeSelectionEnabled(true)
            controller.hideTemporarily(); controller.close(); return probe
        }
    }
    private static func context(width: Int, height: Int) throws -> CGContext {
        guard PinImageRenderer.allowsRasterSize(width: width, height: height), let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failure("Raster allocation failed") }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height)); return context
    }
    private static func snapshot(_ window: NSWindow, to url: URL) throws {
        window.displayIfNeeded()
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw failure("Snapshot allocation failed") }
        view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage, let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failure("Snapshot PNG allocation failed") }
        // cacheDisplay omits NSWindow's background. Resolve dynamic colors in the
        // window appearance, while a borderless pin's clear background stays clear.
        window.effectiveAppearance.performAsCurrentDrawingAppearance { context.setFillColor(window.backgroundColor.cgColor) }
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        try required(context.makeImage(), "Snapshot PNG encoding failed").writePNG(to: url)
    }
    private static func required<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw failure(message) }; return value }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw failure(message) } }
    private static func failure(_ message: String) -> Error { PicShotError.message("Barcode acceptance fixture: " + message) }
}

@MainActor private final class BarcodeReleaseProbe {
    weak var controller: PinController?
    weak var overlay: BarcodeSelectionOverlay?
    weak var browser: BarcodeResultController?
    weak var preview: BarcodeSourcePreview?
    init(_ controller: PinController) {
        self.controller = controller; overlay = controller.barcodeSelectionOverlay
        browser = controller.barcodeWindow; preview = controller.barcodeWindow?.preview
    }
    var released: Bool { autoreleasepool { controller == nil && overlay == nil && browser == nil && preview == nil } }
}

private actor BarcodeFixtureGate {
    private var waiting: [CheckedContinuation<RecognizedBarcodeDocument, Never>] = []
    var count: Int { waiting.count }
    func wait() async -> RecognizedBarcodeDocument { await withCheckedContinuation { waiting.append($0) } }
    func finishFirst(_ document: RecognizedBarcodeDocument) { if !waiting.isEmpty { waiting.removeFirst().resume(returning: document) } }
    func finishAll(_ document: RecognizedBarcodeDocument) { while !waiting.isEmpty { finishFirst(document) } }
}
