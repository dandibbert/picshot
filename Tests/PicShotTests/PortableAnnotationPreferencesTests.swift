import XCTest
import Foundation
import PicShotCore
@testable import PicShot

@MainActor final class PortableAnnotationPreferencesTests: XCTestCase {
    private enum Failure: Error { case write }

    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) rethrows {
        let name = "PicShot-PortableAnnotation-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, name)
    }
    private func styles(blue: Bool) throws -> AnnotationStyleSettings {
        try AnnotationStyleSettings(styles: [.init(tool: .arrow, values: [
            .color: .color(red: blue ? 0 : 1, green: 0, blue: blue ? 1 : 0, alpha: 1),
            .lineWidth: .number(6), .endArrowEnabled: .flag(true)])])
    }
    private func shortcuts(key: UInt16) throws -> LocalAnnotationShortcutSettings {
        try .init(bindings: [.init(tool: .arrow, binding: .init(keyCode: key))])
    }
    private func object(_ store: PortableSettingsStore) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: store.exportData()) as? [String: Any])
    }
    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private func changed(_ store: PortableSettingsStore) throws -> Data {
        var value = try object(store)
        var preferences = try XCTUnwrap(value["preferences"] as? [String: Any])
        preferences["appearance"] = "dark"; value["preferences"] = preferences
        value["annotationStyles"] = try JSONSerialization.jsonObject(with: styles(blue: true).encoded())
        value["annotationShortcuts"] = try JSONSerialization.jsonObject(with: shortcuts(key: 17).encodedData())
        return try data(value)
    }

    func testRoundTripUsesAppearanceAllowlistAndReadableSameToolDifference() throws {
        try withDefaults { defaults, name in
            try styles(blue: false).write(to: defaults)
            try shortcuts(key: 1).write(to: defaults)
            defaults.set("PRIVATE_ANNOTATION_TEXT", forKey: "annotationDocument")
            defaults.set("PRIVATE_WATERMARK_LITERAL", forKey: "watermarkText")
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let exported = try store.exportData()
            XCTAssertEqual(exported, try store.exportData())
            XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("PRIVATE_"))
            let plan = try store.prepareImport(changed(store))
            let style = try XCTUnwrap(plan.changes.first { $0.id == "annotationStyle.arrow" })
            XCTAssertNotEqual(style.oldValue, style.newValue)
            XCTAssertTrue(style.oldValue.contains("#FF0000FF"))
            XCTAssertTrue(style.newValue.contains("#0000FFFF"))
            XCTAssertFalse(plan.changesHotKeys, "Local tool bindings are not global hotkeys")
            try store.apply(plan) { _ in XCTFail("Local bindings must not probe global registrations") }
            XCTAssertEqual(AnnotationStyleSettings.read(from: defaults), try styles(blue: true))
            XCTAssertEqual(LocalAnnotationShortcutSettings.read(from: defaults), try shortcuts(key: 17))
            XCTAssertEqual(defaults.string(forKey: "annotationDocument"), "PRIVATE_ANNOTATION_TEXT")
            XCTAssertFalse(try store.prepareImport(store.exportData()).hasChanges)
        }
    }

    func testOlderFileMissingBothSectionsPreservesLocalStylesAndBindings() throws {
        try withDefaults { defaults, name in
            try styles(blue: false).write(to: defaults); try shortcuts(key: 1).write(to: defaults)
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let before = defaults.persistentDomain(forName: name)! as NSDictionary
            var older = try object(store)
            older.removeValue(forKey: "annotationStyles"); older.removeValue(forKey: "annotationShortcuts")
            let plan = try store.prepareImport(data(older))
            XCTAssertFalse(plan.hasChanges)
            try store.apply(plan)
            XCTAssertEqual(defaults.persistentDomain(forName: name)! as NSDictionary, before)
        }
    }

    func testExplicitEmptySectionsResetAndCanceledReviewPreservesValues() throws {
        try withDefaults { defaults, name in
            try styles(blue: false).write(to: defaults); try shortcuts(key: 1).write(to: defaults)
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let before = defaults.persistentDomain(forName: name)! as NSDictionary
            var incoming = try object(store)
            incoming["annotationStyles"] = ["version": 1, "styles": []] as [String: Any]
            incoming["annotationShortcuts"] = ["schemaVersion": 1, "bindings": []] as [String: Any]
            let canceled = try store.prepareImport(data(incoming))
            XCTAssertEqual(canceled.changes.count, 2)
            XCTAssertEqual(defaults.persistentDomain(forName: name)! as NSDictionary, before)
            let applied = try store.prepareImport(data(incoming))
            try store.apply(applied)
            XCTAssertEqual(AnnotationStyleSettings.read(from: defaults), .defaults)
            XCTAssertEqual(LocalAnnotationShortcutSettings.read(from: defaults), .defaults)
            XCTAssertThrowsError(try store.apply(canceled))
        }
    }

    func testMalformedNestedSectionsRejectWholeImportBeforeAnyWrite() throws {
        try withDefaults { defaults, name in
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let base = try object(store)
            let invalidStyles: [Any] = [NSNull(), [], ["version": true, "styles": []],
                ["version": 2, "styles": []], ["version": 1, "styles": [], "text": "PRIVATE"],
                ["version": 1, "styles": [["tool": "text", "values": ["text": "PRIVATE"]]]],
                ["version": 1, "styles": [["tool": "watermark", "values": ["watermarkTemplate": "PRIVATE"]]]],
                ["version": 1, "styles": [["tool": "arrow", "values": ["opacity": 2]]]]]
            let invalidShortcuts: [Any] = [NSNull(), [], ["schemaVersion": true, "bindings": []],
                ["schemaVersion": 1, "bindings": [], "text": "PRIVATE"],
                ["schemaVersion": 1, "bindings": [["tool": "arrow", "binding": ["keyCode": 0, "modifiers": 0]]]],
                ["schemaVersion": 1, "bindings": [["tool": "arrow", "binding": ["keyCode": 15, "modifiers": 2]]]]]
            for (key, invalid) in [("annotationStyles", invalidStyles), ("annotationShortcuts", invalidShortcuts)] {
                for item in invalid {
                    var value = base; value[key] = item
                    XCTAssertThrowsError(try store.prepareImport(data(value)), "Accepted invalid \(key)")
                    XCTAssertTrue(defaults.persistentDomain(forName: name)?.isEmpty ?? true)
                }
            }
        }
    }

    func testDuplicateNestedKeysAreRejectedBeforeCodableCanDiscardThem() throws {
        try withDefaults { defaults, name in
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            let input = String(decoding: try changed(store), as: UTF8.self)
            for (from, to) in [("\"version\":1", "\"version\":1,\"version\":1"),
                               ("\"keyCode\":17", "\"keyCode\":17,\"keyCode\":15"),
                               ("\"lineWidth\":6", "\"lineWidth\":6,\"lineWidth\":8")] {
                XCTAssertTrue(input.contains(from))
                XCTAssertThrowsError(try store.prepareImport(Data(input.replacingOccurrences(of: from, with: to).utf8)))
            }
            XCTAssertTrue(defaults.persistentDomain(forName: name)?.isEmpty ?? true)
        }
    }

    func testEveryNewWritePrefixAndFinalWriteRollBackIncludingAbsentValues() throws {
        for persisted in [false, true] {
            for failureAfterWrite in [false, true] {
                for failureIndex in 0..<3 {
                    try withDefaults { defaults, name in
                        if persisted { try styles(blue: false).write(to: defaults); try shortcuts(key: 1).write(to: defaults) }
                        let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
                        let before = (defaults.persistentDomain(forName: name) ?? [:]) as NSDictionary
                        let plan = try store.prepareImport(changed(store))
                        let fail: (Int) throws -> Void = { if $0 == failureIndex { throw Failure.write } }
                        if failureAfterWrite { store.afterWrite = fail } else { store.beforeWrite = fail }
                        XCTAssertThrowsError(try store.apply(plan))
                        XCTAssertEqual((defaults.persistentDomain(forName: name) ?? [:]) as NSDictionary, before)
                        store.beforeWrite = nil; store.afterWrite = nil
                        try store.apply(plan)
                        XCTAssertEqual(AnnotationStyleSettings.read(from: defaults), try styles(blue: true))
                        XCTAssertEqual(LocalAnnotationShortcutSettings.read(from: defaults), try shortcuts(key: 17))
                    }
                }
            }
        }
    }

    func testNewPreferenceChangesInvalidateReviewIncludingUnrelatedImport() throws {
        for changeStyle in [false, true] {
            try withDefaults { defaults, name in
                let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
                let plan = try store.prepareImport(changed(store))
                if changeStyle { try styles(blue: false).write(to: defaults) }
                else { try shortcuts(key: 1).write(to: defaults) }
                let before = defaults.persistentDomain(forName: name)! as NSDictionary
                XCTAssertThrowsError(try store.apply(plan)) { XCTAssertEqual($0 as? PortableSettingsError, .conflict) }
                XCTAssertEqual(defaults.persistentDomain(forName: name)! as NSDictionary, before)
            }
        }
    }

    func testCorruptLocalPayloadCannotLeakUnknownContentIntoExport() throws {
        try withDefaults { defaults, name in
            defaults.set(Data("{\"version\":1,\"styles\":[],\"text\":\"PRIVATE_LITERAL\"}".utf8),
                         forKey: AnnotationStyleSettings.preferenceKey)
            defaults.set(Data("{\"schemaVersion\":1,\"bindings\":[],\"text\":\"PRIVATE_COMMENT\"}".utf8),
                         forKey: LocalAnnotationShortcutSettings.preferenceKey)
            let before = defaults.persistentDomain(forName: name)! as NSDictionary
            let store = PortableSettingsStore(defaults: defaults, persistentDomainName: name)
            XCTAssertFalse(String(decoding: try store.exportData(), as: UTF8.self).contains("PRIVATE_"))
            XCTAssertEqual(defaults.persistentDomain(forName: name)! as NSDictionary, before)
        }
    }
}
