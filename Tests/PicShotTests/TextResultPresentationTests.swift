import XCTest
import AppKit
@testable import PicShot

final class TextResultPresentationTests: XCTestCase {
    @MainActor func testCompactEditableResultHasWorkingPreferenceAndNoFakeLanguageControl() async throws {
        _ = NSApplication.shared
        let suite = "TextResultPresentationTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        var closes = 0
        let probe = try autoreleasepool { () throws -> ClosedAuxiliaryWindowProbe in
            let controller = TextResultController(text: "Line one\nLine two", defaults: defaults)
            let probe = try ClosedAuxiliaryWindowProbe(controller)
            let window = probe.window, content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded()
            XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, NSSize(width: 470, height: 310))
            XCTAssertFalse(controller.offersLanguageSelection)
            let text = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextView }.first)
            XCTAssertTrue(text.isEditable); text.string = "Edited text"
            XCTAssertEqual(controller.resultText, "Edited text")
            let checkbox = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "下次直接复制文本" })
            checkbox.performClick(nil)
            XCTAssertTrue(defaults.bool(forKey: TextResultController.directCopyPreferenceKey))
            let copy = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "复制" })
            XCTAssertEqual(copy.keyEquivalent, "\r")
            controller.onClose = { closes += 1 }
            controller.close(); controller.close()
            XCTAssertEqual(closes, 1); XCTAssertNil(controller.onClose)
            XCTAssertTrue(text.string.isEmpty, "Closed OCR results must clear the retained text view")
            probe.assertDetached()
            return probe
        }
        try await probe.assertReleased()
        XCTAssertEqual(closes, 1)
    }

    @MainActor func testLanguageSelectorAppearsOnlyForAvailableVisionLanguagesAndSource() throws {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let controller = TextResultController(text: "Text", sourceImage: image); defer { controller.close() }
        XCTAssertEqual(controller.offersLanguageSelection, !(try RecognitionService.supportedLanguages()).isEmpty)
    }

    @MainActor func testClosingDuringLanguageRerunCannotResurrectResultWindow() async throws {
        _ = NSApplication.shared
        let probe = try autoreleasepool { () throws -> ClosedAuxiliaryWindowProbe in
            let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let controller = TextResultController(text: "Keep old text", sourceImage: try XCTUnwrap(context.makeImage()))
            let probe = try ClosedAuxiliaryWindowProbe(controller)
            let content = try XCTUnwrap(probe.window.contentView)
            let language = descendants(content).compactMap { $0 as? NSPopUpButton }.first { !$0.pullsDown && $0.numberOfItems > 1 }
            if let language, let action = language.action {
                language.selectItem(at: 1); XCTAssertTrue(NSApp.sendAction(action, to: language.target, from: language))
            }
            controller.close(); probe.assertDetached()
            return probe
        }
        try await probe.assertReleased()
    }

    @MainActor func testTextLayoutAndPasteboardUseEditedTextWithoutSourcePixels() {
        XCTAssertEqual(TextResultController.joinedLines(" First line\n\n Second line \r\nThird "), "First line Second line Third")
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        TextResultController.copyToPasteboard("Corrected OCR", pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "Corrected OCR")
        XCTAssertNil(pasteboard.data(forType: .png))
    }

    func testLanguageFilteringNeverSubmitsUnsupportedIdentifiers() {
        XCTAssertEqual(RecognitionService.preferredLanguages(from: ["en-US", "fr-FR"]), ["en-US"])
        XCTAssertEqual(RecognitionService.preferredLanguages(from: ["fr-FR"]), [])
        XCTAssertEqual(RecognitionService.preferredLanguages(from: ["zh-Hant", "en-US", "zh-Hans"]), ["zh-Hans", "zh-Hant", "en-US"])
        XCTAssertEqual(RecognitionResult(text: "", barcodes: ["local:code"]).displayText, "识别码：\nlocal:code")
        XCTAssertEqual(RecognitionResult(text: "Text", barcodes: []).displayText, "Text")
    }

    @MainActor private func descendants(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + descendants($0) } }
}
