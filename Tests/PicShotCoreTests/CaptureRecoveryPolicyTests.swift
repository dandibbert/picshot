import XCTest
@testable import PicShotCore

final class CaptureRecoveryPolicyTests: XCTestCase {
    func testKnownFullCountAndExhaustedBytesRefuseWithoutWorstCaseReservation() {
        let policy = EditorAdmissionPolicy(maximumEditors: 6, maximumRasterBytes: 100)
        XCTAssertEqual(CaptureRecoveryPolicy.preflight(editorPolicy: policy,
            existingRasterBytes: [1, 1, 1, 1, 1, 1], drainingBytes: 0, pendingBytes: 0), .windowLimit)
        XCTAssertEqual(CaptureRecoveryPolicy.preflight(editorPolicy: policy,
            existingRasterBytes: [99], drainingBytes: 1, pendingBytes: 0), .rasterBudget)
        XCTAssertNil(CaptureRecoveryPolicy.preflight(editorPolicy: policy,
            existingRasterBytes: [99], drainingBytes: 0, pendingBytes: 0), "Unknown incoming size is not a worst-case screenshot reservation")
    }
    func testPendingIsChargedToUnrelatedAdmissionButNotDoubleCountedOnTransfer() {
        let policy = EditorAdmissionPolicy(maximumRasterBytes: 100)
        let normal = CaptureRecoveryPolicy.admissionBytes(incomingBytes: 20, drainingBytes: 10, pendingBytes: 40, transferringPending: false)
        XCTAssertEqual(normal, 70)
        XCTAssertEqual(policy.refusal(existingRasterBytes: [40], incomingRasterBytes: normal), .rasterBudget)
        let transfer = CaptureRecoveryPolicy.admissionBytes(incomingBytes: 60, drainingBytes: 0, pendingBytes: 40, transferringPending: true)
        XCTAssertEqual(transfer, 60)
        XCTAssertNil(policy.refusal(existingRasterBytes: [40], incomingRasterBytes: transfer))
    }
    func testSeparatePoolHasExactManagedBackingCeiling() {
        let raster = CaptureRecoveryPolicy.maximumRasterBytes, encoded = CaptureRecoveryPolicy.maximumEncodedBytes
        XCTAssertEqual(CaptureRecoveryPolicy.maximumPendingBytes, 671_088_640)
        XCTAssertEqual(CaptureRecoveryPolicy.retainedBytes(rasterBytes: raster, encodedBytes: encoded), 671_088_640)
        XCTAssertNil(CaptureRecoveryPolicy.retainedBytes(rasterBytes: raster + 1, encodedBytes: 0))
        XCTAssertNil(CaptureRecoveryPolicy.retainedBytes(rasterBytes: 1, encodedBytes: encoded + 1))
        XCTAssertNil(CaptureRecoveryPolicy.retainedBytes(rasterBytes: Int.max, encodedBytes: Int.max))
        XCTAssertNil(CaptureRecoveryPolicy.retainedBytes(rasterBytes: 1, encodedBytes: -1))
    }
    func testSystemHeaderPreserves100MPixelsAnd128MiBButRejectsUnboundedDepth() {
        let cap = CaptureRecoveryPolicy.maximumEncodedBytes
        XCTAssertTrue(CaptureRecoveryPolicy.allowsSystemHeader(width: 10_000, height: 10_000, depth: 8, encodedBytes: cap))
        XCTAssertFalse(CaptureRecoveryPolicy.allowsSystemHeader(width: 10_001, height: 10_000, depth: 8, encodedBytes: cap))
        XCTAssertFalse(CaptureRecoveryPolicy.allowsSystemHeader(width: 10_000, height: 10_000, depth: 16, encodedBytes: cap))
        XCTAssertTrue(CaptureRecoveryPolicy.allowsSystemHeader(width: 8_000, height: 8_000, depth: 16, encodedBytes: cap))
        for (width, height, depth, bytes) in [(1, 0, 8, 1), (1, 1, 0, 1), (1, 1, 32, 1),
            (Int.max, Int.max, 16, 1), (1, 1, 8, cap + 1)] {
            XCTAssertFalse(CaptureRecoveryPolicy.allowsSystemHeader(width: width, height: height, depth: depth, encodedBytes: bytes))
        }
    }
}
