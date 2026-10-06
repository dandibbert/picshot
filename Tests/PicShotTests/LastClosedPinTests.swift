import XCTest
import AppKit
import PicShotCore
@testable import PicShot

final class LastClosedPinTests: XCTestCase {
    @MainActor func testRestoreFollowsLastExplicitCloseAcrossGroupsAndRestarts() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-CloseOrder-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let coordinator = PinSessionCoordinator(store: store, presentWindows: false)
        let first = try coordinator.add(image: image())
        let second = try coordinator.add(image: image())
        coordinator.liveControllers[second]?.close()
        coordinator.liveControllers[first]?.close()
        XCTAssertEqual(store.index.lastArchivedEntry?.id, first, "The older-created pin was closed last")
        let sequence = store.entry(id: first)?.archiveSequence
        try store.archive(id: first) // An already-archived item is not a new close.
        XCTAssertEqual(store.entry(id: first)?.archiveSequence, sequence)
        let other = try store.createGroup(name: "Other")
        try coordinator.switchGroup(id: other.id)
        try coordinator.prepareForTermination()
        let reopenedStore = try PinSessionStore(directory: directory)
        let reopened = PinSessionCoordinator(store: reopenedStore, presentWindows: false)
        defer { try? reopened.prepareForTermination() }
        XCTAssertEqual(try reopened.restoreLastClosedPin(), first)
        XCTAssertEqual(reopenedStore.index.activeGroupID, PinGroup.defaultID)
        XCTAssertEqual(reopened.livePinIDs, [first])
        XCTAssertNil(reopenedStore.entry(id: first)?.archiveSequence)
        XCTAssertEqual(try reopened.restoreLastClosedPin(), second)
        XCTAssertEqual(reopened.livePinIDs, [first, second])
        XCTAssertNil(try reopened.restoreLastClosedPin())
    }
    @MainActor func testHideSwitchAndTerminationNeverCreateCloseHistory() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-HideOrder-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let coordinator = PinSessionCoordinator(store: store, presentWindows: false)
        let id = try coordinator.add(image: image())
        try coordinator.hideAll(); XCTAssertNil(store.index.lastArchivedEntry)
        try coordinator.showCurrentGroup(); XCTAssertNil(store.index.lastArchivedEntry)
        let group = try store.createGroup(name: "Other")
        try coordinator.switchGroup(id: group.id); XCTAssertNil(store.index.lastArchivedEntry)
        try coordinator.switchGroup(id: PinGroup.defaultID); try coordinator.prepareForTermination()
        XCTAssertNil(store.index.lastArchivedEntry); XCTAssertNil(store.entry(id: id)?.archiveSequence)
        XCTAssertEqual(store.entry(id: id)?.isVisible, true)
    }
    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.4, blue: 0.7, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try XCTUnwrap(context.makeImage())
    }
}
