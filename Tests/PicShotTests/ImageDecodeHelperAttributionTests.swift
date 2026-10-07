import XCTest
import Foundation
import PicShotCodecCore
@testable import PicShot

@MainActor
final class ImageDecodeHelperAttributionTests: XCTestCase {
    func testChildAdmissionErrorSurvivesOnlyConfirmedNormalErrorExit() throws {
        var event = ImageDecodeDiagnosticEvent(kind: .error, phase: "failed", childPID: 123)
        event.error = .invalidJob
        XCTAssertEqual(try ImageDecodeDiagnosticProcess.terminalFailure(event, normalExit: true, status: 1), .invalidJob)
        XCTAssertThrowsError(try ImageDecodeDiagnosticProcess.terminalFailure(event, normalExit: false, status: 9))
        XCTAssertThrowsError(try ImageDecodeDiagnosticProcess.terminalFailure(event, normalExit: true, status: 0))
        event.error = nil
        XCTAssertThrowsError(try ImageDecodeDiagnosticProcess.terminalFailure(event, normalExit: true, status: 1))
    }
    func testChildErrorCannotExcuseInvalidPhaseOrder() throws {
        var admission = ImageDecodeDiagnosticEventSequence(holdsAfterDecode: false)
        var error = ImageDecodeDiagnosticEvent(kind: .error, phase: "failed", childPID: 123); error.error = .invalidJob
        try admission.consume(error)
        XCTAssertThrowsError(try admission.consume(error))
        var invalid = ImageDecodeDiagnosticEventSequence(holdsAfterDecode: false)
        XCTAssertThrowsError(try invalid.consume(.init(kind: .phase, phase: "rasterDrawn", childPID: 123)))
        var valid = ImageDecodeDiagnosticEventSequence(holdsAfterDecode: false)
        for phase in ["beforePNGRead", "imageCreated", "rasterDrawn", "afterContextRelease", "outputClosed", "afterDecodePool"] {
            try valid.consume(.init(kind: .phase, phase: phase, childPID: 123))
        }
        try valid.consume(.init(kind: .result, phase: "complete", childPID: 123))
        var held = ImageDecodeDiagnosticEventSequence(holdsAfterDecode: true)
        for phase in ["beforePNGRead", "imageCreated", "rasterDrawn", "afterContextRelease"] {
            try held.consume(.init(kind: .phase, phase: phase, childPID: 123))
        }
        try held.consume(.init(kind: .ready, phase: "heldAfterDecode", childPID: 123))
        XCTAssertThrowsError(try held.consume(.init(kind: .result, phase: "complete", childPID: 123)))
        try held.consume(error)
    }
    func testExplicitSelectorsAndFixedBounds() async throws {
        XCTAssertNil(try ImageDecodeHelperAttributionFixture.request(environment: [:]))
        let missing = try await ImageDecodeHelperAttributionFixture.runIfRequested(evidenceDirectory: FileManager.default.temporaryDirectory, environment: [:])
        XCTAssertNil(missing)
        for mode in ImageDecodeHelperAttributionFixture.Mode.allCases {
            let request = try ImageDecodeHelperAttributionFixture.request(environment: ["PICSHOT_IMAGE_DRAW_HELPER_MODE": mode.rawValue, "PICSHOT_IMAGE_DRAW_HELPER_INPUT_DIRECTORY": "/tmp/prepared"])
            XCTAssertEqual(request?.mode, mode)
        }
        XCTAssertEqual(ImageDecodeDiagnosticLimits.width, 768); XCTAssertEqual(ImageDecodeDiagnosticLimits.height, 576)
        XCTAssertEqual(ImageDecodeDiagnosticLimits.rasterBytes, 1_769_472)
        XCTAssertEqual(ImageDecodeDiagnosticLimits.childWorkSeconds, 5)
        XCTAssertEqual(ImageDecodeDiagnosticLimits.childHardSeconds, 6)
        XCTAssertEqual(ImageDecodeDiagnosticLimits.exitSeconds, 9)
        XCTAssertEqual(ImageDecodeDiagnosticLimits.armSeconds, 180)
        XCTAssertEqual(ImageDecodeDiagnosticLimits.outerSeconds, 200)
        for extra in ["PICSHOT_IMAGE_DRAW_MODE", "PICSHOT_IMAGE_DRAW_HELPER_CYCLES", "PICSHOT_IMAGE_DRAW_HELPER_EXECUTABLE", "PICSHOT_IMAGE_RELIEF_MODE", "PICSHOT_CODEC_ATTRIBUTION_MODE", "PICSHOT_IMAGE_BACKING_MODE", "PICSHOT_GIF_DIAGNOSTIC_MODE", "PICSHOT_UI_PREVIEW_ONLY"] {
            XCTAssertThrowsError(try ImageDecodeHelperAttributionFixture.request(environment: ["PICSHOT_IMAGE_DRAW_HELPER_MODE": "isolated-decode", "PICSHOT_IMAGE_DRAW_HELPER_INPUT_DIRECTORY": "/tmp/prepared", extra: "1"]))
        }
        XCTAssertThrowsError(try ImageDecodeHelperAttributionFixture.request(environment: ["PICSHOT_IMAGE_DRAW_HELPER_MODE": "isolated-decode"]))
        XCTAssertThrowsError(try ImageDecodeHelperAttributionFixture.request(environment: ["PICSHOT_IMAGE_DRAW_HELPER_MODE": "unknown", "PICSHOT_IMAGE_DRAW_HELPER_INPUT_DIRECTORY": "/tmp/prepared"]))
        XCTAssertThrowsError(try ImageDecodeHelperAttributionFixture.request(environment: ["PICSHOT_IMAGE_DRAW_HELPER_MODE": "isolated-decode", "PICSHOT_IMAGE_DRAW_HELPER_INPUT_DIRECTORY": "relative"]))
    }
    func testFullWidthMemoryReportBudgetAndOversizeFailure() throws {
        let actual = ImageDecodeMemoryReading.current()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(actual)) as? [String: Any])
        func stress(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] { return dictionary.mapValues(stress) }
            if value is NSNumber { return UInt64.max }
            return value
        }
        let memory = stress(object)
        let child: [String: Any] = ["schema": ImageDecodeDiagnosticLimits.schema, "kind": "phase", "phase": "afterContextRelease",
            "childPID": Int32.max, "uptimeSeconds": Double.greatestFiniteMagnitude, "memory": memory]
        let pair: [String: Any] = ["child": child, "parentAtReceipt": memory, "childObservedRunning": true, "receiptSkewSeconds": Double.greatestFiniteMagnitude]
        let process: [String: Any] = ["phases": Array(repeating: pair, count: ImageDecodeDiagnosticLimits.maximumEvents),
            "terminal": child, "jobDirectory": String(repeating: "p", count: 1024)]
        let cycle: [String: Any] = ["before": memory, "beforeParentDraw": memory, "afterPool": memory, "settled": memory,
            "draw": ["beforeDrawImageLive": memory, "afterDrawAndReadbackImageLive": memory], "process": process]
        // This is a deliberately oversized scalar-width/schema rehearsal, not
        // fabricated native measurements. The new ceiling is diagnostic-only.
        let report: [String: Any] = ["cycles": Array(repeating: cycle, count: 14), "scope": String(repeating: "s", count: 16384)]
        let data = try ImageDecodeHelperAttributionFixture.encodedReport(report)
        XCTAssertLessThanOrEqual(data.count, ImageDecodeDiagnosticLimits.reportBytes)
        XCTAssertThrowsError(try ImageDecodeHelperAttributionFixture.encodedReport(["oversize": String(repeating: "x", count: ImageDecodeDiagnosticLimits.reportBytes)]))
    }
    func testCurrentMemoryPreservesBothFlavorStatusesAndVolatileFields() throws {
        let reading = ImageDecodeMemoryReading.current()
        XCTAssertTrue(reading.usable)
        XCTAssertNil(reading.standard.bytes["purgeable_volatile_resident"])
        XCTAssertNotNil(reading.purgeable.bytes["purgeable_volatile_resident"])
        let decoded = try JSONDecoder().decode(ImageDecodeMemoryReading.self, from: JSONEncoder().encode(reading))
        XCTAssertEqual(decoded.standard.bytes, reading.standard.bytes)
        XCTAssertEqual(decoded.purgeable.bytes, reading.purgeable.bytes)
    }
}
