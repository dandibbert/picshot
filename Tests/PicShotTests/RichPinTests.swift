import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import PicShotCore
@testable import PicShot

final class RichPinTests: XCTestCase {
    @MainActor func testManagedTextSurvivesArchiveRestoreAndGroupVisibility() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let coordinator = PinSessionCoordinator(store: store, presentWindows: false)
        defer { try? coordinator.prepareForTermination() }
        let content = PinTextContent(runs: [PinTextRun(text: "Hello "), PinTextRun(text: "world", bold: true)], importedHTML: true)
        let (id, hiddenProbe) = try autoreleasepool { () throws -> (UUID, ClosedAuxiliaryWindowProbe) in
            let id = try coordinator.add(rich: PreparedRichPin(document: PinRichDocument(text: content), title: "Text"))
            XCTAssertEqual(coordinator.livePinCount, 1); XCTAssertTrue(coordinator.liveControllers.isEmpty)
            let controller = try XCTUnwrap(coordinator.richControllers[id])
            XCTAssertEqual(controller.richDocument?.text, content)
            let probe = try ClosedAuxiliaryWindowProbe(controller)
            try coordinator.hideAll()
            XCTAssertNil(controller.richDocument); XCTAssertNil(controller.onClose); XCTAssertNil(controller.onPresentationChange)
            probe.assertDetached()
            return (id, probe)
        }
        try await hiddenProbe.assertReleased()
        XCTAssertEqual(store.entry(id: id)?.isVisible, true); XCTAssertEqual(coordinator.livePinCount, 0)
        let archivedProbe = try autoreleasepool { () throws -> ClosedAuxiliaryWindowProbe in
            try coordinator.showCurrentGroup(); XCTAssertEqual(coordinator.livePinCount, 1)
            let controller = try XCTUnwrap(coordinator.richControllers[id])
            let probe = try ClosedAuxiliaryWindowProbe(controller)
            controller.close()
            XCTAssertEqual(store.entry(id: id)?.isVisible, false); XCTAssertEqual(coordinator.livePinCount, 0)
            probe.assertDetached()
            return probe
        }
        try await archivedProbe.assertReleased()
        let terminatedProbe = try autoreleasepool { () throws -> ClosedAuxiliaryWindowProbe in
            try coordinator.openPin(id: id)
            let controller = try XCTUnwrap(coordinator.richControllers[id])
            XCTAssertEqual(controller.richDocument?.text, content)
            let probe = try ClosedAuxiliaryWindowProbe(controller)
            try coordinator.prepareForTermination(); probe.assertDetached()
            return probe
        }
        try await terminatedProbe.assertReleased()
        let restored = try PinSessionStore(directory: directory)
        XCTAssertEqual(restored.index.version, 2)
        XCTAssertEqual(try JSONDecoder().decode(PinRichDocument.self, from: restored.richData(id: id)).text, content)
    }
    @MainActor func testRichCloseAndRepeatedSwitchReleaseControllersAndPreservePresentation() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let coordinator = PinSessionCoordinator(store: store, presentWindows: false)
        defer { try? coordinator.prepareForTermination() }
        let id = try autoreleasepool { try coordinator.add(rich: text()) }
        let group = try store.createGroup(name: "Other")
        var closed: [ClosedAuxiliaryWindowProbe] = []
        for _ in 0..<5 {
            let (expected, probe) = try autoreleasepool { () throws -> (PinPresentation, ClosedAuxiliaryWindowProbe) in
                let controller = try XCTUnwrap(coordinator.richControllers[id])
                let value = PinPresentation(frame: PinWindowFrame(x: 25, y: 25, width: 550, height: 410), opacity: 0.4, zoom: 1.3, clickThrough: true, locked: true)
                controller.applyPresentation(value)
                let expected = controller.presentation, probe = try ClosedAuxiliaryWindowProbe(controller)
                try coordinator.switchGroup(id: group.id)
                XCTAssertNil(controller.richDocument); XCTAssertNil(controller.onClose); XCTAssertNil(controller.onPresentationChange)
                probe.assertDetached()
                return (expected, probe)
            }
            closed.append(probe); try await probe.assertReleased()
            XCTAssertEqual(store.entry(id: id)?.presentation, expected); XCTAssertEqual(store.entry(id: id)?.isVisible, true)
            try autoreleasepool {
                try coordinator.switchGroup(id: PinGroup.defaultID)
                XCTAssertEqual(coordinator.livePinCount, 1)
            }
        }
        let last = try autoreleasepool { () throws -> ClosedAuxiliaryWindowProbe in
            try coordinator.recoverCurrentGroup()
            let controller = try XCTUnwrap(coordinator.richControllers[id])
            XCTAssertEqual(controller.presentation.opacity, 1); XCTAssertEqual(controller.presentation.clickThrough, false)
            let probe = try ClosedAuxiliaryWindowProbe(controller)
            try coordinator.prepareForTermination(); probe.assertDetached()
            return probe
        }
        closed.append(last)
        for probe in closed { try await probe.assertReleased() }
    }
    @MainActor func testMixedLivePinsShareProtectionAndQuota() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory, policy: PinSessionPolicy(maxPins: 2))
        let coordinator = PinSessionCoordinator(store: store, presentWindows: false)
        defer { try? coordinator.prepareForTermination() }
        let imageID = try coordinator.add(image: raster())
        let textID = try coordinator.add(rich: text())
        XCTAssertEqual(coordinator.livePinIDs, [imageID, textID])
        XCTAssertThrowsError(try coordinator.add(rich: text()))
        XCTAssertThrowsError(try coordinator.add(image: raster()))
        XCTAssertEqual(coordinator.livePinCount, 2); XCTAssertEqual(store.entries.count, 2)
    }
    @MainActor func testFailedRichManifestCommitRollsBackPosterAndPayload() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let original = try store.add(image: raster())
        let before = store.index
        let manifest = directory.appendingPathComponent("index.json")
        try FileManager.default.removeItem(at: manifest); try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.add(rich: text()))
        XCTAssertEqual(store.index, before)
        XCTAssertEqual(try assetNames(directory), Set(original.assetFilenames))
    }
    @MainActor func testProtectedCapacityFailureAlsoRollsBackPayload() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory, policy: PinSessionPolicy(maxPins: 1))
        let first = try store.add(rich: text()); try store.setGroupProtected(id: PinGroup.defaultID, protected: true)
        let before = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        XCTAssertThrowsError(try store.add(rich: text()))
        XCTAssertEqual(try assetNames(directory), Set(first.assetFilenames))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("index.json")), before)
    }
    @MainActor func testFileReferenceRestoreAndRemovalNeverTouchTarget() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let external = directory.appendingPathComponent("outside-private.txt"); let bytes = Data("private contents".utf8); try bytes.write(to: external)
        let folder = directory.appendingPathComponent("session")
        let store = try PinSessionStore(directory: folder)
        let missing = PinFileReference(path: "/unavailable/private-file", name: "Missing", isDirectory: false)
        let document = PinRichDocument(files: [PinFileReference(path: external.path, name: external.lastPathComponent, isDirectory: false), missing])
        let entry = try store.add(rich: PreparedRichPin(document: document, title: "Files"))
        let restored = try PinSessionStore(directory: folder)
        let coordinator = PinSessionCoordinator(store: restored, presentWindows: false)
        try coordinator.restoreOnLaunch(enabled: true, isSmoke: false)
        XCTAssertEqual(coordinator.richControllers[entry.id]?.richDocument, document)
        XCTAssertEqual(try Data(contentsOf: external), bytes)
        try restored.remove(id: entry.id); try coordinator.reconcileVisiblePins()
        XCTAssertTrue(try assetNames(folder).isEmpty)
        XCTAssertEqual(try Data(contentsOf: external), bytes)
    }
    @MainActor func testRichSymlinkRejectsSessionWithoutTouchingOutsideTarget() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory.appendingPathComponent("session"))
        let entry = try store.add(rich: text())
        let asset = try XCTUnwrap(entry.richContent)
        let target = directory.appendingPathComponent("outside.pinjson"); let bytes = Data("private".utf8); try bytes.write(to: target)
        let payload = store.directory.appendingPathComponent(asset.filename)
        try FileManager.default.removeItem(at: payload); try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: target)
        let before = try Data(contentsOf: store.directory.appendingPathComponent("index.json"))
        XCTAssertThrowsError(try PinSessionStore(directory: store.directory)) { XCTAssertEqual($0 as? PinSessionError, .unsafePath) }
        XCTAssertThrowsError(try store.richData(id: entry.id))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try Data(contentsOf: store.directory.appendingPathComponent("index.json")), before)
    }
    @MainActor func testRichCleanupRemovesOrphansAndCorruptPayloadButPreservesUnrelatedFiles() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let entry = try store.add(rich: text())
        let orphan = directory.appendingPathComponent(UUID().uuidString + ".pinjson")
        let temporary = directory.appendingPathComponent(".pin-write-" + UUID().uuidString + ".gif")
        let unrelated = directory.appendingPathComponent("notes.pinjson")
        for file in [orphan, temporary, unrelated] { try Data("stale".utf8).write(to: file) }
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent(try XCTUnwrap(entry.richContent).filename))
        let restored = try PinSessionStore(directory: directory)
        XCTAssertTrue(restored.entries.isEmpty); XCTAssertTrue(try assetNames(directory).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
    @MainActor func testGIFHeaderValidationSequentialDecodeAndRelease() async throws {
        let data = try gif()
        let prepared = try PreparedRichPin(animation: data, title: "Animation")
        XCTAssertEqual(prepared.frameCount, 2); XCTAssertEqual(prepared.width, 16)
        let decoder = try RichPinFrameDecoder(data: data, asset: prepared.asset)
        for index in 0..<10 {
            let (frame, delay) = try await decoder.frame(at: index % 2)
            XCTAssertEqual(frame.width, 16); XCTAssertEqual(frame.height, 8); XCTAssertGreaterThanOrEqual(delay, 0.04)
        }
        await decoder.release()
        do { _ = try await decoder.frame(at: 0); XCTFail("Released decoder must reject subsequent work") } catch {}
        XCTAssertThrowsError(try PreparedRichPin(animation: Data("not an animation".utf8), title: "Invalid"))
        XCTAssertThrowsError(try PreparedRichPin(animation: Data(count: PinRichAsset.maximumAnimationBytes + 1), title: "Huge"))
    }
    @MainActor func testAnimatedWebPSequentialDecodeWhenSystemCodecIsAvailable() async throws {
        // Original two-frame 12 × 8 lossless red/blue fixture, generated for this test.
        let data = try XCTUnwrap(Data(base64Encoded: "UklGRoQAAABXRUJQVlA4WAoAAAACAAAACwAABwAAQU5JTQYAAAAAAAAAAABBTk1GKAAAAAAAAAAAAAsAAAcAAGQAAAJWUDhMDwAAAC8LwAEABxD9j/4HIqL/AQBBTk1GKAAAAAAAAAAAAAsAAAcAAGQAAABWUDhMDwAAAC8LwAEABxDR//4HIqL/AQA="))
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 2 else {
            throw XCTSkip("This macOS ImageIO build does not expose animated WebP frames; the explicit importer reports unsupported input")
        }
        let prepared = try PreparedRichPin(animation: data, title: "WebP")
        XCTAssertEqual(prepared.fileExtension, "webp"); XCTAssertEqual(prepared.frameCount, 2)
        let decoder = try RichPinFrameDecoder(data: data, asset: prepared.asset)
        let first = try await decoder.frame(at: 0), second = try await decoder.frame(at: 1)
        XCTAssertEqual(first.0.width, 12); XCTAssertEqual(second.0.height, 8)
        XCTAssertEqual(first.1, 0.1, accuracy: 0.001); XCTAssertEqual(second.1, 0.1, accuracy: 0.001)
        await decoder.release()
    }
    @MainActor func testAnimationLiveLimitAndHideCleanup() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PinSessionStore(directory: directory)
        let coordinator = PinSessionCoordinator(store: store, presentWindows: false)
        defer { try? coordinator.prepareForTermination() }
        let prepared = try PreparedRichPin(animation: gif(), title: "GIF")
        let hidden = try autoreleasepool { () throws -> [ClosedAuxiliaryWindowProbe] in
            for _ in 0..<4 { try coordinator.add(rich: prepared) }
            XCTAssertThrowsError(try coordinator.add(rich: prepared)); XCTAssertEqual(store.entries.count, 4)
            let probes = try coordinator.richControllers.values.map { try ClosedAuxiliaryWindowProbe($0) }
            try coordinator.hideAll(); XCTAssertEqual(coordinator.livePinCount, 0)
            for probe in probes { probe.assertDetached() }
            return probes
        }
        for probe in hidden { try await probe.assertReleased() }
        let terminated = try autoreleasepool { () throws -> [ClosedAuxiliaryWindowProbe] in
            try coordinator.showCurrentGroup(); XCTAssertEqual(coordinator.livePinCount, 4)
            let probes = try coordinator.richControllers.values.map { try ClosedAuxiliaryWindowProbe($0) }
            try coordinator.prepareForTermination(); XCTAssertEqual(coordinator.livePinCount, 0)
            for probe in probes { probe.assertDetached() }
            return probes
        }
        for probe in terminated { try await probe.assertReleased() }
        let restored = try PinSessionStore(directory: directory); XCTAssertEqual(restored.entries.count, 4)
    }
    @MainActor func testColorContentSurvivesPersistence() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let color = try XCTUnwrap(PinRGBColor.parse("#FE123480"))
        let store = try PinSessionStore(directory: directory)
        let entry = try store.add(rich: PreparedRichPin(document: PinRichDocument(color: color), title: color.hex))
        XCTAssertEqual(entry.current.width, 480); XCTAssertEqual(entry.current.height, 280)
        let restored = try PinSessionStore(directory: directory)
        XCTAssertEqual(try JSONDecoder().decode(PinRichDocument.self, from: restored.richData(id: entry.id)).color, color)
    }
    func testClipboardSingleFrameGIFDecodesAsStaticImage() throws {
        let data = try XCTUnwrap(Data(base64Encoded: "R0lGODdhDAAIAIEAAChQoAAAAAAAAAAAACwAAAAADAAIAAAIEgABCBxIsKDBgwgTKlzIsGHBgAA7"))
        let info = try RichPinContainerInfo.inspect(data)
        XCTAssertFalse(info.requiresAnimation); XCTAssertEqual(info.frameCount, 1)
        guard case .still(let image) = try RichPinClipboardImage.prepare(data) else { return XCTFail("A true single-frame GIF must use the normal image pin") }
        XCTAssertEqual(image.width, 12); XCTAssertEqual(image.height, 8)
    }
    func testClipboardSingleFrameWebPDecodesAsStaticImage() throws {
        let data = try XCTUnwrap(Data(base64Encoded: "UklGRh4AAABXRUJQVlA4TBEAAAAvC8ABAAdQqKIUtP+BiOh/AAA="))
        let info = try RichPinContainerInfo.inspect(data)
        XCTAssertFalse(info.requiresAnimation); XCTAssertEqual(info.frameCount, 1)
        guard case .still(let image) = try RichPinClipboardImage.prepare(data) else { return XCTFail("A true single-frame WebP must use the normal image pin") }
        XCTAssertEqual(image.width, 12); XCTAssertEqual(image.height, 8)
    }
    func testClipboardMultiframeGIFRemainsAnimationAndFrameCountDisagreementIsRejected() throws {
        let data = try gif(), info = try RichPinContainerInfo.inspect(data)
        XCTAssertTrue(info.requiresAnimation); XCTAssertEqual(info.frameCount, 2)
        XCTAssertThrowsError(try info.validateDecodedFrameCount(1))
        guard case .animated(let prepared) = try RichPinClipboardImage.prepare(data) else { return XCTFail("Multiframe GIF must never be flattened") }
        XCTAssertEqual(prepared.frameCount, 2)
    }
    func testClipboardWebPAnimationMarkerNeverBecomesStaticEvenWithOneDecodedFrame() throws {
        let data = try XCTUnwrap(Data(base64Encoded: "UklGRoQAAABXRUJQVlA4WAoAAAACAAAACwAABwAAQU5JTQYAAAAAAAAAAABBTk1GKAAAAAAAAAAAAAsAAAcAAGQAAAJWUDhMDwAAAC8LwAEABxD9j/4HIqL/AQBBTk1GKAAAAAAAAAAAAAsAAAcAAGQAAABWUDhMDwAAAC8LwAEABxDR//4HIqL/AQA="))
        let info = try RichPinContainerInfo.inspect(data)
        XCTAssertTrue(info.requiresAnimation); XCTAssertThrowsError(try info.validateDecodedFrameCount(1))
        // Keep RIFF + VP8X + ANIM + only the first ANMF. This is still an animation container.
        var oneFrame = Data(data.prefix(92)); writeRIFFLength(&oneFrame)
        let single = try RichPinContainerInfo.inspect(oneFrame)
        XCTAssertTrue(single.requiresAnimation); XCTAssertEqual(single.frameCount, 1)
        XCTAssertThrowsError(try single.validateDecodedFrameCount(1))
        XCTAssertThrowsError(try RichPinClipboardImage.prepare(oneFrame))
    }
    func testClipboardMalformedAndOversizedSourcesFailWithoutBitmapFallback() throws {
        let gif = try XCTUnwrap(Data(base64Encoded: "R0lGODdhDAAIAIEAAChQoAAAAAAAAAAAACwAAAAADAAIAAAIEgABCBxIsKDBgwgTKlzIsGHBgAA7"))
        XCTAssertThrowsError(try RichPinClipboardImage.prepare(Data(gif.dropLast())))
        var hugeGIF = gif
        for index in 6...9 { hugeGIF[index] = 255 }
        XCTAssertThrowsError(try RichPinClipboardImage.prepare(hugeGIF))
        XCTAssertThrowsError(try RichPinClipboardImage.prepare(Data(count: PinRichAsset.maximumAnimationBytes + 1)))
        var webp = try XCTUnwrap(Data(base64Encoded: "UklGRh4AAABXRUJQVlA4TBEAAAAvC8ABAAdQqKIUtP+BiOh/AAA="))
        webp[4] = 255 // RIFF byte count contradicts the actual input.
        XCTAssertThrowsError(try RichPinClipboardImage.prepare(webp))
        // Valid chunk envelope with an overlarge extended canvas must fail before raster decode.
        var hugeWebP = Data("RIFF".utf8) + Data(repeating: 0, count: 4) + Data("WEBPVP8X".utf8)
        hugeWebP += Data([10, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 255, 255])
        hugeWebP += try XCTUnwrap(Data(base64Encoded: "UklGRh4AAABXRUJQVlA4TBEAAAAvC8ABAAdQqKIUtP+BiOh/AAA=")).dropFirst(12)
        writeRIFFLength(&hugeWebP)
        XCTAssertThrowsError(try RichPinClipboardImage.prepare(hugeWebP))
    }
    func testClipboardImageOnlyOrUnsupportedHTMLFallsThroughToOtherRepresentations() {
        for html in ["<img src='https://example.invalid/image.png'>", "<p></p><img src='file:///private/image.png'>", "<script>ignored()</script>", "<div>&nbsp;</div>", ""] {
            XCTAssertNil(RichPinClipboardRouting.preferredHTMLText(html), html)
        }
        XCTAssertNil(RichPinClipboardRouting.preferredHTMLText(String(repeating: "x", count: PinTextContent.maximumUTF8Bytes + 1)))
        let rich = RichPinClipboardRouting.preferredHTMLText("<p><b>Meaningful text</b><img src='https://example.invalid'></p>")
        XCTAssertTrue(rich?.plainText.contains("Meaningful text") == true)
        XCTAssertTrue(rich?.runs.contains(where: { $0.bold }) == true)
    }
    private func writeRIFFLength(_ data: inout Data) {
        let size = data.count - 8
        for index in 0..<4 { data[4 + index] = UInt8((size >> (8 * index)) & 255) }
    }
    @MainActor private func text() throws -> PreparedRichPin { try PreparedRichPin(document: PinRichDocument(text: PinTextContent(text: "Hello rich pins")), title: "Text") }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RichPinTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); return directory
    }
    private func assetNames(_ directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map(\.lastPathComponent).filter { PinRasterAsset.isSafeFilename($0) || PinRichAsset.isSafeFilename($0) })
    }
    private func raster(red: CGFloat = 0.7) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.3, blue: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
        return try XCTUnwrap(context.makeImage())
    }
    private func gif() throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        for red in [CGFloat(0.2), CGFloat(0.9)] {
            CGImageDestinationAddImage(destination, try raster(red: red), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return data as Data
    }
}
