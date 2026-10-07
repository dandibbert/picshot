import AppKit
import Combine
import PicShotCore

/// Owns only bounded IDs and value metadata. The session alone owns live pin windows.
@MainActor final class PinGroupTransformController: ObservableObject {
    @Published private(set) var revision: UInt = 0
    private(set) var selectedIDs: Set<UUID> = []
    private(set) var history = PinGroupTransformHistory()
    private weak var session: PinSessionCoordinator?
    private var groupID: UUID
    private(set) var editor: PinGroupTransformEditor?
    var canUndo: Bool { !history.undoPlans.isEmpty }
    var canRedo: Bool { !history.redoPlans.isEmpty }
    var canTransform: Bool { selectedIDs.count >= 2 }

    init(session: PinSessionCoordinator) { self.session = session; groupID = session.store.index.activeGroupID }

    func setSelection(_ ids: Set<UUID>) throws {
        guard let session, ids.count <= PinGroupTransformPlan.maximumSelection else { throw PinGroupTransformError.invalidSelection }
        guard ids.isSubset(of: session.groupTransformEligibleIDs) else { throw PinGroupTransformError.unavailablePin }
        selectedIDs = ids; updateHighlights(); revision &+= 1
    }
    func toggleSelection(id: UUID) {
        var ids = selectedIDs
        if !ids.insert(id).inserted { ids.remove(id) }
        do { try setSelection(ids) } catch { session?.onError?(error) }
    }
    func clearSelection() { selectedIDs.removeAll(); updateHighlights(); revision &+= 1 }

    /// Closing/deleting a member, changing its presentation independently, or changing
    /// groups cannot cause a later undo to overwrite an unrelated or stale pin.
    func pinChanged(id: UUID) {
        history.invalidate(id: id)
        if session?.groupTransformEligibleIDs.contains(id) != true { selectedIDs.remove(id) }
        updateHighlights(); revision &+= 1
    }
    func reconcile() {
        guard let session else { return }
        if groupID != session.store.index.activeGroupID || session.store.visibleEntries.isEmpty {
            reset(); groupID = session.store.index.activeGroupID
        } else {
            let eligible = session.groupTransformEligibleIDs
            for id in selectedIDs.subtracting(eligible) { history.invalidate(id: id) }
            selectedIDs.formIntersection(eligible); updateHighlights(); revision &+= 1
        }
    }
    func dismissEditor() { editor?.close(); editor = nil }
    func reset() {
        dismissEditor()
        history.clear(); clearSelection()
    }
    private func updateHighlights() {
        guard let session else { return }
        for (id, pin) in session.liveControllers { pin.setGroupSelected(selectedIDs.contains(id)) }
        for (id, pin) in session.richControllers { pin.setGroupSelected(selectedIDs.contains(id)) }
    }
    func snapshot() throws -> PinSessionIndex {
        guard let session, selectedIDs.count >= 2, selectedIDs.isSubset(of: session.groupTransformEligibleIDs) else {
            throw PinGroupTransformError.invalidSelection
        }
        try session.flushPresentationChanges()
        return session.store.index
    }
    func transform(_ transform: PinGroupTransform) throws {
        let plan = try PinGroupTransformPlan(index: snapshot(), selectedIDs: selectedIDs, transform: transform)
        try execute(plan)
    }
    func execute(_ plan: PinGroupTransformPlan) throws {
        guard selectedIDs == plan.ids else { throw PinGroupTransformError.stalePresentation }
        try apply(plan, forward: true)
        history.record(plan); revision &+= 1
    }
    func undo() throws {
        guard let plan = history.undoPlans.last else { return }
        try apply(plan, forward: false); history.didUndo(); revision &+= 1
    }
    func redo() throws {
        guard let plan = history.redoPlans.last else { return }
        try apply(plan, forward: true); history.didRedo(); revision &+= 1
    }

    private func apply(_ plan: PinGroupTransformPlan, forward: Bool) throws {
        guard let session, plan.ids.isSubset(of: session.groupTransformEligibleIDs) else { throw PinGroupTransformError.unavailablePin }
        try session.flushPresentationChanges()
        _ = try plan.applying(to: session.store.index, forward: forward)
        for change in plan.changes {
            guard let window = session.liveControllers[change.id]?.window ?? session.richControllers[change.id]?.window else {
                throw PinGroupTransformError.unavailablePin
            }
            let expected = forward ? change.before : change.after
            guard presentation(id: change.id) == expected else { throw PinGroupTransformError.stalePresentation }
            let target = forward ? change.after : change.before
            let minimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
            guard target.frame.width >= Double(minimum.width), target.frame.height >= Double(minimum.height) else {
                throw PinGroupTransformError.invalidGeometry
            }
        }
        // No await/event-loop yield occurs in this transaction. AppKit's constrained
        // frame is verified before the single disk write; either failure restores all.
        do {
            for change in plan.changes { setPresentation(forward ? change.after : change.before, id: change.id) }
            for change in plan.changes {
                guard presentation(id: change.id) == (forward ? change.after : change.before) else {
                    throw PinGroupTransformError.windowConstraint
                }
            }
            try session.store.applyGroupPresentations(plan, forward: forward)
        } catch {
            for change in plan.changes { setPresentation(forward ? change.before : change.after, id: change.id) }
            throw error
        }
    }
    private func presentation(id: UUID) -> PinPresentation? {
        session?.liveControllers[id]?.presentation ?? session?.richControllers[id]?.presentation
    }
    private func setPresentation(_ value: PinPresentation, id: UUID) {
        session?.liveControllers[id]?.applyPresentation(value)
        session?.richControllers[id]?.applyPresentation(value)
    }
    func showEditor() {
        if let editor { editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil); return }
        do {
            let snapshot = try snapshot(), ids = selectedIDs
            let editor = PinGroupTransformEditor(count: ids.count) { [weak self] transform in
                let plan = try PinGroupTransformPlan(index: snapshot, selectedIDs: ids, transform: transform)
                try self?.execute(plan)
            }
            editor.onClose = { [weak self] in self?.editor = nil }
            editor.window?.collectionBehavior = PinDesktopVisibilityPolicy.behavior(session?.desktopVisibility ?? .defaultMode, preserving: [.fullScreenAuxiliary])
            self.editor = editor; editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
        } catch { session?.onError?(error) }
    }
}

/// A small native inspector, reached from the existing manager or pin context menu.
/// Editing fields does not preview/mutate windows, so Esc/Cancel is an exact no-op.
@MainActor final class PinGroupTransformEditor: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let dx = NSTextField(string: "0"), dy = NSTextField(string: "0"), scale = NSTextField(string: "100")
    private let status = NSTextField(wrappingLabelWithString: "向右 / 向上位移（点），围绕整体左下角缩放；图片像素与文字大小不变")
    private var apply: ((PinGroupTransform) throws -> Void)?
    init(count: Int, apply: @escaping (PinGroupTransform) throws -> Void) {
        self.apply = apply
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 215), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "组合移动 / 缩放 · \(count) 项"; panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.level = .floating; panel.center()
        let fields: [(String, String, NSTextField)] = [("向右", "pin-group-dx", dx), ("向上", "pin-group-dy", dy), ("比例 %", "pin-group-scale", scale)]
        let rows = fields.map { title, identifier, field -> NSStackView in
            field.identifier = NSUserInterfaceItemIdentifier(identifier); field.setAccessibilityLabel(title)
            field.widthAnchor.constraint(equalToConstant: 160).isActive = true
            let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 75).isActive = true
            let row = NSStackView(views: [label, field]); row.spacing = 10; return row
        }
        let applyButton = NSButton(title: "应用", target: self, action: #selector(applyTransform))
        applyButton.identifier = NSUserInterfaceItemIdentifier("pin-group-apply"); applyButton.keyEquivalent = "\r"; applyButton.keyEquivalentModifierMask = []
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTransform))
        cancel.identifier = NSUserInterfaceItemIdentifier("pin-group-cancel"); cancel.keyEquivalent = "\u{1b}"; cancel.keyEquivalentModifierMask = []
        let actions = NSStackView(views: [cancel, applyButton]); actions.spacing = 10
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        let root = NSStackView(views: rows.map { $0 as NSView } + [status, actions]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        let container = NSView(); container.addSubview(root); panel.contentView = container
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16), root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16), root.topAnchor.constraint(equalTo: container.topAnchor, constant: 16)])
        panel.initialFirstResponder = dx
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func applyTransform() {
        guard let x = Double(dx.stringValue), let y = Double(dy.stringValue), let percent = Double(scale.stringValue) else {
            status.stringValue = PinGroupTransformError.invalidGeometry.localizedDescription; return
        }
        do { try apply?(.moveAndScale(dx: x, dy: y, scale: percent / 100)); close() }
        catch { status.stringValue = error.localizedDescription }
    }
    @objc private func cancelTransform() { close() }
    func windowWillClose(_ notification: Notification) {
        apply = nil
        window?.initialFirstResponder = nil; window?.contentView = nil; window?.delegate = nil
        let callback = onClose; onClose = nil; callback?()
    }
}
