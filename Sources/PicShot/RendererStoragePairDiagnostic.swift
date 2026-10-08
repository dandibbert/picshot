import Foundation
import CryptoKit

/// Bounded scalar companion at the existing drawing checkpoints. This owns no
/// images, performs no extra raster observation and does not add memory samples.
@MainActor final class RendererStoragePairDiagnostic {
    typealias O = EditableAnnotationFixtureObservation
    static var process: RendererStoragePairDiagnostic?
    private let strategy: String, resources: Bool, observer: String
    private var checkpoints: [[String: Any]] = []

    private init(strategy: String, resources: Bool, observer: String) {
        self.strategy = strategy; self.resources = resources; self.observer = observer
    }
    static func begin(includeResources: Bool, observer: String) throws {
        process = nil
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICSHOT_RENDERER_STORAGE_STRATEGY"] != nil else { return }
        let selected = try RendererStorageConfiguration.process.selectedStrategy().rawValue
        try O.require(environment["PICSHOT_SMOKE_TEST"] == "1"
            && environment["PICSHOT_EDITABLE_ANNOTATIONS_ONLY"] == "1"
            && environment["PICSHOT_DRAWING_RASTER_STRATEGY"] == "owned-srgb8",
            "Renderer pair requires the owned editable route and fixed drawing strategy")
        try O.require(observer == "vimage" || (observer == "certify" && !includeResources),
                      "Renderer pair requires common observation and isolated certification")
        process = RendererStoragePairDiagnostic(strategy: selected, resources: includeResources, observer: observer)
    }
    func checkpoint(drawingCheckpoint: [String: Any]) throws {
        try O.require(checkpoints.count < 256, "Renderer checkpoint bound exceeded")
        let workload = try O.required(drawingCheckpoint["workload"] as? String, "Renderer workload missing")
        let label = try O.required(drawingCheckpoint["label"] as? String, "Renderer stage missing")
        let tracker = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RendererStorageConfiguration.process.tracker.snapshot()))
        checkpoints.append(["workload": workload, "label": label, "rendererStorage": tracker])
    }
    func write(native: [String: Any], nativeData: Data, drawingData: Data, directory: URL) throws {
        guard native["status"] as? String != "running" else { return }
        var report: [String: Any] = ["schemaVersion": 1, "status": native["status"] ?? "unknown",
            "comparisonKind": "renderer-final-storage", "rendererStorageStrategy": strategy,
            "drawingStrategy": "owned-srgb8", "productionDefaultStrategy": RendererStorageStrategy.productionDefault.rawValue,
            "hashObservation": observer, "resourcesRequested": resources,
            "nativeReportSHA256": SHA256.hash(data: nativeData).map { String(format: "%02x", $0) }.joined(),
            "drawingReportSHA256": SHA256.hash(data: drawingData).map { String(format: "%02x", $0) }.joined(),
            "maximumCheckpoints": 256, "additionalRasterObservations": 0,
            "observationBoundary": "after-existing-drawing-checkpoint", "checkpoints": checkpoints,
            "productDefaultsChanged": false, "privateFrameworkReleaseClaim": false,
            "scope": "Scalar renderer storage outcomes at existing fixed phase checkpoints. No new raster or memory observation, retained image, pressure or purge. Owned byte release does not establish private framework backing release."]
        for field in ["sourceCommit", "executableSHA256", "executableBytes", "architecture", "processIdentifier"] { report[field] = native[field] }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        try O.require(data.count <= 256 * 1_024, "Renderer evidence exceeds scalar byte bound")
        try data.write(to: directory.appendingPathComponent("renderer-storage-pair.json"), options: .atomic)
    }
}
