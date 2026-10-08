import AppKit
import CryptoKit
import PicShotCore

/// Optional scalar observation of the existing installed failure guard. This
/// neither adds work nor waits for cleanup; the separate checker decides whether
/// the actual post-fixture counts satisfy the candidate contract.
@MainActor enum DrawingRasterOutputGuardEvidence {
    static let filename = "drawing-raster-output-guard.json"

    static func writeIfRequested(evidenceDirectory: URL) throws {
        guard let requested = ProcessInfo.processInfo.environment["PICSHOT_DRAWING_RASTER_STRATEGY"] else { return }
        let configuration = DrawingRasterConfiguration.process
        let selected = try configuration.selectedStrategy()
        let snapshot = configuration.tracker.snapshot()
        guard let executable = Bundle.main.executableURL else {
            throw PicShotError.message("Drawing guard executable identity missing")
        }
        let reportURL = evidenceDirectory.appendingPathComponent(EffectOutputFailureNativeFixture.filename)
        let maximum = 128 * 1024
        let values = try reportURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink == false,
              let size = values.fileSize, size > 0, size <= maximum else {
            throw PicShotError.message("Drawing guard native report missing, linked or oversized")
        }
        let stream = try FileHandle(forReadingFrom: reportURL)
        defer { try? stream.close() }
        let nativeBytes = try stream.read(upToCount: maximum + 1) ?? Data()
        guard nativeBytes.count == size else {
            throw PicShotError.message("Drawing guard native report changed while reading")
        }
        let payload: [String: Any] = [
            "schemaVersion": 1, "status": "observed", "diagnosticOnly": true,
            "observationBoundary": "after-effect-output-failure-fixture-return",
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "buildVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "bundlePath": Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            "executablePath": executable.resolvingSymlinksInPath().path,
            "processIdentifier": Int(ProcessInfo.processInfo.processIdentifier),
            "nativeReportPath": reportURL.resolvingSymlinksInPath().path,
            "nativeReportBytes": nativeBytes.count,
            "nativeReportSHA256": SHA256.hash(data: nativeBytes).map { String(format: "%02x", $0) }.joined(),
            "requestedStrategy": requested, "selectedStrategy": selected.rawValue,
            "productionDefaultStrategy": DrawingRasterStrategy.productionDefault.rawValue,
            "tracker": try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
        ]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidenceDirectory.appendingPathComponent(filename), options: .atomic)
        try RendererStorageOutputGuardEvidence.writeIfRequested(evidenceDirectory: evidenceDirectory)
    }
}
