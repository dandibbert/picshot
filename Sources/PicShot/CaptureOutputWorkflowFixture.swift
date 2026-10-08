import AppKit
import PicShotCore

/// Packaged-app acceptance over owned synthetic pixels and temporary storage.
/// Does not request capture permissions, read desktop pixels or touch user defaults.
@MainActor enum CaptureOutputWorkflowFixture {
    static func verify(evidenceDirectory: URL) async throws -> [String: Any] {
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let effectFailure = try await EffectOutputFailureNativeFixture.verify(evidenceDirectory: evidenceDirectory)
        let ratios = try await CaptureRatioNativeFixture.verify(evidenceDirectory: evidenceDirectory.appendingPathComponent("ratios"))
        let decoration = try await EditorOutputDecorationNativeFixture.verify(evidenceDirectory: evidenceDirectory.appendingPathComponent("decoration"))
        let windows = try await MultiWindowCaptureNativeFixture.verify(evidenceDirectory: evidenceDirectory.appendingPathComponent("windows"))
        let pins = try await verifyOriginalPin(evidenceDirectory: evidenceDirectory)
        for value in [effectFailure, ratios, decoration, windows, pins] {
            guard value["status"] as? String == "passed" else { throw failure("A component did not pass") }
        }
        let report: [String: Any] = ["status": "passed", "schemaVersion": 1,
            "sourceCommit": Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "bundlePath": Bundle.main.bundlePath,
            "buildVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "effectOutputFailure": effectFailure, "captureRatios": ratios, "outputDecoration": decoration, "multipleWindows": windows,
            "originalCurrentPin": pins, "realDesktopCaptured": false, "permissionRequested": false,
            "generalPasteboardChanged": false, "standardDefaultsChanged": false,
            "scope": "Owned native controls and synthetic source pixels; physical Retina, live window acquisition, TCC and multiple monitors remain unverified"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidenceDirectory.appendingPathComponent("capture-output-workflow.json"), options: .atomic)
        return report
    }

    private static func verifyOriginalPin(evidenceDirectory: URL) async throws -> [String: Any] {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("PicShot-Output-Pin-" + UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let source = try sample()
        var options = ImageOutputDecoration.none
        options.enabled = true; options.cornerRadius = 6; options.borderEnabled = true
        options.borderWidth = 2; options.shadowEnabled = true; options.shadowBlur = 2
        options.shadowOffsetX = -3; options.shadowOffsetY = 4
        let projected = try ImageOutputDecorationRenderer.project(flattened: source, decoration: options)
        let originalBytes = try rgba(source), currentBytes = try rgba(projected)
        let store = try PinSessionStore(directory: directory)
        let coordinator = session(store)
        defer { try? coordinator.prepareForTermination() }
        let (id, firstProbe) = try addAndInspect(coordinator, original: source, current: projected)
        guard let entry = store.entry(id: id), entry.original.filename != entry.current.filename,
              entry.original.width == source.width, entry.current.width == projected.width else {
            throw failure("Original/current pin assets were conflated")
        }
        try coordinator.prepareForTermination()
        try await released(firstProbe)
        let loadedStore = try PinSessionStore(directory: directory)
        let restored = session(loadedStore)
        defer { try? restored.prepareForTermination() }
        try restored.restoreOnLaunch(enabled: true, isSmoke: false)
        let secondProbe = try inspect(restored, id: id, originalBytes: originalBytes, currentBytes: currentBytes)
        guard let original = loadedStore.image(id: id, original: true), let current = loadedStore.image(id: id),
              try rgba(original) == originalBytes, try rgba(current) == currentBytes,
              try rgba(source) == originalBytes else { throw failure("Pin restoration changed source/current pixels") }
        try original.writePNG(to: evidenceDirectory.appendingPathComponent("pin-undecorated-original.png"))
        try current.writePNG(to: evidenceDirectory.appendingPathComponent("pin-decorated-current.png"))
        try restored.prepareForTermination()
        try await released(secondProbe)
        try files.removeItem(at: directory)
        guard !files.fileExists(atPath: directory.path) else { throw failure("Temporary pin storage remained") }
        return ["status": "passed", "separateAssets": true, "sourcePixelsUnchanged": true,
                "currentPixelsRestoredExactly": true, "controllerReleaseCount": 2,
                "temporaryDirectoryRemoved": true, "userPreferencesChanged": false]
    }
    private static func session(_ store: PinSessionStore) -> PinSessionCoordinator {
        PinSessionCoordinator(store: store, presentWindows: false,
            desktopVisibilityService: PinDesktopVisibilityService(defaults: nil),
            ocrPreferences: PinOCRPreferences(defaults: nil))
    }
    private static func addAndInspect(_ session: PinSessionCoordinator, original: CGImage,
                                      current: CGImage) throws -> (UUID, WeakPin) {
        let id = try session.add(originalImage: original, currentImage: current, title: "Synthetic decorated source")
        guard let controller = session.liveControllers[id], controller.image === original,
              controller.currentImage === current else { throw failure("New pin did not receive both images") }
        return (id, WeakPin(controller))
    }
    private static func inspect(_ session: PinSessionCoordinator, id: UUID, originalBytes: Data,
                                currentBytes: Data) throws -> WeakPin {
        guard let controller = session.liveControllers[id], try rgba(controller.image) == originalBytes,
              try rgba(controller.currentImage) == currentBytes else { throw failure("Restored pin did not receive both assets") }
        return WeakPin(controller)
    }
    private static func released(_ probe: WeakPin) async throws {
        let until = ProcessInfo.processInfo.systemUptime + 3
        while probe.controller != nil && ProcessInfo.processInfo.systemUptime < until {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard probe.controller == nil else { throw failure("Pin controller remained after termination") }
    }
    private final class WeakPin { weak var controller: PinController?; init(_ value: PinController) { controller = value } }
    private static func sample() throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: 48 * 32 * 4)
        for y in 0..<32 { for x in 0..<48 {
            let i = (y * 48 + x) * 4; bytes[i] = UInt8(x * 5); bytes[i + 1] = UInt8(y * 7); bytes[i + 2] = 170
        } }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: 48, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 48 * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw failure("Synthetic source allocation failed") }
        return image
    }
    private static func rgba(_ image: CGImage) throws -> Data {
        var bytes = Data(count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw failure("Pixel inspection allocation failed")
            }
            context.setBlendMode(.copy); context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    private static func failure(_ text: String) -> Error { PicShotError.message("Capture/output workflow: " + text) }
}
