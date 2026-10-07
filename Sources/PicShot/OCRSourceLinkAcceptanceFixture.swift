import AppKit

/// Called by installed acceptance after it has obtained a real Vision result. It exercises
/// production controls on that exact document; it does not claim OCR accuracy or post input.
@MainActor enum OCRSourceLinkAcceptanceFixture {
    static func verify(result: RecognitionResult, sourceImage: CGImage, evidenceDirectory: URL? = nil) throws -> [String: Any] {
        _ = NSApplication.shared
        guard let document = result.document, let first = document.units.first, document.units.count >= 2 else {
            throw PicShotError.message("Source-link acceptance requires a recognized document with at least two units.")
        }
        let pasteboardCount = NSPasteboard.general.changeCount
        let controller = TextResultController(result: result, sourceImage: sourceImage, defaults: nil)
        defer { controller.close() }
        guard let window = controller.window, let root = window.contentView,
              let text = descendants(root).compactMap({ $0 as? NSTextView }).first else {
            throw PicShotError.message("OCR result controls missing.")
        }
        var callbacks: [[NSRange]] = []
        controller.onSourceSelection = { received, ranges in
            if received == document { callbacks.append(ranges) }
        }
        try require(controller.resultDocument == document && !controller.isSourcePreviewVisible, "Compact result lost its document")
        text.setSelectedRange(first.range)
        controller.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: text))
        try require(controller.selectedSourceRanges == [first.range] && callbacks.last == [first.range], "Output did not link to its exact source unit")
        controller.setSourcePreviewVisible(true); root.layoutSubtreeIfNeeded()
        guard let overlay = descendants(root).compactMap({ $0 as? PinTextSelectionOverlay }).first else {
            throw PicShotError.message("Source preview did not reuse the selection overlay.")
        }
        let last = document.units[document.units.count - 1]
        overlay.select(last.range)
        try require(text.selectedRange() == last.range, "Source unit did not select its output range")
        if let evidenceDirectory {
            try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
            controller.showWindow(nil)
            try PinWorkflowSnapshot.write(root, to: evidenceDirectory.appendingPathComponent("ocr-source-linked-result.png"))
        }
        let prefix = "NEW 👩🏽‍💻 "
        text.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: prefix); text.didChangeText()
        text.setSelectedRange(NSRange(location: 0, length: prefix.utf16.count))
        try require(controller.selectedSourceRanges.isEmpty, "Inserted text acquired false source geometry")
        controller.selectSourceRanges([last.range], document: document)
        try require((text.string as NSString).substring(with: text.selectedRange()) == document.substring(last.range), "Edit shifted the source link incorrectly")
        controller.applyRecognitionResult(RecognitionResult(text: result.text, barcodes: [document.substring(first.range)], document: document))
        text.setSelectedRange(NSRange(location: result.text.utf16.count, length: controller.resultText.utf16.count - result.text.utf16.count))
        try require(controller.selectedSourceRanges.isEmpty, "Barcode appendix acquired text geometry")
        let menus = descendants(root).compactMap { $0 as? NSPopUpButton }.compactMap(\.menu)
        guard let join = menus.flatMap(\.items).first(where: { $0.title == "合并换行" }), let action = join.action else {
            throw PicShotError.message("Text layout menu missing.")
        }
        try require(NSApp.sendAction(action, to: join.target, from: join), "Join-lines menu action failed")
        controller.selectSourceRanges([last.range], document: document)
        try require((text.string as NSString).substring(with: text.selectedRange()) == document.substring(last.range), "Layout lost source correspondence")
        controller.close()
        try require(controller.resultText.isEmpty && controller.resultDocument == nil && controller.onSourceSelection == nil,
                    "Closed result retained source data or callbacks")
        try require(NSPasteboard.general.changeCount == pasteboardCount, "Source-link acceptance changed the general clipboard")
        return ["status": "passed", "exactDocumentPreserved": true, "sourceUnitCount": document.units.count,
                "checks": ["compact-default", "output-to-source", "source-to-output", "native-edits-unmapped", "unchanged-edit-spans", "barcode-appendix-unmapped", "join-lines-source-map", "close-clears-document"],
                "generalPasteboardChanged": false, "userDefaultsChanged": false, "globalInputPosted": false,
                "screenshotBackground": PinWorkflowSnapshot.backgroundDescription,
                "realAppleVisionRanHere": false, "scope": "Native result-link controls over caller-supplied recognition; caller records actual Vision provenance."]
    }
    private static func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw PicShotError.message(message) }
    }
}
