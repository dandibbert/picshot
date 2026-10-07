import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PicShotCore

/// A manual or explicitly started automatic same-region scroll session. Full-resolution sources live in a private
/// temporary directory; only the last grayscale frame and a thumbnail stay in memory.
@MainActor
final class ScrollCaptureController: NSWindowController, NSWindowDelegate {
    private let onComplete: (CGImage) -> Void
    private let captureService = CaptureService()
    private var sequence: ScrollCaptureSequence?
    private var previousFrame: ScrollFrame?
    private var frames: [StoredScrollSource] = []
    private var edits = ScrollSequenceEdits()
    private var selectedBlockID: UUID?
    private var selectedBand: Range<Int>?
    private(set) var lastMatch: ScrollPlacement?
    var sourceWriteBarrierForVerification: (@Sendable (URL) async -> Void)?
    private var directory: URL?
    private var diskBytes: Int64 = 0
    private var region: CGRect?
    private var selectedDisplayID: CGDirectDisplayID?
    private var selectedDisplaySize: CGSize?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var busy = false
    private var automatic: AutomaticScrollCoordinator?
    private var automaticControls: AutomaticScrollControls?
    private var manual: ManualScrollCoordinator?
    private var manualDriver: ManualScrollScreenDriver?
    private var manualControls: ManualScrollControls?
    private var regionMover: ManualScrollRegionMover?
    private var moveOperation: Task<Void, Never>?
    private var repositioning = false
    private let maximumFrames = 100
    private let maximumDiskBytes: Int64

    private let direction = NSPopUpButton(frame: .zero, pullsDown: false)
    private let displayPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let chooseButton = NSButton(title: "选择区域并连续捕获", target: nil, action: nil)
    private let nextButton = NSButton(title: "连续捕获", target: nil, action: nil)
    private let automaticButton = NSButton(title: "自动滚动（3秒）", target: nil, action: nil)
    private let accessibilityButton = NSButton(title: "辅助功能设置…", target: nil, action: nil)
    private let importButton = NSButton(title: "导入图片…", target: nil, action: nil)
    private let resetButton = NSButton(title: "重新开始", target: nil, action: nil)
    private let finishButton = NSButton(title: "完成并编辑", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "请选择滚动内容，避开固定页眉、侧栏和滚动条。")
    private let dimensions = NSTextField(labelWithString: "尚未捕获图片")
    private let preview = ScrollSequencePreview()
    private let trimButton = NSButton(title: "裁剪片段…", target: nil, action: nil)
    private let blockPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let deleteButton = NSButton(title: "删除整段", target: nil, action: nil)
    private let undoButton = NSButton(title: "撤销", target: nil, action: nil)
    private let redoButton = NSButton(title: "重做", target: nil, action: nil)
    private let applyButton = NSButton(title: "应用裁剪", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消裁剪", target: nil, action: nil)
    private let autoCropButton = NSButton(checkboxWithTitle: "反向自动裁剪", target: nil, action: nil)
    private let resetDirectionButton = NSButton(title: "重设方向", target: nil, action: nil)
    private let restoreCoverageButton = NSButton(title: "恢复已捕获边缘", target: nil, action: nil)
    private let bandStartField = NSTextField(string: "0")
    private let bandLengthField = NSTextField(string: "1")
    private let selectBandButton = NSButton(title: "选择范围", target: nil, action: nil)
    private let restoreCutsButton = NSButton(title: "重置裁剪", target: nil, action: nil)
    private var bandControls: NSStackView?

    init(storageLimitBytes: Int64 = 512 * 1024 * 1024, onComplete: @escaping (CGImage) -> Void) {
        self.onComplete = onComplete
        maximumDiskBytes = min(512 * 1024 * 1024, max(0, storageLimitBytes))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "长截图"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        buildInterface()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var axis: ScrollAxis { direction.indexOfSelectedItem == 1 ? .horizontal : .vertical }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        direction.addItems(withTitles: ["纵向 ↕", "横向 ↔"])
        direction.target = self
        direction.action = #selector(directionChanged)
        for screen in NSScreen.screens {
            displayPicker.addItem(withTitle: screen.localizedName)
            displayPicker.lastItem?.representedObject = screen.displayID
        }
        if let main = NSScreen.main?.displayID,
           let index = NSScreen.screens.firstIndex(where: { $0.displayID == main }) { displayPicker.selectItem(at: index) }
        let explanation = NSTextField(wrappingLabelWithString: "手动滚动时自动捕获停稳画面，可暂停、移动固定选区再继续。请保留至少25%重叠并避开固定页眉和动画。自动滚动单独需要辅助功能权限。")
        explanation.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 4
        dimensions.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        dimensions.textColor = .secondaryLabelColor
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        preview.layer?.cornerRadius = 8
        chooseButton.target = self; chooseButton.action = #selector(chooseRegion)
        nextButton.target = self; nextButton.action = #selector(startManual)
        nextButton.keyEquivalent = "\r"
        nextButton.keyEquivalentModifierMask = [.command]
        automaticButton.target = self; automaticButton.action = #selector(startAutomatic)
        accessibilityButton.target = self; accessibilityButton.action = #selector(openAccessibilitySettings)
        importButton.target = self; importButton.action = #selector(importFrames)
        resetButton.target = self; resetButton.action = #selector(startOver)
        finishButton.target = self; finishButton.action = #selector(finishCapture)
        let controls = NSStackView(views: [NSTextField(labelWithString: "方向："), direction,
                                          NSTextField(labelWithString: "显示器："), displayPicker])
        controls.orientation = .horizontal
        controls.spacing = 10
        let captureControls = NSStackView(views: [chooseButton, nextButton, importButton])
        captureControls.orientation = .horizontal
        captureControls.spacing = 10
        let automaticRow = NSStackView(views: [automaticButton, accessibilityButton])
        automaticRow.orientation = .horizontal
        automaticRow.spacing = 10
        trimButton.target = self; trimButton.action = #selector(beginTrimming)
        blockPicker.target = self; blockPicker.action = #selector(blockSelectionChanged)
        blockPicker.setAccessibilityLabel("已捕获片段")
        deleteButton.target = self; deleteButton.action = #selector(deleteSelectedBlock)
        undoButton.target = self; undoButton.action = #selector(undoCut)
        redoButton.target = self; redoButton.action = #selector(redoCut)
        undoButton.keyEquivalent = "z"; undoButton.keyEquivalentModifierMask = [.command]
        redoButton.keyEquivalent = "z"; redoButton.keyEquivalentModifierMask = [.command, .shift]
        applyButton.target = self; applyButton.action = #selector(applyTrimming)
        cancelButton.target = self; cancelButton.action = #selector(cancelTrimming)
        preview.setAccessibilityLabel("长截图预览。拖动选择任意范围，也可从片段菜单中选择整段。")
        preview.onSelect = { [weak self] id in self?.selectBlock(id) }
        preview.onDelete = { [weak self] in self?.deleteSelectedBlock() }
        preview.onBandSelect = { [weak self] range in self?.selectBand(range) }
        autoCropButton.state = .on; autoCropButton.target = self; autoCropButton.action = #selector(autoCropChanged)
        resetDirectionButton.target = self; resetDirectionButton.action = #selector(resetCaptureDirection)
        restoreCoverageButton.target = self; restoreCoverageButton.action = #selector(restoreCapturedEdges)
        selectBandButton.target = self; selectBandButton.action = #selector(selectTypedBand)
        restoreCutsButton.target = self; restoreCutsButton.action = #selector(restoreCuts)
        bandStartField.setAccessibilityLabel("选区起点像素，从0开始")
        bandLengthField.setAccessibilityLabel("选区长度，单位为像素")
        for field in [bandStartField, bandLengthField] { field.widthAnchor.constraint(equalToConstant: 65).isActive = true }
        let captureMode = NSStackView(views: [autoCropButton, resetDirectionButton])
        captureMode.orientation = .horizontal; captureMode.spacing = 10
        let bandRow = NSStackView(views: [NSTextField(labelWithString: "起点（像素）："), bandStartField,
                                         NSTextField(labelWithString: "长度："), bandLengthField, selectBandButton, restoreCoverageButton, restoreCutsButton])
        bandRow.orientation = .horizontal; bandRow.spacing = 8; bandControls = bandRow
        for (control, identifier) in [(trimButton, "trim"), (deleteButton, "delete"), (undoButton, "undo"),
                                      (redoButton, "redo"), (applyButton, "apply"), (cancelButton, "cancel"),
                                      (finishButton, "finish"), (nextButton, "manualStart"), (chooseButton, "choose"), (resetButton, "reset"), (autoCropButton, "autoCrop"), (resetDirectionButton, "resetDirection"),
                                      (restoreCoverageButton, "restoreEdges"), (selectBandButton, "selectBand"), (restoreCutsButton, "restoreCuts")] {
            control.identifier = NSUserInterfaceItemIdentifier("scroll." + identifier)
        }
        preview.identifier = NSUserInterfaceItemIdentifier("scroll.preview")
        blockPicker.identifier = NSUserInterfaceItemIdentifier("scroll.blocks")
        bandStartField.identifier = NSUserInterfaceItemIdentifier("scroll.bandStart")
        bandLengthField.identifier = NSUserInterfaceItemIdentifier("scroll.bandLength")
        let trimControls = NSStackView(views: [trimButton, blockPicker, deleteButton, undoButton, redoButton])
        trimControls.orientation = .horizontal; trimControls.spacing = 8
        let finalControls = NSStackView(views: [resetButton, finishButton, applyButton, cancelButton])
        finalControls.orientation = .horizontal
        finalControls.spacing = 10
        let stack = NSStackView(views: [explanation, controls, captureControls, automaticRow, captureMode, preview, dimensions, trimControls, bandRow, status, finalControls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.distribution = .fill
        // Give remaining inspector space to the preview. Tool rows keep their natural
        // heights, and expanded trimming controls reclaim space from the preview.
        for row in stack.arrangedSubviews where row !== preview {
            row.setContentHuggingPriority(.required, for: .vertical)
        }
        preview.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 230),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        updateControls()
    }

    @objc private func directionChanged() { preview.axis = axis }

    @objc private func chooseRegion() {
        guard !sessionBusy, frames.isEmpty,
              let displayID = displayPicker.selectedItem?.representedObject as? CGDirectDisplayID,
              let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }
        selectedDisplayID = displayID
        selectedDisplaySize = screen.frame.size
        startOperation(afterSuccess: { [weak self] in self?.startManual() }) { [weak self] in
            guard let self else { return }
            try CaptureService.requireScreenPermission()
            self.window?.orderOut(nil)
            let selected = try await self.captureService.selectRegion(displayID: displayID)
            try Task.checkCancellation()
            self.region = selected
        }
    }

    @objc private func startManual() {
        guard !sessionBusy, !edits.isEditing, let region, let displayID = selectedDisplayID,
              let screenSize = selectedDisplaySize, frames.count < maximumFrames else { return }
        do {
            let token = generation
            let driver = try ManualScrollScreenDriver(displayID: displayID, region: region, screenSize: screenSize,
                expectedPixelSize: previousFrame.map { CGSize(width: $0.width, height: $0.height) },
                lockedTarget: manualDriver?.target) { [weak self] image in
                guard let self, self.generation == token else { throw CancellationError() }
                return try await self.acceptManualImage(image)
            }
            try driver.checkPermission()
            beginManual(driver: driver)
        } catch {
            status.stringValue = "\(error.localizedDescription) 已保留捕获内容。"
            updateControls()
        }
    }

    private func acceptManualImage(_ image: CGImage) async throws -> ManualScrollSample {
        do {
            try await accept(image)
            return .accepted(totalFrames: frames.count)
        } catch ScrollStitchError.duplicate { return .duplicate }
        catch ScrollSequenceImageError.changedSource {
            // A full-color conflict/revisit refuses only this candidate. Keep the
            // accepted anchor and recovery controls so the user can return and retry.
            throw ManualScrollRecoveryError(message: ScrollSequenceImageError.changedSource.localizedDescription)
        }
    }

    private func beginManual(driver: ManualScrollScreenDriver, configuration: ManualScrollConfiguration = .init()) {
        manual?.onChange = nil
        manual?.cancel()
        manualDriver?.invalidate()
        manualControls?.detach()
        manualDriver = driver
        let coordinator = ManualScrollCoordinator(configuration: configuration, driver: driver, initialFrameCount: frames.count)
        manual = coordinator
        let controls = ManualScrollControls(displayBounds: driver.displayBounds)
        controls.pauseOrResume = { [weak self, weak coordinator] in
            guard let self, !self.repositioning, let coordinator else { return }
            if coordinator.canResume {
                self.window?.orderOut(nil)
                coordinator.resume()
            } else { coordinator.pause() }
        }
        controls.move = { [weak self] in self?.moveManualRegion() }
        controls.stop = { [weak coordinator] in coordinator?.stop() }
        manualControls = controls
        coordinator.onChange = { [weak self] state in self?.manualChanged(state) }
        window?.orderOut(nil); controls.window?.orderFrontRegardless()
        coordinator.start()
    }

    private var manualPaused: Bool {
        switch manual?.state {
        case .paused?, .recoverable?: return true
        default: return false
        }
    }

    private func manualChanged(_ state: ManualScrollState) {
        let text: String
        var recoverable = false
        switch state {
        case .ready: text = "已准备连续手动捕获"
        case .countdown(let seconds): text = "\(seconds)秒后开始 · 请切回目标页面"
        case .sampling: text = "观察页面 · 已保存\(frames.count)帧 · 请手动滚动"
        case .settling: text = "等待画面停稳 · 保留至少25%重叠"
        case .matching: text = "正在验证接缝 · 已保存\(frames.count)帧"
        case .waiting: text = "正在捕获 · 已保存\(frames.count)帧 · 可向两个方向滚动"
        case .paused:
            text = manual?.hasPendingOperation == true ? "已暂停 · 等待当前采样结束" : "已暂停 · 可移动固定选区，或继续、停止并编辑"
        case .recoverable(let message):
            recoverable = true
            text = "\(message) 未接入不确定画面；请返回上次位置、减小滚动距离，再重试。"
        case .failed(let message): text = "\(message) 已保留已接受原图，可完成或重新连续捕获。"
        case .finished(let reason):
            switch reason {
            case .stopped: text = "连续捕获已停止。可检查预览、裁剪、完成，或再次连续捕获。"
            case .frameLimit: text = "已达到100帧上限，请检查并完成截图。"
            case .sampleLimit: text = "已达到采样次数上限。原图已保留，请检查并完成截图。"
            case .timeLimit: text = "已达到3分钟捕获上限。原图已保留，请检查并完成截图。"
            }
        }
        region = manualDriver?.region ?? region
        status.stringValue = text
        manualControls?.update(text: text, paused: manualPaused, retry: recoverable,
                               ready: manual?.canResume == true && !repositioning)
        switch state {
        case .paused, .recoverable:
            if !repositioning { window?.makeKeyAndOrderFront(nil) }
        case .finished, .failed:
            manualDriver?.invalidate()
            manualControls?.detach(); manualControls = nil
            window?.makeKeyAndOrderFront(nil)
        default: break
        }
        updateControls()
    }

    private func moveManualRegion() {
        guard !repositioning, manual?.canResume == true, let driver = manualDriver,
              let screen = NSScreen.screens.first(where: { $0.displayID == driver.displayID }) else { return }
        let token = generation
        repositioning = true
        let mover = ManualScrollRegionMover(); regionMover = mover
        window?.orderOut(nil); manualControls?.window?.orderOut(nil)
        updateControls()
        moveOperation = Task { [weak self] in
            guard let self else { return }
            do {
                let moved = try await mover.choose(screen: screen, region: driver.region)
                try Task.checkCancellation()
                guard self.generation == token, self.manual?.canResume == true else { throw CancellationError() }
                try driver.moveRegion(to: moved)
                self.region = driver.region
                self.status.stringValue = "选区位置已更新，尺寸、显示器、目标窗口及原图均保留。请明确点击继续；接缝仍须验证。"
            } catch is CancellationError { }
            catch CaptureError.cancelled { self.status.stringValue = "已取消移动，保留原选区。" }
            catch { self.status.stringValue = "\(error.localizedDescription) 原选区和已接受图片均保留。" }
            guard self.generation == token else { return }
            self.regionMover = nil; self.moveOperation = nil; self.repositioning = false
            self.manualControls?.update(text: self.status.stringValue, paused: true, retry: false, ready: self.manual?.canResume == true)
            self.manualControls?.window?.orderFrontRegardless(); self.window?.makeKeyAndOrderFront(nil)
            self.updateControls()
        }
    }

    @objc private func openAccessibilitySettings() {
        // This button only opens the pane. PicShot never changes TCC or grants access.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func startAutomatic() {
        guard !sessionBusy, !edits.isEditing, let region, let displayID = selectedDisplayID,
              let screenSize = selectedDisplaySize, !frames.isEmpty else { return }
        do {
            let token = generation
            let driver = try AutomaticScrollScreenDriver(displayID: displayID, region: region, screenSize: screenSize) { [weak self] image in
                guard let self, self.generation == token else { throw CancellationError() }
                do {
                    try await self.accept(image)
                    return .accepted(totalFrames: self.frames.count)
                } catch ScrollStitchError.duplicate {
                    return .duplicate
                }
            }
            try driver.checkPermission()
            edits.resetCaptureDirection() // Explicit user restart, never an internal sampling delay.
            var configuration = AutomaticScrollConfiguration()
            // A modest point-based step leaves generous overlap on Retina and non-Retina.
            let length = axis == .vertical ? region.height : region.width
            configuration.stepPoints = max(1, min(240, Int(length * 0.35)))
            let coordinator = AutomaticScrollCoordinator(axis: axis, configuration: configuration,
                                                         driver: driver, initialFrameCount: frames.count)
            automatic = coordinator
            let controls = AutomaticScrollControls(targetPoint: driver.targetPoint, displayBounds: driver.displayBounds)
            controls.pauseOrResume = { [weak coordinator] in
                guard let coordinator else { return }
                if coordinator.state == .paused { coordinator.resume() } else { coordinator.pause() }
            }
            controls.stop = { [weak coordinator] in coordinator?.stop() }
            automaticControls = controls
            coordinator.onChange = { [weak self] state in self?.automaticChanged(state) }
            window?.orderOut(nil)
            controls.window?.orderFrontRegardless()
            coordinator.start()
        } catch {
            status.stringValue = error.localizedDescription
            updateControls()
        }
    }

    private func automaticChanged(_ state: AutomaticScrollState) {
        let text: String
        switch state {
        case .ready: text = "已准备自动滚动"
        case .countdown(let seconds): text = "\(seconds)秒后开始 · 请切回目标应用"
        case .capturing: text = "正在捕获并匹配 · 已保留\(frames.count)帧"
        case .scrolling: text = "正在选区中心向\(axis == .vertical ? "下" : "右")滚动"
        case .settling: text = "等待页面停止滚动"
        case .retrying(let attempt): text = "画面未变化 · 再次检查（\(attempt)）"
        case .paused:
            text = automatic?.hasPendingOperation == true ? "已暂停 · 等待当前捕获结束" : "已暂停 · 继续后将重新倒计时3秒"
        case .failed(let message): text = "\(message) 已保留捕获内容。"
        case .finished(let reason):
            switch reason {
            case .stopped:
                edits.resetCaptureDirection()
                text = "自动滚动已停止，方向已重设。可完成截图、继续手动捕获或重新启动自动模式。"
            case .noMovement: text = "多次检查后仍未检测到滚动，可能已到页面尽头或应用未响应。请检查预览，可完成截图或继续手动捕获。"
            case .frameLimit: text = "已达到100帧上限，请完成本次截图。"
            case .eventLimit: text = "已达到自动滚动次数上限，请检查并完成截图。"
            case .timeLimit: text = "已达到3分钟自动捕获上限，已保留捕获内容。"
            }
        }
        status.stringValue = text
        automaticControls?.update(text: text, paused: state == .paused,
                                  canResume: automatic?.hasPendingOperation == false)
        switch state {
        case .finished, .failed:
            automaticControls?.window?.delegate = nil
            automaticControls?.close()
            automaticControls = nil
            window?.makeKeyAndOrderFront(nil)
        default: break
        }
        updateControls()
    }

    private var sessionBusy: Bool {
        busy || repositioning || manual?.isRunning == true || manualPaused || manual?.hasPendingOperation == true
            || automatic?.isRunning == true || automatic?.state == .paused || automatic?.hasPendingOperation == true
    }

    @objc private func importFrames() {
        guard !sessionBusy, !edits.isEditing else { return }
        let panel = NSOpenPanel()
        panel.title = "按文件名顺序导入重叠图片"
        panel.message = "请选择大小一致、相互重叠的图片，顺序可包含反向滚动。文件名按自然顺序排列（frame2在frame10之前）；已接受的原图保持不变。"
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

    @discardableResult
    private func accept(_ image: CGImage) async throws -> Bool {
        try Task.checkCancellation()
        let token = generation
        if directory == nil {
            let newDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Scroll-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            directory = newDirectory
        }
        guard let directory else { throw ScrollSessionError.imageIO }
        let sourceID = UUID()
        let url = directory.appendingPathComponent("frame-\(sourceID.uuidString).png")
        let current = sequence
        let old = previousFrame
        let existing = frames // Metadata only, never an array of full-resolution images.
        let currentEdits = edits
        let shouldAutoCrop = autoCropButton.state == .on
        let remaining = maximumDiskBytes - diskBytes
        let selectedAxis = axis
        let sourceWriteBarrier = sourceWriteBarrierForVerification
        let worker = Task.detached(priority: .userInitiated) { () async throws -> (ScrollCaptureSequence, ScrollFrame, StoredScrollSource?, CGImage, ScrollPlacement?, ScrollSequenceEdits) in
            var keepFile = false
            defer { if !keepFile { try? FileManager.default.removeItem(at: url) } }
            try Task.checkCancellation()
            let gray = try ScrollImageIO.luminance(image)
            let next: ScrollCaptureSequence
            let match: ScrollPlacement?
            let contributes: Bool
            if let current, let old {
                var tracked = current
                let verified: ScrollPlacement
                do {
                    verified = try ScrollStitcher.matchBidirectional(previous: old, next: gray, axis: selectedAxis)
                } catch ScrollStitchError.duplicate {
                    // A zero-luminance match can still conceal changed color or alpha.
                    try ScrollImageIO.validateSequenceOverlap(gray, image: image, sequence: current,
                        viewportOffset: current.viewportOffset, sources: existing)
                    throw ScrollStitchError.duplicate
                }
                match = verified
                contributes = try tracked.accept(advance: verified.advance, sourceID: sourceID) != nil
                try ScrollImageIO.validateSequenceOverlap(gray, image: image, sequence: current,
                    viewportOffset: tracked.viewportOffset, sources: existing)
                next = tracked
            } else {
                next = try ScrollCaptureSequence(axis: selectedAxis, width: image.width, height: image.height, sourceID: sourceID)
                match = nil; contributes = true
            }
            var nextEdits = currentEdits
            if current == nil { try nextEdits.setAutoCropEnabled(shouldAutoCrop, sequence: next) }
            else if let match { try nextEdits.captureMoved(sequence: next, advance: match.advance) }
            let layout = try nextEdits.layout(for: next)
            try Task.checkCancellation()
            if !contributes {
                let thumbnail = try ScrollImageIO.sequenceThumbnail(existing, layout: layout, axis: selectedAxis)
                return (next, gray, nil, thumbnail, match, nextEdits)
            }
            try ScrollImageIO.writeBoundedPNG(image, to: url, maximumBytes: remaining)
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0, size <= remaining else { throw ScrollSessionError.diskLimit }
            let stored = StoredScrollSource(id: sourceID, url: url, width: image.width, height: image.height, byteCount: size)
            let thumbnail = try ScrollImageIO.sequenceThumbnail(existing + [stored], layout: layout, axis: selectedAxis)
            // The explicit smoke gate sits after real write/render work, immediately
            // before commit, so both cancellation and late-generation rejection are tested.
            if let sourceWriteBarrier { await sourceWriteBarrier(url) }
            try Task.checkCancellation()
            keepFile = true
            return (next, gray, stored, thumbnail, match, nextEdits)
        }
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        do {
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        sequence = result.0; previousFrame = result.1; lastMatch = result.4; edits = result.5
        if let stored = result.2 { frames.append(stored); diskBytes += stored.byteCount }
        let image = result.3
        preview.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        refreshSequencePresentation()
        if let match = result.4 {
            let motion = axis == .vertical ? (match.advance < 0 ? "向上" : "向下")
                                          : (match.advance < 0 ? "向左" : "向右")
            let evidence = match.evidence.map { String(format: " · 平均误差 %.2f", $0.meanError) } ?? ""
            let direction = edits.establishedDirection.map { $0 > 0 ? "向下／向右" : "向上／向左" } ?? "待确定"
            status.stringValue = edits.autoCropEnabled
                ? "已验证\(motion)移动 · 反向自动裁剪方向：\(direction)。已保留手动裁剪。\(evidence)"
                : (result.2 == nil
                    ? "已验证\(motion)返回已捕获区域，未重复保存或拼接像素。\(evidence)"
                    : "已匹配\(motion)移动，重叠\(match.overlap)像素，仅添加新露出的边缘。\(evidence)")
        } else {
            status.stringValue = "首帧已保存。可双向滚动或启动自动模式，请保留至少25%重叠。上限为100个源片段、6000万像素、单边32768像素。"
        }
        return result.2 != nil
    }

    private func refreshSequencePresentation() {
        guard let sequence, let layout = try? edits.layout(for: sequence) else { return }
        let viewportLength = axis == .vertical ? sequence.frameHeight : sequence.frameWidth
        preview.updateProjection(layout: layout, axis: axis, sources: frames,
                                 viewport: sequence.viewportOffset..<(sequence.viewportOffset + viewportLength))
        selectedBand = nil; preview.selectedRange = nil
        autoCropButton.state = edits.autoCropEnabled ? .on : .off
        if !layout.strips.contains(where: { $0.block.id == selectedBlockID }) { selectedBlockID = layout.strips.first?.block.id }
        preview.selectedID = selectedBlockID
        blockPicker.removeAllItems()
        var listed: Set<UUID> = []
        for strip in layout.strips where listed.insert(strip.block.id).inserted {
            let originalIndex = sequence.blocks.firstIndex(where: { $0.id == strip.block.id }) ?? 0
            let visibleLength = layout.strips.filter { $0.block.id == strip.block.id }.reduce(0) { $0 + $1.block.length }
            blockPicker.addItem(withTitle: "第\(originalIndex + 1)段 · \(visibleLength)像素")
            blockPicker.lastItem?.representedObject = strip.block.id
            if strip.block.id == selectedBlockID { blockPicker.select(blockPicker.lastItem) }
        }
        dimensions.stringValue = "\(Set(layout.strips.map { $0.block.id }).count)/\(sequence.blocks.count)段 · \(layout.width) × \(layout.height)像素 · 原图\(diskBytes / 1_048_576) MB"
        updateControls()
    }

    private func selectBlock(_ id: UUID) {
        guard !sessionBusy, edits.isEditing, sequence?.blocks.contains(where: { $0.id == id }) == true,
              !edits.removed.contains(id) else { return }
        selectedBlockID = id; preview.selectedID = id
        selectedBand = nil; preview.selectedRange = nil
        if let strip = preview.layout?.strips.first(where: { $0.block.id == id }) {
            bandStartField.integerValue = strip.outputStart; bandLengthField.integerValue = strip.block.length
        }
        if let item = blockPicker.itemArray.first(where: { ($0.representedObject as? UUID) == id }) { blockPicker.select(item) }
        updateControls()
    }

    private func selectBand(_ range: Range<Int>) {
        guard !sessionBusy, edits.isEditing, let layout = preview.layout,
              range.lowerBound >= 0, range.upperBound <= (axis == .vertical ? layout.height : layout.width),
              !range.isEmpty else { return }
        selectedBand = range; preview.selectedRange = range; preview.selectedID = nil
        bandStartField.integerValue = range.lowerBound; bandLengthField.integerValue = range.count
        updateControls()
    }
    @objc private func selectTypedBand() {
        guard let start = Int(bandStartField.stringValue), let count = Int(bandLengthField.stringValue),
              start >= 0, count > 0 else { status.stringValue = "起点须为非负整数，长度须为正整数。"; return }
        let end = start.addingReportingOverflow(count)
        guard !end.overflow, let layout = preview.layout, end.partialValue <= (axis == .vertical ? layout.height : layout.width) else {
            status.stringValue = "选区不能超出当前图片。"; return
        }
        selectBand(start..<end.partialValue)
    }
    @objc private func autoCropChanged() {
        guard !sessionBusy, !edits.isEditing else { return }
        guard let sequence else { return }
        var next = edits
        do { try next.setAutoCropEnabled(autoCropButton.state == .on, sequence: sequence); changeProjection(next) }
        catch { autoCropButton.state = edits.autoCropEnabled ? .on : .off; status.stringValue = error.localizedDescription }
    }
    @objc private func resetCaptureDirection() {
        guard !sessionBusy, !edits.isEditing else { return }
        edits.resetCaptureDirection()
        status.stringValue = "方向已重设，下次匹配成功的移动将确定新方向。原图与手动裁剪均保留。"
    }
    @objc private func restoreCapturedEdges() {
        guard !sessionBusy, edits.isEditing, let sequence else { return }
        var next = edits
        do { try next.restoreCapturedCoverage(sequence: sequence); changeProjection(next) }
        catch { status.stringValue = error.localizedDescription }
    }
    @objc private func restoreCuts() {
        guard !sessionBusy, edits.isEditing else { return }
        var next = edits; next.restoreAll(); changeProjection(next)
    }
    @objc private func blockSelectionChanged() {
        if let id = blockPicker.selectedItem?.representedObject as? UUID { selectBlock(id) }
    }
    @objc private func beginTrimming() {
        guard !sessionBusy, !frames.isEmpty, !edits.isEditing else { return }
        edits.begin(); refreshSequencePresentation()
        status.stringValue = "拖动预览选择任意范围，或输入精确起点与长度；单击可选整段。删除后拼接剩余内容，支持撤销、重做与取消，原图保持不变。"
    }
    @objc private func deleteSelectedBlock() {
        guard !sessionBusy, let sequence, let selectedBlockID else { return }
        var next = edits
        do {
            if let selectedBand { try next.deleteBand(selectedBand, from: sequence) }
            else { try next.delete(selectedBlockID, from: sequence) }
            changeProjection(next)
        }
        catch { status.stringValue = error.localizedDescription }
    }
    @objc private func undoCut() {
        guard !sessionBusy, edits.canUndo else { return }
        var next = edits; next.undo(); changeProjection(next)
    }
    @objc private func redoCut() {
        guard !sessionBusy, edits.canRedo else { return }
        var next = edits; next.redo(); changeProjection(next)
    }
    @objc private func applyTrimming() {
        guard !sessionBusy, edits.isEditing else { return }
        edits.apply(); refreshSequencePresentation()
        status.stringValue = "裁剪已应用，完成后将按当前预览进入编辑器。也可继续捕获或再次裁剪。"
    }
    @objc private func cancelTrimming() {
        guard !sessionBusy, edits.isEditing else { return }
        var next = edits; next.cancel(); changeProjection(next)
    }

    private func changeProjection(_ next: ScrollSequenceEdits) {
        startOperation { [weak self] in
            guard let self else { return }
            try await self.installProjection(next)
        }
    }
    private func installProjection(_ next: ScrollSequenceEdits) async throws {
        guard let sequence else { throw ScrollSequenceError.invalidGeometry }
        let layout = try next.layout(for: sequence)
        let sources = frames, selectedAxis = axis, token = generation
        let worker = Task.detached(priority: .userInitiated) {
            try ScrollImageIO.sequenceThumbnail(sources, layout: layout, axis: selectedAxis)
        }
        let image = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        edits = next
        preview.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        refreshSequencePresentation()
        status.stringValue = next.isEditing
            ? "预览已更新。可撤销或重做；取消将恢复本次裁剪前的图片。"
            : "预览已更新，原图与手动裁剪均已保留。"
    }

    private var canFinishCommittedFrames: Bool {
        !busy && !repositioning && !edits.isEditing && manual?.isRunning != true && !manualPaused
            && automatic?.isRunning != true && automatic?.state != .paused
    }

    @objc private func finishCapture() {
        guard !frames.isEmpty, canFinishCommittedFrames else { return }
        // A cancelled SDK capture can be noncooperative. Only committed source metadata
        // enters this export; a late uncommitted sample cannot change the handoff.
        startOperation(allowTerminalDrain: true) { [weak self] in
            try await self?.completeSequence()
        }
    }

    private func completeSequence() async throws {
        guard let sequence else { throw ScrollSequenceError.invalidGeometry }
        let layout = try edits.layout(for: sequence)
        let sourceFrames = frames, selectedAxis = axis, token = generation
        status.stringValue = "正在合成长截图…"
        let worker = Task.detached(priority: .userInitiated) {
            try ScrollImageIO.renderSequence(sourceFrames, layout: layout, axis: selectedAxis)
        }
        let image = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        onComplete(image)
        close()
    }

    @objc private func startOver() {
        guard !sessionBusy else { return }
        if !frames.isEmpty {
            let alert = NSAlert()
            alert.messageText = "放弃本次长截图？"
            alert.informativeText = "本次捕获的临时原图将被删除。"
            alert.addButton(withTitle: "放弃")
            alert.addButton(withTitle: "继续捕获")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        resetSession()
    }

    private func startOperation(allowTerminalDrain: Bool = false, afterSuccess: (() -> Void)? = nil, _ body: @escaping @MainActor () async throws -> Void) {
        guard !sessionBusy || (allowTerminalDrain && canFinishCommittedFrames) else { return }
        busy = true
        updateControls()
        let token = generation
        operation = Task { [weak self] in
            guard let self else { return }
            var succeeded = false
            do { try await body(); succeeded = true }
            catch is CancellationError { }
            catch {
                if self.generation == token {
                    self.status.stringValue = "\(error.localizedDescription) 已保留捕获内容。"
                }
            }
            guard self.generation == token else { return }
            self.busy = false
            self.operation = nil
            self.updateControls()
            if succeeded, let afterSuccess { afterSuccess() }
            else { self.window?.makeKeyAndOrderFront(nil) }
        }
    }

    private func updateControls() {
        let busy = sessionBusy || edits.isEditing
        direction.isEnabled = !busy && frames.isEmpty
        displayPicker.isEnabled = !busy && frames.isEmpty
        chooseButton.isEnabled = !busy && frames.isEmpty
        nextButton.isEnabled = !busy && region != nil && frames.count < maximumFrames
        automaticButton.isEnabled = !busy && region != nil && !frames.isEmpty && frames.count < maximumFrames
        accessibilityButton.isEnabled = !busy
        importButton.isEnabled = !busy
        resetButton.isEnabled = !busy && (!frames.isEmpty || region != nil)
        finishButton.isEnabled = canFinishCommittedFrames && !frames.isEmpty
        trimButton.isHidden = edits.isEditing
        trimButton.isEnabled = !sessionBusy && !frames.isEmpty
        for control in [blockPicker, deleteButton, undoButton, redoButton, applyButton, cancelButton] as [NSControl] {
            control.isHidden = !edits.isEditing
        }
        autoCropButton.isEnabled = !sessionBusy && !edits.isEditing
        resetDirectionButton.isEnabled = !sessionBusy && !edits.isEditing && !frames.isEmpty
        bandControls?.isHidden = !edits.isEditing
        for control in [bandStartField, bandLengthField, selectBandButton, restoreCoverageButton, restoreCutsButton] as [NSControl] {
            control.isEnabled = !sessionBusy && edits.isEditing
        }
        deleteButton.title = selectedBand == nil ? "删除整段" : "删除选区"
        blockPicker.isEnabled = !sessionBusy
        let outputLength = preview.layout.map { axis == .vertical ? $0.height : $0.width } ?? 0
        deleteButton.isEnabled = !sessionBusy && edits.isEditing && (selectedBand.map { $0.count < outputLength }
            ?? ((preview.layout?.strips.filter { $0.block.id != selectedBlockID }.count ?? 0) > 0))
        undoButton.isEnabled = !sessionBusy && edits.canUndo
        redoButton.isEnabled = !sessionBusy && edits.canRedo
        applyButton.isEnabled = !sessionBusy && edits.isEditing; cancelButton.isEnabled = !sessionBusy && edits.isEditing
        preview.allowsSelection = !sessionBusy && edits.isEditing
        preview.needsDisplay = true
    }

    private func resetSession() {
        manual?.onChange = nil
        manual?.cancel(); manual = nil
        manualDriver?.invalidate(); manualDriver = nil
        manualControls?.detach(); manualControls = nil
        regionMover?.cancel(); regionMover = nil
        moveOperation?.cancel(); moveOperation = nil; repositioning = false
        preview.clearDetail()
        automatic?.onChange = nil
        automatic?.cancel()
        automatic = nil
        automaticControls?.window?.delegate = nil
        automaticControls?.close()
        automaticControls = nil
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
        sequence = nil; previousFrame = nil; lastMatch = nil; sourceWriteBarrierForVerification = nil
        edits = ScrollSequenceEdits(); selectedBlockID = nil; selectedBand = nil
        preview.selectedRange = nil
        preview.layout = nil; preview.selectedID = nil; blockPicker.removeAllItems()
        preview.image = nil
        dimensions.stringValue = "尚未捕获图片"
        status.stringValue = "请选择滚动内容，避开固定页眉、侧栏和滚动条。"
        updateControls()
    }

    // Explicit fixture seam: production acceptance, controls and rendering run unchanged.
    // No screen/TCC/input API is invoked by these methods.
    func acceptForVerification(_ image: CGImage, axis requestedAxis: ScrollAxis) async throws -> Bool {
        guard !sessionBusy, !edits.isEditing else { throw ScrollSequenceError.invalidGeometry }
        if frames.isEmpty { direction.selectItem(at: requestedAxis == .vertical ? 0 : 1) }
        guard axis == requestedAxis else { throw ScrollSequenceError.invalidGeometry }
        return try await accept(image)
    }
    @discardableResult
    func startManualForVerification(axis requestedAxis: ScrollAxis, region: CGRect, screenSize: CGSize,
                                    configuration: ManualScrollConfiguration,
                                    provider: @escaping () async throws -> CGImage,
                                    validate: @escaping () throws -> Void = {}) throws -> ManualScrollCoordinator {
        guard !sessionBusy, !edits.isEditing else { throw CaptureError.busy }
        if frames.isEmpty { direction.selectItem(at: requestedAxis == .vertical ? 0 : 1) }
        guard axis == requestedAxis else { throw ScrollSequenceError.invalidGeometry }
        let token = generation
        let driver = ManualScrollScreenDriver(region: region, screenSize: screenSize,
            expectedPixelSize: previousFrame.map { CGSize(width: $0.width, height: $0.height) },
            validate: validate, provider: provider) { [weak self] image in
                guard let self, self.generation == token else { throw CancellationError() }
                return try await self.acceptManualImage(image)
            }
        self.region = region
        beginManual(driver: driver, configuration: configuration)
        guard let manual else { throw CaptureError.busy }
        return manual
    }
    func moveManualRegionForVerification(to region: CGRect) throws {
        guard manual?.canResume == true, let manualDriver else { throw CaptureError.busy }
        try manualDriver.moveRegion(to: region)
        self.region = manualDriver.region
    }
    func resetForVerification() { resetSession() }
    var previewForVerification: ScrollSequencePreview { preview }
    var manualControlsForVerification: NSWindowController? { manualControls }
    var manualDriverForVerification: ManualScrollScreenDriver? { manualDriver }
    var manualRegionForVerification: CGRect? { manualDriver?.region }
    var manualStateForVerification: ManualScrollState? { manual?.state }
    var statusForVerification: String { status.stringValue }
    func waitForOperationForVerification() async { await operation?.value }
    var sequenceForVerification: ScrollCaptureSequence? { sequence }
    var removedBlocksForVerification: Set<UUID> { edits.removed }
    var excludedRangesForVerification: [Range<Int>] { edits.excludedRanges }
    var activeRangeForVerification: Range<Int>? { edits.activeRange }
    var captureDirectionForVerification: Int? { edits.establishedDirection }
    func setAutoCropForVerification(_ enabled: Bool) async throws {
        guard !sessionBusy, !edits.isEditing else { throw ScrollSequenceError.invalidGeometry }
        autoCropButton.state = enabled ? .on : .off
        if let sequence {
            var next = edits; try next.setAutoCropEnabled(enabled, sequence: sequence)
            try await installProjection(next)
        }
    }
    var sourceURLsForVerification: [URL] { frames.map(\.url) }
    var temporaryDirectoryForVerification: URL? { directory }
    var diskBytesForVerification: Int64 { diskBytes }
    var retainedGrayPixelsForVerification: Int { previousFrame?.pixels.count ?? 0 }
    var previewImageForVerification: CGImage? { preview.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
    var previewPixelsForVerification: Int {
        guard let image = preview.image else { return 0 }
        return Int(image.size.width) * Int(image.size.height)
    }
    func currentOutputForVerification() throws -> CGImage {
        guard let sequence else { throw ScrollSequenceError.invalidGeometry }
        return try ScrollImageIO.renderSequence(frames, layout: edits.layout(for: sequence), axis: axis)
    }

    func windowWillClose(_ notification: Notification) { resetSession() }
}

struct StoredScrollFrame: Sendable {
    let url: URL
    let placement: ScrollPlacement
    let width: Int
    let height: Int
}

private enum ScrollSessionError: LocalizedError {
    case imageIO, frameLimit, diskLimit
    var errorDescription: String? {
        switch self {
        case .imageIO: return "无法读取或写入图片。"
        case .frameLimit: return "已达到100帧上限，请完成当前截图后重新开始。"
        case .diskLimit: return "已达到512 MB临时存储上限，请完成当前截图后重新开始。"
        }
    }
}

enum ScrollImageIO {
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

    /// Each source is decoded at thumbnail resolution. The composite never exceeds
    /// 800 × 800 pixels, regardless of output length; no full-size composite is retained.
    static func compositeThumbnail(_ frames: [StoredScrollFrame], width: Int, height: Int,
                                   axis: ScrollAxis) throws -> CGImage {
        guard width > 0, height > 0 else { throw ScrollSessionError.imageIO }
        let scale = min(1, 800 / Double(max(width, height)))
        let thumbnailWidth = max(1, Int(ceil(Double(width) * scale)))
        let thumbnailHeight = max(1, Int(ceil(Double(height) * scale)))
        guard let context = CGContext(data: nil, width: thumbnailWidth, height: thumbnailHeight,
                                      bitsPerComponent: 8, bytesPerRow: thumbnailWidth * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScrollSessionError.imageIO }
        context.interpolationQuality = .high
        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(frame.url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 800,
                        kCGImageSourceCreateThumbnailWithTransform: false
                      ] as CFDictionary) else { throw ScrollSessionError.imageIO }
                let x = Double(frame.placement.x) * scale
                let y = Double(height - frame.placement.y - frame.height) * scale
                let destination = CGRect(x: x, y: y, width: Double(frame.width) * scale, height: Double(frame.height) * scale)
                context.saveGState()
                if index > 0 {
                    if axis == .vertical {
                        context.clip(to: CGRect(x: x, y: y, width: destination.width, height: Double(frame.placement.advance) * scale))
                    } else {
                        context.clip(to: CGRect(x: x + Double(frame.width - frame.placement.advance) * scale,
                                                y: y, width: Double(frame.placement.advance) * scale, height: destination.height))
                    }
                }
                context.draw(image, in: destination)
                context.restoreGState()
            }
        }
        guard let image = context.makeImage() else { throw ScrollSessionError.imageIO }
        return image
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
            try Task.checkCancellation()
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
