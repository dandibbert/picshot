import XCTest
@testable import PicShotCore

final class ApplicationPreferencesTests: XCTestCase {
    private func preferences() -> (UserDefaults, String) {
        let name = "PicShot-ApplicationPreferencesTests-" + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }
    func testAppearanceDefaultRoundTripAndUnknownValueFallback() {
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppAppearancePreference.read(from: defaults), .system)
        for mode in AppAppearancePreference.allCases { mode.save(to: defaults); XCTAssertEqual(AppAppearancePreference.read(from: defaults), mode) }
        defaults.set("unsupported", forKey: AppAppearancePreference.preferenceKey)
        XCTAssertEqual(AppAppearancePreference.read(from: defaults), .system)
    }
    func testHistoryRetentionRetainsDefaultsAndExistingCustomValues() {
        let (defaults, name) = preferences(); defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(HistoryRetentionPreferences.read(from: defaults), HistoryRetentionPreferences())
        let custom = HistoryRetentionPreferences(days: 80, count: 300, megabytes: 2048)
        XCTAssertTrue(custom.save(to: defaults)); XCTAssertEqual(HistoryRetentionPreferences.read(from: defaults), custom)
        for invalid in [HistoryRetentionPreferences(days: 0), .init(days: 3651), .init(count: -1), .init(count: 10001), .init(megabytes: 0), .init(megabytes: 102401)] {
            XCTAssertFalse(invalid.save(to: defaults)); XCTAssertEqual(HistoryRetentionPreferences.read(from: defaults), custom)
        }
        XCTAssertTrue(HistoryRetentionPreferences(days: 3650, count: 10000, megabytes: 102400).isValid)
    }
    func testOrdinaryLaunchIsMenuBarFirstAndSmokeShowsHistory() {
        XCTAssertTrue(AppLaunchPresentation.usesMenuBarOnly(isSmoke: false))
        XCTAssertFalse(AppLaunchPresentation.showsHistory(isSmoke: false))
        XCTAssertFalse(AppLaunchPresentation.usesMenuBarOnly(isSmoke: true))
        XCTAssertTrue(AppLaunchPresentation.showsHistory(isSmoke: true))
    }
    func testPinGroupCountsUseActualLiveIDsAndIncludeArchivedHistory() throws {
        var index = PinSessionIndex()
        let group = try index.createGroup(name: "写报告参考", color: .orange)
        let visible = entry(), archived = entry(visible: false), inactive = entry(group: group.id)
        index.entries = [visible, archived, inactive]
        let rows = PinGroupMenuSummary.make(index: index, livePinIDs: [visible.id])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].countLabel, "1/2"); XCTAssertTrue(rows[0].isCurrent)
        XCTAssertEqual(rows[1].countLabel, "0/1"); XCTAssertEqual(rows[1].color, .orange); XCTAssertFalse(rows[1].isCurrent)
        // Saved visible intent does not mean restored windows actually exist after an opt-out launch.
        XCTAssertEqual(PinGroupMenuSummary.make(index: index, livePinIDs: [])[0].countLabel, "0/2")
    }
    private func entry(group: UUID = PinGroup.defaultID, visible: Bool = true) -> PinSessionEntry {
        PinSessionEntry(groupID: group, original: PinRasterAsset(filename: UUID().uuidString + ".png", width: 4, height: 4, byteCount: 30), isVisible: visible)
    }
}
