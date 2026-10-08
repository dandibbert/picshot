import Foundation
import CryptoKit

/// Records raw scalar counts after the unchanged failure fixture returns.
/// Expected failed renders remain visible; no cleanup wait or extra render.
@MainActor enum RendererStorageOutputGuardEvidence {
    static let filename = "renderer-storage-output-guard.json"
    static func writeIfRequested(evidenceDirectory: URL) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let requested = environment["PICSHOT_RENDERER_STORAGE_STRATEGY"] else { return }
        typealias O = EditableAnnotationFixtureObservation
        let configuration = RendererStorageConfiguration.process
        let selected = try configuration.selectedStrategy()
        let snapshot = configuration.tracker.snapshot()
        try O.require(environment["PICSHOT_DRAWING_RASTER_STRATEGY"] == "owned-srgb8",
                      "Renderer output guard requires fixed owned drawing")
        let executable = try O.required(Bundle.main.executableURL, "Renderer guard executable missing")
        func boundedBytes(_ url: URL, maximum: Int) throws -> Data {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            try O.require(values.isRegularFile == true && values.isSymbolicLink == false
                && (values.fileSize ?? 0) > 0 && (values.fileSize ?? maximum + 1) <= maximum,
                "Renderer guard input missing, linked or oversized")
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: maximum + 1) ?? Data()
            try O.require(data.count == values.fileSize, "Renderer guard input changed during read")
            return data
        }
        let nativeURL = evidenceDirectory.appendingPathComponent(EffectOutputFailureNativeFixture.filename)
        let nativeData = try boundedBytes(nativeURL, maximum: 128 * 1_024)
        let drawingData = try boundedBytes(evidenceDirectory.appendingPathComponent(DrawingRasterOutputGuardEvidence.filename), maximum: 16 * 1_024)
        let executableSize = try executable.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let payload: [String: Any] = ["schemaVersion": 1, "status": "observed", "diagnosticOnly": true,
            "comparisonKind": "renderer-final-storage", "observationBoundary": "after-effect-output-failure-fixture-return",
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "buildVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "bundlePath": Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            "executablePath": executable.resolvingSymlinksInPath().path,
            "executableSHA256": try O.fileDigest(executable),
            "executableBytes": try O.required(executableSize, "Renderer guard executable size missing"),
            "processIdentifier": Int(ProcessInfo.processInfo.processIdentifier),
            "nativeReportPath": nativeURL.resolvingSymlinksInPath().path,
            "nativeReportBytes": nativeData.count,
            "nativeReportSHA256": SHA256.hash(data: nativeData).map { String(format: "%02x", $0) }.joined(),
            "drawingReportSHA256": SHA256.hash(data: drawingData).map { String(format: "%02x", $0) }.joined(),
            "requestedStrategy": requested, "selectedStrategy": selected.rawValue,
            "drawingStrategy": "owned-srgb8", "productionDefaultStrategy": RendererStorageStrategy.productionDefault.rawValue,
            "tracker": try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try O.require(data.count <= 16 * 1_024, "Renderer guard evidence exceeds scalar bound")
        try data.write(to: evidenceDirectory.appendingPathComponent(filename), options: .atomic)
    }
}
