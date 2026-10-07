import Foundation
import PicShotCodecCore

/// One real post-decode cancellation/deadline probe, separate from draw cycles.
@MainActor
enum ImageDecodeExitProbeFixture {
    static func run(input: ImageDecodeLargeInput, mode: ImageDecodeLargeAttributionFixture.Mode, directory: URL) async throws -> [String: Any] {
        guard input.profile == .fiveK, mode == .cancelAfterDecode || mode == .timeoutAfterDecode else { throw ImageDecodeDiagnosticError.invalidProtocol }
        let started = ProcessInfo.processInfo.systemUptime, deadline = started + 20
        let process = ImageDecodeDiagnosticProcess(mode: mode == .cancelAfterDecode ? .cancelAfterDecode : .timeoutAfterDecode,
            profile: input.profile, timingEnabled: true, exitStrategy: .terminationLatch)
        var report = ImageDecodeLargeSupport.base(mode: mode.rawValue, input: input)
        report["timingInstrumentationVersion"] = 3; report["exitObservationStrategy"] = ImageDecodeExitStrategy.terminationLatch.rawValue
        report["warmupCycles"] = 0; report["measuredCycles"] = 0; report["oneShotProbe"] = true
        report["armDeadlineSeconds"] = 20; report["requiredOuterDeadlineSeconds"] = 30
        report["completedParentDraws"] = 0; report["scope"] = "Real child raster is hash-checked at heldAfterDecode; cancellation/deadline prevents raw publication or parent draw"
        let output = directory.appendingPathComponent("image-decode-large-\(mode.rawValue).json")
        do {
            report["beforeProbe"] = try ImageDecodeLargeSupport.object(ImageDecodeLargeSupport.observe())
            let raw = try await withTaskCancellationHandler {
                try await Task.detached { try autoreleasepool { try process.run(png: input.png, armDeadline: deadline) } }.value
            } onCancel: { process.cancel() }
            let metrics = process.snapshot()
            guard raw == nil, metrics.sawPostDecodeReady, metrics.exitConfirmed, metrics.cleanupConfirmed, metrics.admissionReleased,
                  metrics.stdoutEOFConfirmed == true, metrics.stderrEOFConfirmed == true, metrics.terminationHandlerCleared == true,
                  metrics.terminationStatus == 1, metrics.terminationReason == "exit", !metrics.outputExistedBeforeCleanup,
                  let ready = metrics.phases.first(where: { $0.child.kind == .ready }), ready.child.rawSHA256 == input.referenceSHA,
                  ready.child.rawBytes == input.profile.rasterBytes,
                  metrics.outcome == (mode == .cancelAfterDecode ? "cancelled-after-decode" : "deadline-after-decode") else { throw ImageDecodeDiagnosticError.invalidProtocol }
            try ImageDecodeLargeSupport.check(deadline)
            // Successful reacquisition is additional evidence that cleanup released
            // the shared gate; it does not replace the individual exit/EOF checks.
            guard let lease = NativeExportAdmission.shared.acquire() else { throw ImageDecodeDiagnosticError.exitUnconfirmed }
            NativeExportAdmission.shared.release(lease)
            report["sharedLeaseReacquired"] = true; report["probeDecodedRGBAMatchesReference"] = true
            report["probe"] = try ImageDecodeLargeSupport.object(metrics)
            report["afterProbe"] = try ImageDecodeLargeSupport.object(ImageDecodeLargeSupport.observe())
            report["ownedJobsRemaining"] = 0; report["helperInvocations"] = 1
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started; report["status"] = "observed"
            try ImageDecodeLargeSupport.write(report, to: output); return report
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["probe"] = try? ImageDecodeLargeSupport.object(process.snapshot())
            try? ImageDecodeLargeSupport.write(report, to: output); throw error
        }
    }
}
