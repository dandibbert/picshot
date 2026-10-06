import XCTest
@testable import PicShotCore

final class SaveWorkflowTemplateTests: XCTestCase {
    private let base = URL(fileURLWithPath: "/Users/test/Pictures/Captures", isDirectory: true)
    private var context: SaveWorkflowContext {
        SaveWorkflowContext(date: Date(timeIntervalSince1970: 0), width: 1920, height: 1080, counter: 7)
    }
    func testDefaultOffAndFinalizedActionOnly() {
        var settings = SaveWorkflowSettings(baseURL: base)
        XCTAssertFalse(settings.autoOnFinalizedAction)
        XCTAssertEqual(settings.collisionBehavior, .ask)
        XCTAssertFalse(settings.shouldAutomaticallySave(for: .finalizedAction))
        settings.autoOnFinalizedAction = true
        XCTAssertTrue(settings.shouldAutomaticallySave(for: .finalizedAction))
        for trigger in [SaveWorkflowTrigger.captureAcquired, .historyOpened, .previewUpdated, .editorCancelled] {
            XCTAssertFalse(settings.shouldAutomaticallySave(for: trigger))
        }
        settings.baseURL = nil
        XCTAssertFalse(settings.shouldAutomaticallySave(for: .finalizedAction))
        XCTAssertThrowsError(try settings.validate())
    }
    func testExplicitGregorianPOSIXUTCVariablesAndActualExtension() throws {
        let settings = SaveWorkflowSettings(baseURL: base, relativeFolderTemplate: "{date}/尺寸-{width}x{height}",
                                            filenameTemplate: "截图-{date}-{time}-{counter}")
        let result = try settings.preview(context: context, filenameExtension: "avif")
        XCTAssertEqual(result.relativeDirectories, ["1970-01-01", "尺寸-1920x1080"])
        XCTAssertEqual(result.filename, "截图-1970-01-01-00-00-00-7.avif")
        XCTAssertEqual(result.url.path, "/Users/test/Pictures/Captures/1970-01-01/尺寸-1920x1080/截图-1970-01-01-00-00-00-7.avif")
    }
    func testExplicitTimeZoneChangesDayWithoutGlobalLocaleDependence() throws {
        let template = try SaveWorkflowTemplate(filename: "{date}-{time}")
        let west = SaveWorkflowContext(date: Date(timeIntervalSince1970: 0), width: 1, height: 1, counter: 1,
                                       timeZoneIdentifier: "America/Los_Angeles")
        XCTAssertEqual(try template.render(context: west).filename, "1969-12-31-16-00-00")
        XCTAssertEqual(try template.render(context: context).filename, "1970-01-01-00-00-00")
    }
    func testMalformedUnknownAndInventedAppVariablesRejected() {
        for filename in ["", "{", "}", "{{date}}", "{date", "date}", "{app}", "{user}", "{}", "{DATE}", "{counter:03}", ".", "..", "...", "   "] {
            XCTAssertThrowsError(try SaveWorkflowTemplate(filename: filename), filename)
        }
    }
    func testRelativePathsRejectAbsoluteTraversalAndEmptyComponents() {
        for folder in ["/tmp", "../escape", "day/../escape", "day/./escape", "day//escape", "day/", "~/Desktop", "day\\escape", ".", ".."] {
            XCTAssertThrowsError(try SaveWorkflowTemplate(folder: folder, filename: "capture"), folder)
        }
        for filename in ["../escape", "day/capture", "day\\capture"] {
            XCTAssertThrowsError(try SaveWorkflowTemplate(filename: filename), filename)
        }
    }
    func testUnicodeNormalizationAndEmojiPreservedAndUnsafePunctuationSanitized() throws {
        let template = try SaveWorkflowTemplate(filename: "  Cafe\u{301}-截图-👩‍💻:x?\u{0}\u{202E}  ")
        let result = try template.render(context: context).filename
        XCTAssertEqual(result, "Café-截图-👩‍💻_x___")
        XCTAssertFalse(result.contains("\u{0}")); XCTAssertFalse(result.contains("\u{202E}"))
    }
    func testUnicodeBoundNeverSplitsGraphemesAndKeepsCollisionSuffixSpace() throws {
        let template = try SaveWorkflowTemplate(filename: String(repeating: "👨‍👩‍👧‍👦", count: 12))
        let result = try template.render(context: context).filename
        XCTAssertLessThanOrEqual(result.utf8.count, 180)
        XCTAssertTrue(result.allSatisfy { String($0) == "👨‍👩‍👧‍👦" })
        XCTAssertFalse(result.isEmpty)
    }
    func testDotPrefixDoesNotCreateHiddenOutputAndTrailingDotsAreRemoved() throws {
        XCTAssertEqual(try SaveWorkflowTemplate(filename: ".private...").render(context: context).filename, "_private")
        XCTAssertEqual(try SaveWorkflowTemplate(filename: "one ").render(context: context).filename, "one")
    }
    func testTemplateAndRenderedPathBounds() throws {
        XCTAssertThrowsError(try SaveWorkflowTemplate(filename: String(repeating: "a", count: 1_025)))
        XCTAssertThrowsError(try SaveWorkflowTemplate(folder: Array(repeating: "folder", count: 9).joined(separator: "/"), filename: "x"))
        let folder = Array(repeating: String(repeating: "a", count: 120), count: 8).joined(separator: "/")
        let settings = SaveWorkflowSettings(baseURL: base, relativeFolderTemplate: folder, filenameTemplate: String(repeating: "b", count: 100))
        XCTAssertThrowsError(try settings.preview(context: context))
    }
    func testInvalidContextsAndExtremeCountersFailSafely() throws {
        let template = try SaveWorkflowTemplate(filename: "{counter}")
        for invalid in [
            SaveWorkflowContext(width: 0, height: 1, counter: 1),
            SaveWorkflowContext(width: 1, height: 0, counter: 1),
            SaveWorkflowContext(width: Int.max, height: Int.max, counter: 1),
            SaveWorkflowContext(width: 1, height: 1, counter: 0),
            SaveWorkflowContext(date: Date(timeIntervalSince1970: .infinity), width: 1, height: 1, counter: 1),
            SaveWorkflowContext(width: 1, height: 1, counter: 1, timeZoneIdentifier: "not-a-zone")
        ] { XCTAssertThrowsError(try template.render(context: invalid)) }
        XCTAssertEqual(try template.render(context: SaveWorkflowContext(width: 1, height: 1, counter: UInt64.max)).filename, String(UInt64.max))
    }
    func testInvalidBaseAndExtensionRejected() throws {
        for url in [URL(string: "https://example.com/photos")!, URL(fileURLWithPath: "/"), URL(string: "file://remote/Photos")!, URL(string: "file:///Users/test/../escape")!] {
            XCTAssertThrowsError(try SaveWorkflowSettings(baseURL: url).preview(context: context), url.absoluteString)
        }
        let excessiveDepth = URL(fileURLWithPath: "/" + Array(repeating: "x", count: 70).joined(separator: "/"))
        XCTAssertThrowsError(try SaveWorkflowSettings.validateBaseURL(excessiveDepth))
        let settings = SaveWorkflowSettings(baseURL: base)
        for ext in ["../png", "PNG", "png/evil", "", "123456789"] {
            XCTAssertThrowsError(try settings.preview(context: context, filenameExtension: ext))
        }
    }
    func testSettingsRoundTripAndMalformedPreferencesFailClosed() throws {
        try withDefaults { defaults in
            XCTAssertEqual(SaveWorkflowSettings.read(from: defaults), SaveWorkflowSettings())
            let settings = SaveWorkflowSettings(baseURL: base, relativeFolderTemplate: "{date}", filenameTemplate: "截图-{counter}", autoOnFinalizedAction: true, collisionBehavior: .keepBoth)
            try settings.save(to: defaults)
            XCTAssertEqual(SaveWorkflowSettings.read(from: defaults), settings)
            defaults.set(Data("garbage".utf8), forKey: SaveWorkflowSettings.preferenceKey)
            XCTAssertEqual(SaveWorkflowSettings.read(from: defaults), SaveWorkflowSettings())
            let invalid = SaveWorkflowSettings(baseURL: nil, autoOnFinalizedAction: true)
            defaults.set(try JSONEncoder().encode(invalid), forKey: SaveWorkflowSettings.preferenceKey)
            XCTAssertFalse(SaveWorkflowSettings.read(from: defaults).autoOnFinalizedAction)
        }
    }
    func testInvalidSettingsDoNotPartiallyReplaceSavedSettings() throws {
        try withDefaults { defaults in
            let old = SaveWorkflowSettings(baseURL: base); try old.save(to: defaults)
            var invalid = old; invalid.filenameTemplate = "{nope}"; invalid.autoOnFinalizedAction = true
            XCTAssertThrowsError(try invalid.save(to: defaults))
            XCTAssertEqual(SaveWorkflowSettings.read(from: defaults), old)
        }
    }
    func testCounterReservesBeforeUseAndDetectsMalformedAndOverflowValues() throws {
        try withDefaults { defaults in
            XCTAssertEqual(try SaveWorkflowCounter.next(in: defaults), 1)
            XCTAssertEqual(try SaveWorkflowCounter.next(in: defaults), 2)
            defaults.set(String(UInt64.max - 1), forKey: SaveWorkflowCounter.preferenceKey)
            XCTAssertEqual(try SaveWorkflowCounter.next(in: defaults), UInt64.max - 1)
            XCTAssertThrowsError(try SaveWorkflowCounter.next(in: defaults))
            for value in ["0", "-1", "invalid", "18446744073709551616"] {
                defaults.set(value, forKey: SaveWorkflowCounter.preferenceKey)
                XCTAssertThrowsError(try SaveWorkflowCounter.next(in: defaults), value)
                XCTAssertEqual(defaults.string(forKey: SaveWorkflowCounter.preferenceKey), value)
            }
        }
    }
    private func withDefaults(_ action: (UserDefaults) throws -> Void) throws {
        let suite = "PicShot.SaveWorkflowTemplateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }; try action(defaults)
    }
}
