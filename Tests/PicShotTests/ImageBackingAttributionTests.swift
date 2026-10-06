import XCTest
import Foundation
import Darwin
import CoreGraphics
@testable import PicShot

@MainActor
final class ImageBackingAttributionTests: XCTestCase {
    func testFocusedMatrixIsSevenIsolatedControlsAndFormatExpansionIsExplicit() throws {
        XCTAssertEqual(ImageBackingAttributionFixture.focusedMatrix.count, 7)
        XCTAssertEqual(ImageBackingAttributionFixture.Mode.allCases.map(\.rawValue),
            ["source-create", "snapshot-only", "raster-digest-only", "native-export", "preview-only", "independent-decode-only",
             "full-decode-fresh-data", "full-decode-raster-reused-data", "full-decode-raster-fresh-data", "preview-remove-cache", "preview-fresh-data"])
        XCTAssertEqual(ImageBackingAttributionFixture.supportedFormats.map(\.filenameExtension), ["png", "jpg", "bmp", "pdf", "webp", "avif"])
        let root = FileManager.default.temporaryDirectory
        for cell in ImageBackingAttributionFixture.focusedMatrix {
            XCTAssertNoThrow(try ImageBackingAttributionFixture.validateConfiguration(mode: cell.mode, format: cell.format,
                inputDirectory: cell.mode.isReader ? root : nil))
        }
        for format in ImageBackingAttributionFixture.supportedFormats {
            for mode in [ImageBackingAttributionFixture.Mode.previewOnly, .independentDecodeOnly] {
                XCTAssertNoThrow(try ImageBackingAttributionFixture.validateConfiguration(mode: mode, format: format, inputDirectory: root))
            }
            if !format.usesBundledCodec {
                XCTAssertNoThrow(try ImageBackingAttributionFixture.validateConfiguration(mode: .nativeExport, format: format, inputDirectory: nil))
            }
        }
        XCTAssertThrowsError(try ImageBackingAttributionFixture.validateConfiguration(mode: .sourceCreate, format: .png, inputDirectory: nil))
        XCTAssertThrowsError(try ImageBackingAttributionFixture.validateConfiguration(mode: .previewOnly, format: .png, inputDirectory: nil))
        XCTAssertThrowsError(try ImageBackingAttributionFixture.validateConfiguration(mode: .nativeExport, format: .webp, inputDirectory: nil))
        XCTAssertThrowsError(try ImageBackingAttributionFixture.validateConfiguration(mode: .nativeExport, format: .png, inputDirectory: root))
        XCTAssertThrowsError(try ImageBackingAttributionFixture.validateConfiguration(mode: .independentDecodeOnly, format: .tiff, inputDirectory: root))
    }

    func testCacheLifetimeSelectorsAndLongAVIFProfileAreBounded() throws {
        let root = FileManager.default.temporaryDirectory
        XCTAssertEqual(ImageBackingAttributionFixture.cacheLifetimeMatrix.count, 6)
        for cell in ImageBackingAttributionFixture.cacheLifetimeMatrix {
            XCTAssertTrue(cell.mode.isReader)
            XCTAssertTrue(cell.mode.isCacheLifetimeComparison)
            XCTAssertNoThrow(try ImageBackingAttributionFixture.validateConfiguration(mode: cell.mode, format: cell.format, inputDirectory: root))
        }
        let profile = ImageBackingAttributionFixture.Profile.avifLong
        XCTAssertEqual(profile.width, 768); XCTAssertEqual(profile.height, 576)
        XCTAssertEqual(profile.warmupCycles, 2); XCTAssertEqual(profile.measuredCycles, 48)
        XCTAssertEqual(profile.deadlineSeconds, 480)
        XCTAssertEqual(profile.inputProfile, .installed)
        for mode in [ImageBackingAttributionFixture.Mode.previewOnly, .independentDecodeOnly] {
            XCTAssertNoThrow(try ImageBackingAttributionFixture.validateConfiguration(mode: mode, format: .avif, inputDirectory: root, profile: profile))
            XCTAssertThrowsError(try ImageBackingAttributionFixture.validateConfiguration(mode: mode, format: .png, inputDirectory: root, profile: profile))
        }
        XCTAssertThrowsError(try ImageBackingAttributionFixture.validateConfiguration(mode: .fullDecodeFreshData, format: .avif, inputDirectory: root, profile: profile))
        XCTAssertThrowsError(try ImageBackingAttributionFixture.validateConfiguration(mode: .previewRemoveCache, format: .pdf, inputDirectory: root))
        XCTAssertEqual(ImageBackingAttributionFixture.Profile.installed.measuredCycles, 12)
        XCTAssertEqual(ImageBackingAttributionFixture.Profile.quickTest.measuredCycles, 3)
    }

    /// Uses an image larger than the 4 MiB returned-preview budget. The candidate
    /// still requests a bounded thumbnail; it never replaces this with full decode.
    func testCacheRemovalPreservesRenderedPixelsAndLargeInputPreviewLimits() throws {
        let source = try CodecExportResourceFixture.fixture(width: 1280, height: 960)
        let artifact = try ImageExportService.encode(snapshot: ImageExportSnapshot(image: source), options: ImageExportOptions(format: .png))
        for limits in [ImageExportLimits.standard,
                       ImageExportLimits(maximumSourcePixels: 100_000_000, maximumEncodedBytes: 128 * 1_024 * 1_024,
                                         maximumPages: 200, previewDimension: 1024, maximumPreviewBytes: 4096)] {
            try autoreleasepool {
                let expected = try ImageExportService.preview(data: artifact.data, format: .png, limits: limits)
                let expectedPixels = try CodecExportResourceFixture.raster(expected)
                let actual = try ImageBackingAttributionFixture.previewRemovingCache(data: artifact.data, format: .png, limits: limits)
                XCTAssertEqual(actual.image.width, expected.width); XCTAssertEqual(actual.image.height, expected.height)
                XCTAssertLessThanOrEqual(actual.image.width, limits.previewDimension)
                XCTAssertLessThanOrEqual(actual.image.height, limits.previewDimension)
                XCTAssertLessThanOrEqual(actual.image.bytesPerRow * actual.image.height, limits.maximumPreviewBytes)
                XCTAssertLessThan(actual.image.width, source.width)
                XCTAssertEqual(try CodecExportResourceFixture.raster(actual.image), expectedPixels)
                XCTAssertEqual(actual.removal.api, "CGImageSourceRemoveCacheAtIndex")
                XCTAssertEqual(actual.removal.index, 0); XCTAssertEqual(actual.removal.invocationCount, 1)
                XCTAssertTrue(actual.removal.apiReturn.hasPrefix("void"))
            }
        }
        XCTAssertThrowsError(try ImageBackingAttributionFixture.previewRemovingCache(data: artifact.data, format: .pdf))
        XCTAssertThrowsError(try ImageBackingAttributionFixture.previewRemovingCache(data: Data(), format: .png))
    }

    func testMachFieldExtractionDistinguishesMissingFromReturnedZeroAndRetainsSignedLedgers() throws {
        var vm = task_vm_info_data_t()
        vm.resident_size = 123
        vm.`internal` = 77
        vm.external = 45
        vm.reusable = 0
        vm.phys_footprint = 67
        vm.purgeable_volatile_resident = 12
        vm.ledger_purgeable_nonvolatile = -7
        let count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let standard = ImageBackingTaskVMReading.decode(vm, flavor: task_flavor_t(TASK_VM_INFO), result: KERN_SUCCESS,
            requestedCount: count, returnedCount: count)
        XCTAssertEqual(standard.bytes["resident_size"], 123)
        XCTAssertEqual(standard.bytes["internal"], 77)
        XCTAssertEqual(standard.bytes["external"], 45)
        XCTAssertEqual(standard.bytes["reusable"], 0)
        XCTAssertEqual(standard.bytes["phys_footprint"], 67)
        XCTAssertNil(standard.bytes["purgeable_volatile_resident"], "Standard flavor never queried this field")
        XCTAssertEqual(standard.ledgerBytes["ledger_purgeable_nonvolatile"], -7)
        let purgeable = ImageBackingTaskVMReading.decode(vm, flavor: task_flavor_t(TASK_VM_INFO_PURGEABLE), result: KERN_SUCCESS,
            requestedCount: count, returnedCount: count)
        XCTAssertEqual(purgeable.bytes["purgeable_volatile_resident"], 12)
        XCTAssertEqual(purgeable.bytes["purgeable_volatile_virtual"], 0)
        XCTAssertEqual(purgeable.flavor, "TASK_VM_INFO_PURGEABLE")
        let failed = ImageBackingTaskVMReading.decode(vm, flavor: task_flavor_t(TASK_VM_INFO_PURGEABLE), result: KERN_FAILURE,
            requestedCount: count, returnedCount: count)
        XCTAssertTrue(failed.bytes.isEmpty); XCTAssertTrue(failed.ledgerBytes.isEmpty)
        XCTAssertNil(failed.pageSizeBytes); XCTAssertNil(failed.regionCount)
        XCTAssertNoThrow(try JSONEncoder().encode(failed))
        let offset = try XCTUnwrap(MemoryLayout<task_vm_info_data_t>.offset(of: \.phys_footprint))
        let shortCount = mach_msg_type_number_t(offset / MemoryLayout<natural_t>.size)
        let short = ImageBackingTaskVMReading.decode(vm, flavor: task_flavor_t(TASK_VM_INFO), result: KERN_SUCCESS,
            requestedCount: count, returnedCount: shortCount)
        XCTAssertEqual(short.bytes["resident_size"], 123)
        XCTAssertNil(short.bytes["phys_footprint"])
        XCTAssertTrue(short.ledgerBytes.isEmpty)
        let overreported = ImageBackingTaskVMReading.decode(vm, flavor: task_flavor_t(TASK_VM_INFO), result: KERN_SUCCESS,
            requestedCount: shortCount, returnedCount: count)
        XCTAssertNil(overreported.bytes["phys_footprint"], "Cannot read beyond the requested capacity")
    }

    /// Deterministic representation-width ceiling for the tiny codec matrix:
    /// five cycles * (12 boundaries + one live decode) + three root samples.
    /// Every numeric metric uses its maximum JSON width; the other metadata
    /// receives an additional 64 KiB, checked against each actual native report.
    func testWorstCaseTinyBackingMetadataFits512KiBBudget() throws {
        let count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        func largest(_ flavor: task_flavor_t) throws -> [String: Any] {
            let reading = ImageBackingTaskVMReading.decode(task_vm_info_data_t(), flavor: flavor, result: KERN_SUCCESS,
                requestedCount: count, returnedCount: count)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reading)) as? [String: Any])
            object["bytes"] = reading.bytes.mapValues { _ in UInt64.max }
            object["ledgerBytes"] = reading.ledgerBytes.mapValues { _ in Int64.min }
            object["kernelReturn"] = Int32.min
            object["requestedNaturalCount"] = UInt32.max; object["returnedNaturalCount"] = UInt32.max
            object["pageSizeBytes"] = Int32.max; object["regionCount"] = Int32.max
            object["observedAtUptimeSeconds"] = Double.greatestFiniteMagnitude
            return object
        }
        let backing = ["standard": try largest(task_flavor_t(TASK_VM_INFO)),
                       "purgeable": try largest(task_flavor_t(TASK_VM_INFO_PURGEABLE))]
        let boundary: [String: Any] = ["name": String(repeating: "x", count: 64), "backing": backing,
            "memory": ["residentBytes": UInt64.max, "physicalFootprintBytes": UInt64.max]]
        let cycle: [String: Any] = ["boundaries": Array(repeating: boundary, count: 12),
            "independentDecode": ["backingWhilePixelsLive": backing]]
        let report: [String: Any] = ["warmups": Array(repeating: cycle, count: 2),
            "cycles": Array(repeating: cycle, count: 3), "backingBeforeWarmup": backing,
            "backingBaselineAfterWarmup": backing, "backingHalfSecondAfterFinalCycle": backing,
            "otherMetadataBudget": String(repeating: "x", count: 64 * 1_024)]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        XCTAssertLessThan(data.count, 512 * 1_024)
    }

    func testRoutingRejectsInvalidSelectorsWithoutStartingWork() async throws {
        let root = FileManager.default.temporaryDirectory
        let absent = try await ImageBackingAttributionFixture.runIfRequested(evidenceDirectory: root, environment: [:])
        XCTAssertNil(absent)
        for environment in [
            ["PICSHOT_IMAGE_BACKING_MODE": "unknown"],
            ["PICSHOT_IMAGE_BACKING_MODE": "source-create", "PICSHOT_IMAGE_BACKING_FORMAT": "png"],
            ["PICSHOT_IMAGE_BACKING_MODE": "preview-only", "PICSHOT_IMAGE_BACKING_FORMAT": "webp"],
            ["PICSHOT_IMAGE_BACKING_MODE": "native-export", "PICSHOT_IMAGE_BACKING_FORMAT": "avif"],
            ["PICSHOT_IMAGE_BACKING_MODE": "prepare-inputs", "PICSHOT_IMAGE_BACKING_PROFILE": "unbounded"],
            ["PICSHOT_IMAGE_BACKING_MODE": "source-create", "PICSHOT_CODEC_ATTRIBUTION_MODE": "combined"]
        ] {
            do {
                _ = try await CodecExportAttributionFixture.runIfRequested(evidenceDirectory: root, environment: environment)
                XCTFail("Invalid mixed/unknown workload accepted")
            } catch { XCTAssertTrue(error.localizedDescription.contains("attribution")) }
        }
    }

    /// Exercises native control APIs independently of the fresh-process runner.
    /// Pixel validation here is not part of measured reader-only workloads.
    func testIndependentReaderSupportsExistingNativeFormatsIncludingPDF() throws {
        let source = try CodecExportResourceFixture.fixture(width: 160, height: 120)
        let snapshot = try ImageExportSnapshot(image: source)
        for format in [ImageExportFormat.png, .jpeg, .bmp, .pdf] {
            try autoreleasepool {
                let artifact = try ImageExportService.encode(snapshot: snapshot, options: ImageExportOptions(format: format))
                let image = try ImageBackingAttributionFixture.independentDecode(artifact.data, format: format, width: 160, height: 120)
                let pixels = try CodecExportResourceFixture.raster(image)
                XCTAssertEqual(image.width, 160); XCTAssertEqual(image.height, 120)
                XCTAssertEqual(pixels.count, 160 * 120 * 4)
                XCTAssertTrue(pixels.contains { $0 != 0 })
            }
        }
    }

    /// Small native structural test, not installed-size memory acceptance.
    /// The preparation and every cell run in distinct actual app processes.
    func testFocusedFreshProcessMatrixUsesOnlyItsDeclaredWorkload() async throws {
        let app = try CodecProcessTestApplication.make()
        defer { app.cleanup() }
        let root = app.root.appendingPathComponent("image-backing-evidence", isDirectory: true)
        let preparationDirectory = root.appendingPathComponent("prepared", isDirectory: true)
        let preparation = try await launch(app: app, directory: preparationDirectory, mode: "prepare-inputs")
        XCTAssertEqual(preparation["status"] as? String, "prepared")
        let inputs = try XCTUnwrap(preparation["inputs"] as? [[String: Any]])
        XCTAssertEqual(inputs.compactMap { $0["format"] as? String }, ["png", "jpg", "bmp", "pdf", "webp", "avif"])
        var processIDs = Set([try XCTUnwrap(preparation["processIdentifier"] as? Int)])
        for cell in ImageBackingAttributionFixture.focusedMatrix {
            let directory = root.appendingPathComponent("\(cell.format?.filenameExtension ?? "common")-\(cell.mode.rawValue)", isDirectory: true)
            let report = try await launch(app: app, directory: directory, mode: cell.mode.rawValue,
                format: cell.format?.filenameExtension, inputDirectory: cell.mode.isReader ? preparationDirectory : nil)
            XCTAssertEqual(report["status"] as? String, "observed")
            XCTAssertEqual(report["matrixTier"] as? String, "focused-control")
            XCTAssertTrue(processIDs.insert(try XCTUnwrap(report["processIdentifier"] as? Int)).inserted)
            XCTAssertEqual(report["profile"] as? String, "unit-160x120")
            XCTAssertEqual(report["warmupCycles"] as? Int, 2)
            XCTAssertEqual(report["measuredCycles"] as? Int, 3)
            XCTAssertEqual(report["helperInvocations"] as? Int, 0)
            XCTAssertEqual(report["controllerCreationCount"] as? Int, 0)
            XCTAssertEqual(report["completedWorkloadInvocations"] as? Int, 5)
            XCTAssertEqual(report["ownedTemporaryMediaFiles"] as? Int, 0)
            XCTAssertEqual(report["captureStarted"] as? Bool, false)
            XCTAssertEqual(report["networkAttempted"] as? Bool, false)
            XCTAssertEqual(report["activeControllersAfterAllCycles"] as? Int, 0)
            XCTAssertEqual(report["queuedOrRunningJobsAfterAllCycles"] as? Int, 0)
            let warmups = try XCTUnwrap(report["warmups"] as? [[String: Any]])
            let cycles = try XCTUnwrap(report["cycles"] as? [[String: Any]])
            XCTAssertEqual(warmups.count, 2); XCTAssertEqual(cycles.count, 3)
            let expected = ImageBackingOperationCounts(mode: cell.mode)
            for cycle in warmups + cycles {
                XCTAssertEqual(cycle["fixtureScopeExited"] as? Bool, true)
                let workload = try XCTUnwrap(cycle["workload"] as? [String: Any])
                let operations = try XCTUnwrap(workload["operations"] as? [String: Int])
                XCTAssertEqual(operations["syntheticSources"], expected.syntheticSources)
                XCTAssertEqual(operations["snapshots"], expected.snapshots)
                XCTAssertEqual(operations["rasterDigests"], expected.rasterDigests)
                XCTAssertEqual(operations["nativeExports"], expected.nativeExports)
                XCTAssertEqual(operations["productionPreviews"], expected.productionPreviews)
                XCTAssertEqual(operations["independentDecodes"], expected.independentDecodes)
                XCTAssertEqual(workload["width"] as? Int, 160); XCTAssertEqual(workload["height"] as? Int, 120)
                if cell.mode == .rasterDigestOnly {
                    XCTAssertEqual(workload["rasterBytes"] as? Int, 160 * 120 * 4)
                    XCTAssertEqual((workload["rasterSHA256"] as? String)?.count, 64)
                } else { XCTAssertNil(workload["rasterSHA256"]) }
                let settled = try XCTUnwrap(cycle["settled"] as? [String: Any])
                let standard = try XCTUnwrap(settled["standard"] as? [String: Any])
                XCTAssertEqual(standard["kernelReturn"] as? Int, Int(KERN_SUCCESS))
                let bytes = try XCTUnwrap(standard["bytes"] as? [String: Any])
                XCTAssertNotNil(bytes["resident_size"]); XCTAssertNotNil(bytes["phys_footprint"])
                XCTAssertNil(bytes["purgeable_volatile_resident"])
                let purgeable = try XCTUnwrap(settled["purgeable"] as? [String: Any])
                XCTAssertEqual(purgeable["flavor"] as? String, "TASK_VM_INFO_PURGEABLE")
                // A denied/failed optional flavor remains visible, not a fake zero.
                XCTAssertNotNil(purgeable["kernelReturn"])
                let memory = try XCTUnwrap(cycle["memory"] as? [String: Any])
                XCTAssertGreaterThan(try XCTUnwrap(memory["timerTickCount"] as? Int), 0)
            }
            if cell.mode.isReader {
                XCTAssertEqual(report["persistentSyntheticSourceCount"] as? Int, 0)
                XCTAssertEqual(report["persistentSnapshotCount"] as? Int, 0)
                XCTAssertEqual(report["persistentEncodedInputCount"] as? Int, 1)
                XCTAssertEqual(report["immutableInputUnchanged"] as? Bool, true)
                XCTAssertEqual(report["inputPreparationProcessIdentifier"] as? Int, preparation["processIdentifier"] as? Int)
            }
            for key in ["residentTrend", "physicalFootprintTrend"] {
                let trend = try XCTUnwrap(report[key] as? [String: Any])
                XCTAssertEqual(trend["observationsComplete"] as? Bool, true)
                XCTAssertNil(trend["leakDetected"]); XCTAssertNil(trend["withinEnvelope"])
            }
        }
        XCTAssertEqual(processIDs.count, 8)
    }

    /// Separate-process controls compare the encoded-Data lifetime and optional
    /// decoded-pixel materialization without modifying the production decoder.
    func testCacheLifetimeFreshProcessMatrixAndPostRemovalWebPPixels() async throws {
        let app = try CodecProcessTestApplication.make()
        defer { app.cleanup() }
        let root = app.root.appendingPathComponent("cache-lifetime-evidence", isDirectory: true)
        let preparationDirectory = root.appendingPathComponent("prepared", isDirectory: true)
        let preparation = try await launch(app: app, directory: preparationDirectory, mode: "prepare-inputs")
        let entries = try XCTUnwrap(preparation["inputs"] as? [[String: Any]])
        // Pixel tests run here, outside every measured subprocess. Cache removal
        // must leave its returned image renderable and identical to the baseline.
        for format in [ImageExportFormat.png, .webp] {
            let entry = try XCTUnwrap(entries.first { $0["format"] as? String == format.filenameExtension })
            let filename = try XCTUnwrap(entry["filename"] as? String)
            let data = try Data(contentsOf: preparationDirectory.appendingPathComponent(filename))
            try autoreleasepool {
                let expected = try ImageExportService.preview(data: data, format: format)
                let expectedPixels = try CodecExportResourceFixture.raster(expected)
                let actual = try ImageBackingAttributionFixture.previewRemovingCache(data: data, format: format)
                XCTAssertEqual(try CodecExportResourceFixture.raster(actual.image), expectedPixels)
            }
        }
        var processIDs = Set([try XCTUnwrap(preparation["processIdentifier"] as? Int)])
        for cell in ImageBackingAttributionFixture.cacheLifetimeMatrix {
            let directory = root.appendingPathComponent("\(cell.format!.filenameExtension)-\(cell.mode.rawValue)", isDirectory: true)
            let report = try await launch(app: app, directory: directory, mode: cell.mode.rawValue,
                format: cell.format!.filenameExtension, inputDirectory: preparationDirectory)
            XCTAssertEqual(report["status"] as? String, "observed")
            XCTAssertEqual(report["matrixTier"] as? String, "cache-lifetime-comparison")
            XCTAssertTrue(processIDs.insert(try XCTUnwrap(report["processIdentifier"] as? Int)).inserted)
            XCTAssertEqual(report["completedWorkloadInvocations"] as? Int, 5)
            XCTAssertEqual(report["helperInvocations"] as? Int, 0)
            XCTAssertEqual(report["immutableInputUnchanged"] as? Bool, true)
            XCTAssertEqual(report["persistentSyntheticSourceCount"] as? Int, 0)
            XCTAssertEqual(report["persistentSnapshotCount"] as? Int, 0)
            let cycles = try XCTUnwrap(report["cycles"] as? [[String: Any]])
            let warmups = try XCTUnwrap(report["warmups"] as? [[String: Any]])
            XCTAssertEqual(cycles.count, 3); XCTAssertEqual(warmups.count, 2)
            for cycle in warmups + cycles {
                let workload = try XCTUnwrap(cycle["workload"] as? [String: Any])
                let counts = try XCTUnwrap(workload["operations"] as? [String: Int])
                XCTAssertEqual(counts["encodedFileReads"], cell.mode.usesFreshData ? 1 : 0)
                XCTAssertEqual(counts["rasterDigests"], cell.mode.rasterizesDecodedImage ? 1 : 0)
                XCTAssertEqual(counts["independentDecodes"], cell.mode.isFullDecode ? 1 : 0)
                XCTAssertEqual(counts["cacheRemovalCalls"], cell.mode == .previewRemoveCache ? 1 : 0)
                if cell.mode.rasterizesDecodedImage {
                    XCTAssertEqual(workload["rasterBytes"] as? Int, 160 * 120 * 4)
                    XCTAssertEqual((workload["rasterSHA256"] as? String)?.count, 64)
                    let materialization = try XCTUnwrap(workload["materialization"] as? [String: Any])
                    XCTAssertNotNil(materialization["beforeRaster"]); XCTAssertNotNil(materialization["afterRaster"])
                } else { XCTAssertNil(workload["materialization"]) }
                if cell.mode == .previewRemoveCache {
                    let removal = try XCTUnwrap(workload["cacheRemoval"] as? [String: Any])
                    XCTAssertEqual(removal["api"] as? String, "CGImageSourceRemoveCacheAtIndex")
                    XCTAssertEqual(removal["invocationCount"] as? Int, 1)
                    XCTAssertTrue((removal["apiReturn"] as? String)?.hasPrefix("void") == true)
                    XCTAssertNotNil(removal["beforeSourceLocalRemoval"]); XCTAssertNotNil(removal["afterSourceLocalRemoval"])
                    XCTAssertNil(removal["bytesFreed"])
                } else { XCTAssertNil(workload["cacheRemoval"]) }
            }
        }
        XCTAssertEqual(processIDs.count, 7)
    }

    private func launch(app: CodecProcessTestApplication, directory: URL, mode: String,
                        format: String? = nil, inputDirectory: URL? = nil) async throws -> [String: Any] {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let reportURL = directory.appendingPathComponent("launch.json")
        let log = directory.appendingPathComponent("process.log")
        XCTAssertTrue(files.createFile(atPath: log.path, contents: nil))
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = app.bundleURL.appendingPathComponent("Contents/MacOS/PicShot")
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = output
        var environment = ["HOME": NSHomeDirectory(), "TMPDIR": files.temporaryDirectory.path, "LANG": "en_US.UTF-8",
            "PICSHOT_SMOKE_TEST": "1", "PICSHOT_SMOKE_REPORT": reportURL.path,
            "PICSHOT_IMAGE_BACKING_MODE": mode, "PICSHOT_IMAGE_BACKING_PROFILE": "unit-160x120"]
        environment["PICSHOT_IMAGE_BACKING_FORMAT"] = format
        environment["PICSHOT_IMAGE_BACKING_INPUT_DIRECTORY"] = inputDirectory?.path
        process.environment = environment
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = ProcessInfo.processInfo.systemUptime + 100
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = ProcessInfo.processInfo.systemUptime + 3
            while process.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            if !process.isRunning { process.waitUntilExit() }
            throw CodecProcessTestSupportError.failed("Image backing subprocess exceeded its 100-second deadline; child exit confirmed: \(!process.isRunning)")
        }
        process.waitUntilExit()
        let reportData = try Data(contentsOf: reportURL)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: reportData) as? [String: Any])
        XCTAssertEqual(process.terminationStatus, 0, String(data: reportData, encoding: .utf8) ?? "Failed attribution process")
        XCTAssertLessThan(reportData.count, 512 * 1_024)
        return report
    }
}
