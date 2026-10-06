import XCTest
import AppKit
@testable import PicShot

final class RecordingPreviewWindowTests: XCTestCase {
    @MainActor
    func testOpeningSameRecordingReusesWindowAndClosingDetachesPlayerGraph() throws {
        _ = NSApplication.shared
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("recording.mp4")
        let original = Data("a durable original recording".utf8)
        try original.write(to: source)
        let alias = directory.appendingPathComponent("recording-alias.mp4")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let store = RecordingPreviewWindowStore(presentWindows: false)
        var controller: RecordingPreviewController? = store.open(url: source)
        weak var weakController = controller
        let window = try XCTUnwrap(controller?.window)
        XCTAssertTrue(store.open(url: source) === controller)
        XCTAssertTrue(store.open(url: alias) === controller)
        XCTAssertEqual(store.controllers.count, 1)
        controller?.close()
        XCTAssertTrue(store.controllers.isEmpty)
        XCTAssertTrue(controller?.model.closed == true)
        XCTAssertNil(controller?.model.player.currentItem)
        XCTAssertNil(controller?.onClose)
        XCTAssertNil(window.contentView, "AppKit may cache the closed window, but must not keep its video view graph")
        XCTAssertNil(window.delegate)
        controller?.close()
        controller = nil
        XCTAssertNil(weakController)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor
    func testClosingOneRecordingDoesNotCloseAnotherAndReopenCreatesFreshPreview() throws {
        _ = NSApplication.shared
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.mp4")
        let secondURL = directory.appendingPathComponent("second.mp4")
        try Data("first original".utf8).write(to: firstURL)
        try Data("second original".utf8).write(to: secondURL)
        let store = RecordingPreviewWindowStore(presentWindows: false)
        defer { store.closeAll() }
        let first = store.open(url: firstURL)
        let second = store.open(url: secondURL)
        XCTAssertEqual(store.controllers.count, 2)
        first.close()
        XCTAssertEqual(store.controllers.count, 1)
        XCTAssertFalse(second.model.closed)
        XCTAssertTrue(store.open(url: secondURL) === second)
        let reopened = store.open(url: firstURL)
        XCTAssertFalse(reopened === first)
        XCTAssertFalse(reopened.model.closed)
        XCTAssertEqual(store.controllers.count, 2)
        store.closeAll()
        store.closeAll()
        XCTAssertTrue(store.controllers.isEmpty)
        XCTAssertTrue(reopened.model.closed)
        XCTAssertTrue(second.model.closed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }

    @MainActor
    func testRepeatedPreviewCloseDoesNotAccumulateControllersOrDeleteRecording() throws {
        _ = NSApplication.shared
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("recording.mp4")
        let original = Data("keep this saved recording".utf8)
        try original.write(to: source)
        let store = RecordingPreviewWindowStore(presentWindows: false)
        for _ in 0..<12 {
            weak var controller = store.open(url: source)
            XCTAssertEqual(store.controllers.count, 1)
            store.closeAll()
            XCTAssertTrue(store.controllers.isEmpty)
            XCTAssertNil(controller)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["recording.mp4"])
    }

    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicShot-Preview-Windows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
