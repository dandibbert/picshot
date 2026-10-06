import AppKit
import CoreGraphics
import PicShotCore

enum AdvancedSelectionStyle: String, CaseIterable {
    case multiRegion, polygon, freehand

    var title: String {
        switch self {
        case .multiRegion: return "Multi-region"
        case .polygon: return "Polygon"
        case .freehand: return "Freehand"
        }
    }

    var instructions: String {
        switch self {
        case .multiRegion: return "Drag to add · Option-drag to subtract · Return to capture · Esc to cancel · Tab hides controls"
        case .polygon: return "Click vertices · Return closes and captures · Delete undoes a vertex · Esc cancels · Tab hides controls"
        case .freehand: return "Drag a closed outline · Return to capture · Draw again to replace · Esc to cancel · Tab hides controls"
        }
    }
}

/// Freezes just the display beneath the pointer, then selects from that immutable
/// frame. No overlay pixels, live windows, or later desktop changes enter the output.
@MainActor
final class AdvancedCaptureController: NSObject, NSWindowDelegate {
    private let captureService = CaptureService()
    private var sessionID: UUID?
    private var panel: AdvancedSelectionPanel?
    private var selectionView: AdvancedSelectionView?
    private var continuation: CheckedContinuation<CaptureSelectionGeometry, Error>?
    private var screenObserver: NSObjectProtocol?

    func capture(style: AdvancedSelectionStyle) async throws -> CGImage {
        guard sessionID == nil else { throw CaptureError.busy }
        let id = UUID()
        sessionID = id
        defer {
            tearDown()
            sessionID = nil
        }
        try Task.checkCancellation()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main,
              let displayID = screen.displayID else { throw CaptureError.noDisplay }
        let originalFrame = screen.frame
        let originalScale = screen.backingScaleFactor
        // Reject oversized displays before asking ScreenCaptureKit for a full frame.
        // Its returned dimensions are checked again in case display mode changed.
        let mode = CGDisplayCopyDisplayMode(displayID)
        guard CaptureSelectionGeometry.allowsSourceSize(width: CGDisplayPixelsWide(displayID), height: CGDisplayPixelsHigh(displayID)),
              mode.map({ CaptureSelectionGeometry.allowsSourceSize(width: $0.pixelWidth, height: $0.pixelHeight) }) ?? true else {
            throw CaptureError.failed("This display exceeds the 64-million-pixel capture limit. Use a lower display resolution.")
        }
        let frozen = try await captureService.captureDisplay(displayID: displayID)
        try Task.checkCancellation()
        guard let currentScreen = NSScreen.screens.first(where: { $0.displayID == displayID }),
              currentScreen.frame == originalFrame, currentScreen.backingScaleFactor == originalScale else {
            throw CaptureError.noDisplay
        }
        let geometry = try CaptureSelectionGeometry(pointSize: originalFrame.size,
                                                    pixelWidth: frozen.width, pixelHeight: frozen.height)
        let selection = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { completion in
                continuation = completion
                show(screen: currentScreen, image: frozen, style: style, geometry: geometry, session: id)
            }
        } onCancel: {
            // The ID prevents a delayed cancellation callback closing a newer session.
            Task { @MainActor [weak self] in self?.finish(.failure(CaptureError.cancelled), session: id) }
        }
        try Task.checkCancellation()
        // The overlay is gone before raster work begins. Mask generation is bounded
        // and cancellable, and does not block the main event loop on large displays.
        let input = AdvancedSelectionRasterInput(image: frozen, selection: selection)
        let work = Task.detached(priority: .userInitiated) {
            try AdvancedSelectionRenderer.render(image: input.image, selection: input.selection)
        }
        return try await withTaskCancellationHandler {
            let image = try await work.value
            try Task.checkCancellation()
            return image
        } onCancel: {
            work.cancel()
        }
    }

    private func show(screen: NSScreen, image: CGImage, style: AdvancedSelectionStyle,
                      geometry: CaptureSelectionGeometry, session: UUID) {
        let panel = AdvancedSelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.level = .screenSaver
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = AdvancedSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                         image: image, style: style, geometry: geometry)
        view.finished = { [weak self] result in self?.finish(result, session: session) }
        panel.contentView = view
        self.panel = panel
        selectionView = view
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.finish(.failure(CaptureError.noDisplay), session: session) }
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
    }

    func windowWillClose(_ notification: Notification) {
        guard let id = sessionID else { return }
        finish(.failure(CaptureError.cancelled), session: id)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let id = sessionID else { return }
        finish(.failure(CaptureError.cancelled), session: id)
    }

    private func finish(_ result: Result<CaptureSelectionGeometry, Error>, session: UUID) {
        guard sessionID == session, let completion = continuation else { return }
        continuation = nil
        tearDown()
        completion.resume(with: result)
    }

    private func tearDown() {
        let wasKeyWindow = panel?.isKeyWindow == true
        if let observer = screenObserver { NotificationCenter.default.removeObserver(observer) }
        screenObserver = nil
        selectionView?.discard()
        selectionView = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel?.close()
        panel?.contentView = nil
        panel = nil
        if wasKeyWindow { NSCursor.arrow.set() }
        // Cursor rects belong to the window. There is no global cursor-stack push to
        // leak if capture is cancelled, another app activates, or a monitor detaches.
    }
}

private struct AdvancedSelectionRasterInput: @unchecked Sendable {
    // CGImage is immutable; no AppKit object crosses to the raster worker.
    let image: CGImage
    let selection: CaptureSelectionGeometry
}

enum AdvancedSelectionRenderer {
    static func render(image: CGImage, selection: CaptureSelectionGeometry) throws -> CGImage {
        guard image.width == selection.pixelWidth, image.height == selection.pixelHeight else {
            throw CaptureSelectionError.invalidCanvas
        }
        let mask = try selection.rasterized()
        try Task.checkCancellation()
        guard let cropped = image.cropping(to: mask.pixelBounds),
              let provider = CGDataProvider(data: Data(mask.alpha) as CFData) else {
            throw CaptureError.failed("Could not prepare the selected pixels.")
        }
        // Quartz image masks use inverse alpha. Reverse their decode range so our
        // 255 means selected, and use identical top-row-first CGImage coordinates.
        var decode: [CGFloat] = [1, 0]
        let imageMask = decode.withUnsafeMutableBufferPointer { values in
            CGImage(maskWidth: mask.width, height: mask.height, bitsPerComponent: 8,
                    bitsPerPixel: 8, bytesPerRow: mask.width, provider: provider,
                    decode: values.baseAddress, shouldInterpolate: false)
        }
        guard let imageMask, let masked = cropped.masking(imageMask),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: mask.width, height: mask.height,
                                      bitsPerComponent: 8, bytesPerRow: mask.width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw CaptureError.failed("Could not allocate the selected image.")
        }
        // Materialize ONLY the selected bounds in a zeroed RGBA context. Transparent
        // gaps contain no hidden desktop RGB, and the returned image does not retain
        // a full-display crop backing store or editable selection mask.
        let bounds = CGRect(x: 0, y: 0, width: mask.width, height: mask.height)
        context.clear(bounds)
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.draw(masked, in: bounds)
        try Task.checkCancellation()
        guard let output = context.makeImage() else { throw CaptureError.failed("Could not finish the selected image.") }
        return output
    }
}

private final class AdvancedSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AdvancedSelectionView: NSView {
    var finished: ((Result<CaptureSelectionGeometry, Error>) -> Void)?
    private(set) var selection: CaptureSelectionGeometry
    private let style: AdvancedSelectionStyle
    private var frozenImage: NSImage?
    private var dragStart: CGPoint?
    private var dragSubtracts = false
    private var draftPoints: [CGPoint] = []
    private var draftRectangle: CGRect?
    private var hoverPoint: CGPoint?
    private var pointLimitReached = false
    private var tracking: NSTrackingArea?
    private let toolbar = NSVisualEffectView()
    private let help = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame: CGRect, image: CGImage, style: AdvancedSelectionStyle, geometry: CaptureSelectionGeometry) {
        self.style = style
        selection = geometry
        frozenImage = NSImage(cgImage: image, size: frame.size)
        super.init(frame: frame)
        setAccessibilityLabel("\(style.title) screenshot selection on the current display")
        setAccessibilityHelp(style.instructions)
        configureToolbar()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = max(1, min(760, bounds.width - 24))
        toolbar.frame = CGRect(x: (bounds.width - width) / 2, y: 16, width: width, height: 90)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if !toolbar.isHidden { addCursorRect(toolbar.frame, cursor: .arrow) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseDown(with event: NSEvent) {
        guard !selection.isCancelled else { return }
        window?.makeFirstResponder(self)
        let point = localPoint(event)
        status.stringValue = ""
        switch style {
        case .multiRegion:
            dragStart = point
            dragSubtracts = event.modifierFlags.contains(.option)
            draftRectangle = .zero
        case .polygon:
            guard draftPoints.count < CaptureSelectionGeometry.maximumPoints else {
                status.stringValue = CaptureSelectionError.complexityLimit.localizedDescription
                return
            }
            if draftPoints.last != point { draftPoints.append(point) }
            hoverPoint = point
            updateStatus()
        case .freehand:
            dragStart = point
            draftPoints = [point]
            pointLimitReached = false
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !selection.isCancelled, let start = dragStart else { return }
        let point = localPoint(event)
        if style == .multiRegion {
            draftRectangle = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                    width: abs(point.x - start.x), height: abs(point.y - start.y))
        } else if style == .freehand {
            appendFreehandPoint(point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !selection.isCancelled, dragStart != nil else { return }
        mouseDragged(with: event)
        defer {
            dragStart = nil
            draftRectangle = nil
            if style == .freehand { draftPoints.removeAll(keepingCapacity: false) }
            needsDisplay = true
        }
        do {
            switch style {
            case .multiRegion:
                if let rectangle = draftRectangle { try selection.append(.rectangle(rectangle), subtracts: dragSubtracts) }
            case .freehand:
                guard !pointLimitReached else { throw CaptureSelectionError.complexityLimit }
                let end = localPoint(event)
                if draftPoints.last != end { draftPoints.append(end) }
                var replacement = selection
                replacement.clear()
                try replacement.append(.polygon(draftPoints))
                selection = replacement
            case .polygon: break
            }
            updateStatus()
        } catch { status.stringValue = error.localizedDescription }
        window?.makeFirstResponder(self)
    }

    override func mouseMoved(with event: NSEvent) {
        if style == .polygon, !draftPoints.isEmpty {
            hoverPoint = localPoint(event)
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: cancelSelection(nil)
        case 36, 76: captureSelection(nil)
        case 51, 117: undoSelection(nil)
        case 48:
            toolbar.isHidden.toggle()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        case 6 where event.modifierFlags.contains(.command): undoSelection(nil)
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { cancelSelection(sender) }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = frozenImage else { return }
        drawFrozen(image)
        NSColor.black.withAlphaComponent(0.42).setFill()
        bounds.fill()
        var operations = selection.operations
        if let rectangle = draftRectangle, rectangle.width > 0, rectangle.height > 0 {
            operations.append(CaptureSelectionOperation(shape: .rectangle(rectangle), subtracts: dragSubtracts))
        } else if draftPoints.count >= 3 {
            // Polygon/freehand previews show the actual closed mask, rather than
            // a bounding rectangle. The exported fill uses the same even-odd rule.
            if style == .freehand { operations.removeAll() }
            operations.append(CaptureSelectionOperation(shape: .polygon(draftPoints)))
        }
        for operation in operations {
            let path = bezierPath(operation.shape)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            drawFrozen(image)
            if operation.subtracts {
                NSColor.black.withAlphaComponent(0.42).setFill()
                bounds.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        for operation in operations {
            let path = bezierPath(operation.shape)
            path.lineWidth = 1.5
            (operation.subtracts ? NSColor.systemOrange : NSColor.white).setStroke()
            if operation.subtracts { path.setLineDash([5, 4], count: 2, phase: 0) }
            path.stroke()
        }
        if !draftPoints.isEmpty {
            let path = NSBezierPath()
            path.move(to: draftPoints[0])
            for point in draftPoints.dropFirst() { path.line(to: point) }
            if style == .polygon, let hoverPoint { path.line(to: hoverPoint) }
            NSColor.white.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            if style == .polygon {
                NSColor.controlAccentColor.setFill()
                for point in draftPoints { NSBezierPath(ovalIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill() }
            }
        }
    }

    /// Called on every exit path before the panel is released.
    func discard() {
        finished = nil
        selection.cancel()
        draftPoints.removeAll(keepingCapacity: false)
        draftRectangle = nil
        dragStart = nil
        hoverPoint = nil
        frozenImage = nil
    }

    @objc private func captureSelection(_ sender: Any?) {
        guard !selection.isCancelled, dragStart == nil else { return }
        do {
            var committed = selection
            if style == .polygon {
                committed.clear()
                try committed.append(.polygon(draftPoints))
            }
            _ = try committed.enclosingPixelBounds()
            finished?(.success(committed))
        } catch { status.stringValue = error.localizedDescription }
        window?.makeFirstResponder(self)
    }

    @objc private func cancelSelection(_ sender: Any?) {
        guard !selection.isCancelled else { return }
        selection.cancel()
        finished?(.failure(CaptureError.cancelled))
    }

    @objc private func clearSelection(_ sender: Any?) {
        guard !selection.isCancelled else { return }
        selection.clear()
        draftPoints.removeAll(keepingCapacity: false)
        draftRectangle = nil
        dragStart = nil
        hoverPoint = nil
        status.stringValue = "Selection cleared"
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    @objc private func undoSelection(_ sender: Any?) {
        guard !selection.isCancelled else { return }
        if !draftPoints.isEmpty { draftPoints.removeLast() } else { selection.undo() }
        updateStatus()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func configureToolbar() {
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 12
        toolbar.layer?.masksToBounds = true
        addSubview(toolbar)
        let title = NSTextField(labelWithString: "\(style.title) · This display")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSelection(_:)))
        let undo = NSButton(title: "Undo", target: self, action: #selector(undoSelection(_:)))
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearSelection(_:)))
        let capture = NSButton(title: "Capture", target: self, action: #selector(captureSelection(_:)))
        for button in [cancel, undo, clear, capture] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 12)
        }
        capture.keyEquivalent = "\r"
        help.stringValue = style.instructions
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.lineBreakMode = .byWordWrapping
        help.maximumNumberOfLines = 2
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.stringValue = "Frozen screen · Gaps and cutouts export transparent"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [title, spacer, undo, clear, cancel, capture])
        row.orientation = .horizontal
        row.spacing = 5
        let stack = NSStackView(views: [row, help, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: toolbar.bottomAnchor, constant: -8),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func localPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: max(0, min(bounds.width, point.x)), y: max(0, min(bounds.height, point.y)))
    }

    private func appendFreehandPoint(_ point: CGPoint) {
        guard let last = draftPoints.last else { draftPoints = [point]; return }
        guard hypot(point.x - last.x, point.y - last.y) >= 1 else { return }
        guard draftPoints.count < CaptureSelectionGeometry.maximumPoints - 1 else {
            pointLimitReached = true
            status.stringValue = CaptureSelectionError.complexityLimit.localizedDescription
            return
        }
        draftPoints.append(point)
    }

    private func updateStatus() {
        if style == .polygon {
            status.stringValue = "\(draftPoints.count) vertices · Return closes the outline"
        } else if let bounds = try? selection.enclosingPixelBounds() {
            status.stringValue = "\(Int(bounds.width)) × \(Int(bounds.height)) px bounds · \(selection.operations.count) shapes · Return to capture"
        } else {
            status.stringValue = "Draw a selection · Esc cancels"
        }
    }

    private func drawFrozen(_ image: NSImage) {
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.none.rawValue])
    }

    private func bezierPath(_ shape: CaptureSelectionShape) -> NSBezierPath {
        switch shape {
        case .rectangle(let rectangle): return NSBezierPath(rect: rectangle.standardized)
        case .polygon(let points):
            let path = NSBezierPath()
            path.windingRule = .evenOdd
            if let first = points.first {
                path.move(to: first)
                for point in points.dropFirst() { path.line(to: point) }
                path.close()
            }
            return path
        }
    }
}
