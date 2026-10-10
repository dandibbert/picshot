import AppKit

/// An explicit saved-preference review. Building or cancelling the sheet has no
/// persistence effects; the owner commits only after the primary button succeeds.
@MainActor final class PortableSettingsReviewController: NSWindowController, NSWindowDelegate {
    let plan: PortableSettingsImportPlan
    let applyButton = SettingsActionButton(title: "导入并保存", target: nil, action: nil)
    let cancelButton = SettingsActionButton(title: "取消", target: nil, action: nil)
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let applyPlan: () throws -> Void
    private let finished: (Bool) -> Void
    private var completed = false

    init(plan: PortableSettingsImportPlan, apply: @escaping () throws -> Void, finished: @escaping (Bool) -> Void) {
        self.plan = plan; applyPlan = apply; self.finished = finished
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 490),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "导入配置预览"; window.isReleasedWhenClosed = false
        window.identifier = .init("settings.importReview")
        super.init(window: window); window.delegate = self
        let root = PortableSettingsReviewSurface(); window.contentView = root
        let heading = NSTextField(labelWithString: plan.hasChanges ? "将导入 \(plan.changes.count) 项设置" : "导入文件与已保存设置一致")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.identifier = .init("settings.importReview.heading")
        let explanation = NSTextField(wrappingLabelWithString: "只替换下列已保存设置。导入并保存后将关闭设置窗口；本窗口尚未保存的草稿将被放弃。取消不会更改设置或草稿。")
        explanation.font = .systemFont(ofSize: 12); explanation.textColor = .secondaryLabelColor
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder; scroll.drawsBackground = true
        let differences = NSStackView(); differences.orientation = .vertical; differences.alignment = .leading
        differences.spacing = 10; differences.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        differences.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = differences
        for change in plan.changes {
            let label = NSTextField(labelWithString: change.label); label.font = .systemFont(ofSize: 12, weight: .semibold)
            let before = NSTextField(wrappingLabelWithString: "当前：" + change.oldValue)
            let after = NSTextField(wrappingLabelWithString: "导入：" + change.newValue)
            before.textColor = .secondaryLabelColor
            for value in [before, after] { value.font = .systemFont(ofSize: 12); value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
            let row = NSStackView(views: [label, before, after]); row.orientation = .vertical; row.alignment = .leading; row.spacing = 3
            row.identifier = .init("settings.importReview.change." + change.id)
            differences.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: differences.widthAnchor, constant: -24).isActive = true
            before.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            after.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        }
        let warning = NSTextField(wrappingLabelWithString: plan.changesHistoryRetention
            ? "历史保留上限将变化：导入成功后会按新上限清理未收藏内容。此清理不能通过恢复配置找回。"
            : "文件不包含截图、文字、贴图、保存路径、保存命名与自动副本选项、密码或录屏输入提示开关。")
        warning.font = .systemFont(ofSize: 11); warning.textColor = plan.changesHistoryRetention ? .systemOrange : .secondaryLabelColor
        errorLabel.font = .systemFont(ofSize: 11); errorLabel.textColor = .systemRed
        errorLabel.identifier = .init("settings.importReview.error")
        applyButton.target = self; applyButton.action = #selector(applyImport); applyButton.keyEquivalent = "\r"
        applyButton.identifier = .init("settings.importReview.apply"); applyButton.isEnabled = plan.hasChanges
        cancelButton.target = self; cancelButton.action = #selector(cancelImport); cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.identifier = .init("settings.importReview.cancel")
        let buttons = NSStackView(views: [cancelButton, applyButton]); buttons.spacing = 8
        for view in [heading, explanation, scroll, warning, errorLabel, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            explanation.leadingAnchor.constraint(equalTo: heading.leadingAnchor), explanation.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            explanation.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: explanation.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: warning.topAnchor, constant: -10),
            differences.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), differences.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            differences.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            warning.leadingAnchor.constraint(equalTo: heading.leadingAnchor), warning.trailingAnchor.constraint(equalTo: explanation.trailingAnchor),
            warning.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -6),
            errorLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor), errorLabel.trailingAnchor.constraint(equalTo: explanation.trailingAnchor),
            errorLabel.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8), errorLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(on parent: NSWindow) {
        guard !completed, let window, parent.attachedSheet == nil else { return }
        parent.beginSheet(window)
    }
    func cancel() { finish(applied: false) }
    @objc private func cancelImport() { cancel() }
    @objc private func applyImport() {
        guard !completed, plan.hasChanges else { return }
        do { try applyPlan(); finish(applied: true) }
        catch { errorLabel.stringValue = error.localizedDescription; window?.contentView?.layoutSubtreeIfNeeded() }
    }
    private func finish(applied: Bool) {
        guard !completed else { return }; completed = true
        if let window {
            window.sheetParent?.endSheet(window, returnCode: applied ? .OK : .cancel)
            window.orderOut(nil)
        }
        finished(applied)
    }
    func windowWillClose(_ notification: Notification) { cancel() }
}

@MainActor private final class PortableSettingsReviewSurface: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
}
