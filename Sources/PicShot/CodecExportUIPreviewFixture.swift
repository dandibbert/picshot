import AppKit
import CryptoKit
import PicShotCodecCore

/// Tiny original synthetic fixture, using the real production signed helper and
/// native export controls. Cached window content is evidence only; this never
/// captures the live desktop, reads the clipboard, or opens a personal file.
@MainActor
enum CodecExportUIPreviewFixture {
    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }
        var report: [String: Any] = ["status": "running", "syntheticSource": true,
            "screenCaptureAttempted": false, "clipboardRead": false, "networkAttempted": false,
            "mockedCodec": false, "sourceWidth": 160, "sourceHeight": 112,
            "snapshotPixelsPerPoint": 1,
            "snapshotBackground": "Effective NSWindow background resolved in its current drawing appearance; cached native content composited above it, evidence only",
            "scope": "Real signed WebP/AVIF dropdown, quality, lossless, alpha controls; byte-derived preview, exclusive same-byte publication, compact native light/dark layout"]
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PicShot-Codec-UI-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let source = try CodecExportResourceFixture.fixture(width: 160, height: 112)
            let sourceDigest = digest(try CodecExportResourceFixture.raster(source))
            var formats: [[String: Any]] = []
            for format in [ImageExportFormat.webp, .avif] {
                let appearance: NSAppearance.Name = format == .webp ? .aqua : .darkAqua
                let mode = format == .webp ? "light" : "dark"
                NSApp.appearance = NSAppearance(named: appearance)
                let change = CodecUIInFlightChange()
                let target = CodecUIWeakExportTarget()
                let controller = try ImageExportController(image: source, suggestedName: "synthetic-codec",
                    bundledEncoder: { snapshot, options in
                        try await ImageExportService.encodeBundled(snapshot: snapshot, options: options,
                            prepare: { frozen, request in
                                try await CodecExportProcessService.shared.prepare(snapshot: frozen, options: request) { fraction in
                                    guard fraction < 1, change.claim() else { return }
                                    let dispatched = DispatchSemaphore(value: 0)
                                    Task { @MainActor in
                                        defer { dispatched.signal() }
                                        do {
                                            guard let current = target.controller, !current.isClosed else { throw failure("Export closed before in-flight change") }
                                            current.accessory.picker.selectItem(at: format.rawValue); try send(current.accessory.picker)
                                            for value in [23.0, 37] { current.accessory.quality.doubleValue = value; try send(current.accessory.quality) }
                                            change.recordSuccess()
                                        } catch { change.recordFailure(error.localizedDescription) }
                                    }
                                    if dispatched.wait(timeout: .now() + 2) != .success { change.recordFailure("Native control dispatch exceeded its fixture deadline") }
                                }
                            })
                    })
                target.controller = controller
                defer { controller.cancelExport() }
                controller.window?.appearance = NSAppearance(named: appearance)
                controller.showWindow(nil); controller.window?.center(); controller.window?.makeKeyAndOrderFront(nil)
                let controls = controller.accessory
                let initialFormat: ImageExportFormat = format == .webp ? .avif : .webp
                controls.picker.selectItem(at: initialFormat.rawValue); try send(controls.picker)
                for value in [18.0, 89, 37] { controls.quality.doubleValue = value; try send(controls.quality) }
                controls.lossless.state = .off; try send(controls.lossless)
                controls.alphaQuality.doubleValue = 61; try send(controls.alphaQuality)
                controls.preserveAlpha.state = .off; try send(controls.preserveAlpha)
                let lossy = try await ready(controller)
                try require(change.succeeded && change.failure == nil, change.failure ?? "Real helper never triggered the in-flight format/quality change")
                try require(lossy.options.format == format && lossy.options.quality == 0.37 &&
                            !lossy.options.lossless && !lossy.options.preserveAlpha && lossy.options.alphaQuality == 0.61,
                            "Native controls did not reach the actual lossy encoder")
                let lossyDecoded = try CodecExportResourceFixture.independentDecode(lossy.data, format: format, width: 160, height: 112)
                let lossyPixels = try CodecExportResourceFixture.raster(lossyDecoded)
                try require(stride(from: 3, to: lossyPixels.count, by: 4).allSatisfy { lossyPixels[$0] == 255 },
                            "Alpha-off native UI result is not opaque")
                controls.lossless.state = .on; try send(controls.lossless)
                controls.preserveAlpha.state = .on; try send(controls.preserveAlpha)
                let artifact = try await ready(controller)
                try require(artifact.options.format == format && artifact.options.lossless && artifact.options.preserveAlpha,
                            "New lossless/alpha request did not replace the old preview")
                try require(!controls.quality.isEnabled && !controls.alphaQuality.isEnabled,
                            "Lossless controls still imply lossy sliders participate")
                try CodecExportProcessService.validateMagic(artifact.data, format: format == .webp ? .webp : .avif)
                let decoded = try CodecExportResourceFixture.independentDecode(artifact.data, format: format, width: 160, height: 112)
                let decodedPixels = try CodecExportResourceFixture.raster(decoded)
                let previewPixels = try CodecExportResourceFixture.raster(artifact.firstPreview)
                let reference = try CodecExportResourceFixture.raster(source)
                try require(previewPixels.count == decodedPixels.count && zip(previewPixels, decodedPixels).allSatisfy { abs(Int($0.0) - Int($0.1)) <= 2 },
                            "Native UI preview is not the independently decoded export")
                try require(reference.count == decodedPixels.count && zip(reference, decodedPixels).allSatisfy { abs(Int($0.0) - Int($0.1)) <= 2 },
                            "Lossless output pixels/alpha differ from synthetic source")
                try require(controller.statusLabel.stringValue.contains("\(artifact.byteCount) 字节") && controller.saveButton.isEnabled,
                            "UI byte count or save state does not match completed codec bytes")
                controller.fitWindow()
                let regular = try ImageExportPreviewFixture.verifyLayout(controller)
                var small: [String: Any] = [:]
                if let screen = controller.window?.screen ?? NSScreen.main,
                   screen.visibleFrame.width >= 580, screen.visibleFrame.height >= 480 {
                    let bounds = CGRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY, width: 580, height: 480)
                    controller.fitWindow(to: bounds)
                    small = try ImageExportPreviewFixture.verifyLayout(controller, visibleFrame: bounds)
                    controller.fitWindow()
                }
                let screenshot = "ui-codec-\(format.filenameExtension)-\(mode).png"
                try snapshot(controller, to: evidenceDirectory.appendingPathComponent(screenshot))
                let output = root.appendingPathComponent("result." + format.filenameExtension)
                try await controller.savePrepared(to: output)
                let saved = try Data(contentsOf: output)
                try require(saved == artifact.data && controller.isClosed, "Saved bytes do not match the reviewed preview")
                let resultName = "codec-ui-result." + format.filenameExtension
                try saved.write(to: evidenceDirectory.appendingPathComponent(resultName), options: .atomic)
                try FileManager.default.removeItem(at: output)
                let state = await CodecExportProcessService.shared.snapshot()
                let metrics = try CodecExportResourceFixture.finished(state, expectSuccess: true)
                formats.append(["format": format.title, "appearance": mode, "encodedBytes": artifact.byteCount,
                    "sha256": digest(saved), "sourceSHA256": sourceDigest, "sourceUnchanged": true,
                    "lossyQuality": lossy.options.quality, "lossyAlphaQuality": lossy.options.alphaQuality,
                    "lossyBytes": lossy.byteCount, "losslessControlsVerified": true, "alphaOffOpaque": true,
                    "inFlightFormatQualityChange": true, "initialFormat": initialFormat.title,
                    "replacementTrigger": "actual signed helper progress; bounded parent dispatch barrier, child may already have exited",
                    "realPixelsAndAlphaVerified": true, "sameByteSave": true,
                    "regularLayout": regular, "smallLayout": small, "screenshot": screenshot,
                    "result": resultName, "childExitConfirmed": metrics.childExitConfirmed,
                    "temporaryDirectoryRemoved": metrics.temporaryDirectoryRemoved])
                try require(digest(try CodecExportResourceFixture.raster(source)) == sourceDigest, "UI export changed source pixels")
                report["formats"] = formats; try write(report, to: evidenceDirectory)
            }
            try require(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty, "UI export left staging")
            report["status"] = "passed"; report["sourceUnchanged"] = true
            report["files"] = ["ui-codec-webp-light.png", "ui-codec-avif-dark.png", "codec-ui-result.webp", "codec-ui-result.avif", "codec-export-ui.json"]
            try write(report, to: evidenceDirectory); return report
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            try? write(report, to: evidenceDirectory); throw error
        }
    }
    private static func ready(_ controller: ImageExportController) async throws -> ImageExportArtifact {
        let deadline = Date().addingTimeInterval(45)
        while controller.latestArtifact == nil && !controller.isClosed && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard let artifact = controller.latestArtifact else { throw failure("Preview unavailable: " + controller.statusLabel.stringValue) }; return artifact
    }
    private static func send(_ control: NSControl) throws {
        guard control.sendAction(control.action, to: control.target) else { throw failure("Native codec control did not dispatch") }
    }
    private static func snapshot(_ controller: ImageExportController, to url: URL) throws {
        guard let window = controller.window, let view = window.contentView else { throw failure("Native window is missing") }
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let width = Int(view.bounds.width.rounded(.up)), height = Int(view.bounds.height.rounded(.up))
        guard width > 0, height > 0, width <= 620, height <= 550,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: width * 4, bitsPerPixel: 32) else { throw failure("Native snapshot allocation exceeded compact bounds") }
        bitmap.size = view.bounds.size
        window.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        guard let cached = bitmap.cgImage,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw failure("Native snapshot composition failed") }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(window.backgroundColor.cgColor); context.fill(bounds); context.draw(cached, in: bounds)
        }
        guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw failure("Native snapshot PNG encoding failed") }
        try png.write(to: url, options: .atomic)
    }
    private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func write(_ value: [String: Any], to directory: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("codec-export-ui.json"), options: .atomic)
    }
    private static func require(_ condition: Bool, _ text: String) throws { if !condition { throw failure(text) } }
    private static func failure(_ text: String) -> Error { PicShotError.message("Native codec UI: " + text) }
}

@MainActor
private final class CodecUIWeakExportTarget { weak var controller: ImageExportController? }

/// One-shot fixture scheduling instrument. All bytes still come from the
/// signed helper; this never substitutes a mock codec or source-only preview.
private final class CodecUIInFlightChange: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false, completed = false
    private var error: String?
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !claimed else { return false }; claimed = true; return true }
    func recordSuccess() { lock.lock(); completed = true; lock.unlock() }
    func recordFailure(_ text: String) { lock.lock(); error = text; lock.unlock() }
    var succeeded: Bool { lock.lock(); defer { lock.unlock() }; return completed }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return error }
}
