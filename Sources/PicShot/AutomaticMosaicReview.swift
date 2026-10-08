import AppKit
import PicShotCore

/// Stored entirely inside ImageAnnotation; no raster or task enters history.
struct AutomaticMosaicLink {
    var groupID: UUID
    var additionID: UUID
    var rootAdditionID: UUID
    var target: CGRect
    var includedTargets: [CGRect]
    var excludedTargets: [CGRect]
    var synchronizes: Bool

    func forTarget(_ target: CGRect, additionID: UUID) -> Self {
        var copy = self; copy.target = target; copy.additionID = additionID; return copy
    }
}

extension ImageAnnotation {
    var supportsAutomaticMosaic: Bool {
        mosaicLink == nil && [.pixelate, .blur, .redact].contains(tool) && rotation.isFinite && abs(rotation) < 0.000_001
            && points.count == 2 && [localBounds.minX, localBounds.minY, localBounds.width, localBounds.height].allSatisfy({ $0.isFinite })
            && localBounds.width >= 3 && localBounds.height >= 3
    }
}

enum AutomaticMosaicCoordinates {
    static func pixelRect(_ requested: CGRect, imageHeight: Int) -> RepeatedRegionPixelRect? {
        guard imageHeight > 0, imageHeight <= RepeatedRegionMatchLimits.maximumDimension,
              [requested.origin.x, requested.origin.y, requested.width, requested.height].allSatisfy({ $0.isFinite }) else { return nil }
        let rect = requested.standardized.integral
        let limit = CGFloat(RepeatedRegionMatchLimits.maximumDimension)
        guard rect.minX >= 0, rect.minY >= 0, rect.width >= 3, rect.height >= 3,
              rect.maxX <= limit, rect.maxY <= CGFloat(imageHeight) else { return nil }
        return RepeatedRegionPixelRect(x: Int(rect.minX), y: imageHeight - Int(rect.maxY), width: Int(rect.width), height: Int(rect.height))
    }
    static func imageRect(_ rect: RepeatedRegionPixelRect, imageHeight: Int) -> CGRect? {
        let limit = RepeatedRegionMatchLimits.maximumDimension
        guard imageHeight > 0, imageHeight <= limit, rect.x >= 0, rect.y >= 0,
              rect.width >= 3, rect.width <= limit, rect.height >= 3, rect.height <= imageHeight,
              rect.x <= limit - rect.width, rect.y <= imageHeight - rect.height else { return nil }
        return CGRect(x: rect.x, y: imageHeight - rect.y - rect.height, width: rect.width, height: rect.height)
    }
}

enum AutomaticMosaicModelLimits {
    /// Eight full 25-region additions, including their bounded value metadata.
    static let maximumLinkedAnnotations = 200
}

struct AutomaticMosaicReviewCandidate {
    var rect: CGRect
    var confidence: Double
    var included: Bool
    var isSeed = false
    var isManual = false
}

struct AutomaticMosaicReviewState {
    enum Phase: Equatable { case searching, ready, failed }
    static let maximumCandidates = 25 // Includes the seed; manual additions share this limit.
    var phase: Phase
    let generation: UUID
    let sourceIdentity: ObjectIdentifier
    let sourceRevision: UInt64
    let sourceWidth: Int
    let sourceHeight: Int
    let seed: ImageAnnotation
    let replacingID: UUID?
    var candidates: [AutomaticMosaicReviewCandidate]
    var selectedIndex = 0
    var synchronizes = true
    var truncated = false
    var message = ""
    var includedCount: Int { candidates.filter(\.included).count }

    func draw(in context: CGContext, zoom: CGFloat) {
        let scale = max(0.05, zoom)
        for (index, candidate) in candidates.enumerated() {
            context.saveGState()
            let ink = candidate.included ? NSColor.systemBlue : NSColor.systemOrange
            context.setFillColor(ink.withAlphaComponent(candidate.included ? 0.10 : 0.025).cgColor)
            context.fill(candidate.rect)
            context.setStrokeColor(NSColor.white.cgColor); context.setLineWidth(4 / scale)
            context.stroke(candidate.rect)
            context.setStrokeColor(ink.cgColor); context.setLineWidth((index == selectedIndex ? 2.5 : 1.5) / scale)
            if !candidate.included { context.setLineDash(phase: 0, lengths: [5 / scale, 3 / scale]) }
            context.stroke(candidate.rect)
            if !candidate.included {
                context.move(to: candidate.rect.origin)
                context.addLine(to: CGPoint(x: candidate.rect.maxX, y: candidate.rect.maxY)); context.strokePath()
            }
            context.restoreGState()
        }
    }

    func committedAnnotations() -> [ImageAnnotation] {
        guard phase == .ready else { return [] }
        let included = candidates.filter(\.included).map(\.rect)
        let excluded = candidates.filter { !$0.included }.map(\.rect)
        let group = UUID(), addition = UUID()
        return included.map { rect in
            var mark = seed; mark.id = UUID(); mark.rotation = 0
            mark.points = [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)]
            if mark.tool == .redact { mark.opacity = 1; mark.color = mark.color.copy(alpha: 1) ?? CGColor(gray: 0, alpha: 1) }
            mark.mosaicLink = AutomaticMosaicLink(groupID: group, additionID: addition, rootAdditionID: addition, target: rect,
                includedTargets: included, excludedTargets: excluded, synchronizes: synchronizes)
            return mark
        }
    }
}

/// Fixed-height, image-anchored review with one candidate at a time in its controls.
/// The candidates themselves are all visible as outlines in the original image.
@MainActor
final class AutomaticMosaicReviewSurface: EditorFloatingSurface {
    let statusLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let previousButton = NSButton(title: "‹", target: nil, action: nil)
    let nextButton = NSButton(title: "›", target: nil, action: nil)
    let includeButton = NSButton(checkboxWithTitle: "包括此处", target: nil, action: nil)
    let syncButton = NSButton(checkboxWithTitle: "同步增删", target: nil, action: nil)
    let addButton = NSButton(title: "+ 区域", target: nil, action: nil)
    let applyButton = NSButton(title: "应用", target: nil, action: nil)
    let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onInclude: (() -> Void)?
    var onSync: ((Bool) -> Void)?
    var onAdd: (() -> Void)?
    var onApply: (() -> Void)?
    var onCancel: (() -> Void)?
    static let preferredSize = CGSize(width: 326, height: 110)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = .init("mosaic.review")
        orientation = .vertical; alignment = .leading; spacing = 5
        edgeInsets = NSEdgeInsets(top: 8, left: 9, bottom: 8, right: 9)
        statusLabel.identifier = .init("mosaic.review.status")
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        detailLabel.font = .systemFont(ofSize: 10); detailLabel.textColor = .secondaryLabelColor
        for label in [statusLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 306).isActive = true
        }
        addArrangedSubview(statusLabel); addArrangedSubview(detailLabel)
        let navigation = NSStackView(views: [previousButton, nextButton, includeButton, addButton])
        navigation.orientation = .horizontal; navigation.spacing = 6
        let actions = NSStackView(views: [syncButton, cancelButton, applyButton])
        actions.orientation = .horizontal; actions.spacing = 10
        addArrangedSubview(navigation); addArrangedSubview(actions)
        configure(previousButton, "previous", "上一个匹配", #selector(previous))
        configure(nextButton, "next", "下一个匹配", #selector(next))
        configure(includeButton, "include", "包括或排除此处", #selector(include))
        configure(syncButton, "sync", "同步相同内容的区域增删和样式", #selector(sync))
        configure(addButton, "add", "手动画出漏掉的同尺寸匹配区域", #selector(add))
        configure(applyButton, "apply", "应用已包括的区域", #selector(apply))
        configure(cancelButton, "cancel", "取消自动马赛克", #selector(cancel))
        previousButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        nextButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        applyButton.bezelStyle = .rounded; cancelButton.bezelStyle = .rounded
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure(_ button: NSButton, _ suffix: String, _ label: String, _ action: Selector) {
        button.identifier = .init("mosaic.review.\(suffix)"); button.setAccessibilityLabel(label)
        button.toolTip = label; button.target = self; button.action = action; button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
    }

    func display(_ state: AutomaticMosaicReviewState?, drawing: Bool = false) {
        guard let state else { isHidden = true; return }
        isHidden = false
        let ready = state.phase == .ready
        switch state.phase {
        case .searching: statusLabel.stringValue = "正在本机查找相同内容…"
        case .failed: statusLabel.stringValue = state.message
        case .ready:
            statusLabel.stringValue = drawing ? "在图片上拖出漏掉的区域 · Esc 取消" : "包括 \(state.includedCount)/\(state.candidates.count) 处 · \(state.selectedIndex + 1)/\(state.candidates.count)"
        }
        statusLabel.toolTip = statusLabel.stringValue
        detailLabel.stringValue = state.truncated ? "结果已达上限；请分批处理 · 同尺寸、未旋转" : "同尺寸、未旋转 · 模糊/马赛克不能安全隐藏敏感内容"
        detailLabel.toolTip = detailLabel.stringValue
        previousButton.isEnabled = ready && state.candidates.count > 1 && !drawing
        nextButton.isEnabled = previousButton.isEnabled
        includeButton.isEnabled = ready && !drawing
        includeButton.state = state.candidates.indices.contains(state.selectedIndex) && state.candidates[state.selectedIndex].included ? .on : .off
        syncButton.state = state.synchronizes ? .on : .off; syncButton.isEnabled = ready && !drawing
        addButton.isEnabled = ready && state.candidates.count < AutomaticMosaicReviewState.maximumCandidates && !drawing
        applyButton.isEnabled = ready && state.includedCount > 0 && !drawing
    }

    func displayDrawing(_ message: String) {
        isHidden = false; statusLabel.stringValue = message; statusLabel.toolTip = message
        detailLabel.stringValue = "在原始截图上框选 · 同尺寸、未旋转 · Esc 取消"
        for control in [previousButton, nextButton, includeButton, syncButton, addButton, applyButton] { control.isEnabled = false }
    }

    static func frame(image: CGRect, available: CGRect, avoiding controls: [CGRect] = [], focusedCandidate: CGRect? = nil) -> CGRect {
        let inset = available.insetBy(dx: 6, dy: 6)
        let size = CGSize(width: min(preferredSize.width, max(1, inset.width)), height: min(preferredSize.height, max(1, inset.height)))
        func clamped(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: min(max(inset.minX, x), inset.maxX - size.width),
                   y: min(max(inset.minY, y), inset.maxY - size.height), width: size.width, height: size.height)
        }
        let options = [
            clamped(image.minX, image.minY - size.height - 8),
            clamped(image.minX, image.maxY + 8),
            clamped(image.minX - size.width - 8, image.maxY - size.height),
            clamped(image.maxX + 8, image.maxY - size.height),
            clamped(inset.minX, inset.minY), clamped(inset.maxX - size.width, inset.minY),
            clamped(inset.minX, inset.maxY - size.height), clamped(inset.maxX - size.width, inset.maxY - size.height)
        ]
        let clear = options.filter { frame in !controls.contains { $0.insetBy(dx: -4, dy: -4).intersects(frame) } }
        if let outside = clear.first(where: { !$0.intersects(image) }) { return outside }
        if let focusedCandidate, let visible = clear.first(where: { !$0.intersects(focusedCandidate.insetBy(dx: -4, dy: -4)) }) { return visible }
        if let focusedCandidate, let visible = options.first(where: { !$0.intersects(focusedCandidate.insetBy(dx: -4, dy: -4)) }) { return visible }
        return clear.first ?? options[0]
    }
    @objc private func previous() { onPrevious?() }
    @objc private func next() { onNext?() }
    @objc private func include() { onInclude?() }
    @objc private func sync() { onSync?(syncButton.state == .on) }
    @objc private func add() { onAdd?() }
    @objc private func apply() { onApply?() }
    @objc private func cancel() { onCancel?() }
}

@MainActor
extension ImageEditorController {
    func installAutomaticMosaic() {
        automaticMosaicWorkspace.addSubview(automaticMosaicReviewSurface)
        annotationCanvas.onContentInvalidated = { [weak self] in
            guard let self, self.automaticMosaicReviewState != nil || self.annotationCanvas.automaticMosaicDrawHandler != nil else { return }
            self.cancelAutomaticMosaic()
        }
        annotationCanvas.onAutomaticMosaicToggle = { [weak self] index in self?.toggleAutomaticMosaicCandidate(index) }
        annotationCanvas.onAutomaticMosaicCancel = { [weak self] in self?.cancelAutomaticMosaic(); self?.refreshAutomaticMosaicInterface() }
        annotationCanvas.onAutomaticMosaicApply = { [weak self] in self?.applyAutomaticMosaic() }
        annotationCanvas.onAutomaticMosaicLimit = { [weak self] message in self?.showAutomaticMosaicNotice(message) }
        automaticMosaicReviewSurface.onPrevious = { [weak self] in self?.moveAutomaticMosaicCandidate(-1) }
        automaticMosaicReviewSurface.onNext = { [weak self] in self?.moveAutomaticMosaicCandidate(1) }
        automaticMosaicReviewSurface.onInclude = { [weak self] in
            guard let self, let state = self.automaticMosaicReviewState else { return }
            self.toggleAutomaticMosaicCandidate(state.selectedIndex)
        }
        automaticMosaicReviewSurface.onSync = { [weak self] enabled in
            guard let self, var state = self.automaticMosaicReviewState else { return }
            state.synchronizes = enabled; self.publishAutomaticMosaicReview(state)
        }
        automaticMosaicReviewSurface.onAdd = { [weak self] in self?.beginAutomaticMosaicManualCandidate() }
        automaticMosaicReviewSurface.onApply = { [weak self] in self?.applyAutomaticMosaic() }
        automaticMosaicReviewSurface.onCancel = { [weak self] in self?.cancelAutomaticMosaic(); self?.refreshAutomaticMosaicInterface() }
        installAutomaticMosaicInspector()
    }

    @objc func chooseAutomaticMosaicTool() {
        chooseTool(.pixelate)
        annotationCanvas.automaticMosaicDrawHandler = { [weak self] rect in
            guard let self else { return }
            let seed = self.annotationCanvas.makeAnnotation(tool: .pixelate, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)])
            self.beginAutomaticMosaic(seed: seed, replacing: nil)
        }
        automaticMosaicReviewSurface.displayDrawing("拖出要查找的区域 · 自动马赛克")
        refreshAutomaticMosaicInterface()
    }

    @objc func startAutomaticMosaic() {
        guard let seed = annotationCanvas.selectedAnnotation, seed.supportsAutomaticMosaic else { return }
        beginAutomaticMosaic(seed: seed, replacing: seed.id)
    }

    func beginAutomaticMosaic(seed: ImageAnnotation, replacing: UUID?) {
        cancelAutomaticMosaic()
        finishInlineText(commit: true)
        guard !isClosed, seed.supportsAutomaticMosaic else { return }
        let canvas = annotationCanvas, base = canvas.image
        let viewport = canvas.visibleImageRect
        let rect = seed.localBounds.standardized.integral
        guard viewport.contains(rect) else { return }
        let image: CGImage
        if canvas.cropViewportInBase != nil {
            guard let cropped = ImageEditorRenderer.crop(image: base, to: viewport) else { return }
            image = cropped
        } else { image = base }
        let localSeed = rect.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
        guard let pixelSeed = AutomaticMosaicCoordinates.pixelRect(localSeed, imageHeight: image.height) else { return }
        let token = UUID(); automaticMosaicGeneration = token
        let state = AutomaticMosaicReviewState(phase: .searching, generation: token,
            sourceIdentity: ObjectIdentifier(base), sourceRevision: canvas.contentRevision,
            sourceWidth: base.width, sourceHeight: base.height, seed: seed, replacingID: replacing,
            candidates: [AutomaticMosaicReviewCandidate(rect: rect, confidence: 1, included: true, isSeed: true)])
        publishAutomaticMosaicReview(state)
        let matcher = automaticMosaicMatcher, injectedFind = automaticMosaicFind
        automaticMosaicTask = Task { [weak self] in
            do {
                let result: RepeatedRegionMatchResult
                if let injectedFind { result = try await injectedFind(image, pixelSeed) }
                else { result = try await matcher.findMatches(in: image, seed: pixelSeed) }
                guard let self, !Task.isCancelled, self.automaticMosaicStillCurrent(state),
                      self.annotationCanvas.visibleImageRect == viewport else { return }
                self.automaticMosaicTask = nil
                var ready = state; ready.phase = .ready; ready.truncated = result.truncated
                ready.candidates += result.candidates.prefix(AutomaticMosaicReviewState.maximumCandidates - 1).compactMap { candidate in
                    guard let local = AutomaticMosaicCoordinates.imageRect(candidate.rect, imageHeight: image.height) else { return nil }
                    let box = local.offsetBy(dx: viewport.minX, dy: viewport.minY)
                    guard viewport.contains(box) else { return nil }
                    return AutomaticMosaicReviewCandidate(rect: box, confidence: candidate.confidence, included: true)
                }
                ready.truncated = ready.truncated || result.candidates.count >= AutomaticMosaicReviewState.maximumCandidates
                self.publishAutomaticMosaicReview(ready)
            } catch {
                guard let self, !Task.isCancelled, self.automaticMosaicStillCurrent(state),
                      self.annotationCanvas.visibleImageRect == viewport else { return }
                self.automaticMosaicTask = nil
                var failed = state; failed.phase = .failed
                failed.message = (error as? LocalizedError)?.errorDescription ?? "未能完成查找，请缩小截图或重试"
                self.publishAutomaticMosaicReview(failed)
            }
        }
    }

    private func automaticMosaicStillCurrent(_ state: AutomaticMosaicReviewState) -> Bool {
        !isClosed && automaticMosaicGeneration == state.generation
            && annotationCanvas.contentRevision == state.sourceRevision
            && ObjectIdentifier(annotationCanvas.image) == state.sourceIdentity
    }

    func cancelAutomaticMosaic() {
        automaticMosaicGeneration = UUID()
        automaticMosaicTask?.cancel(); automaticMosaicTask = nil
        setAutomaticMosaicReviewState(nil)
        annotationCanvas.automaticMosaicReview = nil; annotationCanvas.automaticMosaicDrawHandler = nil
        annotationCanvas.cancelAutomaticMosaicGesture()
        automaticMosaicReviewSurface.display(nil)
    }

    private func publishAutomaticMosaicReview(_ state: AutomaticMosaicReviewState) {
        setAutomaticMosaicReviewState(state); annotationCanvas.automaticMosaicReview = state
        automaticMosaicReviewSurface.display(state, drawing: annotationCanvas.automaticMosaicDrawHandler != nil)
        if state.phase == .ready && !annotationCanvas.canApplyAutomaticMosaic(count: state.includedCount, replacing: state.replacingID) {
            automaticMosaicReviewSurface.applyButton.isEnabled = false
            automaticMosaicReviewSurface.statusLabel.stringValue = "关联区域已达上限，请先删除部分区域"
        }
        refreshAutomaticMosaicInterface()
    }

    func layoutAutomaticMosaicReview() {
        guard automaticMosaicReviewState != nil || annotationCanvas.automaticMosaicDrawHandler != nil else { return }
        let focus = automaticMosaicReviewState.flatMap { state -> CGRect? in
            guard state.candidates.indices.contains(state.selectedIndex) else { return nil }
            let rect = state.candidates[state.selectedIndex].rect
            return automaticMosaicWorkspace.convert(CGRect(x: rect.minX * annotationCanvas.zoom, y: rect.minY * annotationCanvas.displayScaleY,
                width: rect.width * annotationCanvas.zoom, height: rect.height * annotationCanvas.displayScaleY), from: annotationCanvas)
        }
        automaticMosaicReviewSurface.frame = AutomaticMosaicReviewSurface.frame(image: editorSelectionFrame, available: automaticMosaicWorkspace.bounds,
            avoiding: [floatingToolbarFrame, dimensionLabelFrame], focusedCandidate: focus)
        automaticMosaicReviewSurface.layoutSubtreeIfNeeded()
    }

    func toggleAutomaticMosaicCandidate(_ index: Int) {
        guard var state = automaticMosaicReviewState, state.phase == .ready, state.candidates.indices.contains(index) else { return }
        state.candidates[index].included.toggle(); state.selectedIndex = index
        publishAutomaticMosaicReview(state)
    }

    func moveAutomaticMosaicCandidate(_ delta: Int) {
        guard var state = automaticMosaicReviewState, state.phase == .ready, !state.candidates.isEmpty else { return }
        state.selectedIndex = (state.selectedIndex + delta + state.candidates.count) % state.candidates.count
        publishAutomaticMosaicReview(state)
        let rect = state.candidates[state.selectedIndex].rect
        annotationCanvas.scrollToVisible(CGRect(x: rect.minX * annotationCanvas.zoom, y: rect.minY * annotationCanvas.displayScaleY,
            width: rect.width * annotationCanvas.zoom, height: rect.height * annotationCanvas.displayScaleY))
    }

    func beginAutomaticMosaicManualCandidate() {
        guard let state = automaticMosaicReviewState, state.phase == .ready, state.candidates.count < AutomaticMosaicReviewState.maximumCandidates else { return }
        // Drawing mode remains in the review transaction and only adds an outline.
        annotationCanvas.tool = .pixelate
        annotationCanvas.automaticMosaicDrawHandler = { [weak self] requested in
            guard let self, var state = self.automaticMosaicReviewState, self.automaticMosaicStillCurrent(state) else { return }
            let size = state.candidates[0].rect.size
            let box = CGRect(origin: requested.origin, size: size)
            let extent = CGRect(x: 0, y: 0, width: state.sourceWidth, height: state.sourceHeight)
            guard extent.contains(box), !state.candidates.contains(where: { $0.rect.intersects(box) }) else { return }
            state.candidates.append(AutomaticMosaicReviewCandidate(rect: box, confidence: 0, included: true, isManual: true))
            state.selectedIndex = state.candidates.count - 1
            self.annotationCanvas.automaticMosaicDrawHandler = nil
            self.publishAutomaticMosaicReview(state)
        }
        publishAutomaticMosaicReview(state)
    }

    func applyAutomaticMosaic() {
        guard let state = automaticMosaicReviewState, automaticMosaicStillCurrent(state), state.phase == .ready,
              annotationCanvas.automaticMosaicDrawHandler == nil, state.includedCount > 0 else { return }
        let marks = state.committedAnnotations()
        cancelAutomaticMosaic()
        if annotationCanvas.applyAutomaticMosaic(marks, replacing: state.replacingID) { chooseTool(.select) }
    }

    func showAutomaticMosaicNotice(_ message: String) {
        cancelAutomaticMosaic()
        let canvas = annotationCanvas
        let seed = canvas.selectedAnnotation ?? canvas.makeAnnotation(tool: .pixelate, points: [])
        let state = AutomaticMosaicReviewState(phase: .failed, generation: automaticMosaicGeneration,
            sourceIdentity: ObjectIdentifier(canvas.image), sourceRevision: canvas.contentRevision,
            sourceWidth: canvas.image.width, sourceHeight: canvas.image.height, seed: seed, replacingID: nil,
            candidates: [], message: message)
        publishAutomaticMosaicReview(state)
    }

    func beginLinkedMosaicCorrection() {
        guard let selected = annotationCanvas.selectedAnnotation, selected.mosaicLink != nil else { return }
        chooseTool(selected.tool)
        annotationCanvas.automaticMosaicDrawHandler = { [weak self] rect in
            guard let self else { return }
            self.annotationCanvas.automaticMosaicDrawHandler = nil
            if self.annotationCanvas.addMosaicCorrection(rect, relativeTo: selected) { self.chooseTool(.select) }
        }
        automaticMosaicReviewSurface.displayDrawing(selected.mosaicLink?.synchronizes == true ? "拖出补充区域 · 同步到已包括的相同内容" : "拖出补充区域 · 仅此处")
        refreshAutomaticMosaicInterface()
    }
}

@MainActor
extension ImageEditorController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if automaticMosaicOutputAction(menuItem.action) { return !isClosed && !automaticMosaicBlocksOutput }
        if menuItem.action == #selector(startAutomaticMosaic) {
            return !isClosed && annotationCanvas.selectedAnnotation?.supportsAutomaticMosaic == true
        }
        return !isClosed
    }
}
