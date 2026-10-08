import Accelerate
import XCTest
@testable import PicShot

/// Admission tests only; these do not stand in for native component execution.
@MainActor final class EditableComponentFixtureTests: XCTestCase {
    private let prefix = "PICSHOT_EDITABLE_COMPONENT_"
    private func env(_ mode: String) -> [String: String] {
        ["PICSHOT_SMOKE_TEST": "1", prefix + "MODE": mode]
    }
    func testNormalSmokeHasNoComponentRequest() throws {
        XCTAssertNil(try EditableComponentFixture.request(["PICSHOT_SMOKE_TEST": "1"]))
    }
    func testPreparationIsExplicitAndNeedsNoInputs() throws {
        let request = try XCTUnwrap(EditableComponentFixture.request(env("prepare")))
        XCTAssertEqual(request.mode, .prepare)
        XCTAssertNil(request.input)
        XCTAssertNil(request.certificate)
        XCTAssertNil(request.writes)
    }
    func testUnknownCountsToleranceOrSelectionFailClosed() {
        for key in ["CYCLES", "WIDTH", "TOLERANCE", "DEADLINE"] {
            var environment = env("prepare"); environment[prefix + key] = "1"
            XCTAssertThrowsError(try EditableComponentFixture.request(environment))
        }
        XCTAssertThrowsError(try EditableComponentFixture.request(env("decode-preview")))
        XCTAssertThrowsError(try EditableComponentFixture.request([prefix + "INPUT": "/tmp/input"]))
        XCTAssertThrowsError(try EditableComponentFixture.request([prefix + "MODE": "prepare"]))
    }
    func testPreparationRejectsInputAndCrossDiagnosticSelection() {
        var environment = env("prepare"); environment[prefix + "INPUT"] = "/tmp/input"
        XCTAssertThrowsError(try EditableComponentFixture.request(environment))
        for key in ["PICSHOT_EDITABLE_ANNOTATIONS_ONLY", "PICSHOT_EDITABLE_HASH_DIAGNOSTIC", "PICSHOT_IMAGE_DRAW_MODE", "PICSHOT_CODEC_ATTRIBUTION_MODE"] {
            var combined = env("prepare"); combined[key] = "1"
            XCTAssertThrowsError(try EditableComponentFixture.request(combined))
        }
    }
    func testConsumersRequireAbsoluteInputsAndCertificate() throws {
        for mode in ["raw-draw", "png-write", "png-decode-draw", "png-decode-owned-draw", "png-decode-preserved-draw", "editable-render-pin"] {
            var environment = env(mode)
            XCTAssertThrowsError(try EditableComponentFixture.request(environment))
            environment[prefix + "INPUT"] = "/tmp/input"
            XCTAssertThrowsError(try EditableComponentFixture.request(environment))
            environment[prefix + "CERTIFICATE"] = "relative.json"
            XCTAssertThrowsError(try EditableComponentFixture.request(environment))
            environment[prefix + "CERTIFICATE"] = "/tmp/certificate.json"
            XCTAssertTrue(try XCTUnwrap(EditableComponentFixture.request(environment)).mode.consumer)
        }
    }
    func testOwnedDecodeCandidateIsAnExplicitSeparateCertifiedConsumer() throws {
        // The portable report checker binds the actual native flag value.
        XCTAssertEqual(Int(kvImageNoAllocate), 512)
        XCTAssertNotEqual(Int(kvImageNoAllocate), Int(kvImageDoNotTile))
        XCTAssertEqual(Set(EditableComponentFixture.Mode.allCases.map(\.rawValue)),
            ["prepare", "certify", "raw-draw", "png-write", "png-decode-draw", "png-decode-owned-draw", "png-decode-preserved-draw", "editable-render-pin", "verify-writes"])
        var environment = env("png-decode-owned-draw")
        environment[prefix + "INPUT"] = "/tmp/input"
        environment[prefix + "CERTIFICATE"] = "/tmp/certificate.json"
        let request = try XCTUnwrap(EditableComponentFixture.request(environment))
        XCTAssertEqual(request.mode, .pngDecodeOwnedDraw)
        XCTAssertTrue(request.mode.consumer)
        for (key, value) in [("WRITES", "/tmp/writes"), ("CYCLES", "1"), ("TOLERANCE", "1"),
                             ("WIDTH", "1024"), ("DEADLINE", "900"), ("NORMALIZATION", "context")] {
            var invalid = environment; invalid[prefix + key] = value
            XCTAssertThrowsError(try EditableComponentFixture.request(invalid))
        }
        var ordinary = environment; ordinary["PICSHOT_SMOKE_TEST"] = nil
        XCTAssertThrowsError(try EditableComponentFixture.request(ordinary))
    }
    func testPreservedDecodeCandidateIsAnExplicitSeparateCertifiedConsumer() throws {
        var environment = env("png-decode-preserved-draw")
        XCTAssertThrowsError(try EditableComponentFixture.request(environment))
        environment[prefix + "INPUT"] = "/tmp/input"
        environment[prefix + "CERTIFICATE"] = "/tmp/certificate.json"
        let request = try XCTUnwrap(EditableComponentFixture.request(environment))
        XCTAssertEqual(request.mode, .pngDecodePreservedDraw)
        XCTAssertTrue(request.mode.consumer)
        for (key, value) in [("FORMAT", "sRGB8"), ("FALLBACK", "allow"), ("RAW_READBACK", "1"),
                             ("WRITES", "/tmp/writes"), ("CYCLES", "1")] {
            var invalid = environment; invalid[prefix + key] = value
            XCTAssertThrowsError(try EditableComponentFixture.request(invalid))
        }
    }
    func testCertificateAndWriteVerificationCannotBeConfusedWithConsumers() throws {
        var certificate = env("certify"); certificate[prefix + "INPUT"] = "/tmp/input"
        XCTAssertEqual(try XCTUnwrap(EditableComponentFixture.request(certificate)).mode, .certify)
        certificate[prefix + "CERTIFICATE"] = "/tmp/old-certificate"
        XCTAssertThrowsError(try EditableComponentFixture.request(certificate))
        var verification = env("verify-writes")
        verification[prefix + "INPUT"] = "/tmp/input"; verification[prefix + "CERTIFICATE"] = "/tmp/cert"
        XCTAssertThrowsError(try EditableComponentFixture.request(verification))
        verification[prefix + "WRITES"] = "/tmp/writes"
        XCTAssertEqual(try XCTUnwrap(EditableComponentFixture.request(verification)).mode, .verifyWrites)
    }
}
