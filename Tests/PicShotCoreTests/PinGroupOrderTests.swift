import Foundation
import XCTest
@testable import PicShotCore

final class PinGroupOrderTests: XCTestCase {
    func testAdjacentMovesRoundTripWithoutChangingIdentityOrOtherMetadata() throws {
        var index = try fixture()
        let before = index
        let active = index.activeGroupID
        try index.moveGroup(id: active, offset: -1)
        XCTAssertEqual(index.groups.map(\.id), [before.groups[0].id, active, before.groups[1].id])
        XCTAssertEqual(index.groups.first(where: { $0.id == active }), before.groups.last)
        XCTAssertEqual(index.entries, before.entries)
        XCTAssertEqual(index.activeGroupID, before.activeGroupID)
        XCTAssertEqual(index.allHidden, before.allHidden)
        XCTAssertEqual(index.version, before.version)
        let restored = try JSONDecoder().decode(PinSessionIndex.self, from: JSONEncoder().encode(index)).validated()
        XCTAssertEqual(restored, index)
        try index.moveGroup(id: active, offset: 1)
        XCTAssertEqual(index, before)
    }

    func testDefaultAndProtectedGroupsCanMoveAndDefaultStillReceivesDeletedPins() throws {
        var index = try fixture()
        let defaultGroup = index.groups[0]
        let protected = index.groups[2]
        try index.moveGroup(id: PinGroup.defaultID, offset: 1)
        XCTAssertEqual(index.groups[1], defaultGroup)
        try index.moveGroup(id: protected.id, offset: -1)
        XCTAssertEqual(index.groups[1], protected)
        XCTAssertTrue(index.groups[1].isProtected)
        XCTAssertTrue(index.groups[1].isHidden)
        XCTAssertThrowsError(try index.deleteGroup(id: PinGroup.defaultID)) {
            XCTAssertEqual($0 as? PinSessionError, .cannotDeleteDefault)
        }
        try index.deleteGroup(id: protected.id)
        XCTAssertEqual(index.activeGroupID, PinGroup.defaultID)
        XCTAssertTrue(index.entries.allSatisfy { $0.groupID == PinGroup.defaultID })
        XCTAssertEqual(index.groups.last?.id, PinGroup.defaultID)
        _ = try index.validated()
    }

    func testBoundariesAndZeroAreExactNoOpsAndMissingOrNonUnitMovesThrow() throws {
        var index = try fixture()
        let before = index
        try index.moveGroup(id: index.groups[0].id, offset: -1)
        try index.moveGroup(id: index.groups[2].id, offset: 1)
        try index.moveGroup(id: index.groups[1].id, offset: 0)
        XCTAssertEqual(index, before)
        for offset in [Int.min, -2, 2, Int.max] {
            XCTAssertThrowsError(try index.moveGroup(id: before.groups[1].id, offset: offset)) {
                XCTAssertEqual($0 as? PinSessionError, .invalidGroupOffset)
            }
            XCTAssertEqual(index, before)
        }
        XCTAssertThrowsError(try index.moveGroup(id: UUID(), offset: -1)) {
            XCTAssertEqual($0 as? PinSessionError, .missingGroup)
        }
        XCTAssertThrowsError(try index.moveGroup(id: UUID(), offset: 0))
        XCTAssertEqual(index, before)
        var single = PinSessionIndex()
        let initial = single
        try single.moveGroup(id: PinGroup.defaultID, offset: -1)
        try single.moveGroup(id: PinGroup.defaultID, offset: 1)
        XCTAssertEqual(single, initial)
    }

    func testMaximumGroupCountReordersWithoutAddingOrRegeneratingGroups() throws {
        var index = PinSessionIndex()
        for number in 1..<32 { _ = try index.createGroup(name: "Group \(number)") }
        let before = index
        let last = index.groups[31].id
        try index.moveGroup(id: last, offset: -1)
        XCTAssertEqual(index.groups.count, 32)
        XCTAssertEqual(index.groups[30].id, last)
        XCTAssertEqual(Set(index.groups.map(\.id)), Set(before.groups.map(\.id)))
        XCTAssertEqual(Array(index.groups.prefix(30)), Array(before.groups.prefix(30)))
        XCTAssertThrowsError(try index.createGroup(name: "Overflow")) {
            XCTAssertEqual($0 as? PinSessionError, .tooManyGroups)
        }
    }

    func testCorruptIndexIsRejectedBeforeAnyMutationIncludingBoundaryAndZeroMoves() throws {
        let valid = try fixture()
        var duplicate = valid; duplicate.groups.append(duplicate.groups[0])
        var noDefault = valid; noDefault.groups.removeFirst()
        var noActive = valid; noActive.activeGroupID = UUID()
        var tooMany = valid
        while tooMany.groups.count <= 32 { tooMany.groups.append(PinGroup(name: "Extra")) }
        var missingMembership = valid; missingMembership.entries[0].groupID = UUID()
        var badName = valid; badName.groups[0].name = "\n"
        var unsupported = valid; unsupported.version = PinSessionIndex.schemaVersion + 1
        var duplicatePin = valid; duplicatePin.entries.append(duplicatePin.entries[0])
        for broken in [duplicate, noDefault, noActive, tooMany, missingMembership, badName, unsupported, duplicatePin] {
            for offset in [-1, 0, 1] {
                var candidate = broken
                XCTAssertThrowsError(try candidate.moveGroup(id: candidate.groups[0].id, offset: offset))
                XCTAssertEqual(candidate, broken)
            }
        }
    }

    private func fixture() throws -> PinSessionIndex {
        var index = PinSessionIndex()
        _ = try index.createGroup(name: "First", color: .green)
        let last = try index.createGroup(name: "Saved", color: .purple)
        index.groups[2].isProtected = true; index.groups[2].isHidden = true
        index.activeGroupID = last.id; index.allHidden = true
        index.entries = [PinSessionEntry(groupID: last.id, title: "Retained",
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
            original: PinRasterAsset(filename: UUID().uuidString + ".png", width: 10, height: 10, byteCount: 20),
            presentation: PinPresentation(opacity: 0.5, zoom: 2, clickThrough: true, locked: true),
            isVisible: false, archiveSequence: 1)]
        return try index.validated()
    }
}
