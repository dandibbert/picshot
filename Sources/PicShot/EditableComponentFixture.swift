import AppKit
import CryptoKit
import Darwin
import ImageIO
import PicShotCore

/// Diagnostic component controls only. The complete editable acceptance fixture
/// remains unchanged. Preparation/certification/consumers/verification are fresh processes.
@MainActor enum EditableComponentFixture {
    typealias O = EditableAnnotationFixtureObservation
    static let protocolID = "editable-components-v1"
    static let fixtureSource = "c80e94de9cf712e118009700feacbd707356e0a3"
    static let sourceWidth = 3840, sourceHeight = 2160, warmups = 2, measured = 8
    static let maximumPNGBytes = 40 * 1_024 * 1_024, maximumBundleBytes = 210 * 1_024 * 1_024
    static let maximumOutputBytes = 320 * 1_024 * 1_024, deadlineSeconds = 300.0
    static let roles = ["original", "base", "current"]
    // Independently completed build113, exact complete RGBA bytes. A mismatch is
    // a failed experiment, never an invitation to regenerate an expected value.
    static let expectedHashes = [
        "original": "c7819513b71c4ad1675665feece59747ff9a518db5766c5a8de973f65fdf19c6",
        "base": "b41f79800dd04476e3381aa6fa9da0a2e4f61034729dce3551909a383be83fc9",
        "current": "b8362e485bb0bfc04471d4a9de1eaf01be470fb66f419193fa41966cdcaaaff5"]
    enum Mode: String, CaseIterable {
        case prepare, certify, rawDraw = "raw-draw", pngWrite = "png-write"
        case pngDecodeDraw = "png-decode-draw", editableRenderPin = "editable-render-pin", verifyWrites = "verify-writes"
        var consumer: Bool { [.rawDraw, .pngWrite, .pngDecodeDraw, .editableRenderPin].contains(self) }
    }
    private static var claimed = false
    struct Request { let mode: Mode; let input: URL?; let certificate: URL?; let writes: URL? }
    static func request(_ env: [String: String]) throws -> Request? {
        let prefix = "PICSHOT_EDITABLE_COMPONENT_", keys = Set(env.keys.filter { $0.hasPrefix(prefix) })
        if keys.isEmpty { return nil }
        try O.require(env["PICSHOT_SMOKE_TEST"] == "1", "Component controls require smoke mode")
        try O.require(keys.isSubset(of: [prefix + "MODE", prefix + "INPUT", prefix + "CERTIFICATE", prefix + "WRITES"]), "Unknown component override")
        let mode = try O.required(env[prefix + "MODE"].flatMap(Mode.init(rawValue:)), "Explicit component mode required")
        let conflicting = env.keys.filter { ($0.hasSuffix("_ONLY") || $0.contains("_DIAGNOSTIC") || $0.contains("_ATTRIBUTION_") || $0.hasPrefix("PICSHOT_IMAGE_")) && env[$0] != "0" }
        try O.require(conflicting.isEmpty, "Component controls require an otherwise unselected fresh smoke process")
        func path(_ key: String, required: Bool) throws -> URL? {
            let value = env[prefix + key]
            try O.require((value != nil) == required, "Unexpected/missing component " + key)
            if let value { try O.require(value.hasPrefix("/"), "Component path must be absolute"); return URL(fileURLWithPath: value) }
            return nil
        }
        return try Request(mode: mode, input: path("INPUT", required: mode != .prepare),
            certificate: path("CERTIFICATE", required: mode.consumer || mode == .verifyWrites),
            writes: path("WRITES", required: mode == .verifyWrites))
    }
    static func runIfRequested(evidenceDirectory: URL) async throws -> [String: Any]? {
        guard let request = try request(ProcessInfo.processInfo.environment) else { return nil }
        try O.require(!claimed && evidenceDirectory.isFileURL && NSScreen.main != nil, "Fresh owned native display required")
        claimed = true
        let started = ProcessInfo.processInfo.systemUptime, deadline = started + deadlineSeconds
        let entry = try O.memory(), sampler = EditableAnnotationMemorySampler()
        defer { sampler.stop() }
        var report = try identity()
        report.merge(["protocol": protocolID, "mode": request.mode.rawValue, "status": "running", "entryMemory": entry,
            "diagnosticOnly": true, "fullWorkEquivalent": false, "memoryStabilityAssessed": false,
            "productMemoryRemedyClaim": false, "memoryPressureOrPurgeRequested": false,
            "coreFoundationWeakProbesUsed": false,
            "nativeImageLifetimeScope": "No weak CGImage, CGDataProvider or CGContext probes. Supplied Swift buffer owners have exact release callbacks; ImageIO/rendered native object and backing lifetimes are not proved. Weak probes cover AppKit and Swift controllers/content only.",
            "deadlineSeconds": deadlineSeconds, "fixtureSourceCommit": fixtureSource,
            "warmupCycles": warmups, "measuredCycles": measured,
            "scope": "Unequal-work component controls; excludes full history round trips, changed annotation edits, export, screenshots and original end-to-end acceptance. Self task only; counters overlap, separate task_info calls are not atomic; sampled peaks can miss transients."]){ _, new in new }
        do {
            try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
            if request.mode == .prepare {
                try prepare(directory: evidenceDirectory, report: &report)
            } else {
                var bundle: Input? = try load(request.input!, certificate: request.certificate)
                report["inputManifestSHA256"] = bundle!.manifestHash
                report["inputPreparationProcessIdentifier"] = bundle!.producerPID
                report["certificateSHA256"] = bundle!.certificateHash.map { $0 as Any } ?? NSNull()
                report["retainedInputBytes"] = bundle!.retainedBytes
                report["inputOpenDescriptorsAfterPreparation"] = try O.ownedFileDescriptors(bundle!.directory, identities: []).count
                try O.require(report["inputOpenDescriptorsAfterPreparation"] as? Int == 0, "Prepared input descriptor remained open")
                report["afterInputLoadMemory"] = try O.memory()
                if request.mode == .certify {
                    report["validations"] = try certify(bundle!)
                    report["status"] = "certified"
                } else if request.mode == .verifyWrites {
                    try verifyWrites(bundle!, root: request.writes!, report: &report, deadline: deadline)
                    report["status"] = "verified"
                } else {
                    try await consume(request.mode, input: bundle!, directory: evidenceDirectory, report: &report,
                        sampler: sampler, deadline: deadline)
                    report["status"] = request.mode == .pngWrite ? "observed-pending-output-validation" : "observed"
                }
                bundle = nil
                try await settle(deadline)
                report["retainedInputBytesAfterCleanup"] = 0
            }
            sampler.setPhase("final-cleanup"); sampler.stop()
            report["finalMemory"] = try O.memory(); report["sampledMemory"] = sampler.report
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
            try check(deadline)
            try write(report, evidenceDirectory.appendingPathComponent("component.json"))
            return report
        } catch {
            sampler.stop(); report["status"] = "failed"; report["error"] = error.localizedDescription
            report["sampledMemory"] = sampler.report; report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
            try? write(report, evidenceDirectory.appendingPathComponent("component.json")); throw error
        }
    }
    struct Asset {
        let role: String, width: Int, height: Int, png: Data, raw: Data, pngHash: String, rawHash: String
        var decodedMetadata: [String: Any]? = nil
        var byteCount: Int { width * height * 4 }
    }
    struct Input {
        let assets: [Asset], documentData: Data, document: EditableAnnotationDocument
        let manifestHash: String, certificateHash: String?, producerPID: Int
        let directory: URL
        var retainedBytes: Int { assets.reduce(documentData.count) { $0 + $1.png.count + $1.raw.count } }
        func asset(_ role: String) -> Asset { assets.first { $0.role == role }! }
    }
    private static func prepare(directory: URL, report: inout [String: Any]) throws {
        let result: ([String: Any], [[String: Any]]) = try autoreleasepool {
            let original = try makeSource(width: sourceWidth, height: sourceHeight), base = try derivedBase(original)
            let annotations = marks(width: sourceWidth), crop = viewport(width: sourceWidth)
            let doc = EditableAnnotationDocument(originalAssetID: UUID(), originalPixelWidth: sourceWidth, originalPixelHeight: sourceHeight,
                baseAssetID: UUID(), basePixelWidth: sourceWidth, basePixelHeight: sourceHeight,
                cropViewportInBase: crop, baseProvenance: .derivedRaster, annotations: annotations, outputDecoration: decoration)
            try doc.validate()
            let full = try O.required(ImageEditorRenderer.render(image: base, annotations: annotations), "Preparation render failed")
            let cropped = try O.required(ImageEditorRenderer.crop(image: full, to: crop), "Preparation crop failed")
            let current = try ImageOutputDecorationRenderer.project(flattened: cropped, decoration: decoration)
            try O.require(current.width == 2414 && current.height == 1574, "Actual decorated output extent changed")
            let docData = try EditableAnnotationDocumentCodec.encode(doc)
            try docData.write(to: directory.appendingPathComponent("document.annotations"), options: .withoutOverwriting)
            var entries: [[String: Any]] = [], total = docData.count
            for (role, image) in zip(roles, [original, base, current]) {
                let raw = try canonicalPixels(image) { Data($0) }
                let sha = hash(raw)
                try O.require(sha == expectedHashes[role], "Prepared pixels differ from independently audited build113 " + role)
                let pngURL = directory.appendingPathComponent(role + ".png")
                try image.writePNG(to: pngURL)
                let png = try read(pngURL, maximum: maximumPNGBytes)
                try raw.write(to: directory.appendingPathComponent(role + ".rgba"), options: .withoutOverwriting)
                total += png.count + raw.count; try O.require(total <= maximumBundleBytes, "Preparation bundle exceeds bound")
                entries.append(["role": role, "width": image.width, "height": image.height,
                    "pngFile": role + ".png", "pngBytes": png.count, "pngSHA256": hash(png),
                    "rawFile": role + ".rgba", "rawBytes": raw.count, "rawSHA256": sha,
                    "sourceMetadata": metadata(image), "canonical": canonical(image.width, image.height)])
            }
            var manifest = try identity()
            manifest.merge(["protocol": protocolID, "status": "prepared", "fixtureSourceCommit": fixtureSource,
                "referenceEvidence": "build113 ARM64 run37785905941 certification and paired functional results",
                "assets": entries, "documentFile": "document.annotations", "documentBytes": docData.count,
                "documentSHA256": hash(docData), "totalBytes": total, "originalAndBaseDistinct": true,
                "sourceWidth": sourceWidth, "sourceHeight": sourceHeight, "crop": [480, 240, 2400, 1560],
                "outputWidth": 2414, "outputHeight": 1574, "layerCount": 7]){ _, new in new }
            return (manifest, entries)
        }
        try write(result.0, directory.appendingPathComponent("inputs.json"))
        report["assets"] = result.1; report["status"] = "prepared"
        report["inputManifestSHA256"] = try O.fileDigest(directory.appendingPathComponent("inputs.json"))
    }
    private static func load(_ directory: URL, certificate: URL?) throws -> Input {
        let manifestData = try read(directory.appendingPathComponent("inputs.json"), maximum: 262_144)
        let manifest = try object(manifestData), manifestHash = hash(manifestData)
        try O.require(manifest["protocol"] as? String == protocolID && manifest["status"] as? String == "prepared"
            && manifest["fixtureSourceCommit"] as? String == fixtureSource, "Invalid preparation identity")
        try sameIdentity(manifest)
        let producerPID = try integer(manifest["processIdentifier"])
        try O.require(producerPID != Int(getpid()), "Preparation must be a separate process")
        let entries = try O.required(manifest["assets"] as? [[String: Any]], "Asset list missing")
        try O.require(entries.count == roles.count && entries.compactMap { $0["role"] as? String } == roles, "Asset roles/order differ")
        var assets: [Asset] = [], total = 0
        for entry in entries {
            let role = entry["role"] as! String, width = try integer(entry["width"]), height = try integer(entry["height"])
            try O.require(width == (role == "current" ? 2414 : sourceWidth) && height == (role == "current" ? 1574 : sourceHeight), "Input extent changed")
            try O.require(entry["pngFile"] as? String == role + ".png" && entry["rawFile"] as? String == role + ".rgba", "Unsafe input name")
            let raw = try read(directory.appendingPathComponent(role + ".rgba"), maximum: width * height * 4)
            let png = try read(directory.appendingPathComponent(role + ".png"), maximum: maximumPNGBytes)
            try O.require(raw.count == width * height * 4 && entry["rawBytes"] as? Int == raw.count && entry["pngBytes"] as? Int == png.count,
                "Input byte count changed")
            let rawHash = hash(raw), pngHash = hash(png)
            try O.require(rawHash == expectedHashes[role] && rawHash == entry["rawSHA256"] as? String && pngHash == entry["pngSHA256"] as? String, "Input hash changed")
            let format = try O.required(entry["canonical"] as? [String: Any], "Missing canonical metadata")
            try O.require(NSDictionary(dictionary: format).isEqual(to: canonical(width, height)), "Canonical format changed")
            try inspectPNG(png, width: width, height: height)
            total += png.count + raw.count; try O.require(total <= maximumBundleBytes, "Loaded bundle exceeds bound")
            assets.append(Asset(role: role, width: width, height: height, png: png, raw: raw, pngHash: pngHash, rawHash: rawHash))
        }
        try O.require(manifest["documentFile"] as? String == "document.annotations", "Unsafe document name")
        let documentData = try read(directory.appendingPathComponent("document.annotations"), maximum: 1_048_576)
        try O.require(documentData.count == manifest["documentBytes"] as? Int && hash(documentData) == manifest["documentSHA256"] as? String, "Document identity changed")
        let document = try EditableAnnotationDocumentCodec.decode(documentData)
        try O.require(document.originalPixelWidth == sourceWidth && document.originalPixelHeight == sourceHeight
            && document.basePixelWidth == sourceWidth && document.basePixelHeight == sourceHeight
            && document.cropViewportInBase == viewport(width: sourceWidth) && document.annotations.count == 7
            && document.originalAssetID != document.baseAssetID && document.baseProvenance == .derivedRaster, "Document work changed")
        var certificateHash: String?
        if let certificate {
            let data = try read(certificate, maximum: 2_097_152), cert = try object(data)
            try O.require(cert["protocol"] as? String == protocolID && cert["mode"] as? String == Mode.certify.rawValue
                && cert["status"] as? String == "certified" && cert["inputManifestSHA256"] as? String == manifestHash
                && cert["processIdentifier"] as? Int != producerPID && cert["processIdentifier"] as? Int != Int(getpid()), "Certificate not bound to this input/fresh process")
            try sameIdentity(cert)
            let records = try O.required(cert["validations"] as? [[String: Any]], "Certificate missing validations")
            try O.require(records.count == 4 && records.compactMap { $0["label"] as? String } == ["original", "base", "current", "controller-replay"], "Certificate work incomplete")
            for record in records {
                let role = record["label"] as? String == "controller-replay" ? "current" : record["label"] as? String ?? ""
                let asset = assets.first { $0.role == role }!
                try O.require(record["sha256"] as? String == asset.rawHash && record["comparedBytes"] as? Int == asset.byteCount
                    && record["exact"] as? Bool == true, "Certificate pixel mismatch")
            }
            for i in assets.indices { assets[i].decodedMetadata = records[i]["imageMetadata"] as? [String: Any]
                try O.require(assets[i].decodedMetadata != nil, "Certificate decoded metadata missing") }
            certificateHash = hash(data)
        }
        try O.require(total + documentData.count == manifest["totalBytes"] as? Int && total + documentData.count <= maximumBundleBytes, "Bundle total mismatch")
        return Input(assets: assets, documentData: documentData, document: document,
            manifestHash: manifestHash, certificateHash: certificateHash, producerPID: producerPID, directory: directory)
    }
    private static func certify(_ input: Input) throws -> [[String: Any]] {
        var records: [[String: Any]] = []
        // Independent routes: persisted PNG decode + actual draw, then controller
        // restoration/flattening against preparation's direct renderer reference.
        let decoded = try input.assets.map { try decode($0.png, asset: $0) }
        for (asset, image) in zip(input.assets, decoded) {
            records.append(try independentCompare(image, asset: asset, label: asset.role))
        }
        let payload = EditableCapturePayload(document: input.document, originalImage: decoded[0], baseImage: decoded[1])
        let editor = makeEditor(decoded[1]); defer { editor.close() }
        try editor.restoreEditablePayload(payload)
        let replay = try ImageOutputDecorationRenderer.project(flattened: O.required(editor.annotationCanvas.flattened(), "Certificate controller flatten failed"), decoration: editor.outputDecoration)
        records.append(try independentCompare(replay, asset: input.asset("current"), label: "controller-replay"))
        return records
    }
    // Same complete reference CGContext layout/draw as the established fixture,
    // without its weak CGContext registration. Weak CF probes can abort in ObjC.
    private static func canonicalPixels<Result>(_ image: CGImage,
        _ consume: (UnsafeRawBufferPointer) throws -> Result) throws -> Result {
        try autoreleasepool {
            let context = try context(image.width, image.height)
            context.setBlendMode(.copy); context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let address = try O.required(context.data, "Canonical bytes missing")
            return try withExtendedLifetime(context) {
                try consume(UnsafeRawBufferPointer(start: address, count: image.width * image.height * 4))
            }
        }
    }
    private static func independentCompare(_ image: CGImage, asset: Asset, label: String) throws -> [String: Any] {
        try O.require(image.width == asset.width && image.height == asset.height, "Reference dimensions differ")
        return try canonicalPixels(image) { bytes in
            let equal = asset.raw.withUnsafeBytes { memcmp(bytes.baseAddress!, $0.baseAddress!, bytes.count) == 0 }
            try O.require(equal && O.hash(bytes) == asset.rawHash, "Independent complete pixel comparison failed: " + label)
            return ["label": label, "sha256": O.hash(bytes), "comparedBytes": bytes.count, "exact": equal,
                "width": image.width, "height": image.height, "imageMetadata": metadata(image)]
        }
    }
    private static func consume(_ mode: Mode, input: Input, directory: URL, report: inout [String: Any],
        sampler: EditableAnnotationMemorySampler, deadline: Double) async throws {
        let trackers = Dictionary(uniqueKeysWithValues: input.assets.map { ($0.role, ImageDrawAllocationTracker(maximumAllocations: 10, allocationBytes: $0.byteCount)) })
        let destinationTrackers = Dictionary(uniqueKeysWithValues: input.assets.map { ($0.role, ImageDrawAllocationTracker(maximumAllocations: 1, allocationBytes: $0.byteCount)) })
        var destinations = try Dictionary(uniqueKeysWithValues: input.assets.map { ($0.role, try Destination(asset: $0, tracker: destinationTrackers[$0.role]!)) })
        defer { destinations.values.forEach { $0.close() } }
        let outputRoot = directory.appendingPathComponent("outputs")
        if mode == .pngWrite { try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: false) }
        report["retainedValidationDestinationBytes"] = input.assets.reduce(0) { $0 + $1.byteCount }
        report["afterPreparationMemory"] = try O.memory()
        report["measuredDiskReads"] = 0
        report["diskReadScope"] = "No fixture input/output file content reads during cycles; does not instrument AppKit/framework/OS disk I/O"
        report["nativeImageIOProviderCallbacksObserved"] = false
        report["inputScope"] = "The same full immutable PNG and raw references/document are owned once per consumer; all file handles close before preparation baseline. Three fixed draw destinations are retained equally in every cell. Each nondecode cycle copies three raw providers; decode cell instead creates three ImageIO images. Extra editable render validations remain explicit unequal work."
        var records: [[String: Any]] = [], outputBytes = 0
        records.reserveCapacity(10)
        for ordinal in 1...10 {
            try await settle(deadline)
            let label = ordinal <= warmups ? "warmup-\(ordinal)" : "measured-\(ordinal - warmups)"
            sampler.setPhase(label)
            let lifetime = EditableAnnotationLifetime(), before = try O.memory(), started = ProcessInfo.processInfo.systemUptime
            let temporary = directory.appendingPathComponent("cycle-temp-\(ordinal)")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            var identities = try O.ownedFileIdentities(temporary)
            var cycle: [String: Any]
            do {
                if mode == .editableRenderPin {
                    cycle = try await editableCycle(input, destinations: destinations, trackers: trackers, lifetime: lifetime, deadline: deadline)
                } else {
                    cycle = try autoreleasepool {
                        try simpleCycle(mode, input: input, destinations: destinations, trackers: trackers,
                            temporary: temporary, outputs: outputRoot, ordinal: ordinal, outputBytes: &outputBytes)
                    }
                }
                identities.formUnion(try O.ownedFileIdentities(temporary))
                try FileManager.default.removeItem(at: temporary)
            } catch { try? FileManager.default.removeItem(at: temporary); throw error }
            cycle["afterWorkMemory"] = try O.memory()
            for _ in 0..<3 { try await settle(deadline) }
            try O.require(lifetime.alive == 0 && lifetime.windowContentGraphs == 0, "Cycle retained owned controller/content graph")
            let handles = try O.ownedFileDescriptors(directory, identities: identities)
            let inputHandles = try O.ownedFileDescriptors(input.directory, identities: [])
            try O.require(inputHandles.isEmpty, "Input descriptor survived a measured cycle")
            try O.require(handles.isEmpty && !FileManager.default.fileExists(atPath: temporary.path), "Cycle temporary file/descriptor survived")
            try await inactive(deadline)
            let providerStats = try trackers.mapValues { try object(JSONEncoder().encode($0.snapshot())) }
            for value in trackers.values {
                let s = value.snapshot(), expected = mode == .pngDecodeDraw ? 0 : ordinal
                try O.require(s.allocations == expected && s.releaseCallbacks == expected && s.deallocations == expected
                    && s.activeBytes == 0 && s.callbackSizesMatch, "Owned provider callback/deallocation count mismatch")
            }
            cycle.merge(["ordinal": ordinal, "phase": ordinal <= warmups ? "warmup" : "measured",
                "index": ordinal <= warmups ? ordinal : ordinal - warmups, "beforeMemory": before,
                "afterReleaseMemory": try O.memory(), "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                "ownershipAfterRelease": lifetime.report, "windowContentGraphsAfterRelease": lifetime.windowContentGraphs,
                "providerLifetime": providerStats, "ownedOpenDescriptorsAfter": handles.count, "ownedInputOpenDescriptorsAfter": inputHandles.count,
                "temporaryDirectoryRemoved": true, "activeExportControllersAfter": ImageExportController.activeSessionCount,
                "projectionReservedBytesAfter": EditorOutputProjection.shared.reservedBytes,
                "exportQueueOperationsAfter": ImageExportService.queue.operationCount,
                "measuredDiskReads": 0]) { _, new in new }
            records.append(cycle)
            if ordinal == warmups { report["afterWarmupMemory"] = try O.memory() }
            try check(deadline)
        }
        report["cycles"] = records
        report["afterMeasuredMemory"] = try O.memory()
        report["retainedOutputFileCount"] = mode == .pngWrite ? 30 : 0
        report["retainedOutputBytes"] = outputBytes
        report["outputPixelsValidatedInThisProcess"] = mode != .pngWrite
        report["outputVerificationScope"] = mode == .pngWrite
            ? "All 30 PNG files retained as bounded evidence; no output file read/hash/decode in writer process. A separately launched post-exit verifier must compare every byte against each bound raw reference before matrix completion. Evidence files are distinct from removed per-cycle temporary files."
            : "Every reported draw compares every RGBA byte exactly, including alpha, with independently certified immutable reference."
        destinations.values.forEach { $0.close() }; destinations.removeAll()
        try await settle(deadline)
        report["afterDestinationCleanupMemory"] = try O.memory()
        report["destinationLifetime"] = try destinationTrackers.mapValues { try object(JSONEncoder().encode($0.snapshot())) }
        for tracker in destinationTrackers.values {
            let s = tracker.snapshot()
            try O.require(s.allocations == 1 && s.releaseCallbacks == 1 && s.deallocations == 1 && s.activeBytes == 0 && s.callbackSizesMatch, "Destination owner survived cleanup")
        }
        report["providerLifetime"] = try trackers.mapValues { try object(JSONEncoder().encode($0.snapshot())) }
        report["retainedValidationDestinationBytesAfterCleanup"] = 0
        report["ownedOpenDescriptorsAfterCleanup"] = try O.ownedFileDescriptors(directory, identities: []).count
        try O.require(report["ownedOpenDescriptorsAfterCleanup"] as? Int == 0, "Evidence descriptor survived cleanup")
    }
    private static func simpleCycle(_ mode: Mode, input: Input, destinations: [String: Destination],
        trackers: [String: ImageDrawAllocationTracker],
        temporary: URL, outputs: URL, ordinal: Int, outputBytes: inout Int) throws -> [String: Any] {
        var validations: [[String: Any]] = [], writes: [[String: Any]] = []
        let creationStart = ProcessInfo.processInfo.systemUptime
        let images = try input.assets.map { asset -> CGImage in
            let image = try mode == .pngDecodeDraw ? decode(asset.png, asset: asset) : owned(asset, tracker: trackers[asset.role]!)
            return image
        }
        let creationEnd = try O.memory()
        for (asset, image) in zip(input.assets, images) {
            validations.append(try destinations[asset.role]!.compare(image, asset: asset, label: asset.role))
        }
        let afterValidation = try O.memory(), writeStart = ProcessInfo.processInfo.systemUptime
        if mode == .pngWrite {
            for (asset, image) in zip(input.assets, images) {
                let temporaryFile = temporary.appendingPathComponent(asset.role + ".png")
                try image.writePNG(to: temporaryFile) // Exact production PNG writer.
                let bytes = try safeSize(temporaryFile, maximum: maximumPNGBytes)
                outputBytes += bytes; try O.require(outputBytes <= maximumOutputBytes, "Written evidence exceeded aggregate bound")
                let filename = "cycle-\(ordinal)-\(asset.role).png"
                try FileManager.default.moveItem(at: temporaryFile, to: outputs.appendingPathComponent(filename))
                writes.append(["file": filename, "role": asset.role, "byteCount": bytes,
                    "sourceRawSHA256": asset.rawHash, "width": asset.width, "height": asset.height,
                    "outputPixelVerificationPending": true])
            }
        }
        let afterWrites = try O.memory()
        withExtendedLifetime(images) { }
        return ["validations": validations, "writtenOutputs": writes, "imageCreationCount": 3,
            "pngDecodeCount": mode == .pngDecodeDraw ? 3 : 0, "pngWriteCount": writes.count,
            "editableRestoreCount": 0, "pinApplyCount": 0, "freshRenderCount": 0,
            "creationStartUptime": creationStart, "afterCreationMemory": creationEnd,
            "afterValidationMemory": afterValidation, "afterWritesMemory": afterWrites,
            "writeSeconds": ProcessInfo.processInfo.systemUptime - writeStart]
    }
    private static func editableCycle(_ input: Input, destinations: [String: Destination],
        trackers: [String: ImageDrawAllocationTracker], lifetime: EditableAnnotationLifetime,
        deadline: Double) async throws -> [String: Any] {
        let images = try input.assets.map { asset -> CGImage in
            let image = try owned(asset, tracker: trackers[asset.role]!); return image
        }
        var validations: [[String: Any]] = []
        let afterCreation = try O.memory()
        for (asset, image) in zip(input.assets, images) { validations.append(try destinations[asset.role]!.compare(image, asset: asset, label: asset.role)) }
        let afterValidation = try O.memory()
        let payload = EditableCapturePayload(document: input.document, originalImage: images[0], baseImage: images[1])
        let editor = makeEditor(images[1]); lifetime.editor(editor); defer { editor.close() }
        try editor.restoreEditablePayload(payload)
        try O.require(try EditableAnnotationDocumentCodec.encode(editor.editablePayload().document) == input.documentData, "Restored document changed")
        let current = input.asset("current"), destination = destinations["current"]!
        try autoreleasepool {
            let replay = try ImageOutputDecorationRenderer.project(flattened: O.required(editor.annotationCanvas.flattened(), "Restored controller flatten failed"), decoration: editor.outputDecoration)
            validations.append(try destination.compare(replay, asset: current, label: "restored-render"))
        }
        editor.close()
        let afterRestore = try O.memory()
        let pin = PinController(originalImage: images[0], currentImage: images[2], isModified: true, defaults: nil)
        lifetime.observe(pin, role: "pin")
        if let window = pin.window {
            lifetime.observe(window, role: "window")
            if let content = window.contentView { lifetime.observe(content, role: "content") }
        }
        defer { pin.close() }
        pin.configureEditableCapture(available: true, load: { payload })
        var appliedCount = 0, errorCount = 0
        pin.onAnnotationError = { _ in errorCount += 1 }
        pin.onEditablePixelChange = { image, draft in
            try O.require(try EditableAnnotationDocumentCodec.encode(draft.document) == input.documentData, "Pin apply changed prepared document")
            appliedCount += 1
        }
        pin.showWindow(nil); pin.showAnnotations()
        let pinEditor = try O.required(pin.annotationEditor, "Pin failed to reopen prepared layers")
        lifetime.editor(pinEditor)
        try O.require(try EditableAnnotationDocumentCodec.encode(pinEditor.editablePayload().document) == input.documentData, "Pin restore changed document")
        let afterPinOpen = try O.memory()
        let button = try O.required(descendants(pinEditor.window?.contentView).first { $0.identifier?.rawValue == "editor.applyToPin" } as? NSButton, "Native pin Apply button missing")
        try O.require(button.isEnabled && !button.isHiddenOrHasHiddenAncestor, "Native pin Apply disabled")
        button.performClick(nil)
        while pin.annotationEditor != nil { try await settle(deadline); try O.require(errorCount == 0, "Pin apply failed") }
        try O.require(appliedCount == 1 && errorCount == 0, "Pin Apply count mismatch")
        validations.append(try destination.compare(pin.currentImage, asset: current, label: "pin-applied-current"))
        let afterApply = try O.memory()
        try autoreleasepool {
            let full = try O.required(ImageEditorRenderer.render(image: payload.baseImage, annotations: payload.document.annotations), "Fresh render failed")
            let cropped = try O.required(ImageEditorRenderer.crop(image: full, to: viewport(width: sourceWidth)), "Fresh crop failed")
            let fresh = try ImageOutputDecorationRenderer.project(flattened: cropped, decoration: payload.document.outputDecoration)
            validations.append(try destination.compare(fresh, asset: current, label: "fresh-render"))
        }
        let afterFresh = try O.memory()
        pin.close()
        return ["validations": validations, "writtenOutputs": [[String: Any]](), "imageCreationCount": 3,
            "pngDecodeCount": 0, "pngWriteCount": 0, "editableRestoreCount": 2, "pinApplyCount": appliedCount,
            "freshRenderCount": 1, "documentChanged": false, "persistenceCommitCount": 0,
            "afterCreationMemory": afterCreation, "afterValidationMemory": afterValidation,
            "afterRestoreMemory": afterRestore, "afterPinOpenMemory": afterPinOpen,
            "afterApplyMemory": afterApply, "afterFreshRenderMemory": afterFresh]
    }
    private static func verifyWrites(_ input: Input, root: URL, report: inout [String: Any], deadline: Double) throws {
        let writerData = try read(root.appendingPathComponent("component.json"), maximum: 2_097_152)
        let writer = try object(writerData)
        try sameIdentity(writer)
        try O.require(writer["protocol"] as? String == protocolID && writer["mode"] as? String == Mode.pngWrite.rawValue
            && writer["status"] as? String == "observed-pending-output-validation"
            && writer["inputManifestSHA256"] as? String == input.manifestHash
            && writer["certificateSHA256"] as? String == input.certificateHash
            && writer["processIdentifier"] as? Int != Int(getpid()), "Writer identity/report mismatch")
        let cycles = try O.required(writer["cycles"] as? [[String: Any]], "Missing writer cycles")
        try O.require(cycles.count == 10, "Writer cycle count mismatch")
        let outputRoot = root.appendingPathComponent("outputs")
        let files = try FileManager.default.contentsOfDirectory(atPath: outputRoot.path)
        try O.require(files.count == 30, "Writer output file count mismatch")
        var records: [[String: Any]] = [], total = 0
        for (index, cycle) in cycles.enumerated() {
            let writes = try O.required(cycle["writtenOutputs"] as? [[String: Any]], "Writer output records missing")
            try O.require(cycle["ordinal"] as? Int == index + 1 && writes.count == 3, "Writer cycle identity mismatch")
            for (asset, record) in zip(input.assets, writes) {
                let filename = "cycle-\(index + 1)-\(asset.role).png"
                try O.require(record["file"] as? String == filename && record["role"] as? String == asset.role
                    && record["sourceRawSHA256"] as? String == asset.rawHash, "Written output bound to wrong input")
                let data = try read(outputRoot.appendingPathComponent(filename), maximum: maximumPNGBytes)
                total += data.count; try O.require(total <= maximumOutputBytes && data.count == record["byteCount"] as? Int, "Written output bytes differ")
                var checked = try autoreleasepool { try independentCompare(decode(data, asset: asset), asset: asset,
                    label: filename) }
                checked["fileSHA256"] = hash(data); checked["byteCount"] = data.count
                checked["sourceRawSHA256"] = asset.rawHash; checked["ordinal"] = index + 1; checked["role"] = asset.role
                records.append(checked); try check(deadline)
            }
        }
        try O.require(total == writer["retainedOutputBytes"] as? Int, "Written output aggregate mismatch")
        report["writerReportSHA256"] = hash(writerData)
        report["writerProcessIdentifier"] = writer["processIdentifier"]
        report["validations"] = records; report["verifiedOutputFiles"] = 30; report["verifiedOutputBytes"] = total
        report["memoryComparisonExcluded"] = true
    }
    private static func identity() throws -> [String: Any] {
        let executable = try O.required(Bundle.main.executableURL, "Executable missing")
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unsupported"
        #endif
        return ["sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "executableSHA256": try O.fileDigest(executable), "executableBytes": try safeSize(executable, maximum: 268_435_456),
            "bundlePath": Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path,
            "architecture": architecture, "processIdentifier": Int(getpid()),
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString]
    }
    private static func sameIdentity(_ report: [String: Any]) throws {
        let current = try identity()
        for key in ["sourceCommit", "executableSHA256", "executableBytes", "bundlePath", "architecture", "operatingSystem"] {
            try O.require(String(describing: current[key]!) == String(describing: report[key] ?? NSNull()), "Cross-process identity mismatch: " + key)
        }
    }
    static func canonical(_ width: Int, _ height: Int) -> [String: Any] {
        ["width": width, "height": height, "bytesPerRow": width * 4, "bitsPerComponent": 8, "bitsPerPixel": 32,
            "alphaInfo": CGImageAlphaInfo.premultipliedLast.rawValue,
            "bitmapInfo": CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue,
            "colorSpaceName": "kCGColorSpaceSRGB", "colorSpaceModel": CGColorSpaceModel.rgb.rawValue,
            "colorSpaceICC_SHA256": colorProfileHash, "channelOrder": "RGBA", "includesAllAlphaBytes": true]
    }
    private static var colorProfileHash: String {
        guard let data = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() else { return "missing" }
        return hash(data as Data)
    }
    private static func metadata(_ image: CGImage) -> [String: Any] {
        var result: [String: Any] = ["width": image.width, "height": image.height, "bytesPerRow": image.bytesPerRow,
            "bitsPerComponent": image.bitsPerComponent, "bitsPerPixel": image.bitsPerPixel,
            "alphaInfo": image.alphaInfo.rawValue, "bitmapInfo": image.bitmapInfo.rawValue,
            "colorSpaceName": "unnamed", "colorSpaceModel": -1, "colorSpaceICC_SHA256": "missing",
            "renderingIntent": image.renderingIntent.rawValue, "shouldInterpolate": image.shouldInterpolate]
        if let color = image.colorSpace {
            result["colorSpaceModel"] = color.model.rawValue
            if let name = color.name { result["colorSpaceName"] = name as String }
            if let profile = color.copyICCData() { result["colorSpaceICC_SHA256"] = hash(profile as Data) }
        }
        return result
    }
    private static func inspectPNG(_ data: Data, width: Int, height: Int) throws {
        try O.require(!data.isEmpty && data.count <= maximumPNGBytes, "PNG encoded bound exceeded")
        let source = try O.required(CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), "Invalid PNG")
        let p = try O.required(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], "PNG properties missing")
        try O.require(CGImageSourceGetType(source) as String? == "public.png" && CGImageSourceGetCount(source) == 1
            && p[kCGImagePropertyPixelWidth] as? Int == width && p[kCGImagePropertyPixelHeight] as? Int == height
            && p[kCGImagePropertyDepth] as? Int == 8 && (p[kCGImagePropertyOrientation] as? Int ?? 1) == 1, "PNG dimensions/depth/orientation differ")
    }
    private static func decode(_ data: Data, asset: Asset) throws -> CGImage {
        try inspectPNG(data, width: asset.width, height: asset.height)
        // Same source/cache-immediate options as EditableCaptureAssetStore.read;
        // Data replaces the file URL specifically to exclude measured disk reads.
        let source = try O.required(CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), "PNG source failed")
        let image = try O.required(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary), "Full PNG decode failed")
        try O.require(image.width == asset.width && image.height == asset.height && image.bitsPerComponent == 8
            && image.bitsPerPixel == 32 && image.bytesPerRow <= asset.width * 4 + 256
            && image.colorSpace?.model == .rgb && (image.colorSpace?.name as String?) == (CGColorSpace.sRGB as String),
            "Decoded metadata exceeds certified full-size RGBA scope")
        if let expected = asset.decodedMetadata { try O.require(NSDictionary(dictionary: metadata(image)).isEqual(to: expected), "Decoded metadata differs from certification") }
        return image
    }
    private static func owned(_ asset: Asset, tracker: ImageDrawAllocationTracker) throws -> CGImage {
        let bytes = try OwnedBytes(count: asset.byteCount, data: asset.raw, tracker: tracker)
        let retained = Unmanaged.passRetained(bytes)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: bytes.pointer, size: bytes.count,
            releaseData: { info, _, count in
                guard let info else { return }
                let owner = Unmanaged<OwnedBytes>.fromOpaque(info).takeRetainedValue(); owner.callback(count)
            }) else { retained.release(); throw O.failure("Owned full-size provider allocation failed") }
        return try O.required(CGImage(width: asset.width, height: asset.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: asset.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: asset.role != "current", intent: .defaultIntent), "Owned image failed")
    }
    final class OwnedBytes {
        let pointer: UnsafeMutableRawPointer, count: Int
        private let tracker: ImageDrawAllocationTracker
        init(count: Int, data: Data?, tracker: ImageDrawAllocationTracker) throws {
            try O.require(count > 0 && count <= 33_177_600 && (data == nil || data!.count == count), "Owned raster bound mismatch")
            try tracker.reserve(count); self.count = count; self.tracker = tracker
            pointer = .allocate(byteCount: count, alignment: 64)
            if let data { data.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: count) } }
            else { pointer.initializeMemory(as: UInt8.self, repeating: 0, count: count) }
        }
        func callback(_ count: Int) { tracker.callback(size: count) }
        deinit { pointer.deallocate(); tracker.freed(count) }
    }
    @MainActor final class Destination {
        private var context: CGContext?
        init(asset: Asset, tracker: ImageDrawAllocationTracker) throws {
            let bytes = try OwnedBytes(count: asset.byteCount, data: nil, tracker: tracker)
            let retained = Unmanaged.passRetained(bytes)
            guard let context = CGContext(data: bytes.pointer, width: asset.width, height: asset.height, bitsPerComponent: 8,
                bytesPerRow: asset.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue,
                releaseCallback: { info, _ in
                    guard let info else { return }
                    let owner = Unmanaged<OwnedBytes>.fromOpaque(info).takeRetainedValue(); owner.callback(owner.count)
                }, releaseInfo: retained.toOpaque()) else { retained.release(); throw O.failure("Validation destination failed") }
            context.setBlendMode(.copy); context.interpolationQuality = .none; self.context = context
        }
        func close() { context = nil }
        func compare(_ image: CGImage, asset: Asset, label: String) throws -> [String: Any] {
            let context = try O.required(context, "Destination closed"), pointer = try O.required(context.data, "Destination data missing")
            try O.require(image.width == asset.width && image.height == asset.height, "Actual output dimensions changed")
            let started = ProcessInfo.processInfo.systemUptime, before = try O.memory()
            pointer.initializeMemory(as: UInt8.self, repeating: 0, count: asset.byteCount)
            context.draw(image, in: CGRect(x: 0, y: 0, width: asset.width, height: asset.height)); context.flush()
            let afterDraw = try O.memory()
            let equal = asset.raw.withUnsafeBytes { memcmp(pointer, $0.baseAddress!, asset.byteCount) == 0 }
            let actual = O.hash(UnsafeRawBufferPointer(start: pointer, count: asset.byteCount))
            try O.require(equal && actual == asset.rawHash, "Complete RGBA mismatch: " + label)
            return ["label": label, "sha256": actual, "comparedBytes": asset.byteCount, "exact": equal,
                "width": image.width, "height": image.height, "imageMetadata": metadata(image),
                "beforeDrawMemory": before, "afterDrawMemory": afterDraw, "afterCompareMemory": try O.memory(),
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started]
        }
    }
    private static func makeEditor(_ base: CGImage) -> ImageEditorController {
        ImageEditorController(image: base, onSave: { _ in }, onPin: { _ in }, onOCR: { _ in },
            saveWorkflow: SaveWorkflowPresenter(isSmoke: true), copyAction: { _ in })
    }
    private static func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) }
    }
    private static func inactive(_ deadline: Double) async throws {
        try check(deadline)
        let codec = await CodecExportProcessService.shared.snapshot()
        try O.require(!codec.active && codec.lastJob == nil && ImageExportService.queue.operationCount == 0
            && ImageExportController.activeSessionCount == 0 && !EditorOutputProjection.shared.isBusy
            && EditorOutputProjection.shared.reservedBytes == 0, "Export/projection/helper activity survived")
    }
    private static func settle(_ deadline: Double) async throws {
        try check(deadline)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { autoreleasepool { continuation.resume() } }
        }
        try await Task.sleep(nanoseconds: 60_000_000); await Task.yield(); try check(deadline)
    }
    private static func check(_ deadline: Double) throws {
        try Task.checkCancellation(); try O.require(ProcessInfo.processInfo.systemUptime < deadline, "Component deadline exceeded; launcher bounds native stalls")
    }
    private static func safeSize(_ url: URL, maximum: Int) throws -> Int {
        try O.require(url.isFileURL && url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path, "Unsafe component path")
        var info = stat()
        try O.require(url.path.withCString { lstat($0, &info) } == 0 && (info.st_mode & S_IFMT) == S_IFREG
            && info.st_size > 0 && info.st_size <= maximum, "Component file type/size invalid")
        return Int(info.st_size)
    }
    private static func read(_ url: URL, maximum: Int) throws -> Data {
        let size = try safeSize(url, maximum: maximum)
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        try O.require(descriptor >= 0, "Cannot open bounded component input")
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        try O.require(fstat(descriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_size == size, "Input file changed at open")
        let data = try handle.read(upToCount: size + 1) ?? Data()
        try O.require(data.count == size, "Input length changed while reading"); return data
    }
    private static func integer(_ value: Any?) throws -> Int {
        guard let value = value as? Int, value > 0 else { throw O.failure("Missing positive integer") }; return value
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func object(_ data: Data) throws -> [String: Any] {
        try O.required(JSONSerialization.jsonObject(with: data) as? [String: Any], "Invalid component JSON object")
    }
    private static func write(_ value: [String: Any], _ url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try O.require(data.count <= 2_097_152, "Component report exceeds 2 MiB")
        try data.write(to: url, options: .atomic)
    }

    // Verbatim fixture generators from the held owner; checker binds their bytes.
    private static var decoration: ImageOutputDecoration {
        ImageOutputDecoration(enabled: true, cornerRadius: 8, borderEnabled: true, borderWidth: 2,
            shadowEnabled: true, shadowBlur: 2, shadowOffsetX: 3, shadowOffsetY: 4)
    }
    private static func viewport(width: Int) -> CGRect {
        let s = CGFloat(width) / 640
        return CGRect(x: 80 * s, y: 40 * s, width: 400 * s, height: 260 * s)
    }
    private static func marks(width: Int) -> [ImageAnnotation] {
        let s = CGFloat(width) / 640
        func points(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> [CGPoint] {
            [CGPoint(x: x * s, y: y * s), CGPoint(x: (x + w) * s, y: (y + h) * s)]
        }
        var redaction = ImageAnnotation(tool: .redact, points: points(125, 75, 85, 40), color: CGColor(gray: 0, alpha: 1))
        redaction.rotation = 0.08
        var blur = ImageAnnotation(tool: .blur, points: points(58, 22, 70, 70), lineWidth: 4 * s)
        blur.rotation = 0.11
        var lens = ImageAnnotation(tool: .magnifier, points: points(355, 80, 100, 100), lineWidth: 3)
        lens.magnifierSource = CGRect(x: 555 * s, y: 280 * s, width: 45 * s, height: 40 * s)
        var spotlight = ImageAnnotation(tool: .spotlight, points: points(60, 28, 440, 290))
        spotlight.spotlightDim = 0.23
        let eraser = ImageAnnotation(tool: .eraser, points: [CGPoint(x: 105 * s, y: 100 * s), CGPoint(x: 230 * s, y: 100 * s)], lineWidth: 5 * s)
        let targets = [CGRect(x: 190 * s, y: 195 * s, width: 35 * s, height: 25 * s), CGRect(x: 285 * s, y: 215 * s, width: 35 * s, height: 25 * s)]
        let group = UUID(), addition = UUID()
        let linked = targets.map { rect -> ImageAnnotation in
            var mark = ImageAnnotation(tool: .pixelate, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)], lineWidth: 3 * s)
            mark.mosaicLink = AutomaticMosaicLink(groupID: group, additionID: addition, rootAdditionID: addition,
                target: rect, includedTargets: targets, excludedTargets: [], synchronizes: true)
            return mark
        }
        return [redaction, blur, lens, spotlight, eraser] + linked
    }
    private static func makeSource(width: Int, height: Int) throws -> CGImage {
        let context = try context(width, height)
        for y in stride(from: 0, to: height, by: 16) { for x in stride(from: 0, to: width, by: 16) {
            context.setFillColor(CGColor(srgbRed: Double((x / 16 * 31 + y / 16 * 17) % 251) / 255,
                green: Double((x / 16 * 7 + y / 16 * 23) % 251) / 255,
                blue: Double((x / 16 * 19 + y / 16 * 11) % 251) / 255, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 16, height: 16))
        } }
        return try O.required(context.makeImage(), "Source raster allocation failed")
    }
    private static func derivedBase(_ original: CGImage) throws -> CGImage {
        let context = try context(original.width, original.height)
        context.setBlendMode(.copy); context.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: original.width, height: 3))
        return try O.required(context.makeImage(), "Distinct base allocation failed")
    }
    private static func context(_ width: Int, _ height: Int) throws -> CGContext {
        try O.required(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), "Fixture context allocation failed")
    }
}
