import AppKit
import PicShotCore

/// Edits a draft only. SettingsController commits it explicitly; canceling a
/// native directory picker leaves both the draft and stored preferences intact.
@MainActor
final class SaveWorkflowSettingsView: NSView, NSTextFieldDelegate {
    let folderLabel = NSTextField(labelWithString: "尚未选择文件夹")
    let chooseFolderButton = NSButton(title: "选择文件夹…", target: nil, action: nil)
    let folderTemplate = NSTextField(string: "")
    let filenameTemplate = NSTextField(string: "")
    let automatic = NSButton(checkboxWithTitle: "完成复制 / 贴图 / 保存到历史后，自动保存最终图片副本", target: nil, action: nil)
    let collisions = NSPopUpButton()
    let previewLabel = NSTextField(wrappingLabelWithString: "")
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var baseURL: URL?
    private(set) var folderPanel: NSOpenPanel?
    var onFolderPanelShown: ((NSOpenPanel) -> Void)?
    var onChange: (() -> Void)?
    init(settings: SaveWorkflowSettings) {
        baseURL = settings.baseURL; super.init(frame: .zero)
        folderTemplate.stringValue = settings.relativeFolderTemplate; filenameTemplate.stringValue = settings.filenameTemplate
        automatic.state = settings.autoOnFinalizedAction ? .on : .off
        collisions.addItems(withTitles: ["询问：保留两者 / 改名 / 取消", "自动保留两者"])
        collisions.selectItem(at: settings.collisionBehavior == .ask ? 0 : 1)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        folderLabel.lineBreakMode = .byTruncatingMiddle; folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chooseFolderButton.target = self; chooseFolderButton.action = #selector(chooseFolder); chooseFolderButton.identifier = .init("saveWorkflow.chooseFolder")
        folderTemplate.identifier = .init("saveWorkflow.folderTemplate"); filenameTemplate.identifier = .init("saveWorkflow.filenameTemplate")
        automatic.identifier = .init("saveWorkflow.automatic"); collisions.identifier = .init("saveWorkflow.collision")
        previewLabel.identifier = .init("saveWorkflow.preview"); errorLabel.identifier = .init("saveWorkflow.error")
        folderTemplate.placeholderString = "可选，例如 {date}"; filenameTemplate.placeholderString = "PicShot-{date}-{time}-{counter}"
        for field in [folderTemplate, filenameTemplate] { field.delegate = self; field.target = self; field.action = #selector(changed) }
        automatic.target = self; automatic.action = #selector(changed); collisions.target = self; collisions.action = #selector(changed)
        let folder = NSStackView(views: [folderLabel, chooseFolderButton]); folder.spacing = 8
        stack.addArrangedSubview(folder); folder.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for (title, field) in [("子文件夹", folderTemplate), ("文件名称", filenameTemplate)] {
            let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 60).isActive = true
            let row = NSStackView(views: [label, field]); row.spacing = 8; field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.addArrangedSubview(collisions); stack.addArrangedSubview(automatic)
        let help = NSTextField(wrappingLabelWithString: "支持 {date}、{time}、{width}、{height}、{counter}；扩展名由实际格式添加。自动保存默认关闭，仅保存明确完成动作后的扁平化结果，不保存原始截屏、预览或中间编辑。")
        help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor
        previewLabel.font = .systemFont(ofSize: 11); previewLabel.maximumNumberOfLines = 3
        errorLabel.font = .systemFont(ofSize: 11); errorLabel.textColor = .systemRed; errorLabel.maximumNumberOfLines = 2
        for label in [help, previewLabel, errorLabel] { stack.addArrangedSubview(label); label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
        refreshPreview()
    }
    required init?(coder: NSCoder) { fatalError() }
    var draft: SaveWorkflowSettings {
        SaveWorkflowSettings(baseURL: baseURL, relativeFolderTemplate: folderTemplate.stringValue,
            filenameTemplate: filenameTemplate.stringValue, autoOnFinalizedAction: automatic.state == .on,
            collisionBehavior: collisions.indexOfSelectedItem == 1 ? .keepBoth : .ask)
    }
    func validatedSettings() throws -> SaveWorkflowSettings {
        let value = draft; try value.validate(); if let baseURL { try SaveWorkflowService.validateBaseDirectory(baseURL) }; return value
    }
    func applyFolderSelection(_ selected: URL?) throws {
        guard let selected else { return }
        let approved = selected.standardizedFileURL.resolvingSymlinksInPath()
        try SaveWorkflowService.validateBaseDirectory(approved); baseURL = approved; refreshPreview(); onChange?()
    }
    @objc private func changed() { refreshPreview(); onChange?() }
    func controlTextDidChange(_ notification: Notification) { changed() }
    func refreshPreview() {
        folderLabel.stringValue = baseURL?.path ?? "尚未选择文件夹"
        do {
            _ = try SaveWorkflowTemplate(folder: draft.relativeFolderTemplate, filename: draft.filenameTemplate)
            if let baseURL {
                let context = SaveWorkflowContext(width: 1920, height: 1080, counter: 1, timeZoneIdentifier: TimeZone.current.identifier)
                let rendered = try draft.preview(context: context)
                previewLabel.stringValue = "示例（1920 × 1080，编号 1）：\n" + rendered.url.path; folderLabel.toolTip = baseURL.path
            } else { previewLabel.stringValue = "选择文件夹后显示完整保存路径" }
            try draft.validate(); errorLabel.stringValue = ""
        } catch { errorLabel.stringValue = error.localizedDescription; previewLabel.stringValue = "请修正设置后查看示例" }
    }
    @objc private func chooseFolder() {
        guard folderPanel == nil else { return }
        let panel = NSOpenPanel(); panel.title = "选择快速保存文件夹"; panel.prompt = "选择文件夹"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true; panel.directoryURL = baseURL
        panel.message = "此处只修改设置草稿；点击“保存设置”后生效。"; folderPanel = panel
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }; self.folderPanel = nil
            do { try self.applyFolderSelection(response == .OK ? panel.url : nil) }
            catch { self.errorLabel.stringValue = error.localizedDescription }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: completion) } else { panel.begin(completionHandler: completion) }
        DispatchQueue.main.async { [weak self] in self?.onFolderPanelShown?(panel) }
    }
    func cancelPendingPanel() { folderPanel?.cancel(nil); folderPanel = nil }
}
