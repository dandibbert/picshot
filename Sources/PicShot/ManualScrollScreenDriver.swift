import AppKit
import CoreGraphics
import CryptoKit
import ScreenCaptureKit
import PicShotCore

/// Passive screen sampling only. This class contains no input emission or Accessibility API.
/// The one pending image is released whenever sampling stops, and committed PNGs belong to
/// ScrollCaptureController. Injected providers exercise the same stability/acceptance path.
@MainActor
final class ManualScrollScreenDriver: ManualScrollDriver {
    struct Target: Equatable {
        let pid: pid_t
        let windowID: CGWindowID
        let bounds: CGRect
    }

    let displayID: CGDirectDisplayID
    let displayBounds: CGRect
    let screenSize: CGSize
    private(set) var region: CGRect
    private(set) var pendingImage: CGImage?
    private(set) var target: Target?
    private var expectedPixelSize: CGSize?
    private var displayPixelSize: CGSize?
    private let permission: () throws -> Void
    private let validate: (() throws -> Void)?
    private let provider: (() async throws -> CGImage)?
    private let accept: (CGImage) async throws -> ManualScrollSample
    private var invalidated = false
    private let observationStrategy: ManualScrollObservationStrategy
    private var reusableObservation: ManualScrollReusableObservation?
    private var vImageObservation: ManualScrollVImageObservation?

    var targetPoint: CGPoint { CGPoint(x: displayBounds.minX + region.midX, y: displayBounds.minY + region.midY) }
    var pixelSize: CGSize? { expectedPixelSize }

    init(displayID: CGDirectDisplayID, region: CGRect, screenSize: CGSize,
         expectedPixelSize: CGSize? = nil, lockedTarget: Target? = nil,
         accept: @escaping (CGImage) async throws -> ManualScrollSample) throws {
        let bounds = CGDisplayBounds(displayID)
        guard region.width >= 8, region.height >= 16,
              CGRect(origin: .zero, size: screenSize).contains(region), bounds.size == screenSize else {
            throw CaptureError.invalidRegion
        }
        self.displayID = displayID; self.region = region; self.screenSize = screenSize
        displayBounds = bounds; self.expectedPixelSize = expectedPixelSize; target = lockedTarget
        self.accept = accept; provider = nil; validate = nil
        observationStrategy = .fullFrame
        permission = { guard CGPreflightScreenCaptureAccess() else { throw CaptureError.screenPermission } }
    }

    /// Verification initializer never inspects the desktop, asks for TCC or sends input.
    init(region: CGRect, screenSize: CGSize, expectedPixelSize: CGSize? = nil,
         observationStrategy: ManualScrollObservationStrategy = .fullFrame,
         permission: @escaping () throws -> Void = {}, validate: @escaping () throws -> Void = {},
         provider: @escaping () async throws -> CGImage,
         accept: @escaping (CGImage) async throws -> ManualScrollSample) {
        displayID = 0; displayBounds = CGRect(origin: .zero, size: screenSize)
        self.region = region; self.screenSize = screenSize; self.expectedPixelSize = expectedPixelSize
        self.permission = permission; self.validate = validate; self.provider = provider; self.accept = accept
        self.observationStrategy = observationStrategy
    }

    func checkPermission() throws { try permission() }

    func validateTarget() throws {
        try Task.checkCancellation()
        guard !invalidated else { throw CancellationError() }
        try checkPermission()
        if let validate { try validate(); return }
        guard CGDisplayBounds(displayID) == displayBounds,
              NSScreen.screens.contains(where: { $0.displayID == displayID && $0.frame.size == screenSize }) else {
            throw CaptureError.failed("显示器已断开或布局改变。已保留原图，请停止后完成截图。")
        }
        let current = try Self.checkedTarget(windowAt(region: region), locked: target, region: region,
                                             displayBounds: displayBounds, allowMovedWindow: false)
        target = current
    }

    func capture() async throws -> ManualScrollObservation {
        try validateTarget()
        pendingImage = nil
        let image: CGImage
        if let provider { image = try await provider() }
        else { image = try await screenImage() }
        try Task.checkCancellation()
        try validateTarget()
        let size = CGSize(width: image.width, height: image.height)
        if let expectedPixelSize, expectedPixelSize != size {
            throw ManualScrollRecoveryError(message: "选区像素尺寸改变。原图未修改，请恢复原显示缩放或停止截图。")
        }
        let strategy = observationStrategy
        if strategy == .reusableFullFrame, reusableObservation == nil {
            reusableObservation = ManualScrollReusableObservation()
        }
        if strategy == .vImageFullFrame, vImageObservation == nil {
            vImageObservation = ManualScrollVImageObservation()
        }
        let reusable = reusableObservation
        let vImage = vImageObservation
        let worker = Task.detached(priority: .userInitiated) {
            switch strategy {
            case .fullFrame: return try Self.observation(image)
            case .pooledFullFrame: return try autoreleasepool { try Self.observation(image) }
            case .reusableFullFrame:
                guard let reusable else { throw ScrollStitchError.invalidPixels }
                return try reusable.observation(image)
            case .vImageFullFrame:
                guard let vImage else { throw ScrollStitchError.invalidPixels }
                return try vImage.observation(image)
            }
        }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard !invalidated else { throw CancellationError() }
        expectedPixelSize = size
        pendingImage = image
        return result
    }

    func acceptStableCapture() async throws -> ManualScrollSample {
        try validateTarget()
        guard let image = pendingImage else { throw CaptureError.invalidRegion }
        defer { pendingImage = nil }
        try Task.checkCancellation()
        return try await accept(image)
    }

    func discardPendingCapture() { pendingImage = nil }
    // Ordinary discard also runs between observations. Keep the reusable bitmap
    // there; release it when the owner observes that pause/recovery has drained.
    func releaseObservationResources() { reusableObservation = nil; vImageObservation = nil }
    var normalizationBufferBytesForVerification: Int {
        (reusableObservation?.allocatedByteCount ?? 0) + (vImageObservation?.allocatedByteCount ?? 0)
    }
    func invalidate() { invalidated = true; discardPendingCapture(); releaseObservationResources() }

    /// Caller must be paused with no pending operation. No accepted source is changed.
    /// The exact pixel extent is preserved and the new origin is snapped to source pixels.
    func moveRegion(to proposed: CGRect) throws {
        try Task.checkCancellation()
        guard !invalidated, pendingImage == nil else { throw CaptureError.busy }
        let moved = try Self.movedRegion(proposed, original: region, screenSize: screenSize,
                                         displayPixels: displayPixelSize, expectedPixels: expectedPixelSize)
        if provider == nil {
            guard CGDisplayBounds(displayID) == displayBounds else { throw CaptureError.noDisplay }
            // Reposition may follow the same target window after the user moved it, but
            // never silently adopts another window, display, size or image scaling.
            let next = try Self.checkedTarget(windowAt(region: moved), locked: target, region: moved,
                                              displayBounds: displayBounds, allowMovedWindow: true)
            target = next
        } else { try validate?() }
        region = moved
    }

    static func movedRegion(_ proposed: CGRect, original: CGRect, screenSize: CGSize,
                            displayPixels: CGSize?, expectedPixels: CGSize?) throws -> CGRect {
        guard proposed.origin.x.isFinite, proposed.origin.y.isFinite, proposed.size == original.size,
              CGRect(origin: .zero, size: screenSize).contains(proposed) else {
            throw ManualScrollRecoveryError(message: "移动只能改变位置，尺寸和显示器保持不变。")
        }
        guard let displayPixels, let expectedPixels else { return proposed }
        let sx = displayPixels.width / screenSize.width, sy = displayPixels.height / screenSize.height
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0 else { throw CaptureError.invalidRegion }
        let result = CGRect(x: (proposed.minX * sx).rounded() / sx,
                            y: (proposed.minY * sy).rounded() / sy,
                            width: expectedPixels.width / sx, height: expectedPixels.height / sy)
        guard result.size == original.size, CGRect(origin: .zero, size: screenSize).contains(result) else {
            throw ManualScrollRecoveryError(message: "移动后无法保持原像素尺寸，请将选区移回显示器内。")
        }
        return result
    }

    static func checkedTarget(_ current: Target?, locked: Target?, region: CGRect,
                              displayBounds: CGRect, allowMovedWindow: Bool) throws -> Target {
        let globalRegion = region.offsetBy(dx: displayBounds.minX, dy: displayBounds.minY)
        guard let current, current.pid > 0, current.windowID != kCGNullWindowID,
              current.bounds.origin.x.isFinite, current.bounds.origin.y.isFinite,
              current.bounds.size.width.isFinite, current.bounds.size.height.isFinite,
              current.bounds.contains(globalRegion) else {
            throw ManualScrollRecoveryError(message: "选区须完整位于同一目标窗口内，请移开遮挡或暂停后移动选区。")
        }
        if let locked {
            guard current.pid == locked.pid, current.windowID == locked.windowID,
                  allowMovedWindow || current.bounds == locked.bounds else {
                throw ManualScrollRecoveryError(message: "目标窗口已移动或被遮挡。请恢复目标窗口，或暂停后移动选区，再重试。")
            }
        }
        return current
    }

    private func screenImage() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        try validateTarget()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.noDisplay }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        guard !ownApps.isEmpty else { throw CaptureError.failed("无法排除PicShot控制条，捕获已暂停。") }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let width = max(1, Int((filter.contentRect.width * scale).rounded()))
        let height = max(1, Int((filter.contentRect.height * scale).rounded()))
        guard width <= ScrollFrame.maximumDimension, height <= ScrollFrame.maximumDimension,
              width <= ScrollFrame.maximumPixels / height else { throw ScrollStitchError.invalidPixels }
        let descriptor = CGSize(width: width, height: height)
        if let displayPixelSize, displayPixelSize != descriptor {
            throw CaptureError.failed("显示器像素缩放已改变。请停止并完成当前截图。")
        }
        configuration.width = width; configuration.height = height; configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        try validateTarget()
        guard image.width == width, image.height == height else { throw ScrollStitchError.differentDimensions }
        let pixels = try AutomaticScrollGeometry.pixelRect(region: region, logicalSize: screenSize,
                                                           pixelWidth: image.width, pixelHeight: image.height)
        guard let crop = image.cropping(to: pixels) else { throw CaptureError.invalidRegion }
        // Normalize the initial selection to the exact crop once. A subsequent move
        // changes only integral pixel origin, never its original dimensions.
        if displayPixelSize == nil {
            let sx = CGFloat(width) / screenSize.width, sy = CGFloat(height) / screenSize.height
            region = CGRect(x: pixels.minX / sx, y: pixels.minY / sy, width: pixels.width / sx, height: pixels.height / sy)
        }
        displayPixelSize = descriptor
        return crop
    }

    nonisolated static func observation(_ image: CGImage) throws -> ManualScrollObservation {
        try Task.checkCancellation()
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= ScrollFrame.maximumDimension, height <= ScrollFrame.maximumDimension,
              width <= ScrollFrame.maximumPixels / height,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { throw ScrollStitchError.invalidPixels }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var hash = SHA256()
        let rowBytes = width * 4
        for start in stride(from: 0, to: height, by: 64) {
            try Task.checkCancellation()
            let count = min(64, height - start) * rowBytes
            hash.update(bufferPointer: UnsafeRawBufferPointer(start: data.advanced(by: start * rowBytes), count: count))
        }
        return try ManualScrollObservation(width: width, height: height, rgbaSHA256: Array(hash.finalize()))
    }

    private func windowAt(region: CGRect) -> Target? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let globalRegion = region.offsetBy(dx: displayBounds.minX, dy: displayBounds.minY)
        for window in windows {
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary), bounds.intersects(globalRegion),
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01 else { continue }
            // Own UI is excluded by ScreenCaptureKit. Any other intersecting overlay
            // invalidates the whole region rather than capturing an uncertain seam.
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            return Target(pid: pid, windowID: id, bounds: bounds)
        }
        return nil
    }
}
