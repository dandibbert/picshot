import AppKit
import PicShotCore

/// Owns exactly one controller per live pin. Hidden/inactive groups have no controllers
/// or decoded full-size images. The store owns only disk assets and bounded thumbnails.
@MainActor final class PinSessionCoordinator {
    static let maximumLivePins = 20
    let store: PinSessionStore
    private(set) var liveControllers: [UUID: PinController] = [:]
    private(set) var richControllers: [UUID: RichPinController] = [:]
    var livePinIDs: Set<UUID> { Set(liveControllers.keys).union(richControllers.keys) }
    var livePinCount: Int { liveControllers.count + richControllers.count }
    static let maximumLiveAnimations = 4
    var onError: ((Error) -> Void)?
    private let screens: @MainActor () -> [CGRect]
    private let presentWindows: Bool
    private let debounceNanoseconds: UInt64
    private var pendingPresentations: [UUID: PinPresentation] = [:]
    private var presentationSaveTask: Task<Void, Never>?
    private var terminated = false

    init(store: PinSessionStore, presentWindows: Bool = true,
         debounceNanoseconds: UInt64 = 250_000_000,
         screens: @escaping @MainActor () -> [CGRect] = { NSScreen.screens.map(\.visibleFrame) }) {
        self.store = store; self.presentWindows = presentWindows
        self.debounceNanoseconds = debounceNanoseconds; self.screens = screens
    }
    deinit { presentationSaveTask?.cancel() }

    /// Call only at launch. A disabled preference and smoke mode are strict no-op paths.
    func restoreOnLaunch(enabled: Bool, isSmoke: Bool) throws {
        guard enabled, !isSmoke, !terminated else { return }
        try reconcileVisiblePins()
    }

    /// A new capture does not implicitly reopen old saved pins when launch restore is off.
    /// Explicit Show, Recover, or a group-manager action reopens the whole visible group.
    @discardableResult func add(image: CGImage, title: String = "贴图") throws -> UUID {
        guard !terminated else { throw PinSessionError.missingPin }
        guard livePinCount < Self.maximumLivePins else { throw PinSessionError.capacityExceeded }
        let controller = PinController(image: image)
        let entry: PinSessionEntry
        do {
            entry = try store.add(image: image, title: title, presentation: controller.presentation,
                                  protecting: livePinIDs, revealingGroup: true)
        } catch {
            controller.close()
            throw error
        }
        connect(controller, id: entry.id)
        present(controller)
        return entry.id
    }

    @discardableResult func add(rich prepared: PreparedRichPin) throws -> UUID {
        guard !terminated else { throw PinSessionError.missingPin }
        guard livePinCount < Self.maximumLivePins else { throw PinSessionError.capacityExceeded }
        try checkAnimationCapacity(kind: prepared.kind)
        let controller = try RichPinController(asset: prepared.asset, data: prepared.data, title: prepared.title)
        do {
            let entry = try store.add(rich: prepared, presentation: controller.presentation, protecting: livePinIDs, revealingGroup: true)
            connect(controller, id: entry.id); present(controller); return entry.id
        } catch { controller.close(); throw error }
    }
    private func checkAnimationCapacity(kind: PinContentKind) throws {
        if kind == .animation && richControllers.values.filter({ $0.kind == .animation }).count >= Self.maximumLiveAnimations {
            throw PicShotError.message("最多同时打开 4 个动态贴图，请先隐藏或关闭一些动态贴图。")
        }
    }
    private func loadRich(_ entry: PinSessionEntry) throws {
        guard let rich = entry.richContent else { return }
        try checkAnimationCapacity(kind: rich.kind)
        let controller = try RichPinController(asset: rich, data: store.richData(id: entry.id), title: entry.title)
        if let recovered = store.recoveredPresentation(id: entry.id, screens: screens()) { controller.applyPresentation(recovered) }
        connect(controller, id: entry.id); present(controller)
    }
    private func connect(_ controller: RichPinController, id: UUID) {
        precondition(!livePinIDs.contains(id)); richControllers[id] = controller
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller, self.richControllers[id] === controller else { return }
            self.richControllers.removeValue(forKey: id); self.pendingPresentations.removeValue(forKey: id)
            do {
                if self.store.visibleEntries.contains(where: { $0.id == id }) { try self.store.archive(id: id, presentation: controller.presentation) }
                else if self.store.entry(id: id) != nil { try self.store.updatePresentation(controller.presentation, id: id) }
            } catch { self.onError?(error) }
        }
        controller.onPresentationChange = { [weak self, weak controller] value in
            guard let self, let controller, self.richControllers[id] === controller, !self.terminated else { return }
            self.pendingPresentations[id] = value; self.schedulePresentationSave()
        }
    }
    private func present(_ controller: RichPinController) {
        guard presentWindows else { return }
        controller.showWindow(nil); controller.window?.orderFrontRegardless(); controller.startPlayback()
    }

    func showCurrentGroup() throws {
        guard !terminated else { return }
        try store.showActiveGroup(); try reconcileVisiblePins()
    }
    func hideCurrentGroup() throws {
        guard !terminated else { return }
        try store.setGroupHidden(id: store.index.activeGroupID, hidden: true)
        try reconcileVisiblePins()
    }
    func hideAll() throws {
        guard !terminated else { return }
        try store.setAllHidden(true); try reconcileVisiblePins()
    }
    func switchGroup(id: UUID) throws {
        guard !terminated else { return }
        try store.setActiveGroup(id: id); try reconcileVisiblePins()
    }
    func recoverCurrentGroup() throws {
        guard !terminated else { return }
        var firstError: Error?
        do { try showCurrentGroup() } catch { firstError = error }
        // A corrupt sibling must not strand healthy pins in click-through/low opacity.
        for (id, controller) in liveControllers where store.entry(id: id)?.groupID == store.index.activeGroupID {
            recover(controller)
        }
        for (id, controller) in richControllers where store.entry(id: id)?.groupID == store.index.activeGroupID {
            var value = controller.presentation.normalized(screens: screens().map { PinWindowFrame($0) })
            value.opacity = 1; value.clickThrough = false
            controller.applyPresentation(value); controller.onPresentationChange?(controller.presentation); present(controller)
        }
        do { try flushPresentationChanges() } catch { firstError = firstError ?? error }
        if let firstError { throw firstError }
    }
    /// Restore by explicit close order, including archived entries in another group.
    /// Hide, group switches, and termination never create a close-history entry.
    @discardableResult func restoreLastClosedPin() throws -> UUID? {
        guard !terminated, let entry = store.index.lastArchivedEntry else { return nil }
        try openPin(id: entry.id)
        return entry.id
    }

    func openPin(id: UUID) throws {
        guard !terminated else { throw PinSessionError.missingPin }
        try store.reopen(id: id)
        var firstError: Error?
        do { try reconcileVisiblePins() } catch { firstError = error }
        // Reopening is faithful to the saved presentation. Recover is a separate action.
        if let controller = liveControllers[id] { present(controller) }
        if let controller = richControllers[id] { present(controller) }
        do { try flushPresentationChanges() } catch { firstError = firstError ?? error }
        if let firstError { throw firstError }
    }

    /// The group manager mutates the store first, then calls this. A store removal has
    /// already deleted the pin; hiding/moving/switching merely releases its live window.
    func reconcileVisiblePins() throws {
        guard !terminated else { return }
        let entries = store.visibleEntries
        let desired = Set(entries.map(\.id))
        var firstError: Error?
        for id in Array(livePinIDs) where !desired.contains(id) {
            do { try closePreservingSession(id: id) } catch { firstError = firstError ?? error }
        }
        for entry in entries where !livePinIDs.contains(entry.id) {
            do { try load(entry) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }

    /// Synchronous flush is also used on hide, switch and exit, so the debounce cannot
    /// lose the last move/resize. This writes metadata only, never raster PNGs.
    func flushPresentationChanges() throws {
        presentationSaveTask?.cancel(); presentationSaveTask = nil
        var firstError: Error?
        for (id, presentation) in pendingPresentations {
            guard livePinIDs.contains(id), store.entry(id: id) != nil else {
                pendingPresentations.removeValue(forKey: id); continue
            }
            do {
                try store.updatePresentation(presentation, id: id)
                pendingPresentations.removeValue(forKey: id)
            } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }

    /// Termination preserves which pins were open, never archives or deletes them, even when a metadata write
    /// fails. Detach callbacks before asking AppKit to close its windows.
    func prepareForTermination() throws {
        guard !terminated else { return }
        terminated = true
        var firstError: Error?
        for id in Array(livePinIDs) {
            do { try closePreservingSession(id: id) } catch { firstError = firstError ?? error }
        }
        presentationSaveTask?.cancel(); presentationSaveTask = nil
        pendingPresentations.removeAll(); store.clearThumbnailCache()
        if let firstError { throw firstError }
    }

    private func load(_ entry: PinSessionEntry) throws {
        guard !livePinIDs.contains(entry.id) else { return }
        guard livePinCount < Self.maximumLivePins else { throw PinSessionError.capacityExceeded }
        if entry.richContent != nil {
            try loadRich(entry)
            return
        }
        guard let original = store.image(id: entry.id, original: true) else { throw PinSessionError.invalidImage }
        let modified = entry.original.filename != entry.current.filename
        guard let current = modified ? store.image(id: entry.id) : original else { throw PinSessionError.invalidImage }
        let controller = PinController(originalImage: original, currentImage: current, isModified: modified)
        if let recovered = store.recoveredPresentation(id: entry.id, screens: screens()) {
            controller.applyPresentation(recovered)
        }
        connect(controller, id: entry.id)
        present(controller)
    }
    private func connect(_ controller: PinController, id: UUID) {
        precondition(liveControllers[id] == nil)
        liveControllers[id] = controller
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller, self.liveControllers[id] === controller else { return }
            self.liveControllers.removeValue(forKey: id)
            self.pendingPresentations.removeValue(forKey: id)
            do {
                if self.store.visibleEntries.contains(where: { $0.id == id }) {
                    try self.store.archive(id: id, presentation: controller.presentation)
                } else if self.store.entry(id: id) != nil {
                    // A group mutation can precede reconciliation. A late close from an
                    // already hidden/inactive group must preserve its previous open state.
                    try self.store.updatePresentation(controller.presentation, id: id)
                }
            } catch { self.onError?(error) }
        }
        controller.onPixelChange = { [weak self, weak controller] image, isOriginal in
            guard let self, let controller, self.liveControllers[id] === controller, !self.terminated else { return }
            if isOriginal { try self.store.resetImage(id: id) }
            else { try self.store.replaceImage(image, id: id, protecting: self.livePinIDs) }
        }
        controller.onPresentationChange = { [weak self, weak controller] presentation in
            guard let self, let controller, self.liveControllers[id] === controller, !self.terminated else { return }
            self.pendingPresentations[id] = presentation
            self.schedulePresentationSave()
        }
    }
    private func schedulePresentationSave() {
        presentationSaveTask?.cancel()
        let delay = debounceNanoseconds
        presentationSaveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            do { try self.flushPresentationChanges() } catch { self.onError?(error) }
        }
    }
    private func closePreservingSession(id: UUID) throws {
        if let controller = richControllers[id] {
            defer {
                controller.onClose = nil; controller.onPresentationChange = nil
                richControllers.removeValue(forKey: id); pendingPresentations.removeValue(forKey: id); controller.close()
            }
            if store.entry(id: id) != nil { try store.updatePresentation(controller.presentation, id: id) }
            return
        }
        guard let controller = liveControllers[id] else { return }
        defer {
            // Removing onClose preserves open state on hide/switch instead of archiving.
            controller.onClose = nil; controller.onPixelChange = nil; controller.onPresentationChange = nil
            liveControllers.removeValue(forKey: id); pendingPresentations.removeValue(forKey: id)
            controller.close()
        }
        if store.entry(id: id) != nil { try store.updatePresentation(controller.presentation, id: id) }
    }
    private func present(_ controller: PinController) {
        guard presentWindows else { return }
        controller.showWindow(nil); controller.window?.orderFrontRegardless()
    }
    private func recover(_ controller: PinController) {
        var value = controller.presentation.normalized(screens: screens().map { PinWindowFrame($0) })
        value.opacity = 1; value.clickThrough = false
        controller.applyPresentation(value)
        controller.onPresentationChange?(controller.presentation)
        present(controller)
    }
}
