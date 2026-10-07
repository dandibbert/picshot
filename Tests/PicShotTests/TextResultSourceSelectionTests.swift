import XCTest
import AppKit
import ImageIO
@testable import PicShot

final class TextResultSourceSelectionTests: XCTestCase {
    @MainActor func testCompactSourcePreviewUsesExistingOverlayAndLinksBothDirections() throws {
        _ = NSApplication.shared
        let document = PinTextSelectionSmokeFixture.deterministicDocument()
        let result = RecognitionResult(text: document.text, barcodes: ["Select"], document: document)
        let controller = TextResultController(result: result, sourceImage: try PinTextSelectionSmokeFixture.visionRaster(), defaults: nil)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window), root = try XCTUnwrap(window.contentView)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, NSSize(width: 470, height: 310))
        XCTAssertFalse(controller.isSourcePreviewVisible); XCTAssertEqual(controller.resultDocument, document)
        let text = try textView(controller)
        var sourceChanges: [[NSRange]] = []
        controller.onSourceSelection = { received, ranges in XCTAssertEqual(received, document); sourceChanges.append(ranges) }
        text.setSelectedRange(document.units[1].range)
        controller.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: text))
        XCTAssertEqual(sourceChanges.last, [document.units[1].range])
        let toggle = try XCTUnwrap(descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "原图" })
        toggle.performClick(nil); root.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.isSourcePreviewVisible)
        let overlay = try XCTUnwrap(descendants(root).compactMap { $0 as? PinTextSelectionOverlay }.first)
        XCTAssertEqual(overlay.document, document); XCTAssertGreaterThan(overlay.imageRect.width, 0)
        overlay.select(document.units[7].range)
        XCTAssertEqual(text.selectedRange(), document.units[7].range)
        XCTAssertEqual(controller.selectedSourceRanges, [document.units[7].range])
        text.setSelectedRange((result.displayText as NSString).range(of: "识别码：\nSelect"))
        controller.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: text))
        XCTAssertTrue(controller.selectedSourceRanges.isEmpty); XCTAssertEqual(overlay.linkedSelectionRanges, [])
        toggle.performClick(nil)
        XCTAssertFalse(controller.isSourcePreviewVisible)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size.width, 470)
    }

    @MainActor func testNativeTextStorageEditsKeepUnchangedMappingAndSkipInsertedOrReplacedText() throws {
        _ = NSApplication.shared
        let document = PinTextSelectionSmokeFixture.deterministicDocument()
        let controller = TextResultController(result: RecognitionResult(text: document.text, barcodes: [], document: document), defaults: nil)
        defer { controller.close() }
        let text = try textView(controller), original = document.units[1].range
        text.textStorage?.replaceCharacters(in: NSRange(location: original.location, length: 0), with: "NEW ")
        text.didChangeText()
        text.setSelectedRange(NSRange(location: original.location, length: 3))
        XCTAssertTrue(controller.selectedSourceRanges.isEmpty)
        text.setSelectedRange(NSRange(location: original.location + 4, length: original.length))
        XCTAssertEqual(controller.selectedSourceRanges, [original])
        text.textStorage?.replaceCharacters(in: NSRange(location: original.location + 4, length: original.length), with: "exact")
        text.didChangeText(); text.setSelectedRange(NSRange(location: original.location + 4, length: 5))
        XCTAssertTrue(controller.selectedSourceRanges.isEmpty)
        controller.selectSourceRanges([document.units[2].range], document: document)
        XCTAssertEqual((text.string as NSString).substring(with: text.selectedRange()), "text")
        let oldSelection = text.selectedRanges
        let stale = RecognizedTextDocument(text: "Other", lines: [], units: [])
        controller.selectSourceRanges([NSRange(location: 0, length: 5)], document: stale)
        XCTAssertEqual(text.selectedRanges, oldSelection)
    }

    @MainActor func testLayoutMenuPreservesGeometryThroughUnicodeAndRepeatedActions() throws {
        _ = NSApplication.shared
        let document = PinTextSelectionSmokeFixture.deterministicDocument()
        let controller = TextResultController(result: RecognitionResult(text: document.text, barcodes: ["text"], document: document), defaults: nil)
        defer { controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView), text = try textView(controller)
        let menus = descendants(root).compactMap { $0 as? NSPopUpButton }.compactMap(\.menu)
        let join = try XCTUnwrap(menus.flatMap(\.items).first { $0.title == "合并换行" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(join.action), to: join.target, from: join))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(join.action), to: join.target, from: join))
        controller.selectSourceRanges([document.units[7].range], document: document)
        XCTAssertEqual((text.string as NSString).substring(with: text.selectedRange()), "👩🏽‍💻")
        XCTAssertEqual(controller.selectedSourceRanges, [document.units[7].range])
        let code = (text.string as NSString).range(of: "text", options: .backwards)
        text.setSelectedRange(code); XCTAssertTrue(controller.selectedSourceRanges.isEmpty)
    }

    @MainActor func testBackgroundResultApplyAndLinkedSelectionDoNotActivateOrCopy() throws {
        _ = NSApplication.shared
        let document = PinTextSelectionSmokeFixture.deterministicDocument()
        let controller = TextResultController(text: "old", defaults: nil)
        defer { controller.close() }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false; other.makeKeyAndOrderFront(nil); defer { other.close() }
        let key = NSApp.keyWindow, firstResponder = key?.firstResponder, clipboardChanges = NSPasteboard.general.changeCount
        controller.applyRecognitionResult(RecognitionResult(text: document.text, barcodes: [], document: document))
        controller.selectSourceRanges([document.units[0].range], document: document)
        XCTAssertTrue(NSApp.keyWindow === key); XCTAssertTrue(key?.firstResponder === firstResponder)
        XCTAssertFalse(controller.window?.isVisible ?? true)
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboardChanges)
    }

    @MainActor func testMappingBudgetLeavesTextEditableAndShowsCompactStatus() throws {
        _ = NSApplication.shared
        let document = PinTextSelectionSmokeFixture.deterministicDocument()
        let controller = TextResultController(result: RecognitionResult(text: document.text, barcodes: [], document: document), defaults: nil)
        defer { controller.close() }
        let text = try textView(controller)
        let oversized = String(repeating: "x", count: RecognizedTextProjection.maximumMappedUTF16Count + 1)
        text.textStorage?.replaceCharacters(in: NSRange(location: 0, length: text.string.utf16.count), with: oversized); text.didChangeText()
        XCTAssertTrue(controller.sourceLinkingLimitReached); XCTAssertEqual(controller.resultText, oversized); XCTAssertTrue(text.isEditable)
        let root = try XCTUnwrap(controller.window?.contentView)
        let status = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first { $0.stringValue == "原图关联已暂停" })
        XCTAssertFalse(status.isHidden)
        controller.applyRecognitionResult(RecognitionResult(text: document.text, barcodes: [], document: document))
        XCTAssertFalse(controller.sourceLinkingLimitReached); XCTAssertTrue(status.isHidden)
    }

    @MainActor func testOverlaySilentDisjointHighlightsAndNativeCallbackDoNotLoop() {
        _ = NSApplication.shared
        let overlay = PinTextSelectionOverlay(), document = PinTextSelectionSmokeFixture.deterministicDocument()
        overlay.document = document
        var changes: [[NSRange]] = []; overlay.onSelectionChange = { changes.append($0) }
        let ranges = [document.units[0].range, document.units[2].range]
        overlay.setLinkedSelection(ranges)
        XCTAssertEqual(overlay.linkedSelectionRanges, ranges); XCTAssertNil(overlay.selectedRange); XCTAssertTrue(changes.isEmpty)
        overlay.select(document.units[1].range)
        XCTAssertNil(overlay.linkedSelectionRanges); XCTAssertEqual(changes, [[document.units[1].range]])
        overlay.releaseResources(); XCTAssertNil(overlay.onSelectionChange); XCTAssertNil(overlay.document)
    }

    @MainActor func testImageFreeLanguageProviderPreservesOrientationAndRejectsLateGeneration() async throws {
        _ = NSApplication.shared
        let gate = TextResultRecognitionGate(), document = PinTextSelectionSmokeFixture.deterministicDocument()
        let controller = TextResultController(result: RecognitionResult(text: document.text, barcodes: [], document: document),
            options: RecognitionOptions(orientation: .right), onRecognize: { try await gate.request($0) }, defaults: nil)
        defer { controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        let picker = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { !$0.pullsDown && $0.numberOfItems > 1 })
        picker.selectItem(at: 1); XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
        try await waitUntil { gate.requests.count == 1 }
        XCTAssertEqual(gate.requests[0].orientation, .right)
        picker.selectItem(at: 0); XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
        try await waitUntil { gate.requests.count == 2 }
        gate.complete(1, result: RecognitionResult(text: "New language", barcodes: []))
        try await waitUntil { controller.resultText == "New language" }
        gate.complete(0, result: RecognitionResult(text: "Stale language", barcodes: []))
        await Task.yield(); await Task.yield()
        XCTAssertEqual(controller.resultText, "New language"); XCTAssertNil(controller.resultDocument)
        XCTAssertTrue(try textView(controller).isEditable)
    }

    @MainActor func testClosingDuringInjectedRerunReleasesControllerAndSuppressesLateValue() async throws {
        _ = NSApplication.shared
        let gate = TextResultRecognitionGate()
        var controller: TextResultController? = TextResultController(text: "Old", onRecognize: { try await gate.request($0) }, defaults: nil)
        let probe = try ClosedAuxiliaryWindowProbe(try XCTUnwrap(controller))
        try autoreleasepool {
            let root = try XCTUnwrap(probe.window.contentView)
            let picker = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { !$0.pullsDown && $0.numberOfItems > 1 })
            picker.selectItem(at: 1); XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
        }
        try await waitUntil { gate.requests.count == 1 }
        autoreleasepool { controller?.close(); controller = nil }
        probe.assertDetached()
        try await probe.assertReleased()
        if !gate.requests.isEmpty { gate.complete(0, result: RecognitionResult(text: "Late", barcodes: [])) }
        await Task.yield(); XCTAssertFalse(probe.window.isVisible)
    }

    @MainActor private func textView(_ controller: TextResultController) throws -> NSTextView {
        try XCTUnwrap(descendants(try XCTUnwrap(controller.window?.contentView)).compactMap { $0 as? NSTextView }.first)
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition())
    }
}

@MainActor private final class TextResultRecognitionGate {
    var requests: [RecognitionOptions] = []
    private var completions: [Int: CheckedContinuation<RecognitionResult, Error>] = [:]
    func request(_ options: RecognitionOptions) async throws -> RecognitionResult {
        try Task.checkCancellation()
        let index = requests.count; requests.append(options)
        return try await withCheckedThrowingContinuation { completions[index] = $0 }
    }
    func complete(_ index: Int, result: RecognitionResult) { completions.removeValue(forKey: index)?.resume(returning: result) }
}
