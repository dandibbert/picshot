import XCTest
import Foundation
import Darwin
@testable import PicShot

/// These default tests never invoke allocator relief. The live comparison is
/// deliberately opt-in through scripts/image-relief-attribution.sh --compare.
@MainActor
final class ImageAllocatorReliefTests: XCTestCase {
    func testAbsentSelectorDoesNothingAndLeavesExistingSmokeRoutingAvailable() async throws {
        XCTAssertNil(try ImageAllocatorReliefFixture.request(environment: [:]))
        XCTAssertNil(try ImageAllocatorReliefFixture.request(environment: ["PICSHOT_IMAGE_BACKING_MODE": "preview-only"]))
        let result = try await ImageAllocatorReliefFixture.runIfRequested(evidenceDirectory: FileManager.default.temporaryDirectory, environment: [:])
        XCTAssertNil(result)
    }

    func testExplicitModesAndFixedBounds() throws {
        XCTAssertEqual(ImageAllocatorReliefFixture.Mode.allCases.map(\.rawValue), ["prepare-inputs", "wait-control", "allocator-relief"])
        XCTAssertEqual(ImageAllocatorReliefFixture.width, 768)
        XCTAssertEqual(ImageAllocatorReliefFixture.height, 576)
        XCTAssertEqual(ImageAllocatorReliefFixture.warmupCycles, 2)
        XCTAssertEqual(ImageAllocatorReliefFixture.measuredCycles, 12)
        XCTAssertEqual(ImageAllocatorReliefFixture.goalBytes, 33_554_432)
        XCTAssertEqual(ImageAllocatorReliefFixture.cooperativeDeadlineSeconds, 45)
        XCTAssertEqual(ImageAllocatorReliefFixture.requiredOuterDeadlineSeconds, 60)
        XCTAssertEqual(ImageAllocatorReliefFixture.postObservationSeconds, [0.5, 2])
        let prepared = try XCTUnwrap(ImageAllocatorReliefFixture.request(environment: ["PICSHOT_IMAGE_RELIEF_MODE": "prepare-inputs"]))
        XCTAssertEqual(prepared.mode, .prepareInputs); XCTAssertNil(prepared.inputDirectory)
        XCTAssertEqual(prepared.mode.expectedReliefCalls, 0)
        for mode in [ImageAllocatorReliefFixture.Mode.waitControl, .allocatorRelief] {
            let request = try XCTUnwrap(ImageAllocatorReliefFixture.request(environment:
                ["PICSHOT_IMAGE_RELIEF_MODE": mode.rawValue, "PICSHOT_IMAGE_RELIEF_INPUT_DIRECTORY": "/tmp/prepared"]))
            XCTAssertEqual(request.mode, mode)
            XCTAssertEqual(request.inputDirectory?.path, "/tmp/prepared")
            XCTAssertEqual(mode.expectedReliefCalls, mode == .allocatorRelief ? 1 : 0)
        }
    }

    func testUnknownMixedAndOverrideSelectorsAreRejectedBeforeAnyWork() {
        let valid = ["PICSHOT_IMAGE_RELIEF_MODE": "allocator-relief", "PICSHOT_IMAGE_RELIEF_INPUT_DIRECTORY": "/tmp/prepared"]
        var invalid: [[String: String]] = [
            ["PICSHOT_IMAGE_RELIEF_MODE": "automatic"],
            ["PICSHOT_IMAGE_RELIEF_MODE": "allocator-relief"],
            ["PICSHOT_IMAGE_RELIEF_MODE": "prepare-inputs", "PICSHOT_IMAGE_RELIEF_INPUT_DIRECTORY": "/tmp/prepared"],
            ["PICSHOT_IMAGE_RELIEF_INPUT_DIRECTORY": "/tmp/prepared"],
            ["PICSHOT_IMAGE_RELIEF_MODE": "wait-control", "PICSHOT_IMAGE_RELIEF_INPUT_DIRECTORY": "relative"]
        ]
        for key in ["PICSHOT_IMAGE_RELIEF_GOAL_BYTES", "PICSHOT_IMAGE_RELIEF_MEASURED_CYCLES", "PICSHOT_IMAGE_RELIEF_DEADLINE",
                    "PICSHOT_IMAGE_RELIEF_PROFILE", "PICSHOT_IMAGE_BACKING_MODE", "PICSHOT_CODEC_ATTRIBUTION_MODE",
                    "PICSHOT_GIF_DIAGNOSTIC_MODE", "PICSHOT_UI_PREVIEW_ONLY", "PICSHOT_SMOKE_GIF_RESOURCES"] {
            var request = valid; request[key] = "1"; invalid.append(request)
        }
        for environment in invalid { XCTAssertThrowsError(try ImageAllocatorReliefFixture.request(environment: environment)) }
    }

    func testReportPreservesZeroReturnAndDoesNotInventReturnForWaitControl() throws {
        // Artificial metrics exercise serialization only, never live evidence.
        let count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let standard = ImageBackingTaskVMReading.decode(task_vm_info_data_t(), flavor: task_flavor_t(TASK_VM_INFO),
            result: KERN_FAILURE, requestedCount: count, returnedCount: 0)
        let purgeable = ImageBackingTaskVMReading.decode(task_vm_info_data_t(), flavor: task_flavor_t(TASK_VM_INFO_PURGEABLE),
            result: KERN_FAILURE, requestedCount: count, returnedCount: 0)
        let missing = ImageBackingMemoryReading(standard: standard, purgeable: purgeable)
        let control = ImageReliefIntervention(mode: "wait-control", invocationCount: 0, requestedGoalBytes: nil,
            apiReportedReleasedBytes: nil, callElapsedSeconds: 0, before: missing, immediatelyAfter: missing)
        let attempted = ImageReliefIntervention(mode: "allocator-relief", invocationCount: 1, requestedGoalBytes: 33_554_432,
            apiReportedReleasedBytes: 0, callElapsedSeconds: 0.01, before: missing, immediatelyAfter: missing)
        let controlJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(control)) as? [String: Any])
        let attemptedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(attempted)) as? [String: Any])
        XCTAssertNil(controlJSON["apiReportedReleasedBytes"]); XCTAssertNil(controlJSON["requestedGoalBytes"])
        XCTAssertEqual(attemptedJSON["apiReportedReleasedBytes"] as? Int, 0)
        XCTAssertEqual(attemptedJSON["invocationCount"] as? Int, 1)
        for object in [controlJSON, attemptedJSON] {
            XCTAssertNil(object["previewBytesReclaimed"]); XCTAssertNil(object["leakDetected"])
            XCTAssertNil(object["zeroCost"]); XCTAssertNil(object["success"])
        }
    }
}
