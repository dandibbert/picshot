import XCTest
@testable import PicShotCore

final class AnnotationToolbarOrderTests: XCTestCase {
    func testDefaultsAreTheAcceptedFourteenPrimaryFamilies() {
        XCTAssertEqual(AnnotationToolbarOrder.defaults.rawIDs,
            ["rectangle", "ellipse", "freehand", "arrow", "text", "number", "pixelate", "redact",
             "eraser", "spotlight", "line", "highlighter", "select", "crop"])
        XCTAssertEqual(Set(AnnotationToolbarOrder.defaults.families), Set(AnnotationToolbarOrder.Family.allCases))
    }

    func testStrictValidationRejectsUnknownDuplicateAndMissingIDs() throws {
        let defaults = AnnotationToolbarOrder.defaults.rawIDs
        var unknown = defaults; unknown[0] = "future-tool"
        XCTAssertThrowsError(try AnnotationToolbarOrder(rawIDs: unknown)) {
            XCTAssertEqual($0 as? AnnotationToolbarOrder.ValidationError, .unknownID("future-tool"))
        }
        var duplicate = defaults; duplicate[0] = "crop"
        XCTAssertThrowsError(try AnnotationToolbarOrder(rawIDs: duplicate)) {
            XCTAssertEqual($0 as? AnnotationToolbarOrder.ValidationError, .duplicateID("crop"))
        }
        XCTAssertThrowsError(try AnnotationToolbarOrder(rawIDs: Array(defaults.dropLast()))) {
            XCTAssertEqual($0 as? AnnotationToolbarOrder.ValidationError, .missingIDs(["crop"]))
        }
        XCTAssertThrowsError(try AnnotationToolbarOrder(rawIDs: []))
        XCTAssertThrowsError(try AnnotationToolbarOrder(families: [.rectangle, .rectangle]))
        XCTAssertThrowsError(try AnnotationToolbarOrder(rawIDs: defaults + ["rectangle"]))
        XCTAssertThrowsError(try AnnotationToolbarOrder(rawIDs: defaults.map { $0.uppercased() }))
    }

    func testStableArrayCodingValidatesOnDecode() throws {
        let order = try AnnotationToolbarOrder(rawIDs: Array(AnnotationToolbarOrder.defaults.rawIDs.reversed()))
        let data = try JSONEncoder().encode(order)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: data), order.rawIDs)
        XCTAssertEqual(try JSONDecoder().decode(AnnotationToolbarOrder.self, from: data), order)
        for malformed in ["[]", "[\"rectangle\",\"rectangle\"]", "[\"unknown\"]", "[1]", "null", "{\"families\":[]}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(AnnotationToolbarOrder.self, from: Data(malformed.utf8)))
        }
    }

    func testPreferencesRoundTripAndCorruptionFallbackDoNotRewriteStorage() throws {
        let name = "PicShot-AnnotationToolbarOrderTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AnnotationToolbarOrder.read(from: defaults), .defaults)
        XCTAssertNil(defaults.object(forKey: AnnotationToolbarOrder.preferenceKey))
        let order = try AnnotationToolbarOrder(rawIDs: Array(AnnotationToolbarOrder.defaults.rawIDs.reversed()))
        order.write(to: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: AnnotationToolbarOrder.preferenceKey), order.rawIDs)
        XCTAssertEqual(AnnotationToolbarOrder.read(from: defaults), order)
        let malformedValues: [Any] = [["rectangle"], ["crop", "crop"], "rectangle", 9, ["rectangle", 1] as [Any]]
        for malformed in malformedValues {
            defaults.set(malformed, forKey: AnnotationToolbarOrder.preferenceKey)
            let before = defaults.dictionaryRepresentation() as NSDictionary
            XCTAssertEqual(AnnotationToolbarOrder.read(from: defaults), .defaults)
            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before, "A read must never repair or mutate personal preferences")
        }
        AnnotationToolbarOrder.defaults.write(to: defaults)
        XCTAssertEqual(AnnotationToolbarOrder.read(from: defaults), .defaults)
    }

    func testMovesPreserveEveryFamilyAndBoundsAreNoOps() {
        var draft = AnnotationToolbarOrder.defaults
        XCTAssertFalse(draft.move(.rectangle, by: -1)); XCTAssertFalse(draft.move(.crop, by: 1))
        XCTAssertFalse(draft.move(.rectangle, by: 0)); XCTAssertFalse(draft.move(.crop, by: Int.max))
        XCTAssertFalse(draft.move(.crop, by: Int.min)); XCTAssertEqual(draft, .defaults)
        XCTAssertTrue(draft.move(.crop, by: -13)); XCTAssertEqual(draft.families.first, .crop)
        XCTAssertEqual(Set(draft.families), Set(AnnotationToolbarOrder.Family.allCases))
        XCTAssertEqual(draft.families.count, 14)
        XCTAssertTrue(draft.move(.crop, by: 13)); XCTAssertEqual(draft, .defaults)
    }

    func testOverflowKeepsDefaultPrioritiesAndCustomFamiliesFromTheLeft() throws {
        XCTAssertEqual(Array(AnnotationToolbarOrder.defaults.overflowPriority.prefix(7)),
            [.ellipse, .line, .highlighter, .select, .crop, .spotlight, .eraser])
        XCTAssertEqual(Set(AnnotationToolbarOrder.defaults.overflowPriority), Set(AnnotationToolbarOrder.Family.allCases))
        var custom = AnnotationToolbarOrder.defaults; XCTAssertTrue(custom.move(.pixelate, by: -6))
        XCTAssertEqual(custom.overflowPriority, Array(custom.families.reversed()))
        XCTAssertEqual(custom.overflowPriority.last, .pixelate)
    }
}
