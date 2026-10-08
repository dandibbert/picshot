import AppKit
import PicShotCore

/// Owns exactly one controller per live pin. Hidden/inactive groups have no controllers
/// or decoded full-size images. The store owns only disk assets and bounded thumbnails.
@MainActor final class PinSessionCoordinator {
    static let maximumLivePins = 20
    let store: PinSessionStore
    let ocrPreferences: PinOCRPreferences
    let desktopVisibilityService: PinDesktopVisibilityService
    var desktopVisibility: PinDesktopVisibility { desktopVisibilityService.mode }
    lazy var groupTransforms = PinGroupTransformController(session: self)
    var groupTransformEligibleIDs: Set<UUID> {
        let visible = Set(store.visibleEntries.map(\.id))
        let images = liveControllers.filter { $0.value.canParticipateInGroupTransform && (!presentWindows || $0.value.window?.isVisible == true) }.keys
        let rich = richControllers.filter { $0.value.canParticipateInGroupTransform && (!presentWindows || $0.value.window?.isVisible == true) }.keys
        return visible.intersection(Set(images).union(rich))
    }
    private(set) var liveControllers: [UUID: PinController] = [:]
    private(set) var richControllers: [UUID: RichPinController] = [:]
    var livePinIDs: Set<UUID> { Set(liveControllers.keys).union(richControllers.keys) }
    var livePinCount: Int { liveControllers.count + richControllers.count }
    static let maximumLiveAnimations = 4
    var onError: ((Error) -> Void)?
    private let screens: @MainActor () -> [CGRect]
    private let presentWindows: Bool
    private let makeImageController: @MainActor (CGImage, CGImage, Bool) -> PinController
    private let debounceNanoseconds: UInt64
    private let editableRasterByteLimit: Int
    private var pendingPresentations: [UUID: PinPresentation] = [:]
    private var presentationSaveTask: Task<Void, Never>?
    private var terminated = false

    init(store: PinSessionStore, presentWindows: Bool = true,
         desktopVisibilityService: PinDesktopVisibilityService? = nil,
         ocrPreferences: PinOCRPreferences? = nil,
         makeImageController: (@MainActor (CGImage, CGImage, Bool) -> PinController)? = nil,
         debounceNanoseconds: UInt64 = 250_000_000,
         editableRasterByteLimit: Int = EditorAdmissionPolicy().maximumRasterBytes,
         screens: @escaping @MainActor () -> [CGRect] = { NSScreen.screens.map(\.visibleFrame) }) {
        self.store = store; self.presentWindows = presentWindows
        self.editableRasterByteLimit = max(0, min(EditorAdmissionPolicy().maximumRasterBytes, editableRasterByteLimit))
        let preferences = ocrPreferences ?? PinOCRPreferences()
        self.ocrPreferences = preferences
        let defaults = preferences.defaults
        self.makeImageController = makeImageController ?? { original, current, modified in
            PinController(originalImage: original, currentImage: current, isModified: modified, defaults: defaults)
        }
        self.desktopVisibilityService = desktopVisibilityService ?? PinDesktopVisibilityService(
            defaults: ProcessInfo.processInfo.environment["PICSHOT_SMOKE_REPORT"] == nil ? .standard : nil)
        self.debounceNanoseconds = debounceNanoseconds; self.screens = screens
    }
    deinit { presentationSaveTask?.cancel() }

    /// Settings save and context controls share this metadata-only path. Hidden pins
    /// adopt the preference when next constructed; changing it never opens a group.
    func setDesktopVisibility(_ mode: PinDesktopVisibility) {
        guard !terminated else { return }
        if mode != desktopVisibility { groupTransforms.dismissEditor() }
        desktopVisibilityService.select(mode); applyDesktopVisibilityToLivePins()
    }
    func reloadDesktopVisibility() {
        guard !terminated else { return }
        let previousMode = desktopVisibility
        desktopVisibilityService.reload()
        if desktopVisibility != previousMode { groupTransforms.dismissEditor() }
        applyDesktopVisibilityToLivePins()
    }
    private func applyDesktopVisibilityToLivePins() {
        for controller in liveControllers.values { controller.applyDesktopVisibility(desktopVisibility) }
        for controller in richControllers.values { controller.applyDesktopVisibility(desktopVisibility) }
    }

    /// Only already-live image pins are updated; hidden groups remain unloaded.
    func setAutomaticOCR(_ enabled: Bool) {
        guard !terminated else { return }
        ocrPreferences.select(enabled)
        liveControllers.values.forEach { $0.applyAutomaticOCR(enabled) }
    }
    func reloadOCRPreferences() {
        guard !terminated else { return }
        ocrPreferences.reload()
        liveControllers.values.forEach { $0.applyAutomaticOCR(ocrPreferences.automaticallyRecognizeText) }
    }

    /// Call only at launch. A disabled preference and smoke mode are strict no-op paths.
    func restoreOnLaunch(enabled: Bool, isSmoke: Bool) throws {
        guard enabled, !isSmoke, !terminated else { return }
        try reconcileVisiblePins()
    }

    /// A new capture does not implicitly reopen old saved pins when launch restore is off.
    /// Explicit Show, Recover, or a group-manager action reopens the whole visible group.
    @discardableResult func add(image: CGImage, title: String = "贴图") throws -> UUID {
        try add(originalImage: image, currentImage: image, title: title)
    }

    /// Editor output keeps its undecorated source available for original-copy/save/reset.
    /// A shared image object is unmodified; distinct source/current images persist together.
    @discardableResult func add(originalImage: CGImage, currentImage: CGImage,
                               title: String = "贴图", editable: EditableCapturePayload? = nil) throws -> UUID {
        guard !terminated else { throw PinSessionError.missingPin }
        guard livePinCount < Self.maximumLivePins else { throw PinSessionError.capacityExceeded }
        if let editable { try editable.validate(currentImage: currentImage) }
        let controller = makeImageController(originalImage, currentImage, !(originalImage === currentImage))
        let entry: PinSessionEntry
        do {
            entry = try store.add(originalImage: originalImage, currentImage: currentImage,
                                  title: title, presentation: controller.presentation,
                                  protecting: livePinIDs, revealingGroup: true, editable: editable)
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
        let controller = try RichPinController(asset: prepared.asset, data: prepared.data, title: prepared.title, renderedImage: prepared.kind == .latex ? prepared.poster : nil)
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
        let controller = try RichPinController(asset: rich, data: store.richData(id: entry.id), title: entry.title, renderedImage: rich.kind == .latex ? store.image(id: entry.id) : nil)
        if let recovered = store.recoveredPresentation(id: entry.id, screens: screens()) { controller.applyPresentation(recovered) }
        connect(controller, id: entry.id); present(controller)
    }
    private func connect(_ controller: RichPinController, id: UUID) {
        controller.applyDesktopVisibility(desktopVisibility)
        controller.onDesktopVisibilityChange = { [weak self, weak controller] mode in
            guard let self, let controller, self.richControllers[id] === controller else { return }
            self.setDesktopVisibility(mode)
        }
        precondition(!livePinIDs.contains(id)); richControllers[id] = controller
        controller.onToggleGroupSelection = { [weak self] in self?.groupTransforms.toggleSelection(id: id) }
        controller.onShowGroupTransform = { [weak self] in self?.groupTransforms.showEditor() }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller, self.richControllers[id] === controller else { return }
            self.richControllers.removeValue(forKey: id); self.pendingPresentations.removeValue(forKey: id)
            self.groupTransforms.pinChanged(id: id)
            do {
                if self.store.visibleEntries.contains(where: { $0.id == id }) { try self.store.archive(id: id, presentation: controller.presentation) }
                else if self.store.entry(id: id) != nil { try self.store.updatePresentation(controller.presentation, id: id) }
            } catch { self.onError?(error) }
        }
        controller.onRichChange = { [weak self, weak controller] prepared in
            guard let self, let controller, self.richControllers[id] === controller, !self.terminated else { throw CancellationError() }
            try self.store.replaceRich(prepared, id: id, protecting: self.livePinIDs)
        }
        controller.onPresentationChange = { [weak self, weak controller] value in
            guard let self, let controller, self.richControllers[id] === controller, !self.terminated else { return }
            if self.store.entry(id: id)?.presentation == value { self.pendingPresentations.removeValue(forKey: id); return }
            self.groupTransforms.pinChanged(id: id)
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
        groupTransforms.reconcile()
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
        pendingPresentations = pendingPresentations.filter { livePinIDs.contains($0.key) && store.entry(id: $0.key) != nil }
        guard !pendingPresentations.isEmpty else { return }
        try store.updatePresentations(pendingPresentations)
        pendingPresentations.removeAll()
    }

    /// Termination preserves which pins were open, never archives or deletes them, even when a metadata write
    /// fails. Detach callbacks before asking AppKit to close its windows.
    func prepareForTermination() throws {
        guard !terminated else { return }
        groupTransforms.reset()
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
        let controller = makeImageController(original, current, modified)
        if let recovered = store.recoveredPresentation(id: entry.id, screens: screens()) {
            controller.applyPresentation(recovered)
        }
        connect(controller, id: entry.id)
        present(controller)
    }
    private func editableAdmissionRemaining(workBytes: Int) throws -> Int {
        try PinEditableAdmission.remaining(limit: editableRasterByteLimit,
            retained: EditorAdmissionPolicy.sum(liveControllers.values.map(\.estimatedRetainedRasterBytes)),
            reportedProjection: EditorAdmissionPolicy.sum(liveControllers.values.map(\.estimatedOutputProjectionReservationBytes)),
            globalProjection: EditorOutputProjection.shared.reservedBytes, work: workBytes)
    }
    private func connect(_ controller: PinController, id: UUID) {
        controller.configureEditableCapture(available: store.entry(id: id)?.editableCapture != nil,
            loadForWork: { [weak self, weak controller] work in
                guard let self, let controller, self.liveControllers[id] === controller, !self.terminated else { throw CancellationError() }
                guard let descriptor = self.store.entry(id: id)?.editableCapture else { return nil }
                let document = try PinEditableAdmission.document(descriptor, directory: self.store.directory)
                if PinEditableAdmission.requiresProjection(work, document: document), EditorOutputProjection.shared.isBusy {
                    throw EditorOutputProjectionError.busy
                }
                let extra = try PinEditableAdmission.workBytes(work, document: document,
                    baseWidth: descriptor.base.width, baseHeight: descriptor.base.height)
                let remaining = try self.editableAdmissionRemaining(workBytes: extra)
                let additionalDecode = descriptor.base.filename == descriptor.original.filename
                    ? 0 : descriptor.base.decodedRasterByteEstimate
                guard additionalDecode <= remaining else { throw PinSessionError.capacityExceeded }
                // Persistence also accounts for the supplied original, but it is
                // already owned by this live pin. Credit it only in that reader's
                // local budget, not in the aggregate live-pin calculation.
                let originalCredit = max(descriptor.original.decodedRasterByteEstimate,
                    EditorRasterEstimate.retainedBytes([controller.image]))
                return try self.store.editablePayload(id: id, reusingOriginal: controller.image,
                    maximumRasterBytes: EditorAdmissionPolicy.sum([remaining, originalCredit]))
            }, admission: { [weak self, weak controller] work, payload in
                guard let self, let controller, self.liveControllers[id] === controller, !self.terminated else { throw CancellationError() }
                let document = payload?.document, base = payload?.baseImage ?? controller.currentImage
                if PinEditableAdmission.requiresProjection(work, document: document), EditorOutputProjection.shared.isBusy {
                    throw EditorOutputProjectionError.busy
                }
                let additional = PinEditableAdmission.additionalImages(payload.map { [$0.originalImage, $0.baseImage] } ?? [],
                    alreadyOwned: self.liveControllers.values.flatMap(\.retainedRasterImagesForAdmission))
                let extra = try PinEditableAdmission.workBytes(work, document: document,
                    baseWidth: base.width, baseHeight: base.height)
                _ = try self.editableAdmissionRemaining(workBytes: EditorAdmissionPolicy.sum([additional, extra]))
            })
        controller.onEditablePixelChange = { [weak self, weak controller] image, editable in
            guard let self, let controller, self.liveControllers[id] === controller, !self.terminated else { throw CancellationError() }
            try self.store.replaceImage(image, id: id, protecting: self.livePinIDs, editable: editable)
        }
        controller.applyAutomaticOCR(ocrPreferences.automaticallyRecognizeText)
        controller.onAutomaticOCRChange = { [weak self, weak controller] enabled in
            guard let self, let controller, self.liveControllers[id] === controller else { return }
            self.setAutomaticOCR(enabled)
        }
        controller.applyDesktopVisibility(desktopVisibility)
        controller.onDesktopVisibilityChange = { [weak self, weak controller] mode in
            guard let self, let controller, self.liveControllers[id] === controller else { return }
            self.setDesktopVisibility(mode)
        }
        precondition(liveControllers[id] == nil)
        liveControllers[id] = controller
        controller.onToggleGroupSelection = { [weak self] in self?.groupTransforms.toggleSelection(id: id) }
        controller.onShowGroupTransform = { [weak self] in self?.groupTransforms.showEditor() }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller, self.liveControllers[id] === controller else { return }
            self.liveControllers.removeValue(forKey: id)
            self.groupTransforms.pinChanged(id: id)
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
            guard let self, let controller, self.liveControllers[id] === controller, !self.terminated else { throw CancellationError() }
            if isOriginal { try self.store.resetImage(id: id) }
            else { try self.store.replaceImage(image, id: id, protecting: self.livePinIDs) }
        }
        controller.onPresentationChange = { [weak self, weak controller] presentation in
            guard let self, let controller, self.liveControllers[id] === controller, !self.terminated else { return }
            if self.store.entry(id: id)?.presentation == presentation { self.pendingPresentations.removeValue(forKey: id); return }
            self.groupTransforms.pinChanged(id: id)
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
        groupTransforms.pinChanged(id: id)
        if let controller = richControllers[id] {
            defer {
                controller.onClose = nil; controller.onPresentationChange = nil; controller.onRichChange = nil
                richControllers.removeValue(forKey: id); pendingPresentations.removeValue(forKey: id); controller.close()
            }
            if store.entry(id: id) != nil { try store.updatePresentation(controller.presentation, id: id) }
            return
        }
        guard let controller = liveControllers[id] else { return }
        defer {
            // Removing onClose preserves open state on hide/switch instead of archiving.
            controller.onClose = nil; controller.onPixelChange = nil; controller.onEditablePixelChange = nil; controller.onPresentationChange = nil
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
