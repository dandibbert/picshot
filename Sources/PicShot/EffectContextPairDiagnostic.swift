import Foundation
import CryptoKit

/// Scalar companion at existing drawing boundaries. No retained raster or new
/// observation of task memory; the context policy is immutable for this process.
@MainActor final class EffectContextPairDiagnostic {
    typealias O = EditableAnnotationFixtureObservation
    static var process: EffectContextPairDiagnostic?
    static let comparisonKind = "effect-context-memory-target"
    private let policy: EffectContextPolicy, resources: Bool, observer: String
    private var checkpoints: [[String: Any]] = []

    private init(policy: EffectContextPolicy, resources: Bool, observer: String) {
        self.policy = policy; self.resources = resources; self.observer = observer
    }
    static func selectedPolicy() throws -> EffectContextPolicy {
        let environment = ProcessInfo.processInfo.environment
        let selected = try EffectContextConfiguration.selection(environment: environment)
        try O.require(environment["PICSHOT_SMOKE_TEST"] == "1"
            && environment["PICSHOT_EFFECT_CONTEXT_POLICY"] == selected.rawValue
            && environment["PICSHOT_DRAWING_RASTER_STRATEGY"] == "owned-srgb8"
            && environment["PICSHOT_RENDERER_STORAGE_STRATEGY"] == nil,
            "Effect context diagnostic requires explicit policy, owned drawing and default native renderer")
        try O.require(try DrawingRasterConfiguration.process.selectedStrategy() == .ownedSRGB8,
                      "Effect context drawing strategy differs")
        try O.require(try RendererStorageConfiguration.process.selectedStrategy() == .native,
                      "Effect context renderer strategy differs")
        return selected
    }
    static func begin(includeResources: Bool, observer: String) throws {
        process = nil
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICSHOT_EFFECT_CONTEXT_POLICY"] != nil else { return }
        let selected = try selectedPolicy()
        try O.require(environment["PICSHOT_EDITABLE_ANNOTATIONS_ONLY"] == "1",
                      "Effect context pair requires the full editable route")
        try O.require(observer == "vimage" || (observer == "certify" && !includeResources),
                      "Effect context pair requires common observation and isolated certification")
        process = EffectContextPairDiagnostic(policy: selected, resources: includeResources, observer: observer)
    }
    static func scalar<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    func checkpoint(drawingCheckpoint: [String: Any]) throws {
        try O.require(checkpoints.count < 256, "Effect context checkpoint bound exceeded")
        let workload = try O.required(drawingCheckpoint["workload"] as? String, "Effect workload missing")
        let label = try O.required(drawingCheckpoint["label"] as? String, "Effect stage missing")
        checkpoints.append(["workload": workload, "label": label,
            "effectContext": try Self.scalar(EffectContextConfiguration.process.tracker.snapshot()),
            "rendererStorage": try Self.scalar(RendererStorageConfiguration.process.tracker.snapshot())])
    }
    func write(native: [String: Any], nativeData: Data, drawingData: Data, directory: URL) throws {
        guard native["status"] as? String != "running" else { return }
        let actualPolicy = try EffectContextConfiguration.process.selectedPolicy()
        try O.require(actualPolicy == policy, "Effect context process selection changed")
        let renderer = try RendererStorageConfiguration.process.selectedStrategy()
        let drawing = try DrawingRasterConfiguration.process.selectedStrategy()
        var report: [String: Any] = ["schemaVersion": 1, "status": native["status"] ?? "unknown",
            "comparisonKind": Self.comparisonKind, "effectContextPolicy": actualPolicy.rawValue,
            "productionDefaultPolicy": EffectContextPolicy.productionDefault.rawValue,
            "rendererStorageStrategy": renderer.rawValue, "rendererAutoreleaseScope": renderer.autoreleaseScope,
            "rendererProductionDefaultStrategy": RendererStorageStrategy.productionDefault.rawValue,
            "drawingStrategy": drawing.rawValue, "hashObservation": observer, "resourcesRequested": resources,
            "nativeReportSHA256": SHA256.hash(data: nativeData).map { String(format: "%02x", $0) }.joined(),
            "drawingReportSHA256": SHA256.hash(data: drawingData).map { String(format: "%02x", $0) }.joined(),
            "maximumCheckpoints": 256, "additionalRasterObservations": 0, "additionalMemoryObservations": 0,
            "observationBoundary": "after-existing-drawing-checkpoint",
            "contextOwnershipScope": "one-immutable-process-context",
            "contextInitializationBoundary": "after-first-drawing-memory-before-native-entry", "checkpoints": checkpoints,
            "productDefaultsChanged": false, "privateFrameworkReleaseClaim": false,
            "scope": "Scalar effect context options/calls and native renderer counts at unchanged drawing checkpoints. No retained images, extra raster observations, memory polls, pressure, purge or cache clearing. The per-context render-task memory target is not a process RSS cap or memory remedy claim."]
        for field in ["sourceCommit", "executableSHA256", "executableBytes", "architecture", "processIdentifier"] { report[field] = native[field] }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        try O.require(data.count <= 256 * 1_024, "Effect context evidence exceeds scalar byte bound")
        try data.write(to: directory.appendingPathComponent("effect-context-pair.json"), options: .atomic)
    }
}
