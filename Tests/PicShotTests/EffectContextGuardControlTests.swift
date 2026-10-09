import Foundation
import XCTest
@testable import PicShot

@MainActor final class EffectContextGuardControlTests: XCTestCase {
    func testBothPoliciesProduceSeparateExactPositiveControlEvidence() throws {
        for policy in EffectContextPolicy.allCases {
            let configuration = EffectContextConfiguration(policy: policy)
            let report = try EffectContextGuardControl.verify(configuration: configuration)
            XCTAssertEqual(report.schemaVersion, 1)
            XCTAssertEqual(report.status, "passed")
            XCTAssertEqual(report.stage, "separate-positive-effect-control-after-output-guard")
            XCTAssertEqual(report.comparisonKind, "effect-context-memory-target")
            XCTAssertEqual(report.selectedPolicy, policy.rawValue)
            XCTAssertEqual(report.processBefore.attemptCount, 0)
            XCTAssertEqual(report.processAfter.attemptCount, 2)
            XCTAssertEqual(report.processAfter.publishCount, 2)
            XCTAssertEqual(report.processAfter.failureCount, 0)
            XCTAssertEqual(report.processBefore.contextCount, 1)
            XCTAssertEqual(report.processAfter.contextCount, 1)
            XCTAssertEqual(report.processAfter.configuredMemoryTargetMegabytes, policy.configuredMemoryTargetMegabytes)
            XCTAssertEqual(report.processAfter.configuredCacheIntermediates, false)
            XCTAssertEqual(report.processControlCallCount, 2)
            XCTAssertEqual(report.independentReferenceContextCount, 1)
            XCTAssertEqual(report.independentReferenceCallCount, 2)
            XCTAssertEqual(report.rasterObservationCount, 5)
            XCTAssertEqual(report.memoryObservationCount, 0)
            XCTAssertEqual(report.records.map(\.effect), ["blur", "pixelate"])
            for record in report.records {
                XCTAssertEqual(record.inputWidth, 129); XCTAssertEqual(record.inputHeight, 101)
                XCTAssertEqual(record.outputWidth, 129); XCTAssertEqual(record.outputHeight, 101)
                XCTAssertTrue(record.pixelsEqual); XCTAssertTrue(record.rgbaEqual)
                XCTAssertTrue(record.metadataEqual); XCTAssertTrue(record.outputDiffersFromInput)
                XCTAssertEqual(record.referenceRGBASHA256, record.candidateRGBASHA256)
                XCTAssertEqual(record.referenceStoredPixelsSHA256, record.candidateStoredPixelsSHA256)
                XCTAssertEqual(record.referenceMetadata, record.candidateMetadata)
                XCTAssertNotEqual(record.inputRGBASHA256, record.candidateRGBASHA256)
                for hash in [record.inputRGBASHA256, record.referenceRGBASHA256, record.candidateRGBASHA256,
                             record.referenceStoredPixelsSHA256, record.candidateStoredPixelsSHA256] {
                    XCTAssertEqual(hash.count, 64)
                    XCTAssertTrue(hash.allSatisfy { "0123456789abcdef".contains($0) })
                }
            }
            let encoded = try JSONEncoder().encode(report)
            XCTAssertLessThan(encoded.count, 8192)
            XCTAssertEqual(try JSONDecoder().decode(EffectContextGuardControlReport.self, from: encoded), report)
        }
    }

    func testControlCountersAreDeltasAndDoNotClaimPreviousRenderWork() throws {
        let configuration = EffectContextConfiguration(policy: .memory32)
        let first = try EffectContextGuardControl.verify(configuration: configuration)
        let second = try EffectContextGuardControl.verify(configuration: configuration)
        XCTAssertEqual(second.processBefore, first.processAfter)
        XCTAssertEqual(second.processBefore.attemptCount, 2)
        XCTAssertEqual(second.processAfter.attemptCount, 4)
        XCTAssertEqual(second.processControlCallCount, 2)
        XCTAssertEqual(second.records, first.records)
    }

    func testInvalidPolicyAndInjectedFailureCannotProducePassingEvidence() {
        let invalid = EffectContextConfiguration(environment: ["PICSHOT_EFFECT_CONTEXT_POLICY": "memory32"])
        XCTAssertThrowsError(try EffectContextGuardControl.verify(configuration: invalid)) {
            XCTAssertEqual($0 as? EffectContextConfiguration.Failure, .invalidConfiguration)
        }
        XCTAssertEqual(invalid.tracker.snapshot().contextCount, 0)
        XCTAssertEqual(invalid.tracker.snapshot().attemptCount, 0)
        for policy in EffectContextPolicy.allCases {
            let failed = EffectContextConfiguration(policy: policy, failureInjection: .render)
            XCTAssertThrowsError(try EffectContextGuardControl.verify(configuration: failed)) {
                XCTAssertEqual($0 as? EffectContextConfiguration.Failure, .injectedRender)
            }
            XCTAssertEqual(failed.tracker.snapshot().attemptCount, 1)
            XCTAssertEqual(failed.tracker.snapshot().publishCount, 0)
            XCTAssertEqual(failed.tracker.snapshot().failureCount, 1)
        }
    }
}
