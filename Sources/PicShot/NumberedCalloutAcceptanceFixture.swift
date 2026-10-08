import AppKit
import CoreGraphics
import CryptoKit
import ImageIO
import PicShotCore

struct NumberedCalloutAcceptanceEvidence: Codable {
    var status = "running"
    var checks: [String: Bool] = [:]
    var files: [String] = []
    var exportedSHA256 = ""
    var closedControllerCount = 0
    var releasedControllerCount = 0
    var commentLifecycle: NumberedCalloutLifecycleEvidence?
    var maximumConcurrentOwnedEditors = 1
    var maximumFixtureRasterPixels = 4_000_000
    var syntheticOwnedWindows = true
    var globalInputAttempted = false
    var screenCaptureAttempted = false
    var networkAttempted = false
    var generalPasteboardTouched = false
    var standardDefaultsWritten = false
    var error: String?
    var limitations = ["Synthetic 1x source and owned-window NSEvents, not physical Retina capture or global input",
                      "Text commands use owned NSWindow key-equivalent dispatch followed, when unhandled, by AppKit responder actions; copy uses a controlled NSTextView probe without a system pasteboard",
                      "Prompt owner/text-system cleanup and separately bounded framework input/context retirement; the historical 10 ms all-object assumption is replaced explicitly. Not a process-memory or leak claim"]
}

/// Opt-in installed-app fixture; no TCC, external input, preference changes or network.
@MainActor
enum NumberedCalloutAcceptanceFixture {
    static func verify(evidenceDirectory: URL) async throws -> NumberedCalloutAcceptanceEvidence {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        var evidence = NumberedCalloutAcceptanceEvidence()
        var releaseMonitor: NumberedCalloutReleaseMonitor?
        let reportURL = evidenceDirectory.appendingPathComponent("annotation-callouts.json")
#if PICSHOT_CALLOUT_RETIREMENT_DIAGNOSTICS
        defer {
            if let path = ProcessInfo.processInfo.environment["PICSHOT_CALLOUT_RETIREMENT_DIAGNOSTIC_PATH"],
               let releaseMonitor {
                do {
                    // The combined fixture owns the whole annotation-details
                    // tree; the launch report additionally protects all UI evidence.
                    var roots = [evidenceDirectory.lastPathComponent == "callouts"
                        ? evidenceDirectory.deletingLastPathComponent() : evidenceDirectory]
                    if let report = ProcessInfo.processInfo.environment["PICSHOT_SMOKE_REPORT"], report.hasPrefix("/") {
                        roots.append(URL(fileURLWithPath: report).deletingLastPathComponent())
                    }
                    try releaseMonitor.writeRetirementDiagnostics(to: path, excluding: roots, acceptanceStatus: evidence.status)
                } catch {
                    FileHandle.standardError.write(Data("Callout retirement diagnostic write failed: \(error)\n".utf8))
                }
            }
        }
#endif
        // Fail a read-only destination before showing any UI.
        try JSONEncoder().encode(evidence).write(to: reportURL, options: .atomic)
        do {
            guard let screen = NSScreen.main, let displayID = screen.displayID,
                  screen.frame.width >= 760, screen.frame.height >= 600 else { throw failure("Native display of at least 760 × 600 points required") }
            let size = CGSize(width: min(1180, screen.frame.width), height: min(760, screen.frame.height))
            let source = try whiteImage(size), originalDigest = try digest(source)
            let frame = CGRect(origin: screen.frame.origin, size: size)
            let captured = try CapturedImage.frozenRegion(image: source, displayID: displayID, displayFrame: frame,
                selection: CGRect(x: 30, y: 80, width: size.width - 60, height: size.height - 170),
                capturedAt: Date(timeIntervalSince1970: 1_704_164_645))
            try await withEditor(captured, verifyOutput: true) { editor in
                try await exercise(editor, directory: evidenceDirectory, evidence: &evidence)
            }
            evidence.closedControllerCount += 1; evidence.releasedControllerCount += 1
            evidence.checks["nativeApplyCallbackMatchesFlattenedPixels"] = true
            try await withEditor(captured, frozenPresentation: false) { editor in
                let checks = try await verifyEditingRoutes(in: editor, evidenceDirectory: evidenceDirectory)
                evidence.checks.merge(checks) { _, new in new }
                evidence.files.append("annotation-callout-active-comment-save.png")
            }
            evidence.closedControllerCount += 1; evidence.releasedControllerCount += 1
            for (name, x, y) in [("top-left", CGFloat(6), CGFloat(6)), ("top-right", size.width - 186, CGFloat(6)),
                                 ("bottom-left", CGFloat(6), size.height - 126), ("bottom-right", size.width - 186, size.height - 126)] {
                let edge = try CapturedImage.frozenRegion(image: source, displayID: displayID, displayFrame: frame,
                    selection: CGRect(x: x, y: y, width: 180, height: 120))
                try await withEditor(edge) { editor in
                    let canvas = editor.annotationCanvas, imageFrame = editor.editorImageScreenFrame
                    try choose(.number, editor); try click(canvas, CGPoint(x: 32, y: 52))
                    let filename = "ui-callout-\(name).png"
                    try await snapshot(editor, filename: filename, directory: evidenceDirectory)
                    try require(editor.editorImageScreenFrame == imageFrame, "Palette moved the edge capture")
                    evidence.files.append(filename)
                }
                evidence.closedControllerCount += 1; evidence.releasedControllerCount += 1
            }
            evidence.checks["allFourEdgePalettesVisibleAndImageAnchored"] = true
            let monitor = try NumberedCalloutReleaseMonitor(expectedCycles: 6)
            releaseMonitor = monitor
            for _ in 0..<6 {
                let probe = try closeUncommittedCommentCycle(captured)
                evidence.closedControllerCount += 1
                try await monitor.append(probe)
                evidence.releasedControllerCount += 1
            }
            try await monitor.finish()
            evidence.commentLifecycle = monitor.evidence
            try require(try digest(source) == originalDigest, "Fixture changed original pixels")
            evidence.checks["sourcePixelsUnchanged"] = true
            evidence.checks["repeatedControllerAndInlineInputCleanup"] = evidence.closedControllerCount == evidence.releasedControllerCount
            evidence.status = "passed"; evidence.files.append(reportURL.lastPathComponent)
            try JSONEncoder().encode(evidence).write(to: reportURL, options: .atomic)
            return evidence
        } catch {
            evidence.status = "failed"; evidence.error = error.localizedDescription
            evidence.commentLifecycle = releaseMonitor?.failedEvidence()
            try? JSONEncoder().encode(evidence).write(to: reportURL, options: .atomic)
            throw error
        }
    }

    private static func withEditor(_ capture: CapturedImage, verifyOutput: Bool = false, frozenPresentation: Bool = true,
                                  body: (ImageEditorController) async throws -> Void) async throws {
        var appliedImage: CGImage?, applicationCount = 0
        var editor: ImageEditorController? = ImageEditorController(image: capture.image, presentation: frozenPresentation ? capture.presentation : nil,
            onSave: { _ in }, onPin: { _ in }, onOCR: { _ in },
            onApply: { image in appliedImage = image; applicationCount += 1; return false }, copyAction: { _ in })
        weak var weakEditor = editor
        defer { editor?.close() }
        editor?.window?.appearance = NSAppearance(named: .aqua)
        editor?.showWindow(nil); editor?.window?.makeKeyAndOrderFront(nil)
        try await body(editor!)
        if verifyOutput {
            let expected = try digest(raster(editor!.annotationCanvas))
            try press("editor.applyToPin", editor!)
            try require(applicationCount == 1 && (try digest(unwrap(appliedImage, "Native apply callback missing image"))) == expected,
                        "Native apply output differs from flattened pixels")
            appliedImage = nil
        }
        // Functional bodies finish their comment edits. Active-input close and
        // framework retirement are checked separately by the six-cycle monitor.
        try require(editor?.annotationCanvas.activeNumberCommentInput == nil,
                    "Functional fixture left an unfinished comment edit")
        editor?.close()
        try require(editor?.isClosed == true && editor?.window?.contentView == nil && editor?.window?.delegate == nil,
                    "Owned window did not detach on close")
        try require(editor?.annotationCanvas.activeNumberCommentInput == nil && editor?.annotationCanvas.retainedPresentationRaster == nil,
                    "Owned comment input or cached raster survived close")
        editor = nil
        try await Task.sleep(nanoseconds: 10_000_000)
        try require(weakEditor == nil, "Owned controller remained retained")
    }

    static func verifyRepeatedCommentClose(_ capture: CapturedImage, frozenPresentation: Bool = true,
                                           cycles: Int = 6) async throws -> NumberedCalloutLifecycleEvidence {
        let monitor = try NumberedCalloutReleaseMonitor(expectedCycles: cycles)
        for _ in 0..<cycles {
            let probe = try closeUncommittedCommentCycle(capture, frozenPresentation: frozenPresentation)
            try await monitor.append(probe)
        }
        try await monitor.finish()
        return monitor.evidence
    }

    /// Return only weak probes from a separate synchronous scope. Text and size
    /// are copied before terminal detachment; the comment stays uncommitted.
    @inline(never)
    private static func closeUncommittedCommentCycle(_ capture: CapturedImage, frozenPresentation: Bool = true) throws
        -> NumberedCalloutClosedInputProbe {
        try autoreleasepool {
            let editor = ImageEditorController(image: capture.image, presentation: frozenPresentation ? capture.presentation : nil,
                onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, onApply: { _ in false }, copyAction: { _ in })
            defer { editor.close() }
            editor.window?.appearance = NSAppearance(named: .aqua)
            editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
            let canvas = editor.annotationCanvas
            try choose(.number, editor); try click(canvas, CGPoint(x: 50, y: 50))
            try press("annotation.numberComment", editor)
            let input = try unwrap(canvas.activeNumberCommentInput, "Repeated cycle did not open comment editor")
            let manager = try unwrap(input.undoManager, "Repeated cycle has no comment undo manager")
            try require(editor.window?.firstResponder === input, "Repeated comment input did not become first responder")
            input.insertText("中 English 👩🏽‍💻", replacementRange: NSRange(location: 0, length: 0))
            try require(input.string == "中 English 👩🏽‍💻" && canvas.annotations[0].numberComment.isEmpty,
                        "Repeated cycle did not leave uncommitted text")
            let probe = NumberedCalloutClosedInputProbe(editor: editor, input: input, undoManager: manager)
            editor.close(); probe.didClose()
            try require(editor.isClosed && editor.window?.contentView == nil && editor.window?.delegate == nil,
                        "Owned window did not detach on close")
            try require(canvas.activeNumberCommentInput == nil && canvas.retainedPresentationRaster == nil,
                        "Owned comment input or cached raster survived close")
            try require(canvas.annotations[0].numberComment.isEmpty && input.delegate == nil
                        && editor.window?.firstResponder !== input && !manager.canUndo && !manager.canRedo,
                        "Close did not discard comment editing and its local undo history")
            try require(input.textContainer == nil && input.textStorage == nil && input.textLayoutManager == nil,
                        "Terminal comment input retained its text-system backing")
            return probe
        }
    }

    private static func exercise(_ editor: ImageEditorController, directory: URL,
                                 evidence: inout NumberedCalloutAcceptanceEvidence) async throws {
        let canvas = editor.annotationCanvas
        try choose(.number, editor)
        try field("annotation.numberNext", "7", editor)
        try drag(canvas, from: CGPoint(x: 80, y: 240), to: CGPoint(x: 160, y: 330))
        try click(canvas, CGPoint(x: 260, y: 90)); try click(canvas, CGPoint(x: 460, y: 260))
        try require(canvas.annotations.map(\.number) == [7, 8, 9] && canvas.numberSequence.nextValue == 10, "Manual start or sequential creation failed")
        try require(canvas.annotations[0].points.count == 2, "Drag did not attach leader arrow")
        try choose(.select, editor); try click(canvas, CGPoint(x: 260, y: 90))
        canvas.keyDown(with: try key(canvas, code: 51, value: "\u{7f}"))
        try require(canvas.annotations.map(\.number) == [7, 9] && canvas.numberSequence.nextValue == 10, "Default deletion reused a serial or renumbered")
        try undo(canvas); try require(canvas.annotations.map(\.number) == [7, 8, 9] && canvas.numberSequence.nextValue == 10, "Deletion undo lost counter")
        try click(canvas, CGPoint(x: 260, y: 90)); try press("annotation.numberCloseGaps", editor)
        canvas.keyDown(with: try key(canvas, code: 51, value: "\u{7f}"))
        try require(canvas.annotations.map(\.number) == [7, 8] && canvas.numberSequence.nextValue == 9, "Optional deletion gap closing failed")
        try undo(canvas); try undo(canvas, redo: true)
        try require(canvas.annotations.map(\.number) == [7, 8] && canvas.numberSequence.nextValue == 9, "Deletion redo lost counter")
        evidence.checks["manualSevenCreationDeleteUndoRedoAndDocumentCounter"] = true

        try click(canvas, CGPoint(x: 80, y: 240))
        try field("annotation.numberValue", "27", editor)
        try picker("annotation.numberStyle", NumberedCalloutStyle.alphabetic.title, editor)
        try require(canvas.annotations[0].numberStyle.label(for: canvas.annotations[0].number) == "AA", "Alphabetic 26/27 boundary failed")
        try require(canvas.numberSequence.nextValue == 9, "Individual value edit changed next value")
        let alpha = try digest(raster(canvas))
        try picker("annotation.numberStyle", NumberedCalloutStyle.roman.title, editor)
        try field("annotation.numberValue", "49", editor)
        try require(canvas.annotations[0].numberStyle.label(for: canvas.annotations[0].number) == "XLIX", "Roman subtractive boundary failed")
        let valueField: NSTextField = try control("annotation.numberValue", editor)
        valueField.selectText(nil)
        let valueEditor = try unwrap(valueField.currentEditor() as? NSTextView, "Native value field editor missing")
        valueEditor.setSelectedRange(NSRange(location: 0, length: valueEditor.string.utf16.count))
        valueEditor.insertText("300", replacementRange: valueEditor.selectedRange())
        valueEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try require(canvas.annotations[0].number == 49, "Escape committed the edited numeric value")
        try require(try digest(raster(canvas)) != alpha, "Numbering style did not change pixels")
        let beforeComment = try digest(raster(canvas))
        try press("annotation.numberComment", editor)
        var input = try unwrap(canvas.activeNumberCommentInput, "Native comment editor missing")
        input.insertText("步骤七 · مرحبا · 👩🏽‍💻\n確認して次へ", replacementRange: NSRange(location: 0, length: 0))
        input.keyDown(with: try key(canvas, code: 53, value: "\u{1b}"))
        try require(canvas.activeNumberCommentInput == nil && (try digest(raster(canvas))) == beforeComment, "Cancel changed committed comment pixels")
        try press("annotation.numberComment", editor)
        input = try unwrap(canvas.activeNumberCommentInput, "Native comment editor did not reopen")
        input.insertText(String(repeating: "界", count: 2049), replacementRange: NSRange(location: 0, length: 0))
        try require(input.string.isEmpty, "Native paste exceeded comment budget")
        input.insertText("步骤七 · مرحبا · 👩🏽‍💻\n確認して次へ", replacementRange: NSRange(location: 0, length: 0))
        input.keyDown(with: try key(canvas, code: 36, value: "\r", flags: .command))
        try require(canvas.activeNumberCommentInput == nil && canvas.annotations[0].numberComment.contains("مرحبا"), "Native comment acceptance lost multilingual text")
        let commented = try digest(raster(canvas))
        try undo(canvas); try require(try digest(raster(canvas)) == beforeComment, "Comment did not use a single undo snapshot")
        try undo(canvas, redo: true); try require(try digest(raster(canvas)) == commented, "Comment redo pixels differed")
        evidence.checks["alphaRomanValuesMultilingualCommentsBoundsAndCancelledEdits"] = true

        try click(canvas, CGPoint(x: 80, y: 240))
        let original = canvas.annotations[0], center = original.points[0]
        try drag(canvas, from: center, to: CGPoint(x: center.x + 20, y: center.y - 20))
        let moved = canvas.annotations[0]
        try require(moved.points[1] == CGPoint(x: original.points[1].x + 20, y: original.points[1].y - 20), "Moving callout left leader behind")
        let sizeHandle = try unwrap(moved.handles(zoom: canvas.zoom).first { $0.0 == .numberSize }?.1, "Missing size handle")
        try drag(canvas, from: sizeHandle, to: CGPoint(x: sizeHandle.x + 10, y: sizeHandle.y + 10))
        try require(canvas.annotations[0].numberRadius > moved.numberRadius, "Badge resize did not change model")
        let commentHandle = try unwrap(canvas.annotations[0].handles(zoom: canvas.zoom).first { $0.0 == .numberCommentSize }?.1, "Missing comment resize handle")
        try drag(canvas, from: commentHandle, to: CGPoint(x: commentHandle.x + 15, y: commentHandle.y - 12))
        try field("annotation.rotation", "15", editor)
        let rotated = canvas.annotations[0], leader = rotated.points[1].applying(rotated.transform)
        try drag(canvas, from: leader, to: CGPoint(x: leader.x + 10, y: leader.y - 15))
        try require(canvas.annotations[0].points[0] == rotated.points[0], "Rotated tip edit moved badge")
        let transformed = try digest(raster(canvas))
        try undo(canvas)
        try click(canvas, rotated.points[0])
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, leader))
        canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, CGPoint(x: leader.x + 70, y: leader.y)))
        canvas.keyDown(with: try key(canvas, code: 53, value: "\u{1b}"))
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, leader))
        try undo(canvas, redo: true)
        try require(try digest(raster(canvas)) == transformed, "Canceled transform consumed redo or changed pixels")
        evidence.checks["moveResizeRotateLeaderEditAndCancelPreserveRedoPixels"] = true

        try click(canvas, canvas.annotations[0].points[0])
        try field("annotation.numberRenumberStart", "7", editor); try press("annotation.numberRenumber", editor)
        try require(canvas.annotations.map(\.number) == [7, 8] && canvas.numberSequence.nextValue == 9, "Explicit renumber did not use creation order")
        let renumbered = try digest(raster(canvas))
        for _ in 0..<2 {
            try undo(canvas); try undo(canvas, redo: true)
            try require(try digest(raster(canvas)) == renumbered && canvas.numberSequence.nextValue == 9, "Renumber undo/redo changed pixels or counter")
        }
        try click(canvas, canvas.annotations[0].points[0])
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            editor.window?.appearance = NSAppearance(named: appearance)
            let filename = "ui-callout-\(name).png"
            try await snapshot(editor, filename: filename, directory: directory); evidence.files.append(filename)
        }
        let flattened = try raster(canvas)
        let output = directory.appendingPathComponent("annotation-callouts-result.png")
        try flattened.writePNG(to: output)
        let data = try Data(contentsOf: output)
        let source = try unwrap(CGImageSourceCreateWithData(data as CFData, nil), "PNG export could not be opened")
        try require(CGImageSourceGetCount(source) == 1, "Export was not a single flattened image")
        let decoded = try unwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), "PNG export could not be decoded")
        let digestValue = try digest(flattened)
        try require(try digest(decoded) == digestValue, "Decoded exported pixels differed from canvas render")
        let preview = try unwrap(canvas.rasterForBoundaryPreview(), "Canvas presentation cache missing")
        try require(try digest(preview) == digestValue, "Cached canvas pixels differed from flattened export")
        evidence.exportedSHA256 = digestValue; evidence.files.append(output.lastPathComponent)
        evidence.checks["explicitRenumberTwoUndoRedoCyclesAndExactPNGCanvasPixels"] = true

        try choose(.number, editor); try field("annotation.numberNext", "3999", editor)
        try click(canvas, CGPoint(x: 560, y: 60))
        try require(canvas.numberSequence.isExhausted, "Maximum serial did not stop incrementing")
        let count = canvas.annotations.count
        try click(canvas, CGPoint(x: 640, y: 60)); try require(canvas.annotations.count == count, "Maximum serial silently repeated")
        try undo(canvas); try require(!canvas.numberSequence.isExhausted && canvas.numberSequence.nextValue == 3999, "Undo did not restore available last serial")
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, CGPoint(x: 560, y: 60)))
        canvas.keyDown(with: try key(canvas, code: 53, value: "\u{1b}"))
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, CGPoint(x: 560, y: 60)))
        try undo(canvas, redo: true); try require(canvas.numberSequence.isExhausted && canvas.annotations.count == count, "Canceled creation consumed redo or sequence")
        evidence.checks["maximumValueExhaustionUndoAndCancelledCreation"] = true
    }

    /// Also invoked directly by focused regressions. This uses real export preview
    /// preparation, without a destination picker, file publication or clipboard.
    static func verifyEditingRoutes(in editor: ImageEditorController, evidenceDirectory: URL) async throws -> [String: Bool] {
        let window = try unwrap(editor.window, "Routing fixture has no owned window"), canvas = editor.annotationCanvas
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        window.makeKeyAndOrderFront(nil)
        try choose(.number, editor); try click(canvas, CGPoint(x: 90, y: 180))
        let count = canvas.annotations.count, original = canvas.annotations[0].numberComment
        canvas.duplicateSelection()
        let documentRedoIDs = canvas.annotations.map(\.id)
        try undo(canvas); try click(canvas, CGPoint(x: 90, y: 180))
        canvas.beginNumberComment()
        let input = try unwrap(canvas.activeNumberCommentInput, "Routing fixture has no comment input")
        let manager = try unwrap(input.undoManager, "Comment has no local undo manager")
        manager.removeAllActions(); manager.beginUndoGrouping()
        input.insertText("Local undo 中文", replacementRange: NSRange(location: 0, length: 0))
        input.breakUndoCoalescing(); manager.endUndoGrouping()
        try routeTextCommand(window, canvas: canvas, value: "z", code: 6, selector: Selector(("undo:")))
        try require(input.string == original && canvas.activeNumberCommentInput === input && canvas.annotations.count == count,
                    "Window Command-Z escaped the comment-local undo stack")
        try routeTextCommand(window, canvas: canvas, value: "z", code: 6, flags: [.command, .shift], selector: Selector(("redo:")))
        try require(input.string == "Local undo 中文" && canvas.annotations[0].numberComment == original,
                    "Window Command-Shift-Z changed document history")
        _ = window.performKeyEquivalent(with: try key(canvas, code: 2, value: "d", flags: .command))
        try require(canvas.annotations.count == count && canvas.activeNumberCommentInput === input, "Text Command-D duplicated a document annotation")
        window.sendEvent(try key(canvas, code: 53, value: "\u{1b}"))
        try require(canvas.activeNumberCommentInput == nil && canvas.annotations[0].numberComment == original && !editor.isClosed,
                    "Window Escape committed text or closed the editor")
        try require(window.performKeyEquivalent(with: key(canvas, code: 6, value: "z", flags: [.command, .shift])), "Window document redo was not handled")
        try require(canvas.annotations.map(\.id) == documentRedoIDs, "Text-local undo/cancel consumed the document redo branch")
        try undo(canvas); try click(canvas, CGPoint(x: 90, y: 180))

        // Check the ordinary inline input too: the shortcut guard must not be
        // limited to number comments, and cancellation must preserve the mark.
        editor.beginInlineText(at: CGPoint(x: 350, y: 200), editing: nil)
        let ordinary = try unwrap(editor.activeInlineTextView, "Ordinary inline input missing")
        let ordinaryUndo = try unwrap(ordinary.undoManager, "Ordinary text undo manager missing")
        ordinaryUndo.removeAllActions(); ordinaryUndo.beginUndoGrouping()
        ordinary.insertText("Ordinary text", replacementRange: NSRange(location: 0, length: 0))
        ordinary.breakUndoCoalescing(); ordinaryUndo.endUndoGrouping()
        try routeTextCommand(window, canvas: canvas, value: "z", code: 6, selector: Selector(("undo:")))
        try require(ordinary.string.isEmpty && editor.activeInlineTextView === ordinary && canvas.annotations.count == count,
                    "Window text undo changed ordinary annotation history")
        window.sendEvent(try key(canvas, code: 53, value: "\u{1b}"))
        try require(editor.activeInlineTextView == nil && canvas.annotations.count == count, "Ordinary inline cancel changed annotations")

        let probe = NumberedCalloutTextCopyProbe(frame: CGRect(x: 10, y: 10, width: 200, height: 50))
        probe.string = "selected text"; probe.isFieldEditor = true
        canvas.addSubview(probe); window.makeFirstResponder(probe)
        probe.setSelectedRange(NSRange(location: 0, length: 8))
        let previousCopy = canvas.onCopy
        var imageCopies = 0; canvas.onCopy = { imageCopies += 1 }
        defer { canvas.onCopy = previousCopy; probe.removeFromSuperview() }
        try routeTextCommand(window, canvas: canvas, value: "c", code: 8, selector: #selector(NSText.copy(_:)))
        _ = window.performKeyEquivalent(with: try key(canvas, code: 2, value: "d", flags: .command))
        try require(probe.copiedText == "selected" && imageCopies == 0 && canvas.annotations.count == count,
                    "Window text/field-editor copy or duplicate shortcut reached canvas actions")
        probe.removeFromSuperview(); window.makeFirstResponder(canvas)
        canvas.onCopy = previousCopy

        // Direct incidental scale changes retain the original image conversion,
        // including unequal horizontal/vertical scales used by pinned images.
        canvas.zoom = 0.6; canvas.verticalZoom = 0.4
        canvas.beginNumberComment()
        let expectedIncidental = try resizeComment(canvas, by: CGSize(width: 18, height: 12))
        canvas.zoom = 0.9; canvas.verticalZoom = 0.7
        canvas.finishNumberComment(commit: true)
        try require(close(canvas.annotations[0].numberCommentSize, expectedIncidental), "Resized comment was reinterpreted at a newer zoom")
        canvas.verticalZoom = nil
        for action in ["100% 像素", "适合窗口", "window resize"] {
            if action == "适合窗口" { window.setContentSize(CGSize(width: 760, height: 520)) }
            canvas.beginNumberComment()
            let expectedSize = try resizeComment(canvas, by: CGSize(width: 12, height: 8))
            if action == "window resize" {
                window.setContentSize(CGSize(width: 820, height: 570))
                try await Task.sleep(nanoseconds: 40_000_000)
                window.contentView?.layoutSubtreeIfNeeded()
            } else { try menuAction(action, editor) }
            try require(canvas.activeNumberCommentInput == nil && close(canvas.annotations[0].numberCommentSize, expectedSize),
                        "\(action) failed to commit comment before changing its image scale")
        }

        let originalExportCount = ImageExportController.activeSessionCount
        for (index, useCommand) in [false, true].enumerated() {
            let text = useCommand ? "Command-S typed comment · 中文" : "Save-button typed comment · مرحبا"
            canvas.beginNumberComment()
            let edit = try unwrap(canvas.activeNumberCommentInput, "Save fixture input missing")
            edit.insertText(text, replacementRange: NSRange(location: 0, length: edit.string.utf16.count))
            var expectedMarks = canvas.annotations; expectedMarks[0].numberComment = text
            let expected = try digest(unwrap(ImageEditorRenderer.render(image: canvas.image, annotations: expectedMarks), "Cannot build expected save pixels"))
            if useCommand {
                canvas.automaticMosaicDrawHandler = { _ in }
                _ = window.performKeyEquivalent(with: try key(canvas, code: 1, value: "s", flags: .command))
                try require(canvas.activeNumberCommentInput === edit && ImageExportController.activeSessionCount == originalExportCount,
                            "Save bypassed the automatic-mosaic output gate")
                canvas.automaticMosaicDrawHandler = nil
                try require(window.performKeyEquivalent(with: key(canvas, code: 1, value: "s", flags: .command)), "Window Command-S was not handled")
            } else { try press("editor.save", editor) }
            try require(canvas.activeNumberCommentInput == nil && canvas.annotations[0].numberComment == text,
                        "Save did not commit active number comment")
            let controller = try unwrap(window.childWindows?.compactMap { $0.delegate as? ImageExportController }.first,
                                        "Save did not open its owned export controller")
            defer { controller.cancelExport() }
            let deadline = Date().addingTimeInterval(15)
            while controller.latestArtifact == nil && !controller.isClosed && Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let artifact = try unwrap(controller.latestArtifact, "Save PNG preparation failed: \(controller.statusLabel.stringValue)")
            try require(artifact.options.format == .png, "Save fixture did not prepare default PNG")
            let source = try unwrap(CGImageSourceCreateWithData(artifact.data as CFData, nil), "Prepared PNG cannot be read")
            let image = try unwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), "Prepared PNG cannot be decoded")
            try require(try digest(image) == expected, "Prepared export pixels lost the active comment")
            if index == 0 { try artifact.data.write(to: evidenceDirectory.appendingPathComponent("annotation-callout-active-comment-save.png"), options: .atomic) }
            controller.cancelExport(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(canvas)
            try require(ImageExportController.activeSessionCount == originalExportCount, "Canceled export retained an owned session")
        }
        return ["windowTextUndoRedoCopyAndCancelStayWithTextResponder": true,
                "resizedCommentPreservesImageGeometryAcrossZoomAndResize": true,
                "activeCommentSaveAndCommandSPreparedPixelsPreserveMosaicGate": true]
    }

    private static func routeTextCommand(_ window: NSWindow, canvas: ImageEditorCanvas, value: String, code: UInt16,
                                         flags: NSEvent.ModifierFlags = .command, selector: Selector) throws {
        // This is the owned window entry point. If AppKit leaves the key to the
        // Edit menu, issue that menu's standard action to the same text responder.
        let textResponder = try unwrap(window.firstResponder as? NSTextView, "No text first responder")
        if !window.performKeyEquivalent(with: try key(canvas, code: code, value: value, flags: flags)) {
            try require(textResponder.tryToPerform(selector, with: window), "AppKit text responder-chain command was not accepted")
        }
    }

    private static func resizeComment(_ canvas: ImageEditorCanvas, by delta: CGSize) throws -> CGSize {
        let input = try unwrap(canvas.activeNumberCommentInput, "Resize fixture input missing")
        let box = try unwrap(input.superview as? InlineAnnotationTextBox, "Resize fixture box missing")
        input.string = "Resized attached comment"
        let start = box.convert(CGPoint(x: box.bounds.maxX - 2, y: 2), to: nil)
        func event(_ type: NSEvent.EventType, _ location: CGPoint) throws -> NSEvent {
            try unwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1), "Cannot create comment resize event")
        }
        let end = CGPoint(x: start.x + delta.width, y: start.y - delta.height)
        box.mouseDown(with: try event(.leftMouseDown, start)); box.mouseDragged(with: try event(.leftMouseDragged, end)); box.mouseUp(with: try event(.leftMouseUp, end))
        try require(box.wasResized, "Native comment resize did not begin")
        return CGSize(width: min(600, max(60, box.bounds.width / max(0.05, canvas.zoom))),
                      height: min(400, max(28, box.bounds.height / max(0.05, canvas.displayScaleY))))
    }

    private static func close(_ first: CGSize, _ second: CGSize) -> Bool { abs(first.width - second.width) < 0.001 && abs(first.height - second.height) < 0.001 }
    private static func menuAction(_ title: String, _ editor: ImageEditorController) throws {
        let more: NSPopUpButton = try control("editor.more", editor)
        let menu = try unwrap(more.menu, "Missing editor menu")
        let index = try unwrap(menu.items.firstIndex { $0.title == title }, "Missing editor action \(title)")
        menu.performActionForItem(at: index)
    }

    private static func snapshot(_ editor: ImageEditorController, filename: String, directory: URL) async throws {
        editor.window?.contentView?.layoutSubtreeIfNeeded(); editor.window?.displayIfNeeded()
        try await Task.sleep(nanoseconds: 40_000_000)
        let view = try unwrap(editor.window?.contentView, "Missing content view")
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        try require(editor.contextualPaletteVisible && view.bounds.contains(editor.contextualPaletteFrame)
            && view.bounds.contains(editor.floatingToolbarFrame) && !editor.contextualPaletteFrame.intersects(editor.floatingToolbarFrame), "Callout palette clipped or overlaps toolbar")
        for id in ["annotation.numberNext", "annotation.numberValue", "annotation.numberStyle", "annotation.numberComment", "annotation.numberRenumber"] {
            let widget: NSControl = try control(id, editor)
            try require(widget.isEnabled && !widget.isHiddenOrHasHiddenAncestor && widget.action != nil && widget.target != nil,
                        "Callout palette control is unreachable: \(id)")
            let rect = widget.convert(widget.bounds, to: view)
            try require(view.bounds.insetBy(dx: -1, dy: -1).contains(rect), "Callout control lies outside workspace")
        }
        let width = Int(ceil(view.bounds.width)), height = Int(ceil(view.bounds.height))
        try require(width > 0 && height > 0 && width * height <= 4_000_000, "Native snapshot exceeded fixture bound")
        let bitmap = try unwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32), "Cannot allocate native screenshot")
        bitmap.size = view.bounds.size; view.cacheDisplay(in: view.bounds, to: bitmap)
        try unwrap(bitmap.cgImage, "Missing native screenshot pixels").writePNG(to: directory.appendingPathComponent(filename))
    }

    private static func descendants(_ root: NSView?) -> [NSView] { guard let root else { return [] }; return [root] + root.subviews.flatMap { descendants($0) } }
    private static func control<T: NSView>(_ id: String, _ editor: ImageEditorController) throws -> T {
        try unwrap(descendants(editor.window?.contentView).first { $0.identifier?.rawValue == id } as? T, "Missing control \(id)")
    }
    private static func press(_ id: String, _ editor: ImageEditorController) throws {
        let button: NSButton = try control(id, editor)
        try require(button.isEnabled && !button.isHiddenOrHasHiddenAncestor, "Disabled/hidden button \(id)"); button.performClick(nil)
    }
    private static func choose(_ tool: ImageEditorTool, _ editor: ImageEditorController) throws { try press("editor.tool.\(tool.rawValue)", editor) }
    private static func send(_ control: NSControl) throws {
        try require(control.isEnabled && !control.isHiddenOrHasHiddenAncestor && control.sendAction(control.action, to: control.target), "Native control did not accept action")
    }
    private static func field(_ id: String, _ value: String, _ editor: ImageEditorController) throws { let field: NSTextField = try control(id, editor); field.stringValue = value; try send(field) }
    private static func picker(_ id: String, _ title: String, _ editor: ImageEditorController) throws { let picker: NSPopUpButton = try control(id, editor); picker.selectItem(withTitle: title); try send(picker) }
    private static func mouse(_ canvas: ImageEditorCanvas, _ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
        try unwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(CGPoint(x: point.x * canvas.zoom, y: point.y * canvas.displayScaleY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1), "Cannot create owned mouse event")
    }
    private static func key(_ canvas: ImageEditorCanvas, code: UInt16, value: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: code), "Cannot create owned key event")
    }
    private static func click(_ canvas: ImageEditorCanvas, _ point: CGPoint) throws { canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, point)); canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, point)) }
    private static func drag(_ canvas: ImageEditorCanvas, from start: CGPoint, to end: CGPoint) throws {
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, start)); canvas.mouseDragged(with: try mouse(canvas, .leftMouseDragged, end)); canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, end))
    }
    private static func undo(_ canvas: ImageEditorCanvas, redo: Bool = false) throws { try require(canvas.performKeyEquivalent(with: key(canvas, code: 6, value: "z", flags: redo ? [.command, .shift] : .command)), "Undo key was not handled") }
    private static func raster(_ canvas: ImageEditorCanvas) throws -> CGImage { try unwrap(canvas.flattened(), "Cannot render callouts") }
    private static func whiteImage(_ size: CGSize) throws -> CGImage {
        let context = try makeContext(Int(size.width), Int(size.height)); context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(origin: .zero, size: size))
        return try unwrap(context.makeImage(), "Cannot create source")
    }
    private static func makeContext(_ width: Int, _ height: Int) throws -> CGContext {
        try unwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), "Cannot allocate fixture raster")
    }
    private static func digest(_ image: CGImage) throws -> String {
        let context = try makeContext(image.width, image.height); context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try unwrap(context.data, "Missing raster bytes")
        return SHA256.hash(data: Data(bytes: data, count: image.width * image.height * 4)).map { String(format: "%02x", $0) }.joined()
    }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw failure(message) } }
    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw failure(message) }; return value }
    private static func failure(_ message: String) -> Error { PicShotError.message("Numbered callout fixture: \(message)") }
}

/// Deliberately substitutes the copy destination; it verifies responder routing
/// without reading or changing the user's general pasteboard.
@MainActor
private final class NumberedCalloutTextCopyProbe: NSTextView {
    private(set) var copiedText: String?
    override func copy(_ sender: Any?) {
        let text = string as NSString, range = selectedRange()
        if range.location != NSNotFound && NSMaxRange(range) <= text.length { copiedText = text.substring(with: range) }
    }
}
