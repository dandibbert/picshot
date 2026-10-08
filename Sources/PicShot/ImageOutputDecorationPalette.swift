import AppKit

/// A compact contextual popover. It previews a draft over a bounded thumbnail;
/// only Apply invokes the metadata callback. Click-away/Escape/close cancel it.
/// Keep one owner property alive while shown and call cancel() on editor close,
/// undo, crop, image replacement, or an output action. A stale job cannot publish.
@MainActor
final class ImageOutputDecorationPalette: NSObject, NSPopoverDelegate, NSTextFieldDelegate {
    static let previewQueue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "PicShot.output-decoration-preview"
        queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .userInitiated
        return queue
    }()
    private let popover = NSPopover()
    private let preview = ImageOutputDecorationPreview(frame: .zero)
    private let dimensions = NSTextField(labelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "阴影跟随图片透明轮廓；边框向内绘制。")
    private let enable = NSButton(checkboxWithTitle: "输出装饰", target: nil, action: nil)
    private let border = NSButton(checkboxWithTitle: "边框", target: nil, action: nil)
    private let shadow = NSButton(checkboxWithTitle: "阴影", target: nil, action: nil)
    private let radius = NSTextField(string: "0"), borderWidth = NSTextField(string: "1")
    private let blur = NSTextField(string: "12"), opacity = NSTextField(string: "30")
    private let offsetX = NSTextField(string: "0"), offsetY = NSTextField(string: "6")
    private let color = NSColorWell()
    private let applyButton = NSButton(title: "应用", target: nil, action: nil)
    private var transaction: ImageOutputDecorationDraft
    private let sourceWidth: Int, sourceHeight: Int
    private var source: ImageOutputDecorationRenderer.PreviewSource?
    private var input: ImageExportJobInput<CGImage>?
    private var operation: Operation?
    private var cancellation: ImageExportCancellation?
    private var generation = UUID()
    private var isFinished = false
    private var draftIsValid = true
    private var onApply: ((ImageOutputDecoration) -> Void)?
    private var onDismiss: (() -> Void)?
    var isShown: Bool { popover.isShown }
    var contentView: NSView? { popover.contentViewController?.view }
    var hasPendingPreview: Bool { operation != nil }
    var displayedPreview: CGImage? { preview.image }
    /// Add this reservation to editor admission while the palette is open. It
    /// includes the flattened RGBA input, its ephemeral normalization, and three
    /// small preview rasters. The full-frame reservation clears after preparation.
    var estimatedAdditionalRasterBytes: Int {
        guard !isFinished else { return 0 }
        let smallReserve = 3 * 1_024 * 1_024 * 4
        if source != nil { return smallReserve }
        guard sourceHeight > 0, sourceWidth <= (Int.max - smallReserve) / 8 / sourceHeight else { return Int.max }
        return sourceWidth * sourceHeight * 8 + smallReserve
    }

    init(flattened image: CGImage, decoration: ImageOutputDecoration,
         onApply: @escaping (ImageOutputDecoration) -> Void, onDismiss: (() -> Void)? = nil) {
        transaction = ImageOutputDecorationDraft(decoration)
        sourceWidth = image.width; sourceHeight = image.height
        self.onApply = onApply; self.onDismiss = onDismiss
        super.init()
        buildInterface(); displayValue()
        popover.behavior = .transient; popover.delegate = self
        // Adjacent capture palettes switch immediately. An animated close can
        // leave the canceled draft's window over the newly selected controls.
        popover.animates = false
        preparePreview(image)
    }
    deinit { cancellation?.cancel(); operation?.cancel(); input?.clear() }

    func show(relativeTo anchor: NSView) {
        guard !isFinished else { return }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }
    func cancel() {
        guard !isFinished else { return }
        transaction.cancel(); finish()
    }
    func popoverDidClose(_ notification: Notification) { cancel() }

    private func buildInterface() {
        let controller = NSViewController()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 338, height: 325))
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: controller.view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 338)
        ])
        for (field, id, label) in [(radius, "radius", "圆角半径（像素）"), (borderWidth, "borderWidth", "向内边框宽度（像素）"),
                                  (blur, "blur", "阴影模糊（像素）"), (opacity, "opacity", "阴影不透明度（百分比）"),
                                  (offsetX, "offsetX", "阴影水平偏移（正数向右）"), (offsetY, "offsetY", "阴影垂直偏移（正数向下）")] {
            field.delegate = self; field.target = self; field.action = #selector(changed)
            field.controlSize = .small; field.font = .systemFont(ofSize: 11)
            field.identifier = .init("decoration.\(id)"); field.setAccessibilityLabel(label)
            field.toolTip = label; field.widthAnchor.constraint(equalToConstant: 43).isActive = true
        }
        for (button, id) in [(enable, "enabled"), (border, "border"), (shadow, "shadow")] {
            button.controlSize = .small; button.target = self; button.action = #selector(changed)
            button.identifier = .init("decoration.\(id)")
        }
        color.target = self; color.action = #selector(changed); color.controlSize = .small; color.isBordered = false
        color.identifier = .init("decoration.borderColor"); color.setAccessibilityLabel("边框颜色")
        color.widthAnchor.constraint(equalToConstant: 24).isActive = true
        color.heightAnchor.constraint(equalToConstant: 22).isActive = true
        preview.widthAnchor.constraint(equalToConstant: 314).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 100).isActive = true
        preview.identifier = .init("decoration.preview"); preview.setAccessibilityLabel("装饰输出预览")
        dimensions.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        dimensions.identifier = .init("decoration.dimensions")
        hint.font = .systemFont(ofSize: 10); hint.textColor = .secondaryLabelColor
        hint.widthAnchor.constraint(equalToConstant: 314).isActive = true
        stack.addArrangedSubview(row([enable, label("圆角"), radius, label("px")]))
        stack.addArrangedSubview(preview); stack.addArrangedSubview(dimensions)
        stack.addArrangedSubview(row([border, borderWidth, label("px"), color]))
        stack.addArrangedSubview(row([shadow, label("模糊"), blur, label("强度"), opacity, label("%")]))
        stack.addArrangedSubview(row([label("偏移 →"), offsetX, label("↓"), offsetY, label("px，可为负数")]))
        stack.addArrangedSubview(hint)
        let reset = NSButton(title: "重置", target: self, action: #selector(resetDraft))
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelDraft))
        reset.identifier = .init("decoration.reset"); cancel.identifier = .init("decoration.cancel")
        applyButton.target = self; applyButton.action = #selector(applyDraft); applyButton.identifier = .init("decoration.apply")
        applyButton.keyEquivalent = "\r"; cancel.keyEquivalent = "\u{1b}"
        for button in [reset, cancel, applyButton] { button.bezelStyle = .rounded; button.controlSize = .small }
        stack.addArrangedSubview(row([reset, cancel, applyButton]))
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 338, height: 325)
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal
        stack.alignment = .centerY; stack.spacing = 6; return stack
    }
    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: 11); return field
    }
    private func displayValue() {
        let value = transaction.value
        enable.state = value.enabled ? .on : .off; border.state = value.borderEnabled ? .on : .off
        shadow.state = value.shadowEnabled ? .on : .off
        for (field, number) in [(radius, value.cornerRadius), (borderWidth, value.borderWidth), (blur, value.shadowBlur),
                                (opacity, value.shadowOpacity * 100), (offsetX, value.shadowOffsetX), (offsetY, value.shadowOffsetY)] {
            field.stringValue = String(format: "%.2f", number).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        }
        color.color = NSColor(srgbRed: value.borderColor.red, green: value.borderColor.green,
                             blue: value.borderColor.blue, alpha: value.borderColor.alpha)
        updateEnabledControls()
    }
    private func updateEnabledControls() {
        let enabled = enable.state == .on
        radius.isEnabled = enabled; border.isEnabled = enabled; shadow.isEnabled = enabled
        borderWidth.isEnabled = enabled && border.state == .on; color.isEnabled = borderWidth.isEnabled
        for field in [blur, opacity, offsetX, offsetY] { field.isEnabled = enabled && shadow.state == .on }
    }
    func controlTextDidChange(_ notification: Notification) { changed() }
    @objc private func changed() {
        guard !isFinished else { return }
        updateEnabledControls()
        do {
            func number(_ field: NSTextField) throws -> Double {
                guard let result = Double(field.stringValue), result.isFinite else { throw ImageOutputDecorationError.invalidOptions }
                return result
            }
            var value = transaction.value
            value.enabled = enable.state == .on; value.borderEnabled = border.state == .on; value.shadowEnabled = shadow.state == .on
            if value.enabled {
                value.cornerRadius = try number(radius); value.borderWidth = try number(borderWidth)
                value.shadowBlur = try number(blur); value.shadowOpacity = try number(opacity) / 100
                value.shadowOffsetX = try number(offsetX); value.shadowOffsetY = try number(offsetY)
                guard let rgb = color.color.usingColorSpace(.sRGB) else { throw ImageOutputDecorationError.invalidOptions }
                value.borderColor = .init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
                try value.validate()
            }
            _ = try ImageOutputDecorationLayout.make(width: sourceWidth, height: sourceHeight, decoration: value)
            transaction.value = value; draftIsValid = true; requestPreview()
        } catch {
            draftIsValid = false
            if source != nil { invalidateJob() }
            applyButton.isEnabled = false; hint.stringValue = error.localizedDescription
        }
    }
    @objc private func resetDraft() { transaction.reset(); draftIsValid = true; displayValue(); requestPreview() }
    @objc private func cancelDraft() { cancel() }
    @objc private func applyDraft() {
        guard !isFinished, applyButton.isEnabled else { return }
        do {
            let value = try transaction.apply(), callback = onApply
            finish()
            if let value { callback?(value) }
        } catch { hint.stringValue = error.localizedDescription; applyButton.isEnabled = false }
    }

    private func preparePreview(_ image: CGImage) {
        invalidateJob(); applyButton.isEnabled = false; hint.stringValue = "正在生成预览…"
        let generation = self.generation, cancellation = ImageExportCancellation(), input = ImageExportJobInput(image)
        self.cancellation = cancellation; self.input = input
        let job = BlockOperation { [weak self] in
            guard let image = input.take() else { return }
            let result = Result { try ImageOutputDecorationRenderer.previewSource(image: image, cancellation: cancellation) }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isFinished, self.generation == generation else { return }
                self.operation = nil; self.cancellation = nil; self.input = nil
                switch result {
                case .success(let source): self.source = source; self.requestPreview()
                case .failure(let error): self.hint.stringValue = error.localizedDescription
                }
            }
        }
        operation = job; Self.previewQueue.addOperation(job)
    }
    private func requestPreview() {
        guard !isFinished, draftIsValid else { return }
        // Initial thumbnail work is shared by successive edits. Do not cancel it
        // merely because the user changes a field before that source is ready.
        guard let source else { return }
        invalidateJob(); applyButton.isEnabled = false
        let value = transaction.value
        let layout: ImageOutputDecorationLayout
        do { layout = try .make(width: sourceWidth, height: sourceHeight, decoration: value) }
        catch { hint.stringValue = error.localizedDescription; return }
        dimensions.stringValue = "原图 \(sourceWidth) × \(sourceHeight) → 输出 \(layout.width) × \(layout.height) px"
        hint.stringValue = "阴影随透明轮廓；留白 上\(layout.top) 下\(layout.bottom) 左\(layout.left) 右\(layout.right) px"
        let generation = self.generation, cancellation = ImageExportCancellation(), input = ImageExportJobInput(source.image)
        self.cancellation = cancellation; self.input = input
        let scaled = value.scaled(by: source.scale)
        let job = BlockOperation { [weak self] in
            guard let image = input.take() else { return }
            let result = Result { try ImageOutputDecorationRenderer.project(flattened: image, decoration: scaled, cancellation: cancellation) }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isFinished, self.generation == generation else { return }
                self.operation = nil; self.cancellation = nil; self.input = nil
                switch result {
                case .success(let image): self.preview.image = image; self.applyButton.isEnabled = true
                case .failure(let error): self.hint.stringValue = error.localizedDescription
                }
            }
        }
        operation = job; Self.previewQueue.addOperation(job)
    }
    private func invalidateJob() {
        generation = UUID(); cancellation?.cancel(); cancellation = nil
        operation?.cancel(); operation = nil; input?.clear(); input = nil
    }
    private func finish() {
        guard !isFinished else { return }
        isFinished = true; invalidateJob(); color.deactivate(); preview.image = nil; source = nil
        onApply = nil; let callback = onDismiss; onDismiss = nil
        popover.delegate = nil; popover.close()
        callback?()
    }
}

@MainActor
private final class ImageOutputDecorationPreview: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        for y in stride(from: 0, to: Int(bounds.height), by: 8) {
            for x in stride(from: 0, to: Int(bounds.width), by: 8) where (x / 8 + y / 8) % 2 == 0 {
                NSColor.quaternaryLabelColor.setFill(); NSRect(x: x, y: y, width: 8, height: 8).fill()
            }
        }
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = min((bounds.width - 8) / CGFloat(image.width), (bounds.height - 8) / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
    }
}
