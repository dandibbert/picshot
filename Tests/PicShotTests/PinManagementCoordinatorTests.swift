import AppKit
import XCTest
import PicShotCore
@testable import PicShot

final class PinManagementCoordinatorTests: XCTestCase {
    @MainActor func testImageRenameCommitsMetadataAndReconcilesExistingOwner() throws {
        let (directory, store, coordinator) = try fixture()
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let id = try coordinator.add(image: image(), title: "Before")
        let controller = try XCTUnwrap(coordinator.liveControllers[id])
        let before = try XCTUnwrap(store.entry(id: id))
        XCTAssertEqual(controller.pinTitle, "Before")
        let rename = try XCTUnwrap(controller.onRename)
        try rename("After", "Before")
        let after = try XCTUnwrap(store.entry(id: id))
        XCTAssertEqual(after.title, "After")
        XCTAssertEqual(after.groupID, before.groupID)
        XCTAssertEqual(after.presentation, before.presentation)
        XCTAssertEqual(after.original, before.original)
        XCTAssertEqual(after.current, before.current)
        try coordinator.reconcileVisiblePins()
        XCTAssertTrue(coordinator.liveControllers[id] === controller)
        XCTAssertEqual(controller.pinTitle, "After")
        XCTAssertTrue(controller.window?.title.hasPrefix("After · ") == true)
        let reloaded = try PinSessionStore(directory: directory)
        XCTAssertEqual(reloaded.entry(id: id)?.title, "After")
    }

    @MainActor func testRenameRejectsStaleTitleWithoutChangingNewerName() throws {
        let (directory, store, coordinator) = try fixture()
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let id = try coordinator.add(image: image(), title: "Original")
        let controller = try XCTUnwrap(coordinator.liveControllers[id])
        let rename = try XCTUnwrap(controller.onRename)
        try store.renamePin(id: id, title: "Changed elsewhere")
        try coordinator.reconcileVisiblePins()
        let safe = store.index
        XCTAssertThrowsError(try rename("Stale draft", "Original"))
        XCTAssertEqual(store.index, safe)
        XCTAssertEqual(controller.pinTitle, "Changed elsewhere")
    }

    @MainActor func testTextCallbackUsesExpectedDocumentAndPreservesRichMetadata() throws {
        let (directory, store, coordinator) = try fixture()
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let original = PinTextContent(text: "Original\n原文 🌱")
        let updated = PinTextContent(text: "Edited\n新内容 👩🏽‍💻")
        let id = try coordinator.add(rich: PreparedRichPin(document: PinRichDocument(text: original), title: "Note"))
        let controller = try XCTUnwrap(coordinator.richControllers[id])
        let before = try XCTUnwrap(store.entry(id: id))
        let update = try XCTUnwrap(controller.onUpdateText)
        try update(updated, original)
        let saved = try JSONDecoder().decode(PinRichDocument.self, from: store.richData(id: id))
        XCTAssertEqual(saved.text, updated)
        let after = try XCTUnwrap(store.entry(id: id))
        XCTAssertEqual(after.groupID, before.groupID)
        XCTAssertEqual(after.presentation, before.presentation)
        XCTAssertEqual(after.title, before.title)
        let safe = store.index
        XCTAssertThrowsError(try update(PinTextContent(text: "Stale"), original))
        XCTAssertEqual(store.index, safe)
        let rename = try XCTUnwrap(controller.onRename)
        try rename("Renamed note", "Note")
        try coordinator.reconcileVisiblePins()
        XCTAssertTrue(coordinator.richControllers[id] === controller)
        XCTAssertTrue(controller.window?.title.contains("Renamed note") == true)
        XCTAssertEqual(try JSONDecoder().decode(PinRichDocument.self, from: store.richData(id: id)).text, updated)
    }

    @MainActor func testRetainedCallbacksCannotMutateAfterOwnerTermination() throws {
        let (directory, store, coordinator) = try fixture()
        defer { try? coordinator.prepareForTermination(); try? FileManager.default.removeItem(at: directory) }
        let imageID = try coordinator.add(image: image(), title: "Image")
        let original = PinTextContent(text: "Text")
        let textID = try coordinator.add(rich: PreparedRichPin(document: PinRichDocument(text: original), title: "Note"))
        let imageOwner = try XCTUnwrap(coordinator.liveControllers[imageID])
        let textOwner = try XCTUnwrap(coordinator.richControllers[textID])
        let imageRename = try XCTUnwrap(imageOwner.onRename)
        let textRename = try XCTUnwrap(textOwner.onRename)
        let update = try XCTUnwrap(textOwner.onUpdateText)
        try coordinator.prepareForTermination()
        let safe = store.index
        XCTAssertThrowsError(try imageRename("Late", "Image"))
        XCTAssertThrowsError(try textRename("Late", "Note"))
        XCTAssertThrowsError(try update(PinTextContent(text: "Late"), original))
        XCTAssertEqual(store.index, safe)
        XCTAssertNil(imageOwner.onRename)
        XCTAssertNil(textOwner.onRename)
        XCTAssertNil(textOwner.onUpdateText)
        XCTAssertEqual(coordinator.livePinCount, 0)
    }

    @MainActor private func fixture() throws -> (URL, PinSessionStore, PinSessionCoordinator) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShotPinManagement-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try PinSessionStore(directory: directory)
        return (directory, store, PinSessionCoordinator(store: store, presentWindows: false))
    }

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 24, height: 16, bitsPerComponent: 8,
            bytesPerRow: 96, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        return try XCTUnwrap(context.makeImage())
    }
}
