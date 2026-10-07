import AppKit
import PicShotCore

/// Compact output navigator. Plain drag keeps band-selection semantics during editing;
/// Option-drag, the overview, scroll wheels and navigation buttons always pan the view.
/// The 800 px overview and bounded sampled detail are never called full resolution.
@MainActor
final class ScrollSequencePreview: NSView {
    var image: NSImage? { didSet { needsDisplay = true; updateStatus() } }
    var layout: ScrollSequenceLayout? {
        didSet {
            if layout != oldValue {
                if oldValue == nil, let layout { center = CGPoint(x: CGFloat(layout.width) / 2, y: CGFloat(layout.height) / 2) }
                invalidateDetail()
            }
            if layout == nil { clearDetail(); zoom = 1 }
            layoutControls(); needsDisplay = true; updateStatus()
        }
    }
    var axis: ScrollAxis = .vertical { didSet {
        if axis != oldValue { invalidateDetail() }
        layoutControls(); needsDisplay = true
    } }
    var selectedID: UUID? { didSet { needsDisplay = true } }
    var selectedRange: Range<Int>? { didSet { needsDisplay = true } }
    var allowsSelection = false
    var onSelect: ((UUID) -> Void)?
    var onDelete: (() -> Void)?
    var onBandSelect: ((Range<Int>) -> Void)?
    private(set) var latestDocumentViewport: Range<Int>?
    private var sources: [StoredScrollSource] = []
    private var zoom: CGFloat = 1
    private var center = CGPoint.zero
    private var dragAnchor: Int?
    private var panAnchor: CGPoint?
    private var panCenter: CGPoint?
    private var draggingOverview = false
    private var detailWorker: Task<CGImage, Error>?
    private var pendingRequest: ScrollPreviewTileRequest?
    private var activeRequest: ScrollPreviewTileRequest?
    private var cachedRequest: ScrollPreviewTileRequest?
    private var detailImage: NSImage?
    private var generation: UInt64 = 0
    private var detailFailure = false
    private let toolbar = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { layout != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolbar.orientation = .horizontal; toolbar.spacing = 3
        let definitions: [(String, String, Selector, String)] = [
            ("适合", "fit", #selector(fitAction), "显示完整长截图"),
            ("起点", "beginning", #selector(beginningAction), "查看长截图起点"),
            ("中部", "middle", #selector(middleAction), "查看长截图中部"),
            ("终点", "end", #selector(endAction), "查看长截图终点"),
            ("最新", "latest", #selector(latestAction), "查看最新捕获视口，青框标示保留部分"),
            ("−", "zoomOut", #selector(zoomOutAction), "缩小采样预览"),
            ("+", "zoomIn", #selector(zoomInAction), "放大采样预览")
        ]
        for (title, name, action, help) in definitions {
            let button = NSButton(title: title, target: self, action: action)
            button.controlSize = .small; button.bezelStyle = .rounded
            button.identifier = NSUserInterfaceItemIdentifier("scroll.preview." + name)
            button.setAccessibilityLabel(help); button.toolTip = help
            toolbar.addArrangedSubview(button)
        }
        addSubview(toolbar)
        statusLabel.font = .systemFont(ofSize: 9)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.identifier = NSUserInterfaceItemIdentifier("scroll.preview.resolution")
        addSubview(statusLabel)
        toolTip = "滚轮或 Option 拖动平移；双指缩放；右侧或底部总览可拖动定位。编辑时直接拖动仍选择删除范围。"
        setAccessibilityLabel("长截图采样预览，青框为最新捕获视口；使用起点、中部、终点及缩放按钮浏览。")
    }
    required init?(coder: NSCoder) { return nil }
    deinit { detailWorker?.cancel() }

    func updateProjection(layout: ScrollSequenceLayout, axis: ScrollAxis, sources: [StoredScrollSource], viewport: Range<Int>) {
        let changedSources = self.sources.map(\.id) != sources.map(\.id) || self.sources.map(\.url) != sources.map(\.url)
        self.sources = sources
        self.axis = axis
        self.latestDocumentViewport = viewport
        self.layout = layout
        if changedSources { invalidateDetail() }
        updateStatus(); needsDisplay = true
        scheduleDetail()
    }

    /// Call before releasing the spool. An ImageIO call already in progress may finish,
    /// but cancellation and generation checks prevent late publication or a second job.
    func clearDetail() {
        generation &+= 1; detailWorker?.cancel()
        pendingRequest = nil; cachedRequest = nil; activeRequest = nil
        detailImage = nil; sources = []; latestDocumentViewport = nil
        detailFailure = false; dragAnchor = nil; panAnchor = nil; panCenter = nil
        draggingOverview = false; needsDisplay = true
    }

    var latestOutputRanges: [Range<Int>] {
        guard let layout, let latestDocumentViewport else { return [] }
        return ScrollPreviewGeometry.project(latestDocumentViewport, into: layout)
    }
    private var outputSize: CGSize { CGSize(width: layout?.width ?? 0, height: layout?.height ?? 0) }
    private var outputLength: Int { axis == .vertical ? layout?.height ?? 0 : layout?.width ?? 0 }
    var canvasRect: CGRect {
        let body = CGRect(x: bounds.minX + 5, y: bounds.minY + 29,
                          width: max(0, bounds.width - 10), height: max(0, bounds.height - 48))
        return axis == .vertical
            ? CGRect(x: body.minX, y: body.minY, width: max(0, body.width - 38), height: body.height)
            : CGRect(x: body.minX, y: body.minY, width: body.width, height: max(0, body.height - 21))
    }
    var overviewRect: CGRect {
        let canvas = canvasRect
        return axis == .vertical
            ? CGRect(x: canvas.maxX + 6, y: canvas.minY, width: 32, height: canvas.height)
            : CGRect(x: canvas.minX, y: canvas.maxY + 6, width: canvas.width, height: 15)
    }
    private var scale: CGFloat { ScrollPreviewGeometry.fitScale(output: outputSize, viewport: canvasRect) * zoom }
    var imageRect: CGRect {
        ScrollPreviewGeometry.imageRect(output: outputSize, viewport: canvasRect, scale: scale, center: center)
    }
    var visibleOutputRect: CGRect {
        ScrollPreviewGeometry.visibleOutput(imageRect: imageRect, viewport: canvasRect, output: outputSize)
    }
    var overviewImageRect: CGRect {
        ScrollPreviewGeometry.imageRect(output: outputSize, viewport: overviewRect,
            scale: ScrollPreviewGeometry.fitScale(output: outputSize, viewport: overviewRect),
            center: CGPoint(x: outputSize.width / 2, y: outputSize.height / 2))
    }
    private func viewRect(for outputRect: CGRect, in rect: CGRect) -> CGRect {
        guard outputSize.width > 0, outputSize.height > 0 else { return .zero }
        return CGRect(x: rect.minX + outputRect.minX / outputSize.width * rect.width,
                      y: rect.minY + outputRect.minY / outputSize.height * rect.height,
                      width: outputRect.width / outputSize.width * rect.width,
                      height: outputRect.height / outputSize.height * rect.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutControls(); scheduleDetail()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layoutControls(); scheduleDetail()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        scheduleDetail()
    }
    private func layoutControls() {
        toolbar.frame = CGRect(x: bounds.minX + 5, y: bounds.minY + 3, width: max(0, bounds.width - 10), height: 23)
        statusLabel.frame = CGRect(x: bounds.minX + 6, y: bounds.maxY - 17, width: max(0, bounds.width - 12), height: 14)
    }
    func showFit() { zoom = 1; changedView() }
    enum Location { case beginning, middle, end, latest }
    func navigate(to location: Location) {
        guard layout != nil, canvasRect.width > 0, canvasRect.height > 0 else { return }
        let crossScale = axis == .vertical ? canvasRect.width / outputSize.width : canvasRect.height / outputSize.height
        let fit = ScrollPreviewGeometry.fitScale(output: outputSize, viewport: canvasRect)
        zoom = max(1, min(2, crossScale) / max(fit, .leastNonzeroMagnitude))
        center = CGPoint(x: outputSize.width / 2, y: outputSize.height / 2)
        let coordinate: CGFloat
        switch location {
        case .beginning: coordinate = 0
        case .middle: coordinate = CGFloat(outputLength) / 2
        case .end: coordinate = CGFloat(outputLength)
        case .latest:
            let ranges = latestOutputRanges
            guard let first = ranges.first, let last = ranges.last else { showFit(); return }
            coordinate = CGFloat(first.lowerBound + last.upperBound) / 2
            let visibleLength = CGFloat(last.upperBound - first.lowerBound)
            let along = axis == .vertical ? canvasRect.height : canvasRect.width
            zoom = max(1, min(crossScale, along / max(1, visibleLength)) / max(fit, .leastNonzeroMagnitude))
        }
        if axis == .vertical { center.y = coordinate } else { center.x = coordinate }
        changedView()
    }
    func zoomPreview(by factor: CGFloat) {
        guard factor.isFinite, factor > 0 else { return }
        let fit = ScrollPreviewGeometry.fitScale(output: outputSize, viewport: canvasRect)
        guard fit > 0 else { return }
        zoom = max(1, min(max(1, 4 / fit), zoom * factor))
        changedView()
    }
    func panPreview(by delta: CGPoint) {
        guard scale > 0 else { return }
        center.x -= delta.x / scale; center.y -= delta.y / scale; changedView()
    }
    private func changedView() {
        center = ScrollPreviewGeometry.clampedCenter(center, output: outputSize, viewport: canvasRect, scale: scale)
        scheduleDetail(); updateStatus(); needsDisplay = true
    }
    @objc private func fitAction() { showFit() }
    @objc private func beginningAction() { navigate(to: .beginning) }
    @objc private func middleAction() { navigate(to: .middle) }
    @objc private func endAction() { navigate(to: .end) }
    @objc private func latestAction() { navigate(to: .latest) }
    @objc private func zoomOutAction() { zoomPreview(by: 0.5) }
    @objc private func zoomInAction() { zoomPreview(by: 2) }

    func block(at point: CGPoint) -> UUID? {
        guard allowsSelection, let layout, canvasRect.contains(point), imageRect.contains(point),
              let pixel = pixel(at: point) else { return nil }
        return layout.strips.first { pixel >= $0.outputStart && pixel < $0.outputStart + $0.block.length }?.block.id
    }
    private func pixel(at point: CGPoint) -> Int? {
        ScrollPreviewGeometry.pixel(at: point, imageRect: imageRect, length: outputLength, axis: axis)
    }
    private func moveOverview(to point: CGPoint) {
        let rect = overviewImageRect
        guard rect.width > 0, rect.height > 0 else { return }
        if zoom == 1 { navigate(to: .middle) }
        center = CGPoint(x: (point.x - rect.minX) / rect.width * outputSize.width,
                         y: (point.y - rect.minY) / rect.height * outputSize.height)
        changedView()
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard layout != nil else { return }
        window?.makeFirstResponder(self)
        if overviewRect.contains(point) { draggingOverview = true; moveOverview(to: point); return }
        guard canvasRect.contains(point) else { return }
        if !allowsSelection || event.modifierFlags.contains(.option) {
            panAnchor = point; panCenter = center; return
        }
        guard let id = block(at: point) else { return }
        selectedRange = nil; dragAnchor = pixel(at: point)
        selectedID = id; onSelect?(id)
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if draggingOverview { moveOverview(to: point); return }
        if let anchor = panAnchor, let original = panCenter, scale > 0 {
            center = CGPoint(x: original.x - (point.x - anchor.x) / scale,
                             y: original.y - (point.y - anchor.y) / scale)
            changedView(); return
        }
        guard allowsSelection, let start = dragAnchor, let end = pixel(at: point), start != end else { return }
        let range = min(start, end)..<(max(start, end) + 1)
        selectedRange = range; selectedID = nil; onBandSelect?(range)
    }
    override func mouseUp(with event: NSEvent) { dragAnchor = nil; panAnchor = nil; panCenter = nil; draggingOverview = false }
    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard canvasRect.contains(point) || overviewRect.contains(point) else { super.scrollWheel(with: event); return }
        if event.modifierFlags.contains(.command) { zoomPreview(by: pow(1.01, event.scrollingDeltaY)) }
        else {
            let amount: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            let horizontalWheel = axis == .horizontal && event.scrollingDeltaX == 0
            let x = horizontalWheel ? event.scrollingDeltaY : event.scrollingDeltaX
            let y = horizontalWheel ? 0 : event.scrollingDeltaY
            panPreview(by: CGPoint(x: x * amount, y: y * amount))
        }
    }
    override func magnify(with event: NSEvent) { zoomPreview(by: max(0.1, 1 + event.magnification)) }
    override func keyDown(with event: NSEvent) {
        if allowsSelection && (event.keyCode == 51 || event.keyCode == 117) { onDelete?(); return }
        switch event.keyCode {
        case 115: navigate(to: .beginning)
        case 119: navigate(to: .end)
        case 116: panPreview(by: axis == .vertical ? CGPoint(x: 0, y: canvasRect.height * 0.8) : CGPoint(x: canvasRect.width * 0.8, y: 0))
        case 121: panPreview(by: axis == .vertical ? CGPoint(x: 0, y: -canvasRect.height * 0.8) : CGPoint(x: -canvasRect.width * 0.8, y: 0))
        case 123: panPreview(by: CGPoint(x: 40, y: 0))
        case 124: panPreview(by: CGPoint(x: -40, y: 0))
        case 125: panPreview(by: CGPoint(x: 0, y: -40))
        case 126: panPreview(by: CGPoint(x: 0, y: 40))
        default: super.keyDown(with: event)
        }
    }

    private func invalidateDetail() {
        generation &+= 1; detailWorker?.cancel(); pendingRequest = nil
        cachedRequest = nil; detailImage = nil; detailFailure = false
    }
    private func scheduleDetail() {
        guard let layout, !sources.isEmpty, zoom > 1,
              let request = try? ScrollPreviewTileRequest(outputSize: outputSize, visibleRect: visibleOutputRect,
                  displayScale: scale * (window?.backingScaleFactor ?? 1)) else {
            if pendingRequest != nil || detailWorker != nil { generation &+= 1; detailWorker?.cancel(); pendingRequest = nil }
            cachedRequest = nil; detailImage = nil; return
        }
        if cachedRequest == request, detailImage != nil {
            if detailWorker != nil { generation &+= 1; detailWorker?.cancel() }
            pendingRequest = nil; return
        }
        if activeRequest == request, detailWorker != nil, !detailWorker!.isCancelled { return }
        if pendingRequest == request { return }
        generation &+= 1; detailWorker?.cancel(); pendingRequest = request
        startPendingDetail(layout: layout)
    }
    private func startPendingDetail(layout: ScrollSequenceLayout) {
        // A canceled decoder still owns its slot until it returns. No overlapping jobs.
        guard detailWorker == nil, let request = pendingRequest, !sources.isEmpty else { return }
        pendingRequest = nil; activeRequest = request
        let version = generation, capturedSources = sources, capturedAxis = axis
        let worker = Task.detached(priority: .utility) {
            try ScrollImageIO.sequencePreviewTile(capturedSources, layout: layout, axis: capturedAxis, request: request)
        }
        detailWorker = worker
        Task { [weak self] in
            let result = await worker.result
            guard let self else { return }
            self.detailWorker = nil; self.activeRequest = nil
            if version == self.generation {
                switch result {
                case .success(let raster):
                    self.detailImage = NSImage(cgImage: raster, size: NSSize(width: raster.width, height: raster.height))
                    self.cachedRequest = request; self.detailFailure = false
                case .failure(let error): self.detailFailure = !(error is CancellationError)
                }
                self.updateStatus(); self.needsDisplay = true
            }
            if let current = self.layout { self.startPendingDetail(layout: current) }
        }
    }
    private func updateStatus() {
        let hasLayout = layout != nil
        for case let button as NSButton in toolbar.arrangedSubviews {
            button.isEnabled = hasLayout && (button.identifier?.rawValue != "scroll.preview.latest" || !latestOutputRanges.isEmpty)
        }
        let text: String
        if !hasLayout { text = "捕获后可浏览完整长截图" }
        else if detailFailure { text = "细节读取失败 · 总览≤800 px · 原图不变" }
        else if zoom > 1 && detailImage == nil {
            text = sources.isEmpty ? "放大总览≤800 px · 青框：最新视口" : "正在读取采样细节 · 当前总览≤800 px"
        } else if zoom > 1 {
            text = "采样预览 \(Int((scale * 100).rounded()))% · 源≤2048 px · 青框：最新视口"
        } else { text = "总览≤800 px · 青框：最新视口 · 放大查看采样细节" }
        statusLabel.stringValue = text
        statusLabel.setAccessibilityValue(text)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        guard let image, let layout else { return }
        let rect = imageRect
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: canvasRect).addClip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if let detailImage, let cachedRequest {
            detailImage.draw(in: viewRect(for: cachedRequest.outputRect, in: rect), from: .zero,
                             operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        drawViewport(in: rect)
        if allowsSelection {
            for strip in layout.strips {
                let area = ScrollPreviewGeometry.bandRect(strip.outputStart..<(strip.outputStart + strip.block.length),
                                                          imageRect: rect, length: outputLength, axis: axis)
                let selected = strip.block.id == selectedID
                (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
                let path = NSBezierPath(rect: area.insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = selected ? 2 : 1; path.stroke()
                if selected { NSColor.controlAccentColor.withAlphaComponent(0.16).setFill(); NSBezierPath(rect: area).fill() }
            }
            if let selectedRange {
                let band = ScrollPreviewGeometry.bandRect(selectedRange, imageRect: rect, length: outputLength, axis: axis)
                NSColor.systemRed.withAlphaComponent(0.26).setFill(); NSBezierPath(rect: band).fill()
                NSColor.systemRed.setStroke(); let outline = NSBezierPath(rect: band); outline.lineWidth = 2; outline.stroke()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let mini = overviewImageRect
        image.draw(in: mini, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        drawViewport(in: mini)
        let visible = viewRect(for: visibleOutputRect, in: mini).intersection(overviewRect)
        if !visible.isNull {
            NSColor.labelColor.setStroke(); let path = NSBezierPath(rect: visible.insetBy(dx: 0.5, dy: 0.5)); path.lineWidth = 1.5; path.stroke()
        }
    }
    private func drawViewport(in rect: CGRect) {
        for range in latestOutputRanges {
            let band = ScrollPreviewGeometry.bandRect(range, imageRect: rect, length: outputLength, axis: axis)
            NSColor.systemTeal.withAlphaComponent(0.1).setFill(); NSBezierPath(rect: band).fill()
            NSColor.systemTeal.setStroke()
            let outline = NSBezierPath(rect: band.insetBy(dx: 1, dy: 1)); outline.lineWidth = 2
            outline.setLineDash([4, 2], count: 2, phase: 0); outline.stroke()
        }
    }

    /// Owned-window evidence only: never posts events or invokes screen capture/TCC.
    var snapshotForVerification: [String: Any] {
        ["outputWidth": layout?.width ?? 0, "outputHeight": layout?.height ?? 0,
         "zoom": Double(zoom), "displayScale": Double(scale),
         "visibleRect": [Double(visibleOutputRect.minX), Double(visibleOutputRect.minY), Double(visibleOutputRect.width), Double(visibleOutputRect.height)],
         "latestOutputRanges": latestOutputRanges.map { [$0.lowerBound, $0.upperBound] },
         "tileWidth": cachedRequest?.pixelWidth ?? 0, "tileHeight": cachedRequest?.pixelHeight ?? 0,
         "activeJobs": detailWorker == nil ? 0 : 1, "pendingJobs": pendingRequest == nil ? 0 : 1,
         "cachedTiles": detailImage == nil ? 0 : 1, "sourceReferences": sources.count,
         "resolutionLabel": statusLabel.stringValue]
    }
    var detailImageForVerification: CGImage? { detailImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
    var detailRequestForVerification: ScrollPreviewTileRequest? { cachedRequest }
    func waitForDetailForVerification() async {
        while let worker = detailWorker { _ = await worker.result; await Task.yield() }
    }
}
