import AVFoundation
import Foundation
import Darwin

/// Standalone verification executable, never linked into PicShot. Compile with
/// the existing CPicShotCodecs bridge/header and pinned static codec libraries.
/// WebPAnimDecoder's borrowed raster is consumed before the next Next call.
@main
struct RecordingInputExportValidator {
    typealias Oracle = RecordingInputExportOracle
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "Usage: RecordingInputExportValidator EVIDENCE_DIRECTORY SOURCE_COMMIT", code: 2)
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let expectedCommit = CommandLine.arguments[2]
        try Oracle.require(expectedCommit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
                           "Expected source commit must be a full SHA-1")
        let output = root.appendingPathComponent(Oracle.independentReportName)
        try Oracle.require(!FileManager.default.fileExists(atPath: output.path), "Refusing to replace independent evidence")
        var report: [String: Any] = ["schemaVersion": 1, "status": "running", "sourceCommit": expectedCommit,
            "decoder": "AVAssetReader / ImageIO GIF / PSCodecWebPAnimationOpen + PSCodecAnimationNext",
            "webPDecoder": "PSCodecAnimationNext", "imageIOUsedForWebP": false,
            "libwebpVersion": String(cString: PSCodecVersion(UInt32(PS_CODEC_WEBP))),
            "maximumRGBABytesPerFrame": Oracle.width * Oracle.height * 4,
            "maximumMediaBytes": Oracle.maximumFileBytes, "maximumReportBytes": Oracle.maximumReportBytes,
            "maximumFramesPerAnimation": Oracle.animationFrames, "cooperativeDeadlineSeconds": 60,
            "frameStorage": "sequential current decoder raster plus one selected-MP4 reference; scalar comparisons only",
            "scope": "synthetic baked input effects, orientation, selected timing and anchors; no physical capture/global-input/region-relocation claim"]
        let began = ProcessInfo.processInfo.systemUptime, deadline = began + 60
        do {
            let manifestURL = root.appendingPathComponent(Oracle.reportName)
            let manifest = try read(manifestURL)
            try Oracle.require(manifest["status"] as? String == "exported-awaiting-independent-validation"
                && manifest["sourceCommit"] as? String == expectedCommit
                && manifest["sourcePreserved"] as? Bool == true
                && manifest["original159ReportPreserved"] as? Bool == true,
                               "Installed derived fixture is incomplete or source binding differs")
            let original = try read(root.appendingPathComponent("recording-input.json"))
            try Oracle.require(original["status"] as? String == "passed" && original["sourceCommit"] as? String == expectedCommit,
                               "Original input evidence did not pass for the selected source")
            let sourceURL = root.appendingPathComponent("recording-input.mp4")
            let sourceHash = try Oracle.hash(sourceURL)
            try Oracle.require(manifest["sourceSHA256"] as? String == sourceHash, "Original source bytes differ from installed fixture")
            guard let exports = manifest["exports"] as? [[String: Any]], exports.count == Oracle.mediaNames.count else {
                throw NSError(domain: "Missing installed outputs", code: 1)
            }
            for (item, name) in zip(exports, Oracle.mediaNames) {
                try Oracle.require(item["file"] as? String == name && item["sha256"] as? String == Oracle.hash(root.appendingPathComponent(name)),
                                   "Installed output hash/order differs: \(name)")
            }
            let source = try await Oracle.movie(sourceURL, selected: false, deadline: deadline)
            let selectedURL = root.appendingPathComponent(Oracle.mediaNames[0])
            let selected = try await Oracle.movie(selectedURL, selected: true, source: source, deadline: deadline)
            report["sourceSHA256"] = sourceHash
            report["sourceFrames"] = source.frameCount; report["selectedFrames"] = selected.frameCount
            report["selectedDurationSeconds"] = selected.duration; report["selectedPacketEndSeconds"] = selected.packetEnd
            report["gif"] = try Oracle.object(Oracle.gif(root.appendingPathComponent(Oracle.mediaNames[1]),
                selectedURL: selectedURL, selected: selected, deadline: deadline))
            report["webpLossless"] = try Oracle.object(webp(root.appendingPathComponent(Oracle.mediaNames[2]),
                selectedURL: selectedURL, selected: selected, format: .webpLossless, deadline: deadline))
            report["webpLossy"] = try Oracle.object(webp(root.appendingPathComponent(Oracle.mediaNames[3]),
                selectedURL: selectedURL, selected: selected, format: .webpLossy, deadline: deadline))
            report["verifiedLoopCounts"] = ["gif": 0, "webpLossless": 0, "webpLossy": 0]
            // Bind the reader result to the exact application evidence, including
            // cancellation/process metrics, instead of trusting names alone.
            report["fixtureReportSHA256"] = try Oracle.hash(manifestURL)
            report["mediaHashes"] = try Dictionary(uniqueKeysWithValues: Oracle.mediaNames.map { ($0, try Oracle.hash(root.appendingPathComponent($0))) })
            try Oracle.require(try Oracle.hash(sourceURL) == sourceHash, "Independent validation changed source bytes")
            report["sourcePreserved"] = true
            report["status"] = "passed"
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - began
            try Oracle.write(report, to: output)
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - began
            try? Oracle.write(report, to: output)
            throw error
        }
    }
    private static func read(_ url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Oracle.boundedData(url, maximum: Oracle.maximumReportBytes)) as? [String: Any]
        else { throw NSError(domain: "Invalid input-export JSON", code: 1) }
        return object
    }
    static func webp(_ url: URL, selectedURL: URL, selected: Oracle.Movie,
                     format: Oracle.Format, deadline: Double) throws -> [Oracle.Comparison] {
        let bytes = try Oracle.boundedData(url)
        var error = PSCodecError()
        let animation = bytes.withUnsafeBytes { raw in
            PSCodecWebPAnimationOpen(raw.bindMemory(to: UInt8.self).baseAddress, UInt64(raw.count),
                UInt64(Oracle.width * Oracle.height), UInt32(Oracle.animationFrames), UInt64(Oracle.width * Oracle.height * 4), &error)
        }
        guard let animation else { throw NSError(domain: "Native WebP animation open failed", code: Int(error.code)) }
        defer { PSCodecAnimationFree(animation) }
        try Oracle.require(PSCodecAnimationWidth(animation) == Oracle.width && PSCodecAnimationHeight(animation) == Oracle.height
            && PSCodecAnimationFrameCount(animation) == Oracle.animationFrames && PSCodecAnimationLoopCount(animation) == 0
            && PSCodecAnimationDurationMS(animation) == 2_050, "Native WebP canvas/frame count/duration/looping differs")
        let generator = Oracle.generator(selectedURL)
        defer { generator.cancelAllCGImageGeneration() }
        var frames: [Oracle.Comparison] = []
        for index in 0..<Oracle.animationFrames {
            try autoreleasepool {
                try Oracle.check(deadline)
                var pixels: UnsafePointer<UInt8>?, count: UInt64 = 0, duration: UInt32 = 0
                let status = PSCodecAnimationNext(animation, &pixels, &count, &duration, &error)
                try Oracle.require(status == PS_CODEC_OK && count == Oracle.width * Oracle.height * 4 && pixels != nil,
                                   "Native WebP frame \(index) did not fully decode")
                guard let pixels else { throw NSError(domain: "Missing WebP raster", code: 1) }
                let raster = UnsafeBufferPointer(start: pixels, count: Int(count))
                try Oracle.require(stride(from: 3, to: raster.count, by: 4).allSatisfy { raster[$0] == 255 },
                                   "Native WebP acquired transparency")
                frames.append(try Oracle.compareAnimation(raster, index: index, actualDelayMS: Int(duration), format: format,
                    generator: generator, selected: selected, deadline: deadline))
            }
        }
        var extra: UnsafePointer<UInt8>?, count: UInt64 = 0, duration: UInt32 = 0
        try Oracle.require(PSCodecAnimationNext(animation, &extra, &count, &duration, &error) == PS_CODEC_END
            && extra == nil && count == 0 && duration == 0, "WebP decoder did not reach exact end")
        try Oracle.verifyTimeline(frames)
        return frames
    }
}
