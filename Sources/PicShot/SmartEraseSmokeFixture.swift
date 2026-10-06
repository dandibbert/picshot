import AppKit
import Darwin
import PicShotEraseCore

/// Invoked only by the explicit packaged-app smoke path. Exercises the real
/// signed bundle-relative helper, PNG interchange, resource watchdog and job
/// cleanup, rather than importing the inference engine into the main app.
@MainActor
enum SmartEraseSmokeFixture {
    static func verifyPackagedHelper(modelDirectory: URL, evidenceDirectory: URL? = nil) async throws -> [String: Any] {
        let size = 800
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        var clean = pixels
        var mask = Data(repeating: 0, count: size * size)
        for y in 0..<size { for x in 0..<size {
            let index = y * size + x
            let texture = 5 * sin(Double(x) / 20) + 4 * sin(Double(y) / 13)
            clean[index * 4] = UInt8(max(0, min(255, 170 + x / 20 + Int(texture))))
            clean[index * 4 + 1] = UInt8(max(0, min(255, 180 + y / 30 + Int(texture))))
            clean[index * 4 + 2] = UInt8(max(0, min(255, 195 + x / 40 + Int(texture))))
            pixels[index * 4] = clean[index * 4]; pixels[index * 4 + 1] = clean[index * 4 + 1]; pixels[index * 4 + 2] = clean[index * 4 + 2]
            if (350..<450).contains(x), (350..<450).contains(y) {
                pixels[index * 4] = 240; pixels[index * 4 + 1] = 20; pixels[index * 4 + 2] = 30
            }
            if (342..<458).contains(x), (342..<458).contains(y) { mask[index] = 255 }
        } }
        let original = try SmartEraseRaster(width: size, height: size, rgba: pixels)
        let image = try original.image()
        let jobsBefore = try currentParentJobs()
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await SmartEraseProcessService.shared.erase(image: image, mask: mask, modelDirectory: modelDirectory)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let jobsAfter = try currentParentJobs()
        let leftOver = jobsAfter.subtracting(jobsBefore)
        guard leftOver.isEmpty else { throw SmartEraseError.failed("Packaged erase left \(leftOver.count) private job directories after helper exit") }
        let output = try SmartEraseRaster(image: result)
        guard output.width == size, output.height == size else { throw SmartEraseError.invalidOutput }
        var beforeError: Double = 0, afterError: Double = 0, changed = 0, samples = 0
        var outsideMismatches = 0, alphaMismatches = 0
        var insideValues = Set<UInt8>()
        for index in 0..<(size * size) {
            if output.rgba[index * 4 + 3] != pixels[index * 4 + 3] { alphaMismatches += 1 }
            if mask[index] == 0 {
                for channel in 0..<4 { if output.rgba[index * 4 + channel] != pixels[index * 4 + channel] { outsideMismatches += 1 } }
            } else {
                if output.rgba[index * 4] != pixels[index * 4] { changed += 1 }
                insideValues.insert(output.rgba[index * 4])
                for channel in 0..<3 {
                    beforeError += abs(Double(pixels[index * 4 + channel]) - Double(clean[index * 4 + channel]))
                    afterError += abs(Double(output.rgba[index * 4 + channel]) - Double(clean[index * 4 + channel]))
                    samples += 1
                }
            }
        }
        guard outsideMismatches == 0, alphaMismatches == 0, changed >= 10_000,
              insideValues.count > 5, beforeError > 0, afterError < beforeError * 0.5,
              elapsed < SmartEraseLimits.seconds else {
            throw SmartEraseError.failed("Packaged erase fixture failed: outside=\(outsideMismatches), alpha=\(alphaMismatches), changed=\(changed), before=\(beforeError), after=\(afterError), seconds=\(elapsed)")
        }
        if let evidenceDirectory {
            try SmartEraseRaster.png(image).write(to: evidenceDirectory.appendingPathComponent("smart-erase-before.png"), options: .atomic)
            try SmartEraseRaster.png(result).write(to: evidenceDirectory.appendingPathComponent("smart-erase-after.png"), options: .atomic)
        }
        return [
            "status": "passed", "runtime": "signed bundled PicShotEraseHelper / native Core ML CPU+GPU",
            "modelID": SmartEraseModelPack.candidateManifest.id, "inputWidth": size, "inputHeight": size,
            "maskedMAEBefore": beforeError / Double(samples), "maskedMAEAfter": afterError / Double(samples),
            "changedMaskedPixels": changed, "distinctMaskedRedValues": insideValues.count,
            "outsideMaskByteMismatches": outsideMismatches, "alphaMismatches": alphaMismatches,
            "newJobDirectoriesRemaining": leftOver.count, "seconds": elapsed,
            "configuredHelperRSSLimitBytes": SmartEraseLimits.residentBytes,
            "configuredHelperWallLimitSeconds": SmartEraseLimits.seconds,
            "scope": "one successful production helper job; not a forced timeout, crash, cancellation or general leak test"
        ]
    }

    /// Ignore another instance's valid marked jobs, but conservatively include
    /// unreadable/unmarked new job directories so damaged markers cannot hide
    /// a cleanup failure. The check is read-only and never removes a path.
    private static func currentParentJobs() throws -> Set<String> {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var jobs = Set<String>()
        for directory in directories where directory.lastPathComponent.hasPrefix("picshot-erase-") {
            guard UUID(uuidString: String(directory.lastPathComponent.dropFirst("picshot-erase-".count))) != nil else { continue }
            let marker = directory.appendingPathComponent(".picshot-erase-job.json")
            guard let values = try? marker.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= 256,
                  let handle = try? FileHandle(forReadingFrom: marker) else { jobs.insert(directory.lastPathComponent); continue }
            let data = try? handle.read(upToCount: 257); try? handle.close()
            guard let data, data.count <= 256,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["format"] as? String == "PicShotEraseJob-v1",
                  let parent = object["parent"] as? NSNumber else { jobs.insert(directory.lastPathComponent); continue }
            if parent.int32Value == getpid() { jobs.insert(directory.lastPathComponent) }
        }
        return jobs
    }
}
