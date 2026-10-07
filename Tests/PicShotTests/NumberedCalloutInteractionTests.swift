import XCTest
import AppKit
import PicShotCore
@testable import PicShot

final class NumberedCalloutInteractionTests: XCTestCase {
    @MainActor
    func testWindowTextRoutingSavePreparedPixelsAndCommentZoomGeometry() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-callout-routing-\(UUID().uuidString)", isDirectory: true)
        let editor = ImageEditorController(image: ImageEditorRenderer.makeSampleImage(), onSave: { _ in }, onPin: { _ in }, onOCR: { _ in }, copyAction: { _ in })
        defer { editor.close(); try? FileManager.default.removeItem(at: directory) }
        let baselineExports = ImageExportController.activeSessionCount
        editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
        let checks = try await NumberedCalloutAcceptanceFixture.verifyEditingRoutes(in: editor, evidenceDirectory: directory)
        XCTAssertEqual(checks.count, 3); XCTAssertTrue(checks.values.allSatisfy { $0 })
        XCTAssertNil(editor.annotationCanvas.activeNumberCommentInput)
        XCTAssertNil(editor.activeInlineTextView)
        XCTAssertEqual(ImageExportController.activeSessionCount, baselineExports)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("annotation-callout-active-comment-save.png").path))
    }

    @MainActor
    func testResizedSessionKeepsItsOriginalAnisotropicImageScale() throws {
        _ = NSApplication.shared
        let mark = ImageAnnotation(tool: .number, points: [CGPoint(x: 90, y: 90)])
        let session = NumberedCalloutCommentSession(annotation: mark,
            frame: CGRect(x: 0, y: 0, width: 150, height: 90), zoom: 0.5, verticalZoom: 0.75)
        defer { session.close() }
        XCTAssertEqual(session.resizedCommentSize, CGSize(width: 300, height: 120))
        session.box.setFrameSize(CGSize(width: 175, height: 120))
        XCTAssertEqual(session.resizedCommentSize, CGSize(width: 350, height: 160))
    }

    @MainActor
    func testNativeCanceledCreationAndDocumentLocalNextUndo() throws {
        _ = NSApplication.shared
        let editor = ImageEditorController(image: ImageEditorRenderer.makeSampleImage(), onSave: { _ in }, onPin: { _ in }, onOCR: { _ in })
        defer { editor.close() }; editor.showWindow(nil)
        let canvas = editor.annotationCanvas; editor.chooseTool(.number)
        canvas.setNextNumber(7)
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, CGPoint(x: 70, y: 70)))
        XCTAssertEqual(canvas.numberSequence.nextValue, 7); XCTAssertTrue(canvas.annotations.isEmpty)
        canvas.keyDown(with: try key(canvas, 53, "\u{1b}"))
        canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, CGPoint(x: 70, y: 70)))
        XCTAssertEqual(canvas.numberSequence.nextValue, 7); XCTAssertTrue(canvas.annotations.isEmpty)
        try click(canvas, CGPoint(x: 100, y: 100)); try click(canvas, CGPoint(x: 220, y: 100))
        XCTAssertEqual(canvas.annotations.map(\.number), [7, 8]); XCTAssertEqual(canvas.numberSequence.nextValue, 9)
        XCTAssertTrue(canvas.performKeyEquivalent(with: try key(canvas, 6, "z", flags: .command)))
        XCTAssertEqual(canvas.annotations.map(\.number), [7]); XCTAssertEqual(canvas.numberSequence.nextValue, 8)
        XCTAssertTrue(canvas.performKeyEquivalent(with: try key(canvas, 6, "z", flags: [.command, .shift])))
        XCTAssertEqual(canvas.annotations.map(\.number), [7, 8]); XCTAssertEqual(canvas.numberSequence.nextValue, 9)
        let other = ImageEditorCanvas(image: canvas.image)
        XCTAssertEqual(other.numberSequence.nextValue, 1)
    }

    @MainActor
    func testDuplicateUsesNextValueAndLimitsDoNotAllocateUnboundedNumberHistory() throws {
        _ = NSApplication.shared
        let canvas = ImageEditorCanvas(image: ImageEditorRenderer.makeSampleImage())
        canvas.setNextNumber(7); canvas.tool = .number
        try click(canvas, CGPoint(x: 50, y: 50)); canvas.setNextNumber(40)
        canvas.duplicateSelection()
        XCTAssertEqual(canvas.annotations.map(\.number), [7, 40]); XCTAssertEqual(canvas.numberSequence.nextValue, 41)
        canvas.annotations = (0..<NumberedCalloutSequence.maximumMarks).map { value in
            ImageAnnotation(tool: .number, points: [CGPoint(x: 100, y: 100)], number: value + 1)
        }
        var history = 0; canvas.onWillChange = { history += 1 }
        try click(canvas, CGPoint(x: 300, y: 300))
        canvas.add(ImageAnnotation(tool: .number, points: [CGPoint(x: 400, y: 400)], number: 999))
        XCTAssertEqual(canvas.annotations.count, 512); XCTAssertEqual(history, 0)
    }

    @MainActor
    func testInlineCancelAcceptClearAndControllerCleanup() async throws {
        _ = NSApplication.shared
        for _ in 0..<4 {
            var editor: ImageEditorController? = ImageEditorController(image: ImageEditorRenderer.makeSampleImage(), onSave: { _ in }, onPin: { _ in }, onOCR: { _ in })
            weak var weakEditor = editor
            editor?.showWindow(nil); editor?.chooseTool(.number)
            let canvas = try XCTUnwrap(editor?.annotationCanvas)
            try click(canvas, CGPoint(x: 50, y: 50))
            canvas.beginNumberComment()
            weak var weakInput = canvas.activeNumberCommentInput
            weak var weakStorage = canvas.activeNumberCommentInput?.textStorage
            weak var weakContainer = canvas.activeNumberCommentInput?.textContainer
            canvas.activeNumberCommentInput?.insertText("界 مرحبا\n👩🏽‍💻", replacementRange: NSRange(location: 0, length: 0))
            let cancelledAt = ProcessInfo.processInfo.systemUptime
            canvas.activeNumberCommentInput?.keyDown(with: try key(canvas, 53, "\u{1b}"))
            try await Task.sleep(nanoseconds: 10_000_000)
            XCTAssertNil(weakStorage); XCTAssertNil(weakContainer)
            XCTAssertEqual(canvas.annotations[0].numberComment, "")
            try await NumberedCalloutReleaseMonitor.awaitNativeRetirement(since: cancelledAt) { weakInput == nil }
            canvas.beginNumberComment()
            canvas.activeNumberCommentInput?.insertText("界 مرحبا", replacementRange: NSRange(location: 0, length: 0))
            canvas.activeNumberCommentInput?.keyDown(with: try key(canvas, 36, "\r", flags: .command))
            XCTAssertEqual(canvas.annotations[0].numberComment, "界 مرحبا")
            canvas.beginNumberComment(); canvas.activeNumberCommentInput?.string = ""
            canvas.finishNumberComment(commit: true)
            XCTAssertEqual(canvas.annotations[0].numberComment, "", "An existing comment must be removable")
            canvas.beginNumberComment(); weakInput = canvas.activeNumberCommentInput
            weakStorage = canvas.activeNumberCommentInput?.textStorage
            weakContainer = canvas.activeNumberCommentInput?.textContainer
            let closedAt = ProcessInfo.processInfo.systemUptime
            editor?.close(); editor = nil
            try await Task.sleep(nanoseconds: 10_000_000)
            XCTAssertNil(weakEditor); XCTAssertNil(weakStorage); XCTAssertNil(weakContainer)
            XCTAssertNil(canvas.activeNumberCommentInput)
            XCTAssertNil(canvas.onWillChange); XCTAssertNil(canvas.onChange); XCTAssertNil(canvas.retainedPresentationRaster)
            try await NumberedCalloutReleaseMonitor.awaitNativeRetirement(since: closedAt) { weakInput == nil }
        }
    }

    @MainActor
    func testTypedCommentCloseReleasesInputWithWindowAndUndoManagersStillOwned() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = content; window.makeKeyAndOrderFront(nil)
        let windowUndo = try XCTUnwrap(window.undoManager), sentinel = NSObject()
        var unrelatedUndoPerformed = false
        windowUndo.groupsByEvent = false
        windowUndo.beginUndoGrouping()
        windowUndo.registerUndo(withTarget: sentinel) { _ in unrelatedUndoPerformed = true }
        windowUndo.endUndoGrouping()
        defer { windowUndo.removeAllActions() }
        var localUndo: UndoManager?
        weak var weakInput: InlineAnnotationTextView?
        weak var weakSession: NumberedCalloutCommentSession?
        weak var weakStorage: NSTextStorage?
        weak var weakContainer: NSTextContainer?
        weak var weakTextLayout: NSTextLayoutManager?
        var closedAt = 0.0
        try autoreleasepool {
            let session = NumberedCalloutCommentSession(annotation: ImageAnnotation(tool: .number, points: [.zero]),
                frame: CGRect(x: 10, y: 10, width: 250, height: 100), zoom: 1)
            weakSession = session; weakInput = session.box.input
            weakStorage = session.box.input.textStorage; weakContainer = session.box.input.textContainer
            weakTextLayout = session.box.input.textLayoutManager
            content.addSubview(session.box); session.box.layoutSubtreeIfNeeded()
            XCTAssertTrue(window.makeFirstResponder(session.box.input))
            localUndo = try XCTUnwrap(session.box.input.undoManager)
            XCTAssertFalse(localUndo === windowUndo)
            session.box.input.insertText("Uncommitted 中 👩🏽‍💻", replacementRange: NSRange(location: 0, length: 0))
            XCTAssertTrue(localUndo?.canUndo == true)
            // No acceptance, cancellation command or explicit coalescing break
            // precedes close: this is the active-typing teardown path.
            closedAt = ProcessInfo.processInfo.systemUptime
            session.close(); session.close()
            XCTAssertFalse(window.firstResponder === session.box.input)
            XCTAssertNil(session.box.input.delegate); XCTAssertNil(session.box.superview)
            XCTAssertNil(session.box.input.textContainer); XCTAssertNil(session.box.input.textStorage)
            XCTAssertFalse(localUndo?.canUndo == true); XCTAssertFalse(localUndo?.canRedo == true)
            XCTAssertTrue(windowUndo.canUndo, "Closing a comment must preserve unrelated window undo")
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertNil(weakSession); XCTAssertNil(weakStorage); XCTAssertNil(weakContainer); XCTAssertNil(weakTextLayout)
        XCTAssertNotNil(localUndo, "Keep the local manager alive to detect retained text undo targets")
        windowUndo.undo(); XCTAssertTrue(unrelatedUndoPerformed)
        try await NumberedCalloutReleaseMonitor.awaitNativeRetirement(since: closedAt) { weakInput == nil }
    }

    @MainActor
    func testTypedCommentCloseReleasesFrozenAndNormalEditorsRepeatedly() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main, let displayID = screen.displayID,
              screen.frame.width >= 760, screen.frame.height >= 600 else {
            throw XCTSkip("Owned-window callout close fixture needs a 760 × 600 WindowServer display")
        }
        let frame = CGRect(origin: screen.frame.origin, size: CGSize(width: min(960, screen.frame.width), height: 600))
        let capture = try CapturedImage.frozenRegion(image: ImageEditorRenderer.makeSampleImage(), displayID: displayID,
            displayFrame: frame, selection: CGRect(x: 30, y: 80, width: frame.width - 60, height: 430))
        for frozen in [false, true] {
            let evidence = try await NumberedCalloutAcceptanceFixture.verifyRepeatedCommentClose(capture, frozenPresentation: frozen, cycles: 3)
            XCTAssertEqual(evidence.status, "passed"); XCTAssertEqual(evidence.cycles.count, 3)
            XCTAssertEqual(evidence.finalDeferredInputs, 0); XCTAssertEqual(evidence.finalDeferredContexts, 0)
            XCTAssertLessThanOrEqual(evidence.samples.count, 256)
            XCTAssertLessThanOrEqual(evidence.peakDeferredInputs, 3)
            XCTAssertTrue(evidence.cycles.allSatisfy { $0.requiredGraphTracked && $0.promptRetainedOwners == 0
                && $0.promptRetainedTextSystemObjects == 0 && ($0.releasedAfterMilliseconds ?? .infinity) <= 2000 })
            XCTAssertTrue(evidence.samples.allSatisfy { $0.retainedOwnedGraphObjects == 0 })
        }
    }

    @MainActor
    func testRepeatedCommentCloseRejectsUnauthoredCycleCountsBeforeOpeningWindows() async throws {
        _ = NSApplication.shared
        let capture = CapturedImage(image: ImageEditorRenderer.makeSampleImage(), presentation: nil)
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        for count in [0, 7] {
            do {
                _ = try await NumberedCalloutAcceptanceFixture.verifyRepeatedCommentClose(capture, cycles: count)
                XCTFail("Unsupported cycle count must fail before opening an editor")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("requires 1...6 cycles"))
            }
            XCTAssertTrue(Set(NSApp.windows.map(ObjectIdentifier.init)).subtracting(originalWindows).isEmpty)
        }
    }

    @MainActor
    private func mouse(_ canvas: ImageEditorCanvas, _ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(CGPoint(x: point.x * canvas.zoom, y: point.y * canvas.displayScaleY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    @MainActor
    private func key(_ canvas: ImageEditorCanvas, _ code: UInt16, _ value: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0,
            context: nil, characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: code))
    }
    @MainActor
    private func click(_ canvas: ImageEditorCanvas, _ point: CGPoint) throws {
        canvas.mouseDown(with: try mouse(canvas, .leftMouseDown, point)); canvas.mouseUp(with: try mouse(canvas, .leftMouseUp, point))
    }
}
