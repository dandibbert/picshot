import XCTest
import Foundation
import Translation
@testable import PicShot

final class TranslationConfigurationTests: XCTestCase {
    private var languages: [LocalTranslationLanguage] {
        ["en", "fr", "zh-Hans"].map { LocalTranslationLanguage(language: Locale.Language(identifier: $0)) }
    }

    func testAutoSourceRemainsNilAndPreservesOriginalWhitespace() throws {
        let text = "  Hello, world!\n\nThis is a test.  "
        let request = try LocalTranslationRequest(text: text, sourceID: "", targetID: "fr", languages: languages)
        XCTAssertNil(request.source)
        XCTAssertEqual(request.target.languageCode?.identifier, "fr")
        XCTAssertEqual(request.text, text)
    }

    func testExplicitSourceUsesTheSystemLanguageChoice() throws {
        let request = try LocalTranslationRequest(text: "Hello", sourceID: "en", targetID: "fr", languages: languages)
        XCTAssertEqual(request.source, languages.first?.language)
        XCTAssertEqual(request.target, languages[1].language)
    }

    func testBlankInputIsRejected() {
        XCTAssertThrowsError(try LocalTranslationRequest(text: " \n\t ", sourceID: "", targetID: "fr", languages: languages)) {
            XCTAssertEqual($0 as? LocalTranslationInputError, .emptyText)
        }
    }

    func testIdenticalLanguagesAreRejected() {
        XCTAssertThrowsError(try LocalTranslationRequest(text: "Hello", sourceID: "en", targetID: "en", languages: languages)) {
            XCTAssertEqual($0 as? LocalTranslationInputError, .sameLanguage)
        }
    }

    func testUnlistedTargetIsRejectedWithoutFallback() {
        XCTAssertThrowsError(try LocalTranslationRequest(text: "Hello", sourceID: "en", targetID: "unknown", languages: languages)) {
            XCTAssertEqual($0 as? LocalTranslationInputError, .missingTarget)
        }
    }

    func testUnlistedExplicitSourceIsRejectedWithoutAutoFallback() {
        XCTAssertThrowsError(try LocalTranslationRequest(text: "Hello", sourceID: "unknown", targetID: "fr", languages: languages)) {
            XCTAssertEqual($0 as? LocalTranslationInputError, .missingSource)
        }
    }

    func testRequestGateRejectsCancelledAndStaleReplies() {
        var gate = LocalTranslationRequestGate()
        let first = UUID()
        let second = UUID()
        XCTAssertFalse(gate.accepts(first))
        gate.begin(first)
        XCTAssertTrue(gate.accepts(first))
        gate.begin(second)
        XCTAssertFalse(gate.accepts(first))
        XCTAssertTrue(gate.accepts(second))
        gate.cancel()
        XCTAssertFalse(gate.accepts(first))
        XCTAssertFalse(gate.accepts(second))
    }

    func testOpeningModelDoesNotCreateTranslationOrResult() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Apple Translation requires macOS 15") }
        await MainActor.run {
            let model = LocalTranslationModel(text: "Original text")
            XCTAssertNil(model.run)
            XCTAssertEqual(model.original, "Original text")
            XCTAssertEqual(model.translated, "")
            XCTAssertEqual(model.phase, .idle)
            XCTAssertFalse(model.canTranslate) // The system language catalog is not loaded yet.
            XCTAssertFalse(model.canExport)
        }
    }

    func testInputChangeClearsPreviousResult() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Apple Translation requires macOS 15") }
        await MainActor.run {
            let model = LocalTranslationModel(text: "Original text")
            model.translated = "Edited old result"
            model.original = "Changed text"
            model.inputChanged()
            XCTAssertEqual(model.translated, "")
            XCTAssertEqual(model.phase, .idle)
            XCTAssertNil(model.run)
            XCTAssertFalse(model.canExport)
        }
    }

    func testCancelClearsPreviousResultAndDisablesExport() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Apple Translation requires macOS 15") }
        await MainActor.run {
            let model = LocalTranslationModel(text: "Original text")
            model.translated = "Previous result"
            model.cancel()
            XCTAssertEqual(model.translated, "")
            XCTAssertEqual(model.phase, .cancelled)
            XCTAssertNil(model.run)
            XCTAssertFalse(model.canExport)
        }
    }

    func testInvalidRequestClearsPreviousResultWithoutStartingSession() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Apple Translation requires macOS 15") }
        await MainActor.run {
            let model = LocalTranslationModel(text: " \n")
            model.translated = "Previous result"
            model.beginTranslation()
            XCTAssertEqual(model.translated, "")
            XCTAssertNil(model.run)
            XCTAssertEqual(model.phase, .failed(LocalTranslationInputError.emptyText.localizedDescription))
            XCTAssertFalse(model.canExport)
        }
    }

    func testKnownTranslationErrorsGiveActionableMessages() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Apple Translation requires macOS 15") }
        await MainActor.run {
            XCTAssertTrue(LocalTranslationModel.explanation(for: TranslationError.unableToIdentifyLanguage).contains("手动选择"))
            XCTAssertTrue(LocalTranslationModel.explanation(for: TranslationError.unsupportedLanguagePairing).contains("不支持"))
            XCTAssertTrue(LocalTranslationModel.explanation(for: TranslationError.nothingToTranslate).contains("没有可翻译"))
        }
    }
}
