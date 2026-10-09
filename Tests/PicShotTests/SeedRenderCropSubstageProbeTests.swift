import Foundation
import CryptoKit
import XCTest
@testable import PicShot

@MainActor final class SeedRenderCropSubstageProbeTests: XCTestCase {
    typealias Probe = SeedRenderCropSubstageProbe

    private func environment(resources: Bool = false) -> [String: String] {
        var result = [Probe.flag: Probe.kind, "PICSHOT_SMOKE_TEST": "1",
            "PICSHOT_SMOKE_REPORT": "/tmp/substage-unit.json", "PICSHOT_EDITABLE_ANNOTATIONS_ONLY": "1",
            "PICSHOT_DRAWING_RASTER_STRATEGY": "owned-srgb8", "PICSHOT_EFFECT_CONTEXT_POLICY": "reference",
            "PICSHOT_EDITABLE_HASH_DIAGNOSTIC": resources ? "vimage" : "certify"]
        if resources { result["PICSHOT_EDITABLE_ANNOTATION_RESOURCES"] = "1" }
        return result
    }
    private func probe(resources: Bool = false) throws -> Probe {
        Probe(selection: try XCTUnwrap(Probe.selected(environment: environment(resources: resources), includeResources: resources)))
    }
    private func metadata(_ workload: String) -> [String: Any] {
        ["workload": workload, "label": "seed-native-render-crop"]
    }
    private func memory() -> [String: Any] {
        let counters = Dictionary(uniqueKeysWithValues: EditableAnnotationMemorySampler.required.map { ($0, Int64(17)) })
        return ["uptimeSeconds": 123.5, "counters": counters,
            "backingAccounting": ["standard": ["bytes": ["resident_size": 17], "ledgerBytes": ["ledger_tag_graphics_nofootprint": -9]],
                                  "purgeable": ["bytes": ["purgeable_volatile_resident": 17], "ledgerBytes": [:]]]]
    }
    private func record(_ probe: Probe, _ boundary: Probe.Boundary, memory value: [String: Any]? = nil) throws {
        try probe.record(boundary, memory: value ?? memory(), drawing: DrawingRasterSnapshot(),
                         renderer: RendererStorageSnapshot(),
                         effect: EffectContextSnapshot(configuredMemoryTargetMegabytes: nil, configuredCacheIntermediates: false,
                                                       contextOptionCount: 1, contextCount: 1))
    }
    private func native(status: String = "passed") -> [String: Any] {
        ["status": status, "sourceCommit": String(repeating: "a", count: 40),
         "executableSHA256": String(repeating: "b", count: 64), "executableBytes": 12345,
         "architecture": "arm64", "processIdentifier": 123]
    }
    private func fill(_ probe: Probe, resources: Bool = false) throws {
        let selection = try XCTUnwrap(Probe.selected(environment: environment(resources: resources), includeResources: resources))
        for workload in selection.workloads {
            try probe.observeDrawingCheckpoint(metadata(workload))
            for boundary in Probe.Boundary.allCases { try record(probe, boundary) }
        }
    }

    func testAbsentFlagIsNoOpAndFiniteSelectionFixesEveryAxis() throws {
        XCTAssertNil(try Probe.selected(environment: [:], includeResources: false))
        XCTAssertNil(try Probe.selected(environment: ["PICSHOT_SMOKE_TEST": "1"], includeResources: true))
        XCTAssertEqual(Probe.flag, "PICSHOT_SUBSTAGE_PROBE")
        for prefix in ["PICSHOT_DRAWING_RASTER", "PICSHOT_RENDERER_STORAGE", "PICSHOT_EFFECT_CONTEXT"] {
            XCTAssertFalse(Probe.flag.hasPrefix(prefix))
        }
        for resources in [false, true] {
            let selected = try XCTUnwrap(Probe.selected(environment: environment(resources: resources), includeResources: resources))
            XCTAssertEqual(selected.observer, resources ? "vimage" : "certify")
            XCTAssertEqual(selected.maximumCheckpoints, resources ? 24 : 4)
            XCTAssertEqual(selected.workloads.count, resources ? 12 : 2)
            XCTAssertEqual(selected.workloads.first, "functional-small")
            XCTAssertEqual(selected.workloads.last, resources ? "measured-8" : "functional-4k")
        }
    }
    func testInvalidSelectorsRoutesAndPolicyChangesFailClosed() throws {
        for raw in ["", "1", "true", "Seed-render-crop", "seed-render-crop ", "seed-render-crop\n", "seed-render-crop\0", "memory32"] {
            var invalid = environment(); invalid[Probe.flag] = raw
            XCTAssertThrowsError(try Probe.selected(environment: invalid, includeResources: false))
        }
        for key in ["PICSHOT_SUBSTAGE", "PICSHOT_SUBSTAGE_PROBE_EXTRA", "PICSHOT_SUBSTAGE_POLICY"] {
            XCTAssertThrowsError(try Probe.selected(environment: [key: Probe.kind], includeResources: false))
            var invalid = environment(); invalid[key] = Probe.kind
            XCTAssertThrowsError(try Probe.selected(environment: invalid, includeResources: false))
        }
        for key in ["PICSHOT_SMOKE_TEST", "PICSHOT_SMOKE_REPORT", "PICSHOT_EDITABLE_ANNOTATIONS_ONLY",
                    "PICSHOT_DRAWING_RASTER_STRATEGY", "PICSHOT_EFFECT_CONTEXT_POLICY", "PICSHOT_EDITABLE_HASH_DIAGNOSTIC"] {
            var invalid = environment(); invalid.removeValue(forKey: key)
            XCTAssertThrowsError(try Probe.selected(environment: invalid, includeResources: false))
        }
        for (key, value) in [("PICSHOT_SMOKE_TEST", "true"), ("PICSHOT_SMOKE_REPORT", "relative.json"),
                            ("PICSHOT_SMOKE_REPORT", "/tmp/bad\0.json"), ("PICSHOT_EDITABLE_ANNOTATIONS_ONLY", "0"),
                            ("PICSHOT_DRAWING_RASTER_STRATEGY", "reference"), ("PICSHOT_RENDERER_STORAGE_STRATEGY", "native"),
                            ("PICSHOT_RENDERER_STORAGE_STRATEGY", "owned-pooled"), ("PICSHOT_RENDERER_COMPARISON_KIND", "renderer-final-storage"),
                            ("PICSHOT_EFFECT_CONTEXT_POLICY", "memory32"), ("PICSHOT_EDITABLE_HASH_DIAGNOSTIC", "cgcontext"),
                            ("PICSHOT_DRAWING_RASTER_UNKNOWN", "1"), ("PICSHOT_EFFECT_CONTEXT_UNKNOWN", "1"),
                            ("PICSHOT_RENDERER_STORAGE_UNKNOWN", "1"), ("PICSHOT_EDITABLE_ANNOTATION_RESOURCES", "1")] {
            var invalid = environment(); invalid[key] = value
            XCTAssertThrowsError(try Probe.selected(environment: invalid, includeResources: false), key)
        }
        XCTAssertThrowsError(try Probe.selected(environment: environment(), includeResources: true))
        XCTAssertThrowsError(try Probe.selected(environment: environment(resources: true), includeResources: false))
        var invalid = environment(resources: true); invalid["PICSHOT_EDITABLE_HASH_DIAGNOSTIC"] = "certify"
        XCTAssertThrowsError(try Probe.selected(environment: invalid, includeResources: true))
    }
    func testSchemaRawByteBindingsAndCompleteMemoryArePreserved() throws {
        let probe = try probe(); try fill(probe)
        let nativeBytes = Data("native raw\n".utf8), drawingBytes = Data("drawing raw\n".utf8)
        let report = try probe.report(native: native(), nativeData: nativeBytes, drawingData: drawingBytes)
        let points = try XCTUnwrap(report["checkpoints"] as? [[String: Any]])
        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(Set(points[0].keys), Set(["index", "workload", "label", "drawingCheckpointLabel", "memory", "drawing", "rendererStorage", "effectContext"]))
        XCTAssertEqual(points[0]["label"] as? String, "after-native-crop")
        XCTAssertEqual(points[1]["label"] as? String, "after-reference-full-render")
        XCTAssertEqual(points[2]["workload"] as? String, "functional-4k")
        XCTAssertEqual(points[0]["memory"] as? NSDictionary, memory() as NSDictionary)
        for (key, data) in [("nativeReportSHA256", nativeBytes), ("drawingReportSHA256", drawingBytes)] {
            XCTAssertEqual(report[key] as? String, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        for key in ["sourceCommit", "executableSHA256", "executableBytes", "architecture", "processIdentifier"] {
            XCTAssertEqual(String(describing: report[key]!), String(describing: native()[key]!))
        }
        XCTAssertEqual(report["schemaVersion"] as? Int, 1)
        XCTAssertEqual(report["additionalMemoryObservations"] as? Int, 4)
        XCTAssertEqual(report["additionalRasterObservations"] as? Int, 0)
        XCTAssertEqual(report["existingMaterializedCropBoundaryCounterCount"] as? Int, 8)
        XCTAssertEqual(report["existingMaterializedCropBoundaryHasFullBackingFields"] as? Bool, false)
        XCTAssertEqual(report["contextInitializationBoundary"] as? String, "after-first-drawing-memory-before-native-entry")
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]).count, Probe.maximumBytes)
    }
    func testActualFullMemoryDictionaryRoundTripsWithoutLosingBackingFields() throws {
        let probe = try probe(), liveMemory = try EditableAnnotationFixtureObservation.memory()
        try probe.observeDrawingCheckpoint(metadata("functional-small"))
        try record(probe, .afterNativeCrop, memory: liveMemory)
        let report = try probe.report(native: native(status: "failed"), nativeData: Data(), drawingData: Data())
        let points = try XCTUnwrap(report["checkpoints"] as? [[String: Any]])
        XCTAssertEqual(points[0]["memory"] as? NSDictionary, liveMemory as NSDictionary)
        let backing = try XCTUnwrap(liveMemory["backingAccounting"] as? [String: Any])
        XCTAssertEqual(Set(backing.keys), Set(["standard", "purgeable"]))
    }
    func testExactBoundsOrderAndMissingWorkflowRejection() throws {
        for resources in [false, true] {
            let probe = try probe(resources: resources)
            XCTAssertThrowsError(try record(probe, .afterNativeCrop))
            try probe.observeDrawingCheckpoint(metadata("functional-small"))
            XCTAssertThrowsError(try record(probe, .afterReferenceFullRender))
            try record(probe, .afterNativeCrop)
            XCTAssertThrowsError(try record(probe, .afterNativeCrop))
            XCTAssertThrowsError(try probe.report(native: native(), nativeData: Data(), drawingData: Data()))
            try record(probe, .afterReferenceFullRender)
            XCTAssertThrowsError(try record(probe, .afterNativeCrop))
            let complete = try self.probe(resources: resources); try fill(complete, resources: resources)
            XCTAssertEqual(complete.checkpointCount, resources ? 24 : 4)
            XCTAssertThrowsError(try record(complete, .afterNativeCrop))
            XCTAssertNoThrow(try complete.report(native: native(), nativeData: Data(), drawingData: Data()))
        }
    }
    func testExistingDrawingMetadataDoesNotSampleOrRetainObjects() throws {
        final class Sentinel {}
        let probe = try probe()
        weak var released: Sentinel?
        do {
            let sentinel = Sentinel(); released = sentinel
            var input = metadata("functional-small")
            input["memory"] = sentinel; input["drawing"] = sentinel
            try probe.observeDrawingCheckpoint(input)
            XCTAssertEqual(probe.checkpointCount, 0)
        }
        XCTAssertNil(released)
        for _ in 1..<256 { try probe.observeDrawingCheckpoint(metadata("functional-small")) }
        XCTAssertThrowsError(try probe.observeDrawingCheckpoint(metadata("functional-small")))
        XCTAssertEqual(probe.checkpointCount, 0)
    }
    func testMemorySchemaRejectsObjectsMissingBackingAndOversizeMetadata() throws {
        let probe = try probe(); try probe.observeDrawingCheckpoint(metadata("functional-small"))
        var invalid = memory(); invalid.removeValue(forKey: "backingAccounting")
        XCTAssertThrowsError(try record(probe, .afterNativeCrop, memory: invalid))
        invalid = memory(); invalid["backingAccounting"] = ["standard": NSObject(), "purgeable": [:]]
        XCTAssertThrowsError(try record(probe, .afterNativeCrop, memory: invalid))
        invalid = memory(); invalid["counters"] = ["resident_size": Int64(17)]
        XCTAssertThrowsError(try record(probe, .afterNativeCrop, memory: invalid))
        invalid = memory(); invalid["backingAccounting"] = ["standard": [:]]
        XCTAssertThrowsError(try record(probe, .afterNativeCrop, memory: invalid))
        invalid = memory(); invalid["backingAccounting"] = ["standard": String(repeating: "x", count: 16 * 1_024), "purgeable": [:]]
        XCTAssertThrowsError(try record(probe, .afterNativeCrop, memory: invalid))
        XCTAssertEqual(probe.checkpointCount, 0)
    }
    func testRunningWriteDoesNothingAndFinalSidecarIsBounded() throws {
        let probe = try probe(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(Probe.filename)
        try probe.write(native: native(status: "running"), nativeData: Data(), drawingData: Data(), directory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try fill(probe)
        try probe.write(native: native(), nativeData: Data([1]), drawingData: Data([2]), directory: root)
        let data = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(data.count, Probe.maximumBytes)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(decoded["status"] as? String, "passed")
        XCTAssertEqual((decoded["checkpoints"] as? [Any])?.count, 4)
    }
}
