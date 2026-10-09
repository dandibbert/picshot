import Foundation
import CryptoKit

/// Opt-in scalar observations in the existing seed/render/crop interval. This
/// probe owns only JSON metadata and never accepts a raster or render closure.
@MainActor final class SeedRenderCropSubstageProbe {
    typealias O = EditableAnnotationFixtureObservation
    enum Boundary: String, CaseIterable {
        case afterNativeCrop = "after-native-crop"
        case afterReferenceFullRender = "after-reference-full-render"
    }
    struct Selection: Equatable {
        let includeResources: Bool
        let observer: String
        var workloads: [String] {
            ["functional-small", "functional-4k"] + (includeResources
                ? (1...2).map { "warmup-\($0)" } + (1...8).map { "measured-\($0)" } : [])
        }
        var maximumCheckpoints: Int { workloads.count * Boundary.allCases.count }
    }
    static let flag = "PICSHOT_SUBSTAGE_PROBE"
    static let kind = "seed-render-crop"
    static let filename = "seed-render-crop-substage.json"
    static let maximumBytes = 256 * 1_024
    static var process: SeedRenderCropSubstageProbe?
    private let selection: Selection
    private var workload = "entry", drawingLabel = "unobserved"
    private var metadataCheckpointCount = 0
    private var checkpoints: [[String: Any]] = []
    var checkpointCount: Int { checkpoints.count }

    init(selection: Selection) { self.selection = selection }

    /// Pure selector validation: deliberately does not access the process effect
    /// configuration or construct its context before the first drawing sample.
    static func selected(environment: [String: String], includeResources: Bool) throws -> Selection? {
        let keys = environment.keys.filter { $0.hasPrefix("PICSHOT_SUBSTAGE") }
        try O.require(keys.allSatisfy { $0 == flag }, "Unknown substage probe selector")
        guard let raw = environment[flag] else { return nil }
        try O.require(raw == kind && environment["PICSHOT_SMOKE_TEST"] == "1"
            && environment["PICSHOT_EDITABLE_ANNOTATIONS_ONLY"] == "1",
            "Substage probe requires the finite owned editable smoke route")
        let observer = environment["PICSHOT_EDITABLE_HASH_DIAGNOSTIC"] ?? ""
        try O.require(observer == (includeResources ? "vimage" : "certify")
            && environment["PICSHOT_EDITABLE_ANNOTATION_RESOURCES"] == (includeResources ? "1" : nil),
            "Substage probe requires isolated certification or the complete resource workflow")
        try O.require(environment["PICSHOT_DRAWING_RASTER_STRATEGY"] == "owned-srgb8"
            && environment["PICSHOT_RENDERER_STORAGE_STRATEGY"] == nil
            && environment["PICSHOT_RENDERER_COMPARISON_KIND"] == nil
            && environment["PICSHOT_EFFECT_CONTEXT_POLICY"] == "reference",
            "Substage probe fixes owned drawing, native/caller storage and reference effects")
        try O.require(try DrawingRasterConfiguration.selection(environment: environment) == .ownedSRGB8,
                      "Substage drawing selection differs")
        try O.require(try RendererStorageConfiguration.selection(environment: environment) == .native,
                      "Substage renderer selection differs")
        try O.require(try EffectContextConfiguration.selection(environment: environment) == .reference,
                      "Substage effect selection differs")
        return Selection(includeResources: includeResources, observer: observer)
    }
    static func begin(includeResources: Bool) throws {
        process = nil
        guard let selection = try selected(environment: ProcessInfo.processInfo.environment,
                                           includeResources: includeResources) else { return }
        process = SeedRenderCropSubstageProbe(selection: selection)
    }

    /// Existing drawing metadata only. Do not read/retain its memory dictionary,
    /// inspect any raster, sample memory, or initialize a process context here.
    func observeDrawingCheckpoint(_ metadata: [String: Any]) throws {
        try O.require(metadataCheckpointCount < 256, "Substage metadata checkpoint bound exceeded")
        let nextWorkload = try O.required(metadata["workload"] as? String, "Substage workload missing")
        let nextLabel = try O.required(metadata["label"] as? String, "Substage drawing label missing")
        try O.require((nextWorkload == "entry" || selection.workloads.contains(nextWorkload))
            && !nextLabel.isEmpty && nextLabel.utf8.count <= 96, "Substage metadata outside finite workload")
        workload = nextWorkload; drawingLabel = nextLabel; metadataCheckpointCount += 1
    }
    private func requireNext(_ boundary: Boundary) throws {
        try O.require(checkpoints.count < selection.maximumCheckpoints, "Substage memory checkpoint bound exceeded")
        try O.require(drawingLabel == "seed-native-render-crop"
            && workload == selection.workloads[checkpoints.count / 2]
            && boundary == Boundary.allCases[checkpoints.count % 2], "Substage checkpoint missing, duplicated or reordered")
    }
    func checkpoint(_ boundary: Boundary) throws {
        try requireNext(boundary)
        // The existing effect companion initialized its context only after the
        // earliest drawing memory sample, before native entry. These snapshots
        // observe that same process context; they do not warm up any render.
        try O.require(try DrawingRasterConfiguration.process.selectedStrategy() == .ownedSRGB8,
                      "Substage actual drawing selection differs")
        try O.require(try RendererStorageConfiguration.process.selectedStrategy() == .native,
                      "Substage actual renderer selection differs")
        try O.require(try EffectContextConfiguration.process.selectedPolicy() == .reference,
                      "Substage actual effect selection differs")
        let memory = try O.memory()
        try record(boundary, memory: memory, drawing: DrawingRasterConfiguration.process.tracker.snapshot(),
                   renderer: RendererStorageConfiguration.process.tracker.snapshot(),
                   effect: EffectContextConfiguration.process.tracker.snapshot())
    }

    /// Scalar test seam; no retained sampler closure or object references. The
    /// live caller above supplies the entire unmodified O.memory() dictionary.
    func record(_ boundary: Boundary, memory: [String: Any], drawing: DrawingRasterSnapshot,
                renderer: RendererStorageSnapshot, effect: EffectContextSnapshot) throws {
        try requireNext(boundary)
        try O.require(Set(memory.keys) == Set(["uptimeSeconds", "counters", "backingAccounting"])
            && memory["uptimeSeconds"] is Double && memory["counters"] is [String: Int64]
            && memory["backingAccounting"] is [String: Any]
            && JSONSerialization.isValidJSONObject(memory), "Substage requires complete scalar memory metadata")
        let counters = try O.required(memory["counters"] as? [String: Int64], "Substage counters missing")
        try O.require(Set(counters.keys) == Set(EditableAnnotationMemorySampler.required), "Substage counters incomplete")
        let backing = try O.required(memory["backingAccounting"] as? [String: Any], "Substage backing missing")
        try O.require(Set(backing.keys) == Set(["standard", "purgeable"]), "Substage full backing flavors missing")
        let bytes = try JSONSerialization.data(withJSONObject: memory)
        try O.require(bytes.count <= 16 * 1_024, "Substage memory metadata byte bound exceeded")
        checkpoints.append(["index": checkpoints.count + 1, "workload": workload, "label": boundary.rawValue,
            "drawingCheckpointLabel": drawingLabel, "memory": memory,
            "drawing": try EffectContextPairDiagnostic.scalar(drawing),
            "rendererStorage": try EffectContextPairDiagnostic.scalar(renderer),
            "effectContext": try EffectContextPairDiagnostic.scalar(effect)])
    }
    func report(native: [String: Any], nativeData: Data, drawingData: Data) throws -> [String: Any] {
        if native["status"] as? String == "passed" {
            try O.require(checkpoints.count == selection.maximumCheckpoints, "Substage full workflow checkpoints missing")
        }
        var result: [String: Any] = ["schemaVersion": 1, "status": native["status"] ?? "unknown",
            "probeKind": Self.kind, "diagnosticOnly": true,
            "drawingStrategy": "owned-srgb8", "rendererStorageStrategy": "native", "rendererAutoreleaseScope": "caller",
            "effectContextPolicy": "reference", "productionDefaultPolicy": EffectContextPolicy.productionDefault.rawValue,
            "hashObservation": selection.observer, "resourcesRequested": selection.includeResources,
            "nativeReportSHA256": SHA256.hash(data: nativeData).map { String(format: "%02x", $0) }.joined(),
            "drawingReportSHA256": SHA256.hash(data: drawingData).map { String(format: "%02x", $0) }.joined(),
            "maximumCheckpoints": selection.maximumCheckpoints, "checkpointsPerWorkflow": 2,
            "additionalMemoryObservations": checkpoints.count, "additionalRasterObservations": 0,
            "metadataCheckpointCount": metadataCheckpointCount, "maximumMetadataCheckpoints": 256,
            "contextInitializationBoundary": "after-first-drawing-memory-before-native-entry",
            "memoryObservationKind": "complete-O.memory-dictionary",
            "existingMaterializedCropBoundary": "reference-crop.before",
            "existingMaterializedCropBoundaryHasFullBackingFields": false,
            "existingMaterializedCropBoundaryCounterCount": 8,
            "productDefaultsChanged": false, "privateFrameworkReleaseClaim": false, "checkpoints": checkpoints,
            "scope": "Two additional logical memory observations per unchanged full workflow. Each O.memory reading uses non-atomic TASK_VM_INFO and TASK_VM_INFO_PURGEABLE calls; scalar dictionary overhead remains in later endpoints. The existing reference-crop.before hash observation follows reference crop materialization and has only eight counters, without full backing fields. No new raster reads, retained images/providers/closures, pools, decoding changes, sleeps, cache clearing, pressure or purge. These endpoints localize intervals, not private framework ownership or a memory remedy."]
        for field in ["sourceCommit", "executableSHA256", "executableBytes", "architecture", "processIdentifier"] {
            result[field] = native[field]
        }
        return result
    }
    func write(native: [String: Any], nativeData: Data, drawingData: Data, directory: URL) throws {
        guard native["status"] as? String != "running" else { return }
        let report = try report(native: native, nativeData: nativeData, drawingData: drawingData)
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        try O.require(data.count <= Self.maximumBytes, "Substage evidence exceeds scalar byte bound")
        try data.write(to: directory.appendingPathComponent(Self.filename), options: .atomic)
    }
}
