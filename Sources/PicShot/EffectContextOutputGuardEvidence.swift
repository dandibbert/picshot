import Foundation
import CryptoKit

/// Observes the unchanged guard after it returns. The fixture injects failure
/// outside the normal effect closure, so refusals are not effect-call failures.
@MainActor enum EffectContextOutputGuardEvidence {
    static let filename = "effect-context-output-guard.json"
    static func writeIfRequested(evidenceDirectory: URL) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let requested = environment["PICSHOT_EFFECT_CONTEXT_POLICY"] else { return }
        typealias O = EditableAnnotationFixtureObservation
        let selected = try EffectContextPairDiagnostic.selectedPolicy()
        try O.require(environment["PICSHOT_EFFECT_OUTPUT_FAILURE_ONLY"] == "1", "Effect guard route differs")
        let actualPolicy = try EffectContextConfiguration.process.selectedPolicy()
        try O.require(actualPolicy == selected, "Effect guard process selection changed")
        let effect = EffectContextConfiguration.process.tracker.snapshot()
        let renderer = RendererStorageConfiguration.process.tracker.snapshot()
        let rendererPolicy = try RendererStorageConfiguration.process.selectedStrategy()
        let drawingPolicy = try DrawingRasterConfiguration.process.selectedStrategy()
        // These snapshots describe only the unchanged original fixture. The
        // separate positive control owns its additional render/read evidence.
        let positiveControl = try EffectContextGuardControl.verify()
        try O.require(positiveControl.processBefore == effect, "Effect guard/control boundary changed")
        let executable = try O.required(Bundle.main.executableURL, "Effect guard executable missing")
        func boundedBytes(_ url: URL, maximum: Int) throws -> Data {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            try O.require(values.isRegularFile == true && values.isSymbolicLink == false
                && (values.fileSize ?? 0) > 0 && (values.fileSize ?? maximum + 1) <= maximum,
                "Effect guard input missing, linked or oversized")
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: maximum + 1) ?? Data()
            try O.require(data.count == values.fileSize, "Effect guard input changed during read")
            return data
        }
        let nativeURL = evidenceDirectory.appendingPathComponent(EffectOutputFailureNativeFixture.filename)
        let nativeData = try boundedBytes(nativeURL, maximum: 128 * 1_024)
        let drawingData = try boundedBytes(evidenceDirectory.appendingPathComponent(DrawingRasterOutputGuardEvidence.filename), maximum: 16 * 1_024)
        let executableSize = try executable.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let payload: [String: Any] = ["schemaVersion": 1, "status": "observed", "diagnosticOnly": true,
            "comparisonKind": EffectContextPairDiagnostic.comparisonKind,
            "observationBoundary": "after-effect-output-failure-fixture-return",
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "buildVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "bundlePath": Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            "executablePath": executable.resolvingSymlinksInPath().path,
            "executableSHA256": try O.fileDigest(executable),
            "executableBytes": try O.required(executableSize, "Effect guard executable size missing"),
            "processIdentifier": Int(ProcessInfo.processInfo.processIdentifier),
            "nativeReportPath": nativeURL.resolvingSymlinksInPath().path,
            "nativeReportBytes": nativeData.count,
            "nativeReportSHA256": SHA256.hash(data: nativeData).map { String(format: "%02x", $0) }.joined(),
            "drawingReportSHA256": SHA256.hash(data: drawingData).map { String(format: "%02x", $0) }.joined(),
            "requestedPolicy": requested, "effectContextPolicy": actualPolicy.rawValue,
            "productionDefaultPolicy": EffectContextPolicy.productionDefault.rawValue,
            "rendererStorageStrategy": rendererPolicy.rawValue, "rendererAutoreleaseScope": rendererPolicy.autoreleaseScope,
            "rendererProductionDefaultStrategy": RendererStorageStrategy.productionDefault.rawValue,
            "drawingStrategy": drawingPolicy.rawValue, "scalarAdditionalRasterObservations": 0,
            "additionalMemoryObservations": 0, "contextOwnershipScope": "one-immutable-process-context",
            "effectContext": try EffectContextPairDiagnostic.scalar(effect),
            "positiveControl": try EffectContextPairDiagnostic.scalar(positiveControl),
            "rendererStorage": try EffectContextPairDiagnostic.scalar(renderer)]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try O.require(data.count <= 16 * 1_024, "Effect guard evidence exceeds scalar bound")
        try data.write(to: evidenceDirectory.appendingPathComponent(filename), options: .atomic)
    }
}
