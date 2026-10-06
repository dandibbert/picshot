import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import PicShotCore

final class PinSessionIndexTests: XCTestCase {
    func testEmptyIndexHasUsableDefaultGroup() throws {
        let index = try PinSessionIndex().validated()
        XCTAssertEqual(index.groups.count, 1)
        XCTAssertEqual(index.activeGroupID, PinGroup.defaultID)
        XCTAssertTrue(index.visibleEntries.isEmpty)
        XCTAssertFalse(index.allHidden)
    }

    func testManifestRoundTripPreservesOriginalEditedAndPresentationMetadata() throws {
        var index = PinSessionIndex()
        let group = try index.createGroup(name: "设计参考", color: .purple)
        let presentation = PinPresentation(frame: PinWindowFrame(x: -1000, y: 12, width: 550, height: 600),
                                           opacity: 0.35, zoom: 2, clickThrough: true, locked: true)
        let entry = PinSessionEntry(groupID: group.id, title: "参考", original: asset(), current: asset(width: 5, height: 3), presentation: presentation)
        index.entries = [entry]; index.activeGroupID = group.id
        let decoded = try JSONDecoder().decode(PinSessionIndex.self, from: JSONEncoder().encode(index)).validated()
        XCTAssertEqual(decoded, index)
        XCTAssertEqual(decoded.visibleEntries, [entry])
    }

    func testTraversalAndNoncanonicalImageFilenamesAreRejected() throws {
        let badNames = ["../outside.png", "/tmp/outside.png", "sub/image.png", "image.png", ".png", "", "index.json",
                        "00000000-0000-0000-0000-000000000001.png/../x", "00000000-0000-0000-0000-000000000001.PNG",
                        "00000000-0000-0000-0000-000000000001.png%00", "..\\outside.png"]
        for name in badNames {
            XCTAssertFalse(PinRasterAsset.isSafeFilename(name), name)
            var index = PinSessionIndex()
            index.entries = [PinSessionEntry(original: PinRasterAsset(filename: name, width: 2, height: 2, byteCount: 20))]
            XCTAssertThrowsError(try index.validated()) { XCTAssertEqual($0 as? PinSessionError, .unsafePath, name) }
        }
        XCTAssertTrue(PinRasterAsset.isSafeFilename(UUID().uuidString + ".png"))
    }

    func testMalformedManifestAndUnsupportedVersionAreRejected() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(PinSessionIndex.self, from: Data("{broken".utf8)))
        var version = PinSessionIndex(); version.version = 90
        XCTAssertThrowsError(try version.validated()) { XCTAssertEqual($0 as? PinSessionError, .unsupportedVersion) }
        var duplicateGroups = PinSessionIndex(); duplicateGroups.groups.append(duplicateGroups.groups[0])
        XCTAssertThrowsError(try duplicateGroups.validated())
        var missingDefault = PinSessionIndex(); missingDefault.groups = [PinGroup(name: "Only")]
        XCTAssertThrowsError(try missingDefault.validated())
        var missingActive = PinSessionIndex(); missingActive.activeGroupID = UUID()
        XCTAssertThrowsError(try missingActive.validated())
        var invalidGroup = PinSessionIndex(); invalidGroup.groups[0].name = "\n"
        XCTAssertThrowsError(try invalidGroup.validated())
        var missingEntryGroup = PinSessionIndex(); missingEntryGroup.entries = [PinSessionEntry(groupID: UUID(), original: asset())]
        XCTAssertThrowsError(try missingEntryGroup.validated())
    }

    func testDuplicatePinAndSharedOrConflictingImageMetadataAreRejected() throws {
        let entry = PinSessionEntry(original: asset())
        var duplicate = PinSessionIndex(entries: [entry, entry])
        XCTAssertThrowsError(try duplicate.validated())
        duplicate.entries = [entry, PinSessionEntry(original: entry.original)]
        XCTAssertThrowsError(try duplicate.validated())
        var conflict = entry
        conflict.current = PinRasterAsset(filename: entry.original.filename, width: 1, height: 1, byteCount: 1)
        XCTAssertThrowsError(try PinSessionIndex(entries: [conflict]).validated())
    }

    func testDimensionAndIntegerOverflowAreRejectedBeforeBudgetArithmetic() {
        for dimensions in [(0, 10), (10, 0), (-1, 10), (Int.max, Int.max), (Int.max, 1), (32_000_001, 1)] {
            let invalid = asset(width: dimensions.0, height: dimensions.1)
            XCTAssertFalse(invalid.isValid)
            XCTAssertFalse(PinSessionPolicy().fits([PinSessionEntry(original: invalid)]))
        }
        XCTAssertTrue(asset(width: 8000, height: 4000).isValid)
        XCTAssertFalse(asset(bytes: Int64.max).isValid)
    }

    func testBudgetCountsOriginalAndEditedOnlyOnceWhenUnchanged() throws {
        let original = asset(width: 10, height: 10, bytes: 40)
        let unchanged = PinSessionEntry(original: original)
        let edited = PinSessionEntry(original: original, current: asset(width: 5, height: 10, bytes: 30))
        XCTAssertEqual(unchanged.assets.count, 1)
        XCTAssertEqual(edited.assets.count, 2)
        XCTAssertTrue(PinSessionPolicy(maxPixelCount: 100, maxDiskBytes: 40).fits([unchanged]))
        XCTAssertFalse(PinSessionPolicy(maxPixelCount: 100, maxDiskBytes: 100).fits([edited]))
        XCTAssertFalse(PinSessionPolicy(maxPixelCount: 200, maxDiskBytes: 69).fits([edited]))
        XCTAssertTrue(PinSessionPolicy(maxPixelCount: 150, maxDiskBytes: 70).fits([edited]))
    }

    func testProtectedHiddenGroupsCountAgainstAllBudgets() throws {
        let group = PinGroup(name: "保存", isHidden: true, isProtected: true)
        let oldProtected = PinSessionEntry(groupID: group.id, updatedAt: Date(timeIntervalSince1970: 1), original: asset())
        let newUnprotected = PinSessionEntry(updatedAt: Date(timeIntervalSince1970: 10), original: asset())
        let index = PinSessionIndex(groups: PinSessionIndex().groups + [group], entries: [newUnprotected, oldProtected])
        XCTAssertEqual(try PinSessionPolicy(maxPins: 1).retaining(index).map(\.id), [oldProtected.id])
        XCTAssertThrowsError(try PinSessionPolicy(maxPins: 1).retaining(index, requiring: [newUnprotected.id])) {
            XCTAssertEqual($0 as? PinSessionError, .capacityExceeded)
        }
        XCTAssertThrowsError(try PinSessionPolicy(maxPixelCount: 100).retaining(index, requiring: [newUnprotected.id]))
        XCTAssertThrowsError(try PinSessionPolicy(maxDiskBytes: 10).retaining(index, requiring: [newUnprotected.id]))
        XCTAssertTrue(index.visibleEntries.contains(where: { $0.id == newUnprotected.id }))
    }

    func testLivePinsCannotBeEvictedAndOrdinaryOldPinsCan() throws {
        let entries = (1...3).map { value in
            PinSessionEntry(updatedAt: Date(timeIntervalSince1970: Double(value)), original: asset())
        }
        let index = PinSessionIndex(entries: entries)
        XCTAssertEqual(try PinSessionPolicy(maxPins: 2).retaining(index).map(\.id), [entries[2].id, entries[1].id])
        XCTAssertEqual(try PinSessionPolicy(maxPins: 2).retaining(index, requiring: [entries[2].id], protecting: [entries[0].id]).map(\.id), [entries[2].id, entries[0].id])
        XCTAssertThrowsError(try PinSessionPolicy(maxPins: 2).retaining(index, requiring: [entries[2].id], protecting: [entries[0].id, entries[1].id]))
    }

    func testDeleteGroupReassignsPinsAndNeverDeletesAssets() throws {
        var index = PinSessionIndex()
        let group = try index.createGroup(name: "项目", color: .green)
        let entry = PinSessionEntry(groupID: group.id, original: asset(), current: asset())
        index.entries = [entry]; index.activeGroupID = group.id
        try index.deleteGroup(id: group.id)
        XCTAssertEqual(index.groups.count, 1); XCTAssertEqual(index.activeGroupID, PinGroup.defaultID)
        XCTAssertEqual(index.entries.count, 1); XCTAssertEqual(index.entries[0].groupID, PinGroup.defaultID)
        XCTAssertEqual(index.entries[0].assets, entry.assets)
        XCTAssertThrowsError(try index.deleteGroup(id: PinGroup.defaultID)) { XCTAssertEqual($0 as? PinSessionError, .cannotDeleteDefault) }
    }

    func testCreateRenameMoveAndVisibilityAreIndependentFromPixels() throws {
        var index = PinSessionIndex()
        let group = try index.createGroup(name: "  工作  ", color: .orange)
        XCTAssertEqual(group.name, "工作")
        let entry = PinSessionEntry(original: asset()); index.entries = [entry]
        try index.movePin(id: entry.id, to: group.id)
        XCTAssertTrue(index.visibleEntries.isEmpty)
        index.activeGroupID = group.id; XCTAssertEqual(index.visibleEntries.count, 1)
        index.groups[1].isHidden = true; XCTAssertTrue(index.visibleEntries.isEmpty)
        index.groups[1].isHidden = false; index.allHidden = true; XCTAssertTrue(index.visibleEntries.isEmpty)
        index.allHidden = false; try index.renameGroup(id: group.id, name: "设计", color: .purple)
        XCTAssertEqual(index.groups[1].name, "设计"); XCTAssertEqual(index.groups[1].color, .purple)
        XCTAssertEqual(index.entries[0].assets, entry.assets)
        XCTAssertThrowsError(try index.movePin(id: entry.id, to: UUID()))
        XCTAssertThrowsError(try index.movePin(id: UUID(), to: group.id))
        XCTAssertThrowsError(try index.renameGroup(id: group.id, name: "\n"))
    }

    func testGroupAndPinMetadataCountsAreBounded() throws {
        var index = PinSessionIndex()
        for value in 1..<32 { _ = try index.createGroup(name: "Group \(value)") }
        XCTAssertThrowsError(try index.createGroup(name: "Overflow")) { XCTAssertEqual($0 as? PinSessionError, .tooManyGroups) }
        XCTAssertThrowsError(try index.renameGroup(id: PinGroup.defaultID, name: String(repeating: "x", count: 49)))
        XCTAssertEqual(PinSessionPolicy(maxPins: Int.max).maxPins, 20)
        XCTAssertEqual(PinSessionPolicy(maxPixelCount: Int64.max).maxPixelCount, 100_000_000)
        XCTAssertEqual(PinSessionPolicy(maxDiskBytes: Int64.max).maxDiskBytes, 536_870_912)
    }

    func testOffscreenRecoveryFitsRemovedMonitorAndSmallScreen() {
        let visible = PinWindowFrame(x: 0, y: 25, width: 1440, height: 850)
        let removed = PinWindowFrame(x: 4000, y: -500, width: 800, height: 600)
        let recovered = removed.recovered(in: [visible])
        XCTAssertEqual(recovered, PinWindowFrame(x: 640, y: 25, width: 800, height: 600))
        let tiny = PinWindowFrame(x: -200, y: -200, width: 300, height: 200)
        XCTAssertEqual(removed.recovered(in: [tiny]), tiny)
        XCTAssertEqual(PinWindowFrame(x: 0, y: 25, width: 680, height: 480).recovered(in: [visible]), PinWindowFrame(x: 0, y: 25, width: 680, height: 480))
    }

    func testOffscreenRecoveryChoosesOverlappingNegativeOriginDisplay() {
        let left = PinWindowFrame(x: -1920, y: 0, width: 1920, height: 1080)
        let right = PinWindowFrame(x: 0, y: 0, width: 1440, height: 900)
        let frame = PinWindowFrame(x: -1800, y: 100, width: 500, height: 500)
        XCTAssertEqual(frame.recovered(in: [right, left]), frame)
        let oversized = PinWindowFrame(x: -1800, y: -100, width: 1700, height: 1400).recovered(in: [right, left])
        XCTAssertEqual(oversized, PinWindowFrame(x: -1800, y: 0, width: 1700, height: 1080))
    }

    func testInvalidPresentationValuesNormalizeWithoutAffectingClickThroughOrLock() {
        let invalid = PinPresentation(frame: PinWindowFrame(x: .infinity, y: 0, width: -1, height: 0), opacity: .nan,
                                      zoom: -.infinity, clickThrough: true, locked: true).normalized()
        XCTAssertEqual(invalid.frame, PinWindowFrame()); XCTAssertEqual(invalid.opacity, 1); XCTAssertNil(invalid.zoom)
        XCTAssertTrue(invalid.clickThrough); XCTAssertTrue(invalid.locked)
        XCTAssertEqual(PinPresentation(opacity: 0, zoom: 100).normalized().opacity, 0.15)
        XCTAssertEqual(PinPresentation(opacity: 2, zoom: 100).normalized().zoom, 4)
    }

    func testLegacySchemaOneEntryWithoutVisibilityDefaultsToOpen() throws {
        let entry = PinSessionEntry(original: asset())
        let index = PinSessionIndex(entries: [entry])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(index)) as? [String: Any])
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        entries[0].removeValue(forKey: "isVisible")
        object["entries"] = entries
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(PinSessionIndex.self, from: legacy).validated()
        XCTAssertEqual(decoded, index)
        XCTAssertTrue(try XCTUnwrap(decoded.entry(id: entry.id)).isVisible)
        XCTAssertEqual(decoded.visibleEntries.map(\.id), [entry.id])
    }

    func testArchivedVisibilityRoundTripsAndIsIndependentOfGroupVisibility() throws {
        let open = PinSessionEntry(original: asset())
        let archived = PinSessionEntry(original: asset(), current: asset(), isVisible: false)
        var index = PinSessionIndex(entries: [open, archived])
        let decoded = try JSONDecoder().decode(PinSessionIndex.self, from: JSONEncoder().encode(index)).validated()
        XCTAssertEqual(decoded, index)
        XCTAssertEqual(decoded.visibleEntries.map(\.id), [open.id])
        index.allHidden = true; XCTAssertTrue(index.visibleEntries.isEmpty)
        index.allHidden = false; index.groups[0].isHidden = true
        XCTAssertTrue(index.visibleEntries.isEmpty)
        index.groups[0].isHidden = false
        XCTAssertEqual(index.visibleEntries.map(\.id), [open.id])
        let group = try index.createGroup(name: "Archived group")
        try index.movePin(id: archived.id, to: group.id)
        index.activeGroupID = group.id
        XCTAssertTrue(index.visibleEntries.isEmpty)
        try index.deleteGroup(id: group.id)
        XCTAssertEqual(index.entry(id: archived.id)?.isVisible, false)
        XCTAssertEqual(index.entry(id: archived.id)?.assets, archived.assets)
    }

    func testArchivedOriginalAndEditedAssetsStillCountTowardQuota() throws {
        let archived = PinSessionEntry(original: asset(width: 10, height: 10, bytes: 40),
                                       current: asset(width: 5, height: 10, bytes: 30), isVisible: false)
        XCTAssertFalse(PinSessionPolicy(maxPixelCount: 149).fits([archived]))
        XCTAssertFalse(PinSessionPolicy(maxDiskBytes: 69).fits([archived]))
        XCTAssertTrue(PinSessionPolicy(maxPixelCount: 150, maxDiskBytes: 70).fits([archived]))
    }

    private func asset(width: Int = 10, height: Int = 10, bytes: Int64 = 10) -> PinRasterAsset {
        PinRasterAsset(filename: UUID().uuidString + ".png", width: width, height: height, byteCount: bytes)
    }
}
