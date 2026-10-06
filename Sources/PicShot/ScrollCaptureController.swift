import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PicShotCore

/// A user-driven, same-region scroll session. Full-resolution sources live in a private
/// temporary directory; only the last grayscale frame and a thumbnail stay in memory.
@MainActor
final class ScrollCaptureController: NSWindowController, NSWindowDelegate {
    private let onComplete: (CGImage) -> Void
    private let captureService = CaptureService()
    private var stitcher = ScrollStitcher()
    private var frames: [StoredScrollFrame] = []
    private var directory: URL?
    private var diskBytes: Int64 = 0
    private var region: CGRect?
    private var selectedDisplayID: CGDirectDisplayID?
    private var selectedDisplaySize: CGSize?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var busy = false
    private let maximumFrames = 100
    private let maximumDiskBytes: Int64 = 512 * 1024 * 1024

    private let direction = NSPopUpButton(frame: .zero, pullsDown: false)
    private let displayPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let chooseButton = NSButton(title: "Choose Region & Capture", target: nil, action: nil)
    private let nextButton = NSButton(title: "Capture Next (3s)", target: nil, action: nil)
    private let importButton = NSButton(title: "Import Frames…", target: nil, action: nil)
    private let resetButton = NSButton(title: "Start Over", target: nil, action: nil)
    private let finishButton = NSButton(title: "Finish & Edit", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "Choose a region containing only scrolling content. Exclude fixed headers, sidebars, and scrollbars.")
    private let dimensions = NSTextField(labelWithString: "No frames yet")
    private let preview = NSImageView()

    init(onComplete: @escaping (CGImage) -> Void) {
        self.onComplete = onComplete
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 690, height: 570),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Scrolling Capture"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        buildInterface()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var axis: ScrollAxis { direction.indexOfSelectedItem == 1 ? .horizontal : .vertical }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        direction.addItems(withTitles: ["Vertical ↓", "Horizontal →"])
        direction.target = self
        direction.action = #selector(directionChanged)
        for screen in NSScreen.screens {
            displayPicker.addItem(withTitle: screen.localizedName)
            displayPicker.lastItem?.representedObject = screen.displayID
        }
        if let main = NSScreen.main?.displayID,
           let index = NSScreen.screens.firstIndex(where: { $0.displayID == main }) { displayPicker.selectItem(at: index) }
        let explanation = NSTextField(wrappingLabelWithString: "Scroll manually down or right between frames. Each capture waits 3 seconds so you can return to the page. Keep at least 25% overlap and stop scrolling before the capture. No automatic scrolling or accessibility access is needed.")
        explanation.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 4
        dimensions.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        dimensions.textColor = .secondaryLabelColor
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        preview.layer?.cornerRadius = 8
        chooseButton.target = self; chooseButton.action = #selector(chooseRegion)
        nextButton.target = self; nextButton.action = #selector(captureNext)
        nextButton.keyEquivalent = "\r"
        nextButton.keyEquivalentModifierMask = [.command]
        importButton.target = self; importButton.action = #selector(importFrames)
        resetButton.target = self; resetButton.action = #selector(startOver)
        finishButton.target = self; finishButton.action = #selector(finishCapture)
        let controls = NSStackView(views: [NSTextField(labelWithString: "Direction:"), direction,
                                          NSTextField(labelWithString: "Display:"), displayPicker])
        controls.orientation = .horizontal
        controls.spacing = 10
        let captureControls = NSStackView(views: [chooseButton, nextButton, importButton])
        captureControls.orientation = .horizontal
        captureControls.spacing = 10
        let finalControls = NSStackView(views: [resetButton, finishButton])
        finalControls.orientation = .horizontal
        finalControls.spacing = 10
        let stack = NSStackView(views: [explanation, controls, captureControls, preview, dimensions, status, finalControls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.heightAnchor.constraint(equalToConstant: 170),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        updateControls()
    }

    @objc private func directionChanged() { stitcher = ScrollStitcher(axis: axis) }

    @objc private func chooseRegion() {
        guard !busy, frames.isEmpty,
              let displayID = displayPicker.selectedItem?.representedObject as? CGDirectDisplayID,
              let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }
        selectedDisplayID = displayID
        selectedDisplaySize = screen.frame.size
        startOperation { [weak self] in
            guard let self else { return }
            try CaptureService.requireScreenPermission()
            self.window?.orderOut(nil)
            self.region = try await self.captureService.selectRegion(displayID: displayID)
            try Task.checkCancellation()
            try await self.grabSelectedRegion()
        }
    }

    @objc private func captureNext() {
        guard region != nil, selectedDisplayID != nil else { return }
        startOperation { [weak self] in try await self?.grabSelectedRegion() }
    }

    private func grabSelectedRegion() async throws {
        guard let region, let displayID = selectedDisplayID, let screenSize = selectedDisplaySize else {
            throw CaptureError.invalidRegion
        }
        guard let currentScreen = NSScreen.screens.first(where: { $0.displayID == displayID }),
              currentScreen.frame.size == screenSize else {
            throw CaptureError.failed("The display layout changed. Start a new scrolling capture.")
        }
        status.stringValue = "Capturing in 3 seconds. Return to your page, scroll, then pause."
        window?.orderOut(nil)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let fullImage = try await captureService.captureDisplay(displayID: displayID)
        try Task.checkCancellation()
        let scaleX = CGFloat(fullImage.width) / screenSize.width
        let scaleY = CGFloat(fullImage.height) / screenSize.height
        // RegionSelectionController and CGImage cropping both use top-left coordinates.
        let pixels = CGRect(x: region.minX * scaleX, y: region.minY * scaleY,
                            width: region.width * scaleX, height: region.height * scaleY).integral
        guard let crop = fullImage.cropping(to: pixels), crop.width >= 8, crop.height >= 16 else {
            throw CaptureError.invalidRegion
        }
        try await accept(crop)
    }

    @objc private func importFrames() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose overlapping frames in filename order"
        panel.message = "Choose equal-size images in scrolling order. Names are sorted naturally (frame2 before frame10). Existing accepted frames are kept."
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        startOperation { [weak self] in
            guard let self else { return }
            for url in urls {
                try Task.checkCancellation()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let image = try await Task.detached(priority: .userInitiated) {
                    try ScrollImageIO.readImage(at: url)
                }.value
                try Task.checkCancellation()
                try await self.accept(image)
            }
        }
    }

    private func accept(_ image: CGImage) async throws {
        guard frames.count < maximumFrames else { throw ScrollSessionError.frameLimit }
        if directory == nil {
            let newDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Scroll-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            directory = newDirectory
        }
        guard let directory else { throw ScrollSessionError.imageIO }
        let url = directory.appendingPathComponent("frame-\(frames.count).png")
        let current = stitcher
        let remaining = maximumDiskBytes - diskBytes
        let result = try await Task.detached(priority: .userInitiated) {
            var next = current
            let gray = try ScrollImageIO.luminance(image)
            let placement = try next.append(gray)
            try ScrollImageIO.writePNG(image, to: url)
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0, size <= remaining else {
                try? FileManager.default.removeItem(at: url)
                throw ScrollSessionError.diskLimit
            }
            return (next, StoredScrollFrame(url: url, placement: placement), size)
        }.value
        try Task.checkCancellation()
        stitcher = result.0
        frames.append(result.1)
        diskBytes += result.2
        preview.image = ScrollImageIO.thumbnail(at: url)
        dimensions.stringValue = "\(frames.count) frame\(frames.count == 1 ? "" : "s") · \(stitcher.outputWidth) × \(stitcher.outputHeight) pixels · \(diskBytes / 1_048_576) MB temporary storage"
        status.stringValue = frames.count == 1
            ? "First frame saved. Scroll \(axis == .vertical ? "down" : "right"), keeping at least 25% visible, then capture the next frame."
            : "Frame \(frames.count) matched with \(result.1.placement.overlap) pixels of overlap. Continue scrolling or finish."
    }

    @objc private func finishCapture() {
        guard frames.count >= 2, !busy else { return }
        let sourceFrames = frames
        let width = stitcher.outputWidth, height = stitcher.outputHeight
        let selectedAxis = axis
        startOperation { [weak self] in
            guard let self else { return }
            self.status.stringValue = "Rendering the stitched image…"
            let image = try await Task.detached(priority: .userInitiated) {
                try ScrollImageIO.render(sourceFrames, width: width, height: height, axis: selectedAxis)
            }.value
            try Task.checkCancellation()
            self.onComplete(image)
            self.close()
        }
    }

    @objc private func startOver() {
        guard !busy else { return }
        if !frames.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Discard this scrolling capture?"
            alert.informativeText = "The temporary source frames will be removed."
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Keep Capturing")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        resetSession()
    }

    private func startOperation(_ body: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        updateControls()
        let token = generation
        operation = Task { [weak self] in
            guard let self else { return }
            do { try await body() }
            catch is CancellationError { }
            catch {
                if self.generation == token {
                    self.status.stringValue = "\(error.localizedDescription) Accepted frames have been kept."
                }
            }
            guard self.generation == token else { return }
            self.busy = false
            self.operation = nil
            self.updateControls()
            self.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func updateControls() {
        direction.isEnabled = !busy && frames.isEmpty
        displayPicker.isEnabled = !busy && frames.isEmpty
        chooseButton.isEnabled = !busy && frames.isEmpty
        nextButton.isEnabled = !busy && region != nil
        importButton.isEnabled = !busy
        resetButton.isEnabled = !busy && (!frames.isEmpty || region != nil)
        finishButton.isEnabled = !busy && frames.count >= 2
    }

    private func resetSession() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        busy = false
        frames.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        diskBytes = 0
        region = nil
        selectedDisplayID = nil
        selectedDisplaySize = nil
        stitcher = ScrollStitcher(axis: axis)
        preview.image = nil
        dimensions.stringValue = "No frames yet"
        status.stringValue = "Choose a region containing only scrolling content. Exclude fixed headers, sidebars, and scrollbars."
        updateControls()
    }

    func windowWillClose(_ notification: Notification) { resetSession() }
}

private struct StoredScrollFrame: Sendable {
    let url: URL
    let placement: ScrollPlacement
}

private enum ScrollSessionError: LocalizedError {
    case imageIO, frameLimit, diskLimit
    var errorDescription: String? {
        switch self {
        case .imageIO: return "The image could not be read or written."
        case .frameLimit: return "This session reached its 100-frame limit. Finish this image and start another."
        case .diskLimit: return "This session reached its 512 MB temporary-storage limit. Finish this image and start another."
        }
    }
}

private enum ScrollImageIO {
    static func readImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= ScrollFrame.maximumDimension, height <= ScrollFrame.maximumDimension,
              width <= ScrollFrame.maximumPixels / height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw ScrollSessionError.imageIO }
        return image
    }

    static func luminance(_ image: CGImage) throws -> ScrollFrame {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= ScrollFrame.maximumDimension, height <= ScrollFrame.maximumDimension,
              width <= ScrollFrame.maximumPixels / height else { throw ScrollStitchError.invalidPixels }
        var pixels = [UInt8](repeating: 255, count: width * height)
        let success = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { throw ScrollSessionError.imageIO }
        return try ScrollFrame(width: width, height: height, grayscale: pixels)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ScrollSessionError.imageIO
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw ScrollSessionError.imageIO
        }
    }

    @MainActor static func thumbnail(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 800,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    static func render(_ frames: [StoredScrollFrame], width: Int, height: Int, axis: ScrollAxis) throws -> CGImage {
        guard width > 0, height > 0, width <= 60_000_000 / height,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ScrollStitchError.pixelLimit
        }
        context.interpolationQuality = .none
        for (index, frame) in frames.enumerated() {
            try autoreleasepool {
                let image = try readImage(at: frame.url)
                if index == 0 {
                    context.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
                } else if axis == .vertical {
                    let amount = frame.placement.advance
                    guard let strip = image.cropping(to: CGRect(x: 0, y: image.height - amount, width: image.width, height: amount)) else {
                        throw ScrollSessionError.imageIO
                    }
                    let top = frame.placement.y + image.height - amount
                    context.draw(strip, in: CGRect(x: 0, y: height - top - amount, width: image.width, height: amount))
                } else {
                    let amount = frame.placement.advance
                    guard let strip = image.cropping(to: CGRect(x: image.width - amount, y: 0, width: amount, height: image.height)) else {
                        throw ScrollSessionError.imageIO
                    }
                    context.draw(strip, in: CGRect(x: frame.placement.x + image.width - amount, y: 0, width: amount, height: image.height))
                }
            }
        }
        guard let image = context.makeImage() else { throw ScrollSessionError.imageIO }
        return image
    }
}
