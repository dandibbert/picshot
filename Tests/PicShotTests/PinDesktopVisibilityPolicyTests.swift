import XCTest
import AppKit
import PicShotCore
@testable import PicShot

final class PinDesktopVisibilityPolicyTests: XCTestCase {
    @MainActor func testDefaultSingleSpaceDoesNotFollowActivationAndPreservesUnrelatedFlags() {
        let original: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        let current = PinDesktopVisibilityPolicy.behavior(.currentDesktop, preserving: original)
        XCTAssertFalse(current.contains(.canJoinAllSpaces))
        XCTAssertFalse(current.contains(.moveToActiveSpace), "Current means assigned desktop, not activation-follow")
        XCTAssertEqual(current, [.fullScreenAuxiliary, .ignoresCycle, .stationary])
        XCTAssertEqual(PinDesktopVisibilityPolicy.behavior(.allDesktops, preserving: current), original)
        XCTAssertEqual(PinDesktopVisibilityPolicy.behavior(.currentDesktop, preserving: [.moveToActiveSpace]), [])
    }

    @MainActor func testRealAppKitParentAndChildFlagsChangeWithoutPresentationOrOrderingChange() {
        _ = NSApplication.shared
        let parent = NSPanel(contentRect: NSRect(x: 20, y: 30, width: 280, height: 150), styleMask: [.borderless], backing: .buffered, defer: false)
        let child = NSWindow(contentRect: NSRect(x: 35, y: 45, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; child.isReleasedWhenClosed = false
        parent.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        parent.alphaValue = 0.4; parent.ignoresMouseEvents = true; parent.level = .floating
        parent.addChildWindow(child, ordered: .above)
        defer { parent.removeChildWindow(child); child.close(); parent.close() }
        let frame = parent.frame, childFrame = child.frame
        let visible = parent.isVisible, childVisible = child.isVisible
        for _ in 0..<20 {
            PinDesktopVisibilityPolicy.apply(.currentDesktop, to: parent)
            XCTAssertFalse(parent.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertFalse(child.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertFalse(parent.collectionBehavior.contains(.moveToActiveSpace))
            PinDesktopVisibilityPolicy.apply(.allDesktops, to: parent)
            XCTAssertTrue(parent.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(child.collectionBehavior.contains(.canJoinAllSpaces))
        }
        XCTAssertEqual(parent.frame, frame); XCTAssertEqual(child.frame, childFrame)
        XCTAssertEqual(parent.alphaValue, 0.4, accuracy: 0.001); XCTAssertTrue(parent.ignoresMouseEvents)
        XCTAssertEqual(parent.level, .floating); XCTAssertEqual(parent.isVisible, visible); XCTAssertEqual(child.isVisible, childVisible)
        XCTAssertTrue(child.parent === parent)
        XCTAssertTrue(parent.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @MainActor func testLaterChildInheritsParentAndSettingsClosesWithParent() throws {
        _ = NSApplication.shared
        let parent = NSPanel(contentRect: NSRect(x: 20, y: 30, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        let child = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; child.isReleasedWhenClosed = false
        defer { child.close(); parent.close() }
        parent.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        child.collectionBehavior = [.ignoresCycle, .moveToActiveSpace]
        PinDesktopVisibilityPolicy.inheritSpaceBehavior(from: parent, to: child)
        XCTAssertEqual(child.collectionBehavior, [.ignoresCycle, .fullScreenAuxiliary, .canJoinAllSpaces])
        let settings = SettingsController(onChange: {}, isSmoke: true)
        settings.showAbove(parent)
        XCTAssertTrue(settings.window?.parent === parent)
        XCTAssertTrue(settings.window?.collectionBehavior.contains(.canJoinAllSpaces) == true)
        PinDesktopVisibilityPolicy.apply(.currentDesktop, to: parent)
        XCTAssertFalse(settings.window?.collectionBehavior.contains(.canJoinAllSpaces) == true)
        parent.close()
        XCTAssertNil(settings.window?.parent); XCTAssertFalse(settings.window?.isVisible == true)
        settings.close()
    }

    @MainActor func testServiceDoesNotOverwritePreferenceUntilSelectionAndIsolatesNilDefaults() {
        let name = "PicShot-DesktopVisibilityService-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let service = PinDesktopVisibilityService(defaults: defaults)
        XCTAssertEqual(service.mode, .allDesktops); XCTAssertNil(defaults.object(forKey: PinDesktopVisibility.preferenceKey))
        service.select(.currentDesktop)
        XCTAssertEqual(PinDesktopVisibilityService(defaults: defaults).mode, .currentDesktop)
        PinDesktopVisibility.allDesktops.save(to: defaults); service.reload()
        XCTAssertEqual(service.mode, .allDesktops)
        let isolated = PinDesktopVisibilityService(defaults: nil, initialMode: .currentDesktop)
        isolated.select(.allDesktops); isolated.reload(); XCTAssertEqual(isolated.mode, .allDesktops)
    }

    @MainActor func testSettingsDraftCancelAndSmokeNeverPersistSelection() throws {
        _ = NSApplication.shared
        let name = "PicShot-DesktopVisibilitySettings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        PinDesktopVisibility.currentDesktop.save(to: defaults)
        let settings = SettingsController(onChange: {}, defaults: defaults, isSmoke: false)
        settings.selectCategory(.pins)
        XCTAssertEqual(settings.pinDesktopVisibility.identifier?.rawValue, "settings.pinDesktopVisibility")
        XCTAssertEqual(settings.pinDesktopVisibility.selectedItem?.title, PinDesktopVisibility.currentDesktop.title)
        settings.pinDesktopVisibility.selectItem(at: 0); settings.close()
        XCTAssertEqual(PinDesktopVisibility.read(from: defaults), .currentDesktop)
        let smoke = SettingsController(onChange: { XCTFail("Smoke must not save") }, defaults: defaults, isSmoke: true)
        smoke.selectCategory(.pins)
        XCTAssertEqual(smoke.pinDesktopVisibility.selectedItem?.title, PinDesktopVisibility.allDesktops.title)
        smoke.perform(NSSelectorFromString("saveSettings"))
        XCTAssertEqual(PinDesktopVisibility.read(from: defaults), .currentDesktop)
    }

    @MainActor func testSettingsSaveUsesExistingOnChangeRoute() throws {
        _ = NSApplication.shared
        let name = "PicShot-DesktopVisibilitySave-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var changed = 0
        let service = PinDesktopVisibilityService(defaults: defaults)
        let settings = SettingsController(onChange: { changed += 1; service.reload() }, defaults: defaults, isSmoke: false)
        settings.selectCategory(.pins)
        settings.pinDesktopVisibility.selectItem(at: PinDesktopVisibility.allCases.firstIndex(of: .currentDesktop)!)
        settings.perform(NSSelectorFromString("saveSettings"))
        XCTAssertEqual(changed, 1); XCTAssertEqual(service.mode, .currentDesktop)
        XCTAssertEqual(PinDesktopVisibility.read(from: defaults), .currentDesktop)
        settings.close()
    }

    /// Executes the same shown-window fixture as the optional packaged smoke route.
    /// Its evidence explicitly does not assert physical multi-Space behavior.
    @MainActor func testManagedModesControlsRestorationAndLifetimeFixture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-DesktopFixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try await PinDesktopVisibilityFixture.verify(evidenceDirectory: directory)
        XCTAssertEqual(report["status"] as? String, "passed")
        XCTAssertEqual(report["physicalSpacesVerified"] as? Bool, false)
        XCTAssertEqual(report["toggledInPlace"] as? Bool, true)
        XCTAssertEqual(report["closedControllersReleased"] as? Bool, true)
        XCTAssertEqual(report["originalRasterProviderReleased"] as? Bool, true)
    }
}
