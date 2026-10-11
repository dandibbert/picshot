import Foundation
import XCTest
@testable import PicShotCore

final class PinGroupNameTests: XCTestCase {
    func testCreateRejectsEquivalentNamesBeforeAnyMutation() throws {
        let equivalents: [(String, String)] = [
            ("工作", "工作"), ("工作", " \n\t工作\r\n "),
            ("Work", "wOrK"), ("Work", "\u{00a0}WORK\u{3000}"),
            ("Café", "CAFE\u{0301}"), ("Straße", "STRASSE"),
            ("Σ", "ς"), ("FILE", "file")
        ]
        for (existing, proposed) in equivalents {
            var index = PinSessionIndex()
            _ = try index.createGroup(name: existing, color: .purple)
            let before = index
            XCTAssertThrowsError(try index.createGroup(name: proposed, color: .red), proposed) {
                XCTAssertEqual($0 as? PinSessionError, .duplicateGroupName)
            }
            XCTAssertEqual(index, before)
        }
    }

    func testDefaultHiddenAndProtectedGroupsReserveTheirNames() throws {
        var index = PinSessionIndex()
        let hidden = try index.createGroup(name: "Hidden")
        let protected = try index.createGroup(name: "Protected")
        index.groups[1].isHidden = true; index.groups[2].isProtected = true
        index.activeGroupID = hidden.id; index.allHidden = true
        let before = index
        for name in [" 默认 ", " HIDDEN ", "protected"] {
            XCTAssertThrowsError(try index.createGroup(name: name)) {
                XCTAssertEqual($0 as? PinSessionError, .duplicateGroupName)
            }
            XCTAssertEqual(index, before)
        }
        XCTAssertThrowsError(try index.renameGroup(id: protected.id, name: "默认", color: .orange)) {
            XCTAssertEqual($0 as? PinSessionError, .duplicateGroupName)
        }
        XCTAssertThrowsError(try index.renameGroup(id: PinGroup.defaultID, name: "hidden", color: .red)) {
            XCTAssertEqual($0 as? PinSessionError, .duplicateGroupName)
        }
        XCTAssertEqual(index, before)
    }

    func testComparisonPreservesAccentsInteriorWhitespaceAndDisplaySpelling() throws {
        var index = PinSessionIndex()
        let names = ["Cafe", "Café", "Work Space", "Work  Space", "工作", "工 作"]
        for name in names { XCTAssertEqual(try index.createGroup(name: name).name, name) }
        let decomposed = "Re\u{0301}sume\u{0301}"
        let group = try index.createGroup(name: " \n" + decomposed + "\t ")
        XCTAssertEqual(Array(group.name.utf8), Array(decomposed.utf8))
        try index.renameGroup(id: group.id, name: " \nRÉSUMÉ\t ", color: .green)
        XCTAssertEqual(Array(try XCTUnwrap(index.groups.last).name.utf8), Array("RÉSUMÉ".utf8))
        XCTAssertEqual(index.groups.last?.id, group.id)
        XCTAssertEqual(index.groups.last?.color, .green)
        XCTAssertEqual(Array(index.groups.dropFirst().prefix(names.count).map(\.name)), names)
    }

    func testRenameRejectsEquivalentOtherGroupNameWithoutChangingColorOrMetadata() throws {
        var index = legacyFixture()
        let id = index.groups[3].id
        let before = index
        for name in ["Café", "CAFE\u{0301}", " \n café\t "] {
            XCTAssertThrowsError(try index.renameGroup(id: id, name: name, color: .red)) {
                XCTAssertEqual($0 as? PinSessionError, .duplicateGroupName)
            }
            XCTAssertEqual(index, before)
        }
    }

    func testUnchangedNormalizedLegacyNameAllowsRetentionAndColorChanges() throws {
        var index = legacyFixture()
        let id = index.groups[1].id
        let before = index
        try index.renameGroup(id: id, name: "Café")
        XCTAssertEqual(index, before)
        try index.renameGroup(id: id, name: "Café", color: .red)
        var expected = before; expected.groups[1].color = .red
        XCTAssertEqual(index, expected)
        let spelling = "cAfE\u{0301}"
        try index.renameGroup(id: id, name: " \n" + spelling + "\t ", color: .green)
        expected.groups[1].name = spelling; expected.groups[1].color = .green
        XCTAssertEqual(index, expected)
        XCTAssertEqual(Array(index.groups[1].name.utf8), Array(spelling.utf8))
        XCTAssertEqual(Array(index.groups[2].name.utf8), Array(before.groups[2].name.utf8))
        XCTAssertEqual(try index.validated(), expected)
    }

    func testLegacyDuplicatesLoadAndRoundTripWithoutMigrationOrLostContent() throws {
        let legacy = legacyFixture()
        for version in 1...PinSessionIndex.schemaVersion {
            var saved = legacy; saved.version = version
            let bytes = try JSONEncoder().encode(saved)
            let decoded = try JSONDecoder().decode(PinSessionIndex.self, from: bytes).validated()
            XCTAssertEqual(decoded, saved)
            XCTAssertEqual(decoded.groups.map(\.id), saved.groups.map(\.id))
            XCTAssertEqual(decoded.groups.map { Array($0.name.utf8) }, saved.groups.map { Array($0.name.utf8) })
            XCTAssertEqual(decoded.entries, saved.entries)
        }
    }

    func testLegacyDuplicatesRemainUsableButCannotGainAnotherConflictingName() throws {
        var index = legacyFixture()
        let before = index
        XCTAssertThrowsError(try index.createGroup(name: "café")) {
            XCTAssertEqual($0 as? PinSessionError, .duplicateGroupName)
        }
        XCTAssertEqual(index, before)
        try index.moveGroup(id: index.groups[2].id, offset: -1)
        XCTAssertEqual(index.groups.map(\.id), [before.groups[0].id, before.groups[2].id, before.groups[1].id, before.groups[3].id])
        XCTAssertEqual(index.entries, before.entries)
        try index.renameGroup(id: before.groups[1].id, name: "Distinct", color: .green)
        XCTAssertEqual(index.groups.first { $0.id == before.groups[2].id }, before.groups[2])
        XCTAssertEqual(index.entries, before.entries)
        XCTAssertEqual(index.activeGroupID, before.activeGroupID)
        XCTAssertEqual(index.allHidden, before.allHidden)
        _ = try index.validated()
    }

    func testInvalidNamesMissingIdentityAndGroupLimitKeepExistingErrorsAndState() throws {
        var index = PinSessionIndex()
        for name in ["", " \n\t ", "Work\nSpace", String(repeating: "x", count: 49)] {
            let before = index
            XCTAssertThrowsError(try index.createGroup(name: name)) {
                XCTAssertEqual($0 as? PinSessionError, .invalidName)
            }
            XCTAssertThrowsError(try index.renameGroup(id: PinGroup.defaultID, name: name, color: .red)) {
                XCTAssertEqual($0 as? PinSessionError, .invalidName)
            }
            XCTAssertEqual(index, before)
        }
        XCTAssertThrowsError(try index.renameGroup(id: UUID(), name: "默认", color: .red)) {
            XCTAssertEqual($0 as? PinSessionError, .missingGroup)
        }
        for number in 1..<32 { _ = try index.createGroup(name: "Group \(number)") }
        let full = index
        XCTAssertThrowsError(try index.createGroup(name: "Overflow")) {
            XCTAssertEqual($0 as? PinSessionError, .tooManyGroups)
        }
        XCTAssertEqual(index, full)
        try index.renameGroup(id: index.groups[31].id, name: "GROUP 31", color: .red)
        XCTAssertEqual(index.groups.count, 32)
        XCTAssertEqual(index.groups.map(\.id), full.groups.map(\.id))
    }

    func testDuplicateErrorHasActionableLocalizedFeedback() {
        let message = PinSessionError.duplicateGroupName.localizedDescription
        XCTAssertTrue(message.contains("同名贴图组"))
        XCTAssertTrue(message.contains("不区分大小写"))
        XCTAssertTrue(message.contains("首尾空白"))
        XCTAssertTrue(message.contains("其他名称"))
    }

    private func legacyFixture() -> PinSessionIndex {
        let first = PinGroup(name: "Café", color: .purple, isHidden: true, isProtected: true)
        let duplicate = PinGroup(name: "  CAFE\u{0301}  ", color: .green)
        let other = PinGroup(name: "Other", color: .orange)
        let groups = [PinGroup(id: PinGroup.defaultID, name: "默认", color: .gray), first, duplicate, other]
        let entries = groups.enumerated().map { offset, group in
            PinSessionEntry(groupID: group.id, title: "Retained \(offset)",
                createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
                original: PinRasterAsset(filename: UUID().uuidString + ".png", width: 10, height: 10, byteCount: 20),
                presentation: PinPresentation(opacity: 0.5, zoom: 2, clickThrough: true, locked: true),
                isVisible: offset != 1, archiveSequence: offset == 1 ? 1 : nil)
        }
        return PinSessionIndex(groups: groups, entries: entries, activeGroupID: first.id, allHidden: true)
    }
}
