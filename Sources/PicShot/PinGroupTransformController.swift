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
    /// One bounded value-only observation, captured before rollback; no windows,
    /// controllers, errors, asset data or raster history are retained here.
    private(set) var lastFailure: PinGroupTransformFailureDiagnostic?
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
        history.clear(); clearSelection(); lastFailure = nil
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
        lastFailure = nil
        let plan = try plannedTransform(index: snapshot(), selectedIDs: selectedIDs, transform: transform)
        try execute(plan)
    }
    /// A single canonical target plan is shared by application, persistence and history.
    /// Do not canonicalize inside apply: undo/redo must replay the exact recorded pair.
    func plannedTransform(index: PinSessionIndex, selectedIDs: Set<UUID>, transform: PinGroupTransform) throws -> PinGroupTransformPlan {
        let screens = NSScreen.screens
        let proposed = try PinGroupTransformPlan(index: index, selectedIDs: selectedIDs, transform: transform)
        if case let .align(alignment) = transform {
            return try PinGroupBackingGeometry.alignmentPlan(proposed, alignment: alignment, screenFrames: screens.map(\.frame)) { index, frame in
                PinGroupBackingGeometry.alignedFrame(frame, toBacking: screens[index].convertRectToBacking,
                                                     fromBacking: screens[index].convertRectFromBacking)
            }
        }
        return try proposed.canonicalizingTargetFrames { try PinGroupBackingGeometry.canonicalFrame($0, screens: screens) }
    }
    private func execute(_ plan: PinGroupTransformPlan) throws {
        lastFailure = nil
        guard selectedIDs == plan.ids else {
            recordFailure(stage: "selection-changed", code: "stalePresentation")
            throw PinGroupTransformError.stalePresentation
        }
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
        lastFailure = nil
        guard let session, plan.ids.isSubset(of: session.groupTransformEligibleIDs) else {
            recordFailure(stage: "eligibility", code: "unavailablePin")
            throw PinGroupTransformError.unavailablePin
        }
        do { try session.flushPresentationChanges() }
        catch { recordFailure(stage: "flush-presentation", code: PinGroupApplyFailure.code(for: error)); throw error }
        do { _ = try plan.applying(to: session.store.index, forward: forward) }
        catch {
            let mismatch = plan.changes.first { session.store.entry(id: $0.id)?.presentation != (forward ? $0.before : $0.after) }
            recordFailure(stage: "validate-store", code: PinGroupApplyFailure.code(for: error), id: mismatch?.id,
                          expected: mismatch.map { forward ? $0.before : $0.after })
            throw error
        }
        for change in plan.changes {
            guard let window = session.liveControllers[change.id]?.window ?? session.richControllers[change.id]?.window else {
                throw PinGroupTransformError.unavailablePin
            }
            let expected = forward ? change.before : change.after
            guard presentation(id: change.id) == expected else {
                recordFailure(stage: "validate-current", code: "stalePresentation", id: change.id, expected: expected)
                throw PinGroupTransformError.stalePresentation
            }
            let target = forward ? change.after : change.before
            let minimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
            guard target.frame.width >= Double(minimum.width), target.frame.height >= Double(minimum.height) else {
                recordFailure(stage: "native-minimum", code: "invalidGeometry", id: change.id, expected: target)
                throw PinGroupTransformError.invalidGeometry
            }
        }
        // No await/event-loop yield occurs in this transaction. AppKit's constrained
        // frame is verified before the single disk write; either failure restores all.
        do {
            for change in plan.changes { setPresentation(forward ? change.after : change.before, id: change.id) }
            for change in plan.changes {
                guard presentation(id: change.id) == (forward ? change.after : change.before) else {
                    recordFailure(stage: "verify-target", code: "windowConstraint", id: change.id,
                                  expected: forward ? change.after : change.before)
                    throw PinGroupTransformError.windowConstraint
                }
            }
            try session.store.applyGroupPresentations(plan, forward: forward)
        } catch {
            if lastFailure == nil { recordFailure(stage: "commit-store", code: PinGroupApplyFailure.code(for: error)) }
            for change in plan.changes { setPresentation(forward ? change.before : change.after, id: change.id) }
            throw error
        }
    }
    private func recordFailure(stage: String, code: String, id: UUID? = nil, expected: PinPresentation? = nil) {
        let window = id.flatMap { session?.liveControllers[$0]?.window ?? session?.richControllers[$0]?.window }
        lastFailure = PinGroupTransformFailureDiagnostic(stage: stage, code: code, pinID: id,
            expected: expected, actual: id.flatMap { presentation(id: $0) },
            stored: id.flatMap { session?.store.entry(id: $0)?.presentation },
            rawWindowFrame: window.map { PinWindowFrame($0.frame) }, backingScaleFactor: window.map { Double($0.backingScaleFactor) })
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
                guard let self else { throw PinGroupTransformError.unavailablePin }
                self.lastFailure = nil
                let plan = try self.plannedTransform(index: snapshot, selectedIDs: ids, transform: transform)
                try self.execute(plan)
            }
            editor.onApplyAttempt = { [weak self] in self?.lastFailure = nil }
            editor.onClose = { [weak self] in self?.editor = nil }
            editor.window?.collectionBehavior = PinDesktopVisibilityPolicy.behavior(session?.desktopVisibility ?? .defaultMode, preserving: [.fullScreenAuxiliary])
            self.editor = editor; editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
        } catch { session?.onError?(error) }
    }
}

/// Destination geometry, never the source window's backing factor. AppKit conversions
/// handle global screen origins and mixed-resolution displays; no points-to-pixels
/// scale is guessed. Offscreen proposals use the nearest display without relocating.
@MainActor enum PinGroupBackingGeometry {
    static func canonicalFrame(_ frame: PinWindowFrame, screens: [NSScreen]) throws -> PinWindowFrame {
        try canonicalFrame(frame, screenFrames: screens.map(\.frame)) { index, proposed in
            let screen = screens[index]
            return alignedFrame(proposed, toBacking: screen.convertRectToBacking, fromBacking: screen.convertRectFromBacking)
        }
    }

    static func canonicalFrame(_ frame: PinWindowFrame, screenFrames: [NSRect], align: (Int, NSRect) -> NSRect) throws -> PinWindowFrame {
        guard var index = destinationScreenIndex(for: frame.rect, screenFrames: screenFrames) else {
            throw PinGroupTransformError.windowConstraint
        }
        // Rounding near a display seam can change the majority-overlap destination.
        // Re-evaluate the original proposal, never accumulate rounding or touch a
        // source snapshot. A destination cycle rejects before any window is mutated.
        var visited: Set<Int> = []
        while visited.insert(index).inserted {
            let canonical = PinWindowFrame(align(index, frame.rect))
            guard canonical.isValid else { throw PinGroupTransformError.invalidGeometry }
            guard let destination = destinationScreenIndex(for: canonical.rect, screenFrames: screenFrames) else {
                throw PinGroupTransformError.windowConstraint
            }
            if destination == index { return canonical }
            index = destination
        }
        throw PinGroupTransformError.windowConstraint
    }

    /// Alignment preserves every dimension. Edges share a representable anchor.
    /// Centers use the nearest pixel-aligned origin around the requested shared
    /// center: mixed odd/even extents can leave a half-pixel center residual.
    /// These are explicit targets, never a tolerance in transaction verification.
    static func alignmentPlan(_ proposed: PinGroupTransformPlan, alignment: PinGroupAlignment,
                              screenFrames: [NSRect], align: (Int, NSRect) -> NSRect) throws -> PinGroupTransformPlan {
        guard !proposed.isNoOp else { return proposed }
        if alignment == .horizontalCenter || alignment == .verticalCenter {
            return try proposed.canonicalizingTargetFrames { frame in
                try canonicalOriginFrame(frame, screenFrames: screenFrames, align: align)
            }
        }
        func anchor(_ frame: PinWindowFrame) -> Double {
            switch alignment {
            case .left: return frame.x
            case .right: return frame.x + frame.width
            case .top: return frame.y + frame.height
            case .bottom: return frame.y
            case .horizontalCenter: return frame.x + frame.width / 2
            case .verticalCenter: return frame.y + frame.height / 2
            }
        }
        func positioned(_ frame: PinWindowFrame, at anchor: Double) -> PinWindowFrame {
            var result = frame
            switch alignment {
            case .left: result.x = anchor
            case .right: result.x = anchor - frame.width
            case .top: result.y = anchor - frame.height
            case .bottom: result.y = anchor
            case .horizontalCenter: result.x = anchor - frame.width / 2
            case .verticalCenter: result.y = anchor - frame.height / 2
            }
            return result
        }
        let desired = anchor(proposed.changes[0].after.frame)
        var candidates: Set<Double> = [desired]
        for change in proposed.changes {
            for index in screenFrames.indices {
                let rounded = align(index, change.after.frame.rect)
                var translated = change.after.frame
                translated.x = Double(rounded.minX); translated.y = Double(rounded.minY)
                let candidate = anchor(translated)
                if candidate.isFinite { candidates.insert(candidate) }
            }
        }
        let ordered = candidates.sorted {
            abs($0 - desired) == abs($1 - desired) ? $0 < $1 : abs($0 - desired) < abs($1 - desired)
        }
        for candidate in ordered {
            guard let plan = try? proposed.canonicalizingTargetFrames({
                try canonicalOriginFrame(positioned($0, at: candidate), screenFrames: screenFrames, align: align)
            }) else { continue }
            let exact = plan.changes.allSatisfy { change in
                guard anchor(change.after.frame) == candidate,
                      let canonical = try? canonicalOriginFrame(change.after.frame, screenFrames: screenFrames, align: align) else { return false }
                return canonical == change.after.frame
            }
            if exact { return plan }
        }
        throw PinGroupTransformError.unrepresentableAlignment
    }

    private static func canonicalOriginFrame(_ frame: PinWindowFrame, screenFrames: [NSRect],
                                             align: (Int, NSRect) -> NSRect) throws -> PinWindowFrame {
        let result = try canonicalFrame(frame, screenFrames: screenFrames) { index, proposed in
            NSRect(origin: align(index, proposed).origin, size: proposed.size)
        }
        // A retained half-point extent from 2× may be unrepresentable on 1×.
        // Reject before mutation rather than resize it or defer to loose equality.
        guard try canonicalFrame(result, screenFrames: screenFrames, align: align) == result else {
            throw PinGroupTransformError.unrepresentableAlignment
        }
        return result
    }

    /// Signed screen-point offsets from the requested collective center. Reporting
    /// them makes quantized center semantics explicit without relaxing exact apply.
    static func centerAlignmentResiduals(_ plan: PinGroupTransformPlan, alignment: PinGroupAlignment) -> [UUID: Double] {
        let frames = plan.changes.map(\.before.frame)
        guard !frames.isEmpty else { return [:] }
        let desired: Double
        switch alignment {
        case .horizontalCenter: desired = (frames.map(\.x).min()! + frames.map { $0.x + $0.width }.max()!) / 2
        case .verticalCenter: desired = (frames.map(\.y).min()! + frames.map { $0.y + $0.height }.max()!) / 2
        default: return [:]
        }
        return Dictionary(uniqueKeysWithValues: plan.changes.map { change in
            let frame = change.after.frame
            let actual = alignment == .horizontalCenter ? frame.x + frame.width / 2 : frame.y + frame.height / 2
            return (change.id, actual - desired)
        })
    }

    static func alignedFrame(_ frame: NSRect, toBacking: (NSRect) -> NSRect, fromBacking: (NSRect) -> NSRect) -> NSRect {
        fromBacking(NSIntegralRectWithOptions(toBacking(frame), .alignAllEdgesNearest))
    }

    /// NSWindow.screen is the screen containing most of the window. Break area ties
    /// by distance, then display order, so crossing a mixed-resolution boundary is stable.
    static func destinationScreenIndex(for frame: NSRect, screenFrames: [NSRect]) -> Int? {
        func overlap(_ screen: NSRect) -> CGFloat {
            let intersection = frame.intersection(screen)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        func distance(_ screen: NSRect) -> CGFloat {
            let dx = max(0, max(screen.minX - frame.midX, frame.midX - screen.maxX))
            let dy = max(0, max(screen.minY - frame.midY, frame.midY - screen.maxY))
            return dx * dx + dy * dy
        }
        var best: Int?
        for index in screenFrames.indices {
            guard let current = best else { best = index; continue }
            if overlap(screenFrames[index]) > overlap(screenFrames[current]) ||
                (overlap(screenFrames[index]) == overlap(screenFrames[current]) && distance(screenFrames[index]) < distance(screenFrames[current])) {
                best = index
            }
        }
        return best
    }
}

/// A small native inspector, reached from the existing manager or pin context menu.
/// Editing fields does not preview/mutate windows, so Esc/Cancel is an exact no-op.
@MainActor final class PinGroupTransformEditor: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onApplyAttempt: (() -> Void)?
    private let dx = NSTextField(string: "0"), dy = NSTextField(string: "0"), scale = NSTextField(string: "100")
    private let status = NSTextField(wrappingLabelWithString: "向右 / 向上位移（点），围绕整体左下角缩放；图片像素与文字大小不变")
    private var apply: ((PinGroupTransform) throws -> Void)?
    private(set) var applyOutcome = "notAttempted"
    private(set) var lastApplyFailure: PinGroupApplyFailure?
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
        applyOutcome = "failed"; lastApplyFailure = nil; onApplyAttempt?()
        guard let x = Double(dx.stringValue), let y = Double(dy.stringValue), let percent = Double(scale.stringValue) else {
            let error = PinGroupTransformError.invalidGeometry
            lastApplyFailure = PinGroupApplyFailure(error); status.stringValue = error.localizedDescription; return
        }
        guard let apply else {
            lastApplyFailure = PinGroupApplyFailure(code: "missing-handler", message: "组合操作已结束，请重新打开。"); return
        }
        do {
            try apply(.moveAndScale(dx: x, dy: y, scale: percent / 100))
            applyOutcome = "succeeded"; close()
        } catch { lastApplyFailure = PinGroupApplyFailure(error); status.stringValue = error.localizedDescription }
    }
    @objc private func cancelTransform() { close() }
    func windowWillClose(_ notification: Notification) {
        apply = nil; onApplyAttempt = nil
        window?.initialFirstResponder = nil; window?.contentView = nil; window?.delegate = nil
        let callback = onClose; onClose = nil; callback?()
    }
}

struct PinGroupTransformFailureDiagnostic: Encodable {
    let stage: String
    let code: String
    let pinID: UUID?
    let expected: PinPresentation?
    let actual: PinPresentation?
    let stored: PinPresentation?
    let rawWindowFrame: PinWindowFrame?
    let backingScaleFactor: Double?
}

struct PinGroupApplyFailure: Encodable {
    let code: String
    let message: String
    init(code: String, message: String) { self.code = code; self.message = String(message.prefix(512)) }
    init(_ error: Error) { self.init(code: Self.code(for: error), message: error.localizedDescription) }
    static func code(for error: Error) -> String {
        if let error = error as? PinGroupTransformError {
            switch error {
            case .invalidSelection: return "invalidSelection"
            case .unavailablePin: return "unavailablePin"
            case .stalePresentation: return "stalePresentation"
            case .invalidGeometry: return "invalidGeometry"
            case .windowConstraint: return "windowConstraint"
            case .unrepresentableAlignment: return "unrepresentableAlignment"
            }
        }
        return String(String(reflecting: type(of: error)).prefix(128))
    }
}
