import Foundation
import CryptoKit

/// Metadata-only companion to the unchanged full native workload. Created only
/// by an explicit owned drawing diagnostic launch; it never owns a product raster.
@MainActor final class EditableDrawingPairDiagnostic {
    typealias O = EditableAnnotationFixtureObservation
    static var process: EditableDrawingPairDiagnostic?
    private let strategy: String, resources: Bool, observer: String
    private let beganReferenceDateSeconds = Date().timeIntervalSinceReferenceDate
    private var workload = "entry"
    private var checkpoints: [[String: Any]] = [], documentRows: [[String: Any]] = []

    private init(strategy: String, resources: Bool, observer: String) {
        self.strategy = strategy; self.resources = resources; self.observer = observer
    }
    static func begin(includeResources: Bool) throws {
        process = nil
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICSHOT_DRAWING_RASTER_STRATEGY"] != nil else { return }
        try O.require(environment["PICSHOT_SMOKE_TEST"] == "1"
            && environment["PICSHOT_EDITABLE_ANNOTATIONS_ONLY"] == "1", "Drawing pair needs the owned full editable route")
        let selected = try DrawingRasterConfiguration.process.selectedStrategy().rawValue
        let observer = environment["PICSHOT_EDITABLE_HASH_DIAGNOSTIC"] ?? ""
        try O.require(observer == "vimage" || (observer == "certify" && !includeResources),
                      "Drawing pair requires common vImage observation or isolated byte certification")
        try RendererStoragePairDiagnostic.begin(includeResources: includeResources, observer: observer)
        process = EditableDrawingPairDiagnostic(strategy: selected, resources: includeResources, observer: observer)
        try process?.checkpoint(workload: "entry", label: "native-entry")
    }
    func checkpoint(workload: String, label: String) throws {
        try O.require(checkpoints.count < 256, "Drawing checkpoint bound exceeded")
        self.workload = workload
        let tracker = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DrawingRasterConfiguration.process.tracker.snapshot()))
        checkpoints.append(["workload": workload, "label": label, "memory": try O.memory(), "drawing": tracker])
        try RendererStoragePairDiagnostic.process?.checkpoint(drawingCheckpoint: checkpoints[checkpoints.count - 1])
    }
    func documents(original: Data, applied: Data) throws {
        try O.require(documentRows.count < 12 && original.count <= 131_072 && applied.count <= 131_072,
                      "Drawing document evidence exceeds metadata bound")
        documentRows.append(["workload": workload, "originalBase64": original.base64EncodedString(),
                             "appliedBase64": applied.base64EncodedString()])
    }
    func write(native: [String: Any], nativeData: Data, directory: URL) throws {
        guard native["status"] as? String != "running" else { return }
        var report: [String: Any] = ["schemaVersion": 1, "status": native["status"] ?? "unknown",
            "drawingStrategy": strategy, "hashObservation": observer, "resourcesRequested": resources,
            "nativeReportSHA256": SHA256.hash(data: nativeData).map { String(format: "%02x", $0) }.joined(),
            "maximumCheckpoints": 256, "maximumDocuments": 12, "maximumDocumentBytes": 131_072,
            "sessionDateBounds": ["beganReferenceDateSeconds": beganReferenceDateSeconds,
                                  "finishedReferenceDateSeconds": Date().timeIntervalSinceReferenceDate],
            "checkpoints": checkpoints, "documents": documentRows,
            "productDefaultsChanged": false, "privateFrameworkReleaseClaim": false,
            "scope": "Full unchanged native editable workflow; immutable per-process drawing choice. Both measured arms use identical per-call vImage hash observation. Metadata-only bounded sidecar records actual task-info fields and scalar copy outcomes, not image ownership or private CoreFoundation backing release. Native CF weak probes remain unchanged. Serialization follows native final endpoints; no pressure or purge."]
        for field in ["sourceCommit", "executableSHA256", "architecture", "processIdentifier"] { report[field] = native[field] }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        try O.require(data.count <= 2 * 1_024 * 1_024, "Drawing evidence exceeds sidecar byte bound")
        try data.write(to: directory.appendingPathComponent("editable-drawing-pair.json"), options: .atomic)
        try RendererStoragePairDiagnostic.process?.write(native: native, nativeData: nativeData, drawingData: data, directory: directory)
    }
}
