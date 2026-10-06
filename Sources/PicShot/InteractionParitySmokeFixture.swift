import AppKit
import Foundation

/// Installed-bundle acceptance of reachable native interaction paths. Inputs
/// are authored fixtures; this never requests screen or device permission.
@MainActor enum InteractionParitySmokeFixture {
    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        let paths = try await AnnotationPathsPreviewFixture.verify(evidenceDirectory: evidenceDirectory)
        let scroll = try await ScrollSequenceSmokeFixture.verify(evidenceDirectory: evidenceDirectory)
        let text = try await PinTextSelectionSmokeFixture.verify(evidenceDirectory: evidenceDirectory)
        for (name, report) in [("annotationPaths", paths), ("scrollSequence", scroll), ("pinTextSelection", text)] {
            guard report["status"] as? String == "passed" else {
                throw PicShotError.message("Native interaction fixture failed: \(name)")
            }
        }
        let report: [String: Any] = [
            "status": "passed",
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "bundlePath": Bundle.main.bundlePath,
            "screenCaptureStarted": false,
            "permissionRequested": false,
            "scope": "Native controls and synthetic image/input fixtures; no live desktop, real scrolling target or external drag destination",
            "annotationPaths": paths,
            "scrollSequence": scroll,
            "pinTextSelection": text
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidenceDirectory.appendingPathComponent("interaction-parity.json"), options: .atomic)
        return report
    }
}
