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
                      "Owned controller, inline input and presentation-cache cleanup only; not a process-memory or leak claim"]
}

/// Opt-in installed-app fixture; no TCC, external input, preference changes or network.
@MainActor
enum NumberedCalloutAcceptanceFixture {
    static func verify(evidenceDirectory: URL) async throws -> NumberedCalloutAcceptanceEvidence {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        var evidence = NumberedCalloutAcceptanceEvidence()
        let reportURL = evidenceDirectory.appendingPathComponent("annotation-callouts.json")
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
            for _ in 0..<6 {
                try await verifyUncommittedCommentClose(captured, diagnosticsDirectory: evidenceDirectory)
                evidence.closedControllerCount += 1; evidence.releasedControllerCount += 1
            }
            try require(try digest(source) == originalDigest, "Fixture changed original pixels")
            evidence.checks["sourcePixelsUnchanged"] = true
            evidence.checks["repeatedControllerAndInlineInputCleanup"] = evidence.closedControllerCount == evidence.releasedControllerCount
            evidence.status = "passed"; evidence.files.append(reportURL.lastPathComponent)
            try JSONEncoder().encode(evidence).write(to: reportURL, options: .atomic)
            return evidence
        } catch {
            evidence.status = "failed"; evidence.error = error.localizedDescription
            if let closeFailure = error as? NumberedCalloutCloseFailure, let filename = closeFailure.diagnosticFilename {
                evidence.files.append(filename)
            }
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
        weak var weakInput: InlineAnnotationTextView?
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
        weakInput = editor?.annotationCanvas.activeNumberCommentInput
        editor?.close()
        try require(editor?.isClosed == true && editor?.window?.contentView == nil && editor?.window?.delegate == nil,
                    "Owned window did not detach on close")
        try require(editor?.annotationCanvas.activeNumberCommentInput == nil && editor?.annotationCanvas.retainedPresentationRaster == nil,
                    "Owned comment input or cached raster survived close")
        editor = nil
        try await Task.sleep(nanoseconds: 10_000_000)
        try require(weakEditor == nil, "Owned controller remained retained")
        try require(weakInput == nil, "Owned comment input remained retained")
    }

    /// This lifecycle is synchronous until the release check. Drain its native
    /// autoreleases and end every strong local's scope before inspecting weak
    /// ownership, rather than depending on the installed app's event-loop pool.
    static func verifyUncommittedCommentClose(_ capture: CapturedImage, frozenPresentation: Bool = true,
                                             diagnosticsDirectory: URL? = nil) async throws {
        weak var weakEditor: ImageEditorController?
        weak var weakInput: InlineAnnotationTextView?
        var closeProbe: NumberedCalloutCloseProbe?
        try autoreleasepool {
            let editor = ImageEditorController(image: capture.image, presentation: frozenPresentation ? capture.presentation : nil,
                onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, onApply: { _ in false }, copyAction: { _ in })
            weakEditor = editor
            defer { editor.close() }
            editor.window?.appearance = NSAppearance(named: .aqua)
            editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
            let canvas = editor.annotationCanvas
            try choose(.number, editor); try click(canvas, CGPoint(x: 50, y: 50))
            try press("annotation.numberComment", editor)
            let input = try unwrap(canvas.activeNumberCommentInput, "Repeated cycle did not open comment editor")
            weakInput = input
            let manager = try unwrap(input.undoManager, "Repeated cycle has no comment undo manager")
            try require(editor.window?.firstResponder === input, "Repeated comment input did not become first responder")
            input.insertText("中 English 👩🏽‍💻", replacementRange: NSRange(location: 0, length: 0))
            try require(input.string == "中 English 👩🏽‍💻" && canvas.annotations[0].numberComment.isEmpty,
                        "Repeated cycle did not leave uncommitted text")
            closeProbe = NumberedCalloutCloseProbe(editor: editor, input: input, undoManager: manager)
            editor.close()
            closeProbe?.didClose()
            try require(editor.isClosed && editor.window?.contentView == nil && editor.window?.delegate == nil,
                        "Owned window did not detach on close")
            try require(canvas.activeNumberCommentInput == nil && canvas.retainedPresentationRaster == nil,
                        "Owned comment input or cached raster survived close")
            try require(canvas.annotations[0].numberComment.isEmpty && input.delegate == nil
                        && editor.window?.firstResponder !== input && !manager.canUndo && !manager.canRedo,
                        "Close did not discard comment editing and its local undo history")
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        let controllerReleased = weakEditor == nil, inputReleased = weakInput == nil
        if !controllerReleased || !inputReleased {
            // Freeze acceptance before any diagnostic observation/intervention.
            // A later release or a passing variant must never turn this into a pass.
            let message = !controllerReleased ? "Repeated cycle controller remained retained after scoped close"
                : "Repeated cycle comment input remained retained after scoped close"
            var diagnosticFilename: String?
            if let directory = diagnosticsDirectory, let probe = closeProbe {
                let url = directory.appendingPathComponent("annotation-callout-close-diagnostics.json")
                do {
                    try await diagnoseCommentClose(capture, frozenPresentation: frozenPresentation, original: probe, to: url)
                    diagnosticFilename = url.lastPathComponent
                } catch {
                    if let data = try? Data(contentsOf: url),
                       var report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        report["status"] = "interrupted"; report["diagnosticError"] = error.localizedDescription
                        if let updated = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                            try? updated.write(to: url, options: .atomic)
                        }
                        diagnosticFilename = url.lastPathComponent
                    }
                }
            }
            throw NumberedCalloutCloseFailure(message: message, diagnosticFilename: diagnosticFilename)
        }
    }

    /// Diagnostic-only controls. These run only after a frozen acceptance failure.
    /// None changes production editing or supplies acceptance evidence.
    private enum CloseIntervention: String, CaseIterable {
        case nonInlinedControl, untypedCallout, minimalNativeTextView, cancelDeferredPerforms, endUndoGroups, closeSpellDocument
        case disableTextChecking, discardMarkedText, retireEditableInput, detachTextContainer, combined

        func apply(to input: InlineAnnotationTextView, undoManager: UndoManager) {
            if self == .endUndoGroups || self == .combined {
                for _ in 0..<32 {
                    guard undoManager.groupingLevel > 0 else { break }
                    undoManager.endUndoGrouping()
                }
                undoManager.removeAllActions()
            }
            if self == .disableTextChecking || self == .combined {
                input.enabledTextCheckingTypes = 0
                input.isContinuousSpellCheckingEnabled = false; input.isGrammarCheckingEnabled = false
                input.isAutomaticSpellingCorrectionEnabled = false; input.isAutomaticTextCompletionEnabled = false
            }
            if self == .closeSpellDocument || self == .combined {
                NSSpellChecker.shared.closeSpellDocument(withTag: input.spellCheckerDocumentTag)
            }
            if self == .discardMarkedText || self == .combined {
                input.unmarkText(); input.inputContext?.discardMarkedText()
            }
            if self == .retireEditableInput || self == .combined {
                input.isEditable = false; input.isSelectable = false
            }
            if self == .detachTextContainer || self == .combined { input.textContainer?.textView = nil }
            if self == .cancelDeferredPerforms || self == .combined {
                NSObject.cancelPreviousPerformRequests(withTarget: input)
            }
        }
    }

    @inline(never)
    private static func diagnosticCloseCycle(_ capture: CapturedImage, frozenPresentation: Bool,
                                            intervention: CloseIntervention) throws -> NumberedCalloutCloseProbe {
        if intervention == .minimalNativeTextView { return try diagnosticNativeTextClose() }
        return try autoreleasepool {
            let editor = ImageEditorController(image: capture.image, presentation: frozenPresentation ? capture.presentation : nil,
                onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, onApply: { _ in false }, copyAction: { _ in })
            defer { editor.close() }
            editor.window?.appearance = NSAppearance(named: .aqua)
            editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
            let canvas = editor.annotationCanvas
            try choose(.number, editor); try click(canvas, CGPoint(x: 50, y: 50))
            try press("annotation.numberComment", editor)
            let input = try unwrap(canvas.activeNumberCommentInput, "Diagnostic comment input missing")
            let manager = try unwrap(input.undoManager, "Diagnostic local undo manager missing")
            try require(editor.window?.firstResponder === input, "Diagnostic input did not become first responder")
            if intervention != .untypedCallout {
                input.insertText("中 English 👩🏽‍💻", replacementRange: NSRange(location: 0, length: 0))
                try require(input.string == "中 English 👩🏽‍💻" && canvas.annotations[0].numberComment.isEmpty,
                            "Diagnostic cycle did not leave uncommitted text")
            }
            let probe = NumberedCalloutCloseProbe(editor: editor, input: input, undoManager: manager)
            editor.close(); probe.didClose()
            intervention.apply(to: input, undoManager: manager)
            return probe
        }
    }

    @inline(never)
    private static func diagnosticNativeTextClose() throws -> NumberedCalloutCloseProbe {
        try autoreleasepool {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let content = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
            let input = NSTextView(frame: CGRect(x: 10, y: 10, width: 300, height: 100))
            input.isRichText = false; input.allowsUndo = true
            content.addSubview(input); window.contentView = content; window.makeKeyAndOrderFront(nil)
            try require(window.makeFirstResponder(input), "Minimal native input could not become first responder")
            let manager = try unwrap(input.undoManager, "Minimal native input has no undo manager")
            input.insertText("中 English 👩🏽‍💻", replacementRange: NSRange(location: 0, length: 0))
            let probe = NumberedCalloutCloseProbe(editor: nil, input: input, undoManager: manager)
            window.makeFirstResponder(nil); input.breakUndoCoalescing(); input.allowsUndo = false
            manager.removeAllActions(); input.delegate = nil; input.removeFromSuperview()
            window.contentView = nil; window.close(); probe.didClose()
            return probe
        }
    }

    private static func diagnoseCommentClose(_ capture: CapturedImage, frozenPresentation: Bool,
                                            original: NumberedCalloutCloseProbe, to url: URL) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        var rows: [[String: Any]] = []
        var probes: [(name: String, probe: NumberedCalloutCloseProbe)] = [("originalFailure", original)]
        func persist(status: String) throws {
            let report: [String: Any] = ["status": status, "acceptanceStatus": "failed", "acceptanceThresholdMilliseconds": 10,
                "diagnosticOnly": true, "laterReleaseChangesAcceptance": false, "maximumDiagnosticEditors": CloseIntervention.allCases.count,
                "maximumConcurrentOwnedEditors": 1, "diagnosticDeadlineSeconds": 20, "observations": rows,
                "maximumTrackedInputs": CloseIntervention.allCases.count + 1,
                "maximumObservationRows": 3 + CloseIntervention.allCases.count * 4,
                "remainingInputVariantsAtLastWrite": probes.compactMap { $0.probe.input != nil ? $0.name : nil },
                "scope": "Owned synthetic typed inputs only; public-API controls, weak object probes and scalar state. No text, screenshots, global input, permissions or preferences. No whole-process leak conclusion."]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        }
        func observe(_ probe: NumberedCalloutCloseProbe, name: String, at target: Int) {
            var row = probe.observation()
            row["variant"] = name; row["targetMilliseconds"] = target
            row["remainingInputVariants"] = probes.compactMap { $0.probe.input != nil ? $0.name : nil }
            row["remainingEditorVariants"] = probes.compactMap { $0.probe.editor != nil ? $0.name : nil }
            rows.append(row)
        }
        observe(original, name: "originalFailure", at: 10); try persist(status: "running")
        for target in [100, 1000] {
            try await waitForDiagnosticSample(original, targetMilliseconds: target, deadline: deadline)
            observe(original, name: "originalFailure", at: target); try persist(status: "running")
        }
        for intervention in CloseIntervention.allCases {
            guard ProcessInfo.processInfo.systemUptime < deadline else { try persist(status: "deadline-reached"); return }
            do {
                let probe = try diagnosticCloseCycle(capture, frozenPresentation: frozenPresentation, intervention: intervention)
                probes.append((intervention.rawValue, probe))
                for target in [10, 100, 1000] {
                    try await waitForDiagnosticSample(probe, targetMilliseconds: target, deadline: deadline)
                    observe(probe, name: intervention.rawValue, at: target); try persist(status: "running")
                }
            } catch {
                rows.append(["variant": intervention.rawValue, "error": error.localizedDescription])
                try persist(status: "running")
                if Task.isCancelled { throw error }
            }
        }
        try persist(status: "completed")
    }

    private static func waitForDiagnosticSample(_ probe: NumberedCalloutCloseProbe, targetMilliseconds: Int,
                                                deadline: Double) async throws {
        let now = ProcessInfo.processInfo.systemUptime
        let target = probe.closedAt + Double(targetMilliseconds) / 1000
        guard target <= deadline && now < deadline else { throw failure("Comment close diagnostic deadline reached") }
        if target > now { try await Task.sleep(nanoseconds: UInt64((target - now) * 1_000_000_000)) }
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

private struct NumberedCalloutCloseFailure: LocalizedError {
    let message: String
    let diagnosticFilename: String?
    var errorDescription: String? { "Numbered callout fixture: \(message)" }
}

/// Never owns a tracked object. Stored state contains only scalar values.
@MainActor
private final class NumberedCalloutCloseProbe {
    weak var editor: ImageEditorController?
    weak var input: NSTextView?
    weak var window: NSWindow?
    weak var box: NSView?
    weak var session: AnyObject?
    weak var undoManager: UndoManager?
    weak var textStorage: NSTextStorage?
    weak var layoutManager: NSLayoutManager?
    weak var textLayoutManager: NSTextLayoutManager?
    weak var textContainer: NSTextContainer?
    weak var activeInputContext: NSTextInputContext?
    private let beforeClose: [String: Any]
    private var afterClose: [String: Any] = [:]
    private(set) var closedAt = ProcessInfo.processInfo.systemUptime

    init(editor: ImageEditorController?, input: NSTextView, undoManager: UndoManager) {
        self.editor = editor; self.input = input; window = input.window; box = input.superview
        session = input.delegate; self.undoManager = undoManager
        textStorage = input.textStorage; textContainer = input.textContainer
        textLayoutManager = input.textLayoutManager
        // Never read NSTextView.layoutManager or NSTextContainer.layoutManager:
        // those accessors can change a TextKit 2 view to compatibility mode.
        if input.textLayoutManager == nil { layoutManager = input.textStorage?.layoutManagers.first }
        if let context = NSTextInputContext.current, (context.client as AnyObject) === input { activeInputContext = context }
        beforeClose = Self.scalarState(input, undoManager: undoManager)
    }

    func didClose() {
        closedAt = ProcessInfo.processInfo.systemUptime
        if let input { afterClose = Self.scalarState(input, undoManager: undoManager) }
    }

    func observation() -> [String: Any] {
        autoreleasepool {
            var result: [String: Any] = [
                "actualMillisecondsAfterClose": (ProcessInfo.processInfo.systemUptime - closedAt) * 1000,
                "editorRetained": editor != nil, "inputRetained": input != nil, "windowRetained": window != nil,
                "boxRetained": box != nil, "sessionRetained": session != nil, "undoManagerRetained": undoManager != nil,
                "textStorageRetained": textStorage != nil, "layoutManagerRetained": layoutManager != nil,
                "textLayoutManagerRetained": textLayoutManager != nil, "textContainerRetained": textContainer != nil,
                "inputContextRetained": activeInputContext != nil,
                "beforeClose": beforeClose, "immediatelyAfterClose": afterClose
            ]
            if let input { result["retainedInputState"] = Self.scalarState(input, undoManager: undoManager) }
            if let window {
                var state: [String: Any] = ["visible": window.isVisible, "contentViewPresent": window.contentView != nil,
                    "delegatePresent": window.delegate != nil, "controllerPresent": window.windowController != nil,
                    "initialFirstResponderPresent": window.initialFirstResponder != nil,
                    "firstResponderPresent": window.firstResponder != nil]
                if let input {
                    state["firstResponderIsInput"] = window.firstResponder === input
                    state["initialFirstResponderIsInput"] = window.initialFirstResponder === input
                }
                result["retainedWindowState"] = state
            }
            return result
        }
    }

    private static func scalarState(_ input: NSTextView, undoManager: UndoManager?) -> [String: Any] {
        ["windowPresent": input.window != nil, "superviewPresent": input.superview != nil,
         "nextResponderPresent": input.nextResponder != nil, "delegatePresent": input.delegate != nil,
         "isWindowFirstResponder": input.window?.firstResponder === input,
         "isWindowInitialFirstResponder": input.window?.initialFirstResponder === input,
         "isCurrentInputContextClient": (NSTextInputContext.current?.client as AnyObject?) === input,
         "hasMarkedText": input.hasMarkedText(), "isEditable": input.isEditable, "isSelectable": input.isSelectable,
         "allowsUndo": input.allowsUndo, "undoGroupingLevel": undoManager?.groupingLevel ?? -1,
         "undoCanUndo": undoManager?.canUndo ?? false, "undoCanRedo": undoManager?.canRedo ?? false,
         "enabledTextCheckingTypes": input.enabledTextCheckingTypes,
         "continuousSpelling": input.isContinuousSpellCheckingEnabled, "grammarChecking": input.isGrammarCheckingEnabled,
         "automaticSpellingCorrection": input.isAutomaticSpellingCorrectionEnabled,
         "automaticCompletion": input.isAutomaticTextCompletionEnabled,
         "usesTextLayoutManager": input.textLayoutManager != nil,
         "stronglyReferencesTextStorage": type(of: input).stronglyReferencesTextStorage,
         "containerReferencesInput": input.textContainer?.textView === input]
    }
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
