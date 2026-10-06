import AppKit
import Foundation

/// Native acceptance for the next offline workflow batch. Inputs and storage
/// are fixture-owned; no screen/device access or OS permission request occurs.
@MainActor enum CaptureExportRecognitionSmokeFixture {
    static func verify(evidenceDirectory: URL, includeResourceCycles: Bool) async throws -> [String: Any] {
        let capture = try await CapturePresetsElementsSmokeFixture.verify(evidenceDirectory: evidenceDirectory)
        let exports = try await ImageExportPreviewFixture.verify(evidenceDirectory: evidenceDirectory,
                                                                 includeResourceCycles: includeResourceCycles)
        let barcodes = try await BarcodeAcceptanceFixture.verify(evidenceDirectory: evidenceDirectory)
        for (name, report) in [("capturePresetsElements", capture), ("imageExport", exports), ("barcodes", barcodes)] {
            guard report["status"] as? String == "passed" else {
                throw PicShotError.message("Native workflow fixture failed: \(name)")
            }
        }
        var settingsRoutes = 0
        let settings = SettingsController(onChange: {}, isSmoke: true,
            onManageCapturePresets: { settingsRoutes += 1 })
        settings.selectCategory(.capture); settings.showWindow(nil)
        defer { settings.close() }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        guard let root = settings.window?.contentView,
              let button = descendants(root).first(where: { $0.identifier?.rawValue == "capture.managePresets" }) as? NSButton else {
            throw PicShotError.message("Capture preset settings entry is missing")
        }
        root.layoutSubtreeIfNeeded()
        let buttonFrame = button.convert(button.bounds, to: root)
        guard root.bounds.contains(buttonFrame), buttonFrame.width > 80, buttonFrame.height >= 16,
              !button.isHiddenOrHasHiddenAncestor else {
            throw PicShotError.message("Capture preset settings action is clipped or hidden")
        }
        button.performClick(nil)
        guard settingsRoutes == 1 else { throw PicShotError.message("Capture preset settings action did not fire exactly once") }
        settings.close()
        let report: [String: Any] = [
            "status": "passed",
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "bundlePath": Bundle.main.bundlePath,
            "screenCaptureStarted": false,
            "permissionRequested": false,
            "externalURLVisited": false,
            "scope": "Synthetic local inputs and native controls; actual AX availability, codec capabilities and barcode decoding are reported separately",
            "settingsPresetRouteVerified": true,
            "settingsPresetButtonWithinWindow": true,
            "capturePresetsElements": capture,
            "imageExport": exports,
            "barcodes": barcodes
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidenceDirectory.appendingPathComponent("capture-export-recognition.json"), options: .atomic)
        return report
    }
}
