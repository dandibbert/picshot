import AppKit
import CryptoKit

/// Sequential owned-window acceptance for the three annotation modules.
/// No live capture, external input, clipboard, model or network is involved.
@MainActor
enum AnnotationDetailAcceptanceFixture {
    static func verify(evidenceDirectory: URL, includeResourceCycles: Bool = true) async throws -> [String: Any] {
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let reportURL = evidenceDirectory.appendingPathComponent("annotation-details.json")
        var report: [String: Any] = [
            "schemaVersion": 1, "status": "running", "bundlePath": Bundle.main.bundlePath,
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "buildVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "screenCaptureStarted": false, "permissionRequests": false, "networkUsed": false,
            "globalInputPosted": false, "generalPasteboardUsed": false, "standardDefaultsWritten": false,
            "physicalRetinaVerified": false, "processMemoryStabilityVerified": false,
            "includeResourceCycles": includeResourceCycles,
            "scope": "Sequential native controls and owned NSEvents over authored 1x images; exact module pixel/PNG, undo/cancel and tracked UI release checks. Full runs add a separate bounded 2+12 direct-vector render/close resource observation. Not live desktop, physical Retina, sustained process-memory or whole-system stability evidence."
        ]
        func write() throws {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: reportURL, options: .atomic)
        }
        try write()
        do {
            let freehand = try await AnnotationFreehandPreviewFixture.verify(evidenceDirectory: evidenceDirectory.appendingPathComponent("freehand"))
            guard freehand["status"] as? String == "passed" else { throw PicShotError.message("Freehand native checks did not pass") }
            report["freehand"] = freehand; try write()
            let textLine = try await AnnotationTextLinePreviewFixture.verify(evidenceDirectory: evidenceDirectory.appendingPathComponent("text-line"))
            guard textLine["status"] as? String == "passed" else { throw PicShotError.message("Text/line native checks did not pass") }
            report["textLine"] = textLine; try write()
            let value = try await NumberedCalloutAcceptanceFixture.verify(evidenceDirectory: evidenceDirectory.appendingPathComponent("callouts"))
            guard value.status == "passed" else { throw PicShotError.message("Numbered callout native checks did not pass") }
            report["callouts"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
            if includeResourceCycles {
                report["resourceEvidence"] = try await AnnotationDetailResourceFixture.verify()
            } else {
                report["resourceEvidence"] = ["status": "not-run", "reason": "includeResourceCycles=false; functional evidence only",
                    "warmupCycles": 0, "completedMeasuredCycles": 0, "completedRenderCycles": 0]
            }
            var hashes: [String: String] = [:]
            for (folder, child) in [("freehand", freehand), ("text-line", textLine), ("callouts", report["callouts"] as? [String: Any] ?? [:])] {
                guard let files = child["files"] as? [String], !files.isEmpty, files.count <= 64 else {
                    throw PicShotError.message("Annotation evidence file inventory is invalid")
                }
                for file in files {
                    guard !file.isEmpty, file == URL(fileURLWithPath: file).lastPathComponent,
                          file != ".", file != "..", file.hasSuffix(".png") || file.hasSuffix(".json") else {
                        throw PicShotError.message("Annotation evidence path is invalid")
                    }
                    let url = evidenceDirectory.appendingPathComponent(folder).appendingPathComponent(file)
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true,
                          let size = values.fileSize, size > 0, size <= 20 * 1024 * 1024 else {
                        throw PicShotError.message("Annotation evidence file exceeds its bound")
                    }
                    let data = try Data(contentsOf: url)
                    hashes[folder + "/" + file] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }
            }
            report["fileSHA256"] = hashes
            report["status"] = "passed"; try write()
            return report
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            try? write(); throw error
        }
    }
}
