import XCTest
@testable import PicShotCore

final class PinDesktopVisibilityTests: XCTestCase {
    func testExistingInstallMissingKeyKeepsAllDesktopsWithoutWritingMigration() {
        let name = "PicShot-DesktopVisibility-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "restorePinSessionOnLaunch")
        XCTAssertNil(defaults.object(forKey: PinDesktopVisibility.preferenceKey))
        XCTAssertEqual(PinDesktopVisibility.read(from: defaults), .allDesktops)
        XCTAssertNil(defaults.object(forKey: PinDesktopVisibility.preferenceKey))
        XCTAssertTrue(defaults.bool(forKey: "restorePinSessionOnLaunch"))
    }

    func testPersistedModesRoundTripAndUnknownOrMalformedKeyFallback() {
        let name = "PicShot-DesktopVisibility-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        for mode in PinDesktopVisibility.allCases {
            mode.save(to: defaults)
            XCTAssertEqual(PinDesktopVisibility.read(from: UserDefaults(suiteName: name)!), mode)
        }
        let malformedValues: [Any] = ["", "space-42", "futureMode", 1, ["space": 4]]
        for malformed in malformedValues {
            defaults.set(malformed, forKey: PinDesktopVisibility.preferenceKey)
            XCTAssertEqual(PinDesktopVisibility.read(from: defaults), .allDesktops)
        }
    }
}
