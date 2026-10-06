import XCTest
import Foundation
import PicShotCore
@testable import PicShot

final class CapturePresetStoreTests: XCTestCase {
    @MainActor func testTwoRectanglesAndDelaysSurviveRelaunchAndOnlyMetadataIsWritten() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = ScreenshotPreferences.options
        let first = try preset(index: 1, delay: .threeSeconds)
        let second = try preset(index: 2, delay: .tenSeconds)
        let store = try CapturePresetStore(directory: directory)
        try store.add(first); try store.add(second)
        let restored = try CapturePresetStore(directory: directory)
        XCTAssertEqual(restored.presets, [first, second])
        XCTAssertNotEqual(restored.presets[0].pixelFrame, restored.presets[1].pixelFrame)
        XCTAssertEqual(restored.presets.map(\.delay), [.threeSeconds, .tenSeconds])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [CapturePresetStore.manifestFilename])
        let bytes = try Data(contentsOf: directory.appendingPathComponent(CapturePresetStore.manifestFilename))
        XCTAssertLessThan(bytes.count, CapturePresetIndex.maximumBytes)
        XCTAssertEqual(ScreenshotPreferences.options, preferences)
    }

    @MainActor func testRenameDelayChangeDeleteAndRelaunchPreserveOtherRectangles() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CapturePresetStore(directory: directory)
        let first = try preset(index: 1), second = try preset(index: 2)
        try store.add(first); try store.add(second)
        try store.rename(id: first.id, name: "新名称")
        try store.updateDelay(id: first.id, delay: .fiveSeconds)
        let renamed = try XCTUnwrap(store.preset(id: first.id))
        XCTAssertEqual(renamed.name, "新名称"); XCTAssertEqual(renamed.delay, .fiveSeconds)
        XCTAssertEqual(renamed.display, first.display); XCTAssertEqual(renamed.pixelFrame, first.pixelFrame)
        try store.remove(id: second.id)
        let restored = try CapturePresetStore(directory: directory)
        XCTAssertEqual(restored.presets, [renamed]); XCTAssertNil(restored.preset(id: second.id))
        try restored.remove(id: first.id)
        XCTAssertTrue(try CapturePresetStore(directory: directory).presets.isEmpty)
    }

    @MainActor func testMalformedAndOversizedCatalogsAreNeverOverwritten() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appendingPathComponent(CapturePresetStore.manifestFilename)
        for bytes in [Data("{bad json".utf8), Data(repeating: 32, count: CapturePresetIndex.maximumBytes + 1)] {
            try bytes.write(to: manifest)
            XCTAssertThrowsError(try CapturePresetStore(directory: directory)) {
                XCTAssertEqual($0 as? CapturePresetError, .invalidManifest)
            }
            XCTAssertEqual(try Data(contentsOf: manifest), bytes)
        }
    }

    @MainActor func testFailedReloadKeepsCurrentCatalogAndMalformedFile() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CapturePresetStore(directory: directory), saved = try preset(index: 1)
        try store.add(saved)
        let bytes = Data("{\"version\":999,\"presets\":[]}".utf8)
        let manifest = directory.appendingPathComponent(CapturePresetStore.manifestFilename)
        try bytes.write(to: manifest)
        XCTAssertThrowsError(try store.reload()) { XCTAssertEqual($0 as? CapturePresetError, .unsupportedVersion) }
        XCTAssertEqual(store.presets, [saved]); XCTAssertEqual(try Data(contentsOf: manifest), bytes)
    }

    @MainActor func testLoadRejectsMalformedDisplayPixelGeometryAndDuplicateIDs() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let record = try preset(index: 1)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        var wrongDelay = raw; wrongDelay["delaySeconds"] = 99
        var wrongDisplay = raw
        var display = try XCTUnwrap(raw["display"] as? [String: Any]); display["uuid"] = "volatile-display-1"
        wrongDisplay["display"] = display
        var wrongPixels = raw
        wrongPixels["pixelFrame"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CGRect(x: 20.5, y: 20, width: 60, height: 80)))
        for entries in [[wrongDelay], [wrongDisplay], [wrongPixels], [raw, raw]] {
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "presets": entries])
            let manifest = directory.appendingPathComponent(CapturePresetStore.manifestFilename)
            try data.write(to: manifest)
            XCTAssertThrowsError(try CapturePresetStore(directory: directory)) { XCTAssertEqual($0 as? CapturePresetError, .invalidManifest) }
            XCTAssertEqual(try Data(contentsOf: manifest), data)
        }
    }

    @MainActor func testLimitAndInvalidUpdatePreserveDiskAndMemory() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CapturePresetStore(directory: directory)
        for index in 1...32 { try store.add(preset(index: index)) }
        let before = store.presets
        let manifest = directory.appendingPathComponent(CapturePresetStore.manifestFilename)
        let bytes = try Data(contentsOf: manifest)
        XCTAssertThrowsError(try store.add(preset(index: 33))) { XCTAssertEqual($0 as? CapturePresetError, .limitReached) }
        XCTAssertThrowsError(try store.add(before[0])) { XCTAssertEqual($0 as? CapturePresetError, .duplicateIdentifier) }
        XCTAssertThrowsError(try store.update(id: before[0].id, name: "\n\n", delay: .tenSeconds))
        XCTAssertEqual(store.presets, before); XCTAssertEqual(try Data(contentsOf: manifest), bytes)
        XCTAssertEqual(try CapturePresetStore(directory: directory).presets.count, 32)
    }

    @MainActor func testSymlinkManifestRejectsReadAndWriteWithoutChangingOutsideTarget() throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("catalog")
        let store = try CapturePresetStore(directory: directory)
        let first = try preset(index: 1); try store.add(first)
        let manifest = directory.appendingPathComponent(CapturePresetStore.manifestFilename)
        let outside = parent.appendingPathComponent("outside.json"), bytes = Data("untouched".utf8)
        try bytes.write(to: outside); try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: outside)
        XCTAssertThrowsError(try CapturePresetStore(directory: directory)) { XCTAssertEqual($0 as? CapturePresetError, .unsafePath) }
        XCTAssertThrowsError(try store.rename(id: first.id, name: "未保存")) { XCTAssertEqual($0 as? CapturePresetError, .unsafePath) }
        XCTAssertEqual(store.presets, [first]); XCTAssertEqual(try Data(contentsOf: outside), bytes)
        try FileManager.default.removeItem(at: outside)
        XCTAssertThrowsError(try CapturePresetStore(directory: directory)) { XCTAssertEqual($0 as? CapturePresetError, .unsafePath) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    @MainActor func testSymlinkDirectoryAndDirectoryManifestAreRejected() throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let actual = parent.appendingPathComponent("actual"), alias = parent.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        XCTAssertThrowsError(try CapturePresetStore(directory: alias)) { XCTAssertEqual($0 as? CapturePresetError, .unsafePath) }
        try FileManager.default.createDirectory(at: actual.appendingPathComponent(CapturePresetStore.manifestFilename), withIntermediateDirectories: true)
        XCTAssertThrowsError(try CapturePresetStore(directory: actual)) { XCTAssertEqual($0 as? CapturePresetError, .unsafePath) }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-PresetTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func preset(index: Int, delay: ScreenshotDelay = .none) throws -> CapturePreset {
        let display = try CapturePresetDisplay(uuid: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900), pixelWidth: 2880, pixelHeight: 1800, rotationDegrees: 0)
        return try CapturePreset(id: UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", index))!,
            name: "区域 \(index)", delay: delay, display: display,
            topLeftFrame: CGRect(x: index * 5, y: index * 5, width: 30, height: 40),
            pixelFrame: CGRect(x: index * 10, y: index * 10, width: 60, height: 80))
    }
}
