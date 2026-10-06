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
        case .multiRegion: return "Drag adds · Option-drag subtracts · Click selects · Return captures · Esc cancels · Tab hides HUD"
        case .polygon: return "Click vertices · Return closes and captures · Delete removes a vertex · Esc cancels · Tab hides controls"
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
final class AdvancedSelectionView: NSView, NSTextFieldDelegate {
    var finished: ((Result<CaptureSelectionGeometry, Error>) -> Void)?
    private(set) var selection: CaptureSelectionGeometry
    private let style: AdvancedSelectionStyle
    private var frozenImage: NSImage?
    private var pixelSampler: FrozenCapturePixelSampler?
    private let precisionHUD = CapturePrecisionHUD()
    private(set) var selectedOperationIndex: Int?
    private var pointerPoint: CGPoint?
    private var undoHistory: [SelectionSnapshot] = []
    private let widthField = NSTextField(string: "")
    private let heightField = NSTextField(string: "")
    private var sizeControls: [NSControl] = []

    private struct SelectionSnapshot {
        let geometry: CaptureSelectionGeometry
        let selectedIndex: Int?
        let points: [CGPoint]
    }
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
        pixelSampler = FrozenCapturePixelSampler(image: image)
        selectedOperationIndex = geometry.operations.indices.last
        super.init(frame: frame)
        setAccessibilityLabel("\(style.title) screenshot selection on the current display")
        setAccessibilityHelp(style.instructions)
        precisionHUD.isHidden = true
        addSubview(precisionHUD)
        configureToolbar()
        updateStatus()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = max(1, min(760, bounds.width - 24))
        toolbar.frame = CGRect(x: (bounds.width - width) / 2, y: 16, width: width, height: style == .multiRegion ? 126 : 90)
        positionPrecisionHUD()
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
        updatePrecision(at: point)
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
            if draftPoints.last != point {
                rememberSelection()
                draftPoints.append(point)
            }
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
        updatePrecision(at: point)
        if style == .multiRegion {
            draftRectangle = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                    width: abs(point.x - start.x), height: abs(point.y - start.y))
        } else if style == .freehand {
            appendFreehandPoint(point)
        }
        updateStatus()
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
                if let rectangle = draftRectangle {
                    if rectangle.width < 2 && rectangle.height < 2 {
                        // A click selects the latest overlapping rectangle, including
                        // cutouts. A drag always creates a new Boolean operation.
                        selectedOperationIndex = selection.operations.indices.reversed().first { index in
                            if case .rectangle(let existing) = selection.operations[index].shape {
                                return existing.standardized.contains(localPoint(event))
                            }
                            return false
                        }
                    } else {
                        var edited = selection
                        try edited.append(.rectangle(rectangle), subtracts: dragSubtracts)
                        rememberSelection()
                        selection = edited
                        selectedOperationIndex = selection.operations.indices.last
                    }
                }
            case .freehand:
                guard !pointLimitReached else { throw CaptureSelectionError.complexityLimit }
                let end = localPoint(event)
                if draftPoints.last != end { draftPoints.append(end) }
                var replacement = selection
                replacement.clear()
                try replacement.append(.polygon(draftPoints))
                rememberSelection(points: [])
                selection = replacement
                selectedOperationIndex = selection.operations.indices.last
            case .polygon: break
            }
            draftRectangle = nil
            updateStatus()
        } catch { status.stringValue = error.localizedDescription }
        window?.makeFirstResponder(self)
    }

    override func mouseMoved(with event: NSEvent) {
        guard !selection.isCancelled else { return }
        updatePrecision(at: localPoint(event))
        if style == .polygon, !draftPoints.isEmpty { needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) {
        guard !selection.isCancelled else { return }
        switch event.keyCode {
        case 53: cancelSelection(nil)
        case 36, 76: captureSelection(nil)
        case 51, 117: removeSelection(nil)
        case 48:
            toolbar.isHidden.toggle()
            precisionHUD.isHidden = toolbar.isHidden || precisionHUD.sample == nil
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        case 6 where event.modifierFlags.contains(.command): undoSelection(nil)
        case 123, 124, 125, 126: nudgeSelection(with: event)
        case 8 where event.modifierFlags.intersection([.command, .control, .option]).isEmpty:
            if let color = precisionHUD.sample?.color {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(color.hex, forType: .string)
                status.stringValue = "Copied \(color.hex) · sRGB from the frozen screen"
            }
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
        for (index, operation) in operations.enumerated() {
            let path = bezierPath(operation.shape)
            path.lineWidth = index == selectedOperationIndex ? 2 : 1.5
            (operation.subtracts ? NSColor.systemOrange : NSColor.white).setStroke()
            if operation.subtracts { path.setLineDash([5, 4], count: 2, phase: 0) }
            path.stroke()
            if index == selectedOperationIndex, case .rectangle(let rectangle) = operation.shape {
                NSColor.controlAccentColor.setFill()
                let rectangle = rectangle.standardized
                for point in [CGPoint(x: rectangle.minX, y: rectangle.minY), CGPoint(x: rectangle.maxX, y: rectangle.minY),
                              CGPoint(x: rectangle.minX, y: rectangle.maxY), CGPoint(x: rectangle.maxX, y: rectangle.maxY)] {
                    NSBezierPath(rect: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)).fill()
                }
            }
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
        pixelSampler = nil
        precisionHUD.sample = nil
        precisionHUD.isHidden = true
        pointerPoint = nil
        selectedOperationIndex = nil
        undoHistory.removeAll(keepingCapacity: false)
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
        rememberSelection()
        selection.clear()
        selectedOperationIndex = nil
        draftPoints.removeAll(keepingCapacity: false)
        draftRectangle = nil
        dragStart = nil
        hoverPoint = nil
        updateSizeFields()
        status.stringValue = "Selection cleared · ⌘Z restores it"
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    @objc private func undoSelection(_ sender: Any?) {
        guard !selection.isCancelled else { return }
        if dragStart != nil {
            dragStart = nil
            draftRectangle = nil
            draftPoints.removeAll(keepingCapacity: false)
        } else if let previous = undoHistory.popLast() {
            selection = previous.geometry
            selectedOperationIndex = previous.selectedIndex
            draftPoints = previous.points
        } else if style == .polygon, !draftPoints.isEmpty {
            draftPoints.removeLast()
        } else {
            selection.undo()
            selectedOperationIndex = selection.operations.indices.last
        }
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
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeSelection(_:)))
        remove.toolTip = "Remove the selected shape (Delete). Undo restores it."
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearSelection(_:)))
        let capture = NSButton(title: "Capture", target: self, action: #selector(captureSelection(_:)))
        for button in [cancel, undo, remove, clear, capture] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 12)
        }
        // Return is handled by the selection responder. Numeric fields use their
        // own Return action to apply dimensions without accidentally capturing.
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
        let row = NSStackView(views: [title, spacer, undo, remove, clear, cancel, capture])
        row.orientation = .horizontal
        row.spacing = 5
        let rows: [NSView] = style == .multiRegion ? [row, help, makeSizeControls(), status] : [row, help, status]
        let stack = NSStackView(views: rows)
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
        updateSizeFields()
        if let rectangle = draftRectangle, let pixels = selection.rectanglePixelBounds(rectangle) {
            status.stringValue = "Draft \(Int(pixels.width)) × \(Int(pixels.height)) px · X \(Int(pixels.minX)) Y \(Int(pixels.minY)) · \(dragSubtracts ? "Subtract" : "Add")"
        } else if style == .polygon {
            status.stringValue = "\(draftPoints.count) vertices · Return closes the outline · C copies the frozen pixel’s HEX"
        } else if let index = selectedOperationIndex, selection.operations.indices.contains(index),
                  case .rectangle(let rectangle) = selection.operations[index].shape,
                  let pixels = selection.rectanglePixelBounds(rectangle) {
            status.stringValue = "Selected \(Int(pixels.width)) × \(Int(pixels.height)) px · X \(Int(pixels.minX)) Y \(Int(pixels.minY)) · Shape \(index + 1)/\(selection.operations.count)\(selection.operations[index].subtracts ? " · Cutout" : "")"
        } else if let bounds = try? selection.enclosingPixelBounds() {
            status.stringValue = "\(Int(bounds.width)) × \(Int(bounds.height)) px bounds · \(selection.operations.count) shapes · Return to capture"
        } else {
            status.stringValue = "Frozen current display · Draw a selection · C copies HEX · Esc cancels"
        }
    }

    private func rememberSelection(points: [CGPoint]? = nil) {
        // At most 64 snapshots, each already bounded by the geometry's 8,192-point
        // limit. COW storage shares unchanged shapes; no image bytes enter undo.
        if undoHistory.count == 64 { undoHistory.removeFirst() }
        undoHistory.append(SelectionSnapshot(geometry: selection, selectedIndex: selectedOperationIndex,
                                             points: points ?? draftPoints))
    }

    @objc private func removeSelection(_ sender: Any?) {
        guard !selection.isCancelled, dragStart == nil else { return }
        if style == .polygon, !draftPoints.isEmpty {
            rememberSelection()
            draftPoints.removeLast()
        } else if let index = selectedOperationIndex ?? selection.operations.indices.last {
            do {
                var edited = selection
                try edited.removeOperation(at: index)
                rememberSelection()
                selection = edited
                selectedOperationIndex = selection.operations.indices.last
            } catch { status.stringValue = error.localizedDescription; return }
        }
        updateStatus()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func nudgeSelection(with event: NSEvent) {
        guard !selection.isCancelled, dragStart == nil, style == .multiRegion,
              let index = selectedOperationIndex,
              event.modifierFlags.intersection([.command, .control]).isEmpty else { return }
        let amount = event.modifierFlags.contains(.shift) ? 10 : 1
        let dx = event.keyCode == 123 ? -amount : event.keyCode == 124 ? amount : 0
        let dy = event.keyCode == 126 ? -amount : event.keyCode == 125 ? amount : 0
        do {
            var edited = selection
            try edited.nudgeRectangle(at: index, deltaX: dx, deltaY: dy, resizing: event.modifierFlags.contains(.option))
            if edited.operations != selection.operations {
                rememberSelection()
                selection = edited
            }
            updateStatus()
            needsDisplay = true
        } catch { status.stringValue = error.localizedDescription }
    }

    private func makeSizeControls() -> NSView {
        for (field, name) in [(widthField, "Pixel width"), (heightField, "Pixel height")] {
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.controlSize = .small
            field.alignment = .right
            field.target = self
            field.action = #selector(applyPixelDimensions(_:))
            field.delegate = self
            field.setAccessibilityLabel(name)
            field.identifier = NSUserInterfaceItemIdentifier(field === widthField ? "capturePixelWidth" : "capturePixelHeight")
            field.widthAnchor.constraint(equalToConstant: 58).isActive = true
        }
        let apply = NSButton(title: "Apply px", target: self, action: #selector(applyPixelDimensions(_:)))
        apply.bezelStyle = .rounded
        apply.controlSize = .small
        apply.font = .systemFont(ofSize: 11)
        sizeControls = [widthField, heightField, apply]
        let instructions = NSTextField(labelWithString: "Arrows: 1 px · Shift: 10 · Option: resize · ⌘Z: undo")
        instructions.font = .systemFont(ofSize: 10)
        instructions.textColor = .secondaryLabelColor
        let row = NSStackView(views: [NSTextField(labelWithString: "W"), widthField,
                                      NSTextField(labelWithString: "H"), heightField, apply, instructions])
        row.orientation = .horizontal
        row.spacing = 5
        return row
    }

    private func updateSizeFields() {
        var dimensions: CGRect?
        if let index = selectedOperationIndex, selection.operations.indices.contains(index),
           case .rectangle(let rectangle) = selection.operations[index].shape {
            dimensions = selection.rectanglePixelBounds(rectangle)
        }
        for control in sizeControls { control.isEnabled = dimensions != nil && !selection.isCancelled }
        // Pointer motion must never replace a partially typed numeric value.
        if widthField.currentEditor() == nil { widthField.stringValue = dimensions.map { String(Int($0.width)) } ?? "" }
        if heightField.currentEditor() == nil { heightField.stringValue = dimensions.map { String(Int($0.height)) } ?? "" }
    }

    @objc private func applyPixelDimensions(_ sender: Any?) {
        guard !selection.isCancelled, dragStart == nil, let index = selectedOperationIndex else { return }
        let minimumWidth = Int(ceil(2 * selection.pixelsPerPointX)), minimumHeight = Int(ceil(2 * selection.pixelsPerPointY))
        let widthText = widthField.currentEditor()?.string ?? widthField.stringValue
        let heightText = heightField.currentEditor()?.string ?? heightField.stringValue
        guard let width = Int(widthText.trimmingCharacters(in: .whitespaces)),
              let height = Int(heightText.trimmingCharacters(in: .whitespaces)),
              width >= minimumWidth, height >= minimumHeight, width <= selection.pixelWidth, height <= selection.pixelHeight else {
            status.stringValue = "Enter whole pixels: W \(minimumWidth)…\(selection.pixelWidth), H \(minimumHeight)…\(selection.pixelHeight)"
            return
        }
        do {
            var edited = selection
            try edited.setRectanglePixelSize(at: index, width: width, height: height)
            if edited.operations != selection.operations {
                rememberSelection()
                selection = edited
            }
            window?.makeFirstResponder(self)
            updateStatus()
            needsDisplay = true
        } catch { status.stringValue = error.localizedDescription }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelSelection(control)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            (control as? NSTextField)?.stringValue = textView.string
            applyPixelDimensions(control)
            return true
        }
        return false
    }

    private func updatePrecision(at point: CGPoint) {
        pointerPoint = point
        hoverPoint = point
        if let coordinate = selection.pixelCoordinate(at: point), coordinate != precisionHUD.sample?.coordinate {
            precisionHUD.sample = pixelSampler?.sample(at: coordinate)
        }
        precisionHUD.isHidden = toolbar.isHidden || precisionHUD.sample == nil || toolbar.frame.contains(point)
        positionPrecisionHUD()
    }

    private func positionPrecisionHUD() {
        guard let point = pointerPoint else { return }
        let width: CGFloat = 286, height: CGFloat = 120
        var x = point.x + 22, y = point.y + 22
        if x + width > bounds.maxX - 8 { x = point.x - width - 22 }
        if y + height > bounds.maxY - 8 { y = point.y - height - 22 }
        x = max(8, min(max(8, bounds.width - width - 8), x))
        y = max(8, min(max(8, bounds.height - height - 8), y))
        var frame = CGRect(x: x, y: y, width: width, height: height)
        if !toolbar.isHidden, frame.intersects(toolbar.frame), toolbar.frame.maxY + height + 8 < bounds.height {
            frame.origin.y = toolbar.frame.maxY + 8
        }
        precisionHUD.frame = frame
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
