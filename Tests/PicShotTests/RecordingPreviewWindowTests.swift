import XCTest
import AppKit
import AVFoundation
@testable import PicShot

final class RecordingPreviewWindowTests: XCTestCase {
    @MainActor
    func testOpeningSameRecordingReusesWindowAndClosingDetachesPlayerGraph() async throws {
        _ = NSApplication.shared
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("recording.mp4")
        let original = Data("a durable original recording".utf8)
        try original.write(to: source)
        let alias = directory.appendingPathComponent("recording-alias.mp4")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let store = RecordingPreviewWindowStore(presentWindows: false)
        weak var weakController: RecordingPreviewController?
        weak var weakModel: RecordingPreviewModel?
        weak var weakPlayer: AVPlayer?
        // AppKit uses event-scoped autoreleases. Enclose construction, close,
        // and every temporary Objective-C access in the same explicit scope.
        let cachedWindow: NSWindow = try autoreleasepool {
            let controller = store.open(url: source)
            weakController = controller
            weakModel = controller.model
            weakPlayer = controller.model.player
            let window = try XCTUnwrap(controller.window)
            XCTAssertTrue(store.open(url: source) === controller)
            XCTAssertTrue(store.open(url: alias) === controller)
            XCTAssertEqual(store.controllers.count, 1)
            controller.close()
            XCTAssertTrue(store.controllers.isEmpty)
            XCTAssertTrue(controller.model.closed)
            XCTAssertNil(controller.model.player.currentItem)
            XCTAssertNil(controller.onClose)
            XCTAssertNil(window.contentView, "AppKit may cache the closed window, but must not keep its video view graph")
            XCTAssertNil(window.delegate)
            controller.close()
            return window
        }
        try await waitForRelease { weakController == nil && weakModel == nil && weakPlayer == nil }
        XCTAssertNil(weakController, "Closed controller retained after its autorelease scope and bounded drain")
        XCTAssertNil(weakModel, "The detached hosting view or cancelled work must not retain the model")
        XCTAssertNil(weakPlayer, "A closed preview must not retain its AVPlayer")
        // Deliberately retain the closed NSWindow across the release check. A
        // cached window is allowed; a cached playback/controller graph is not.
        withExtendedLifetime(cachedWindow) {
            XCTAssertNil(cachedWindow.contentView)
            XCTAssertNil(cachedWindow.delegate)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor
    func testClosingOneRecordingDoesNotCloseAnotherAndReopenCreatesFreshPreview() async throws {
        _ = NSApplication.shared
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.mp4")
        let secondURL = directory.appendingPathComponent("second.mp4")
        try Data("first original".utf8).write(to: firstURL)
        try Data("second original".utf8).write(to: secondURL)
        let store = RecordingPreviewWindowStore(presentWindows: false)
        weak var firstClosed: RecordingPreviewController?
        weak var secondClosed: RecordingPreviewController?
        weak var reopenedClosed: RecordingPreviewController?
        autoreleasepool {
            let first = store.open(url: firstURL)
            let second = store.open(url: secondURL)
            firstClosed = first
            secondClosed = second
            XCTAssertEqual(store.controllers.count, 2)
            first.close()
            XCTAssertEqual(store.controllers.count, 1)
            XCTAssertFalse(second.model.closed)
            XCTAssertTrue(store.open(url: secondURL) === second)
            let reopened = store.open(url: firstURL)
            reopenedClosed = reopened
            XCTAssertFalse(reopened === first)
            XCTAssertFalse(reopened.model.closed)
            XCTAssertEqual(store.controllers.count, 2)
            store.closeAll()
            store.closeAll()
            XCTAssertTrue(store.controllers.isEmpty)
            XCTAssertTrue(reopened.model.closed)
            XCTAssertTrue(second.model.closed)
            XCTAssertNil(reopened.model.player.currentItem)
            XCTAssertNil(second.model.player.currentItem)
        }
        try await waitForRelease { firstClosed == nil && secondClosed == nil && reopenedClosed == nil }
        XCTAssertNil(firstClosed)
        XCTAssertNil(secondClosed)
        XCTAssertNil(reopenedClosed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }

    @MainActor
    func testRepeatedPreviewCloseDoesNotAccumulateControllersOrDeleteRecording() async throws {
        _ = NSApplication.shared
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("recording.mp4")
        let original = Data("keep this saved recording".utf8)
        try original.write(to: source)
        let store = RecordingPreviewWindowStore(presentWindows: false)
        for cycle in 0..<12 {
            weak var controller: RecordingPreviewController?
            weak var model: RecordingPreviewModel?
            weak var player: AVPlayer?
            autoreleasepool {
                let opened = store.open(url: source)
                controller = opened
                model = opened.model
                player = opened.model.player
                XCTAssertEqual(store.controllers.count, 1)
                store.closeAll()
                store.closeAll()
                XCTAssertTrue(store.controllers.isEmpty)
                XCTAssertTrue(opened.model.closed)
                XCTAssertNil(opened.model.player.currentItem)
                XCTAssertNil(opened.window?.contentView)
                XCTAssertNil(opened.window?.delegate)
            }
            try await waitForRelease { controller == nil && model == nil && player == nil }
            XCTAssertNil(controller, "Controller retained after preview cycle \(cycle)")
            XCTAssertNil(model, "Model retained after preview cycle \(cycle)")
            XCTAssertNil(player, "Player retained after preview cycle \(cycle)")
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["recording.mp4"])
    }

    /// This is a test boundary, not a dismissal workaround. Production still
    /// synchronously empties the store, stops playback, and detaches the view.
    /// Yielding permits cancelled loading tasks and queued SwiftUI teardown to
    /// finish. A persistent retain cycle still fails every final weak assertion.
    @MainActor
    private func waitForRelease(_ released: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !autoreleasepool(invoking: { released() }), ProcessInfo.processInfo.systemUptime < deadline {
            await Task.yield()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicShot-Preview-Windows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
