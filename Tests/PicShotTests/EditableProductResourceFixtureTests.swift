import AppKit
import CryptoKit
import XCTest
@testable import PicShot

/// Selector and bounded encoded-I/O tests. The installed-app run separately
/// establishes native UI, persistence, controller retirement and memory evidence.
@MainActor final class EditableProductResourceFixtureTests: XCTestCase {
    private let prefix = "PICSHOT_EDITABLE_PRODUCT_"
    private func environment(_ mode: String = "measure") -> [String: String] {
        ["PICSHOT_SMOKE_TEST": "1", prefix + "MODE": mode,
            prefix + "INPUT": "/tmp/product-input", prefix + "CERTIFICATE": "/tmp/product-certificate.json"]
    }
    func testOrdinarySmokeDoesNotSelectProductMeasurement() throws {
        XCTAssertNil(try EditableProductResourceFixture.request(["PICSHOT_SMOKE_TEST": "1"]))
    }
    func testOnlySeparateExplicitCertificationAndMeasurementAreAccepted() throws {
        XCTAssertEqual(try XCTUnwrap(EditableProductResourceFixture.request(environment())).mode, .measure)
        XCTAssertEqual(try XCTUnwrap(EditableProductResourceFixture.request(environment("certify"))).mode, .certify)
        for mode in ["prepare", "verify-writes", "measure-and-certify", "resource", ""] {
            XCTAssertThrowsError(try EditableProductResourceFixture.request(environment(mode)))
        }
        for key in ["PICSHOT_SMOKE_TEST", prefix + "MODE", prefix + "INPUT", prefix + "CERTIFICATE"] {
            var values = environment(); values[key] = nil
            XCTAssertThrowsError(try EditableProductResourceFixture.request(values))
        }
    }
    func testUnknownWorkloadOverridesAndCompetingRoutesFailClosed() {
        for suffix in ["CYCLES", "WIDTH", "DEADLINE", "TOLERANCE", "PURGE", "RAW_RGBA"] {
            var values = environment(); values[prefix + suffix] = "1"
            XCTAssertThrowsError(try EditableProductResourceFixture.request(values))
        }
        for key in ["PICSHOT_EDITABLE_ANNOTATIONS_ONLY", "PICSHOT_EDITABLE_HASH_DIAGNOSTIC",
                    "PICSHOT_EDITABLE_COMPONENT_MODE", "PICSHOT_DRAWING_RASTER_STRATEGY",
                    "PICSHOT_RENDERER_STORAGE_STRATEGY", "PICSHOT_EFFECT_CONTEXT_POLICY",
                    "PICSHOT_IMAGE_DECODE_MODE", "PICSHOT_CODEC_ATTRIBUTION_MODE", "PICSHOT_SUBSTAGE_MODE"] {
            var values = environment(); values[key] = "1"
            XCTAssertThrowsError(try EditableProductResourceFixture.request(values))
        }
    }
    func testOnlyFiniteExplicitDrawingOverrideIsAllowedForMeasurement() throws {
        for strategy in ["reference", "owned-srgb8"] {
            var values = environment(); values["PICSHOT_SMOKE_REPORT"] = "/tmp/report.json"
            values["PICSHOT_DRAWING_RASTER_STRATEGY"] = strategy
            XCTAssertEqual(try XCTUnwrap(EditableProductResourceFixture.request(values)).mode, .measure)
        }
        var candidateCertificate = environment("certify")
        candidateCertificate["PICSHOT_SMOKE_REPORT"] = "/tmp/report.json"
        candidateCertificate["PICSHOT_DRAWING_RASTER_STRATEGY"] = "owned-srgb8"
        XCTAssertThrowsError(try EditableProductResourceFixture.request(candidateCertificate))
        for invalid in ["native-pooled", "vimage", "unknown", ""] {
            var values = environment(); values["PICSHOT_SMOKE_REPORT"] = "/tmp/report.json"
            values["PICSHOT_DRAWING_RASTER_STRATEGY"] = invalid
            XCTAssertThrowsError(try EditableProductResourceFixture.request(values))
        }
        var unknown = environment(); unknown["PICSHOT_DRAWING_RASTER_FALLBACK"] = "1"
        XCTAssertThrowsError(try EditableProductResourceFixture.request(unknown))
    }
    func testPathsRequireAbsoluteNulFreeValues() {
        for suffix in ["INPUT", "CERTIFICATE"] {
            for invalid in ["relative", "", "/tmp/with\0nul"] {
                var values = environment(); values[prefix + suffix] = invalid
                XCTAssertThrowsError(try EditableProductResourceFixture.request(values))
            }
        }
    }
    func testEncodedStreamingCopiesCompleteMultipleChunksAndClosesDescriptors() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png"), output = root.appendingPathComponent("copy.png")
        let bytes = Data((0..<(65_536 * 2 + 173)).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let copied = try EditableProductResourceFixture.stream(source, to: output, maximum: bytes.count)
        XCTAssertEqual(copied.bytes, bytes.count)
        XCTAssertEqual(copied.sha256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        XCTAssertTrue(try EditableAnnotationFixtureObservation.ownedFileDescriptors(root, identities: []).isEmpty)
    }
    func testStreamingRejectsUnsafeOversizedAndPreexistingDestinations() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png"), existing = root.appendingPathComponent("existing.png")
        let bytes = Data([1, 2, 3, 4]); try bytes.write(to: source); try Data([9]).write(to: existing)
        XCTAssertThrowsError(try EditableProductResourceFixture.stream(source, maximum: 3))
        XCTAssertThrowsError(try EditableProductResourceFixture.stream(source, to: existing, maximum: 4))
        XCTAssertEqual(try Data(contentsOf: existing), Data([9]))
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try EditableProductResourceFixture.stream(link, maximum: 4))
        let directoryLink = root.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: root)
        XCTAssertThrowsError(try EditableProductResourceFixture.stream(source,
            to: directoryLink.appendingPathComponent("missing-output.png"), maximum: 4))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing-output.png").path))
        XCTAssertThrowsError(try EditableProductResourceFixture.stream(root, maximum: 4))
        let empty = root.appendingPathComponent("empty.png"); try Data().write(to: empty)
        XCTAssertThrowsError(try EditableProductResourceFixture.stream(empty, maximum: 4))
        XCTAssertTrue(try EditableAnnotationFixtureObservation.ownedFileDescriptors(root, identities: []).isEmpty)
    }
    func testDirectoryValidationDoesNotFollowSymlinkAncestors() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual"), link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
        XCTAssertThrowsError(try EditableProductResourceFixture.safeDirectory(link, create: false))
        XCTAssertThrowsError(try EditableProductResourceFixture.safeDirectory(link.appendingPathComponent("child"), create: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: actual.appendingPathComponent("child").path))
        XCTAssertThrowsError(try EditableProductResourceFixture.safeDirectory(link.appendingPathComponent("missing/child"), create: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: actual.appendingPathComponent("missing").path))
        let absent = root.appendingPathComponent("absent/child")
        XCTAssertThrowsError(try EditableProductResourceFixture.safeDirectory(absent, create: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("absent").path))
        let safe = root.appendingPathComponent("safe-parent/safe-child")
        XCTAssertNoThrow(try EditableProductResourceFixture.safeDirectory(safe, create: true))
        XCTAssertNoThrow(try EditableProductResourceFixture.safeDirectory(safe, create: false))
    }
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PicShotProductFixtureTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
