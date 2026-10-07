import XCTest
import Foundation
import PicShotCodecCore
@testable import PicShot

@MainActor
final class ImageDecodeExitComparisonTests: XCTestCase {
    func testExitSelectorIsExplicitAndRequiresTiming() throws {
        let base = ["PICSHOT_IMAGE_DECODE_LARGE_MODE": "isolated-decode", "PICSHOT_IMAGE_DECODE_LARGE_PROFILE": "5k",
                    "PICSHOT_IMAGE_DECODE_LARGE_INPUT_DIRECTORY": "/tmp/prepared"]
        XCTAssertEqual(try ImageDecodeLargeAttributionFixture.request(base)?.exitStrategy, .waitUntilExit)
        var candidate = base; candidate["PICSHOT_IMAGE_DECODE_LARGE_TIMING"] = "3"; candidate["PICSHOT_IMAGE_DECODE_LARGE_EXIT"] = "termination-latch"
        XCTAssertEqual(try ImageDecodeLargeAttributionFixture.request(candidate)?.exitStrategy, .terminationLatch)
        candidate.removeValue(forKey: "PICSHOT_IMAGE_DECODE_LARGE_TIMING")
        XCTAssertThrowsError(try ImageDecodeLargeAttributionFixture.request(candidate))
        candidate["PICSHOT_IMAGE_DECODE_LARGE_TIMING"] = "3"
        for value in ["", "true", "wait-until-exit", "callback", "unbounded"] {
            candidate["PICSHOT_IMAGE_DECODE_LARGE_EXIT"] = value
            XCTAssertThrowsError(try ImageDecodeLargeAttributionFixture.request(candidate))
        }
    }
    func testOneShotModesRequireFiveKCandidateAndRejectOverrides() throws {
        for mode in ["cancel-after-decode", "timeout-after-decode"] {
            var env = ["PICSHOT_IMAGE_DECODE_LARGE_MODE": mode, "PICSHOT_IMAGE_DECODE_LARGE_PROFILE": "5k",
                       "PICSHOT_IMAGE_DECODE_LARGE_INPUT_DIRECTORY": "/tmp/prepared", "PICSHOT_IMAGE_DECODE_LARGE_TIMING": "3",
                       "PICSHOT_IMAGE_DECODE_LARGE_EXIT": "termination-latch"]
            XCTAssertEqual(try ImageDecodeLargeAttributionFixture.request(env)?.mode.rawValue, mode)
            env["PICSHOT_IMAGE_DECODE_LARGE_PROFILE"] = "4k"
            XCTAssertThrowsError(try ImageDecodeLargeAttributionFixture.request(env))
            env["PICSHOT_IMAGE_DECODE_LARGE_PROFILE"] = "5k"; env.removeValue(forKey: "PICSHOT_IMAGE_DECODE_LARGE_EXIT")
            XCTAssertThrowsError(try ImageDecodeLargeAttributionFixture.request(env))
        }
    }
    func testCandidateCannotSilentlyActivateWithoutLargeTiming() throws {
        for (profile, timing) in [(Optional<ImageDecodeDiagnosticProfile>.none, true), (.some(.fiveK), false)] {
            let p = ImageDecodeDiagnosticProcess(mode: .decode, profile: profile, timingEnabled: timing, exitStrategy: .terminationLatch)
            XCTAssertThrowsError(try p.run(png: Data([0]), armDeadline: ProcessInfo.processInfo.systemUptime + 1))
            XCTAssertFalse(p.snapshot().childLaunched)
        }
    }
    func testCancellationBeforeLaunchDoesNotInstallCallbackAndReleasesOwnedLease() throws {
        let p = ImageDecodeDiagnosticProcess(mode: .decode, profile: .fiveK, timingEnabled: true, exitStrategy: .terminationLatch)
        p.cancel()
        XCTAssertThrowsError(try p.run(png: Data([0]), armDeadline: ProcessInfo.processInfo.systemUptime + 1)) {
            XCTAssertEqual($0 as? ImageDecodeDiagnosticError, .cancelled)
        }
        let state = p.snapshot()
        XCTAssertFalse(state.childLaunched); XCTAssertTrue(state.cleanupConfirmed); XCTAssertTrue(state.admissionReleased)
        XCTAssertNil(state.terminationLatch); XCTAssertNil(state.parentTimingUptimes?["terminationHandlerInstalled"])
        let lease = try XCTUnwrap(NativeExportAdmission.shared.acquire()); NativeExportAdmission.shared.release(lease)
    }
}
