#if PICSHOT_CALLOUT_RETIREMENT_DIAGNOSTICS
import XCTest
import Foundation
import ObjectiveC
@testable import PicShot

final class NumberedCalloutRetirementDiagnosticsTests: XCTestCase {
    @MainActor
    func testStampDoesNotRetainSourceAndRecordsSynchronously() throws {
        var source: NSObject? = NSObject()
        weak var weakSource = source
        let stamp = NumberedCalloutRetirementStamp.attach(to: source!)
        XCTAssertNil(stamp.snapshot())
        let before = ProcessInfo.processInfo.systemUptime
        source = nil
        let after = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(weakSource)
        let event = try XCTUnwrap(stamp.snapshot())
        XCTAssertTrue(event.sourceWasWeakNil)
        XCTAssertTrue(event.callbackWasOnMainThread)
        XCTAssertGreaterThanOrEqual(event.tokenDeinitUptime, before)
        XCTAssertGreaterThanOrEqual(event.weakCheckFinishedUptime, event.tokenDeinitUptime)
        XCTAssertLessThanOrEqual(event.weakCheckFinishedUptime, after)
        let copy = try JSONDecoder().decode(NumberedCalloutRetirementEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(copy.weakCheckFinishedUptime, event.weakCheckFinishedUptime)
        XCTAssertEqual(copy.sourceWasWeakNil, event.sourceWasWeakNil)
    }

    @MainActor
    func testSharedSourceReusesStampWithoutReplacingToken() {
        let source = NSObject()
        let first = NumberedCalloutRetirementStamp.attach(to: source)
        let second = NumberedCalloutRetirementStamp.attach(to: source)
        XCTAssertTrue(first === second)
        XCTAssertNil(first.snapshot())
        withExtendedLifetime(source) {}
    }

    @MainActor
    func testRemovingAssociationWhileAliveIsNotRetirementEvidence() throws {
        let source = NSObject() // Dedicated test object, no unrelated associations.
        let stamp = NumberedCalloutRetirementStamp.attach(to: source)
        objc_removeAssociatedObjects(source)
        let event = try XCTUnwrap(stamp.snapshot())
        XCTAssertFalse(event.sourceWasWeakNil)
        withExtendedLifetime(source) {}
    }
    private func withDestinationDirectories(_ body: (URL, URL, URL) throws -> Void) throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("PicShot-retirement-path-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let evidence = root.appendingPathComponent("evidence", isDirectory: true)
        let outside = root.appendingPathComponent("evidence-sibling", isDirectory: true)
        try manager.createDirectory(at: evidence.appendingPathComponent("child"), withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        try body(root, evidence, outside)
    }

    func testDestinationRejectsRelativeEmptyAndNULPaths() throws {
        try withDestinationDirectories { _, evidence, _ in
            for path in ["sidecar.json", "", "~/sidecar.json", "file:///tmp/sidecar.json", "/tmp/sidecar\0.json"] {
                XCTAssertThrowsError(try NumberedCalloutDiagnosticDestination.write(Data(), absolutePath: path, excluding: [evidence]), path)
            }
        }
    }

    func testDestinationRejectsEvidenceAndStandardizedTraversal() throws {
        try withDestinationDirectories { root, evidence, outside in
            for path in [evidence.path, evidence.appendingPathComponent("sidecar.json").path,
                         evidence.appendingPathComponent("child/sidecar.json").path,
                         outside.path + "/../evidence/sidecar.json"] {
                XCTAssertThrowsError(try NumberedCalloutDiagnosticDestination.write(Data(), absolutePath: path, excluding: [evidence]), path)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: evidence.appendingPathComponent("sidecar.json").path))
            XCTAssertThrowsError(try NumberedCalloutDiagnosticDestination.write(Data(),
                absolutePath: outside.appendingPathComponent("sidecar.json").path, excluding: [root]))
        }
    }

    func testDestinationRejectsSymlinkAliasesIntoEvidence() throws {
        try withDestinationDirectories { root, evidence, outside in
            let link = outside.appendingPathComponent("evidence-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: evidence)
            XCTAssertThrowsError(try NumberedCalloutDiagnosticDestination.write(Data(),
                absolutePath: link.appendingPathComponent("sidecar.json").path, excluding: [evidence]))
            let childLink = outside.appendingPathComponent("child-link")
            try FileManager.default.createSymbolicLink(at: childLink, withDestinationURL: evidence.appendingPathComponent("child"))
            XCTAssertThrowsError(try NumberedCalloutDiagnosticDestination.write(Data(),
                absolutePath: childLink.path + "/../sidecar.json", excluding: [evidence]))
            let rootAlias = root.appendingPathComponent("evidence-alias")
            try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: evidence)
            XCTAssertThrowsError(try NumberedCalloutDiagnosticDestination.write(Data(),
                absolutePath: evidence.appendingPathComponent("sidecar.json").path, excluding: [rootAlias]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: evidence.appendingPathComponent("sidecar.json").path))
        }
    }

    func testDestinationRejectsLexicalEvidencePathEvenIfLinkPointsOutside() throws {
        try withDestinationDirectories { _, evidence, outside in
            let link = evidence.appendingPathComponent("outside-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            XCTAssertThrowsError(try NumberedCalloutDiagnosticDestination.write(Data(),
                absolutePath: link.appendingPathComponent("sidecar.json").path, excluding: [evidence]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("sidecar.json").path))
        }
    }

    func testDestinationPreservesExistingFileDirectoryAndHardLink() throws {
        try withDestinationDirectories { _, evidence, outside in
            let existing = outside.appendingPathComponent("unrelated.json")
            let original = Data("unrelated original".utf8)
            try original.write(to: existing)
            let hardLink = outside.appendingPathComponent("hard-link.json")
            try FileManager.default.linkItem(at: existing, to: hardLink)
            for path in [existing.path, hardLink.path, outside.path] {
                XCTAssertThrowsError(try NumberedCalloutDiagnosticDestination.write(Data("replacement".utf8),
                    absolutePath: path, excluding: [evidence]), path)
            }
            XCTAssertEqual(try Data(contentsOf: existing), original)
            XCTAssertEqual(try Data(contentsOf: hardLink), original)
        }
    }

    func testDestinationPreservesExistingAndDanglingLeafSymlinks() throws {
        try withDestinationDirectories { _, evidence, outside in
            let existing = outside.appendingPathComponent("unrelated.json")
            let original = Data("unrelated original".utf8)
            try original.write(to: existing)
            let missing = outside.appendingPathComponent("missing.json")
            for (name, target) in [("existing-link", existing), ("dangling-link", missing)] {
                let link = outside.appendingPathComponent(name)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
                XCTAssertThrowsError(try NumberedCalloutDiagnosticDestination.write(Data("replacement".utf8),
                    absolutePath: link.path, excluding: [evidence]))
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
            }
            XCTAssertEqual(try Data(contentsOf: existing), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        }
    }

    func testDestinationRequiresExistingParentAndProtectedRoot() throws {
        try withDestinationDirectories { _, evidence, outside in
            XCTAssertThrowsError(try NumberedCalloutDiagnosticDestination.write(Data(),
                absolutePath: outside.appendingPathComponent("missing/sidecar.json").path, excluding: [evidence]))
            XCTAssertThrowsError(try NumberedCalloutDiagnosticDestination.write(Data(),
                absolutePath: outside.appendingPathComponent("sidecar.json").path, excluding: []))
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("missing").path))
        }
    }

    func testDestinationCreatesFreshSiblingOnceWithPrivatePermissions() throws {
        try withDestinationDirectories { root, evidence, outside in
            let destination = outside.appendingPathComponent("sidecar.json")
            let original = Data("{\"diagnostic\":true}".utf8)
            try NumberedCalloutDiagnosticDestination.write(original, absolutePath: destination.path, excluding: [evidence])
            XCTAssertEqual(try Data(contentsOf: destination), original)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
            XCTAssertEqual(permissions & 0o077, 0)
            XCTAssertThrowsError(try NumberedCalloutDiagnosticDestination.write(Data("replacement".utf8),
                absolutePath: destination.path, excluding: [evidence]))
            XCTAssertEqual(try Data(contentsOf: destination), original)
            let safeAlias = root.appendingPathComponent("safe-outside-alias")
            try FileManager.default.createSymbolicLink(at: safeAlias, withDestinationURL: outside)
            try NumberedCalloutDiagnosticDestination.write(original,
                absolutePath: safeAlias.appendingPathComponent("second-sidecar.json").path, excluding: [evidence])
            XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("second-sidecar.json")), original)
        }
    }

}
#endif
