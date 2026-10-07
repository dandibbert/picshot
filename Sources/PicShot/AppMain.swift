import AppKit
import SwiftUI
import PicShotCore
import PicShotFormulaRenderCore
import ScreenCaptureKit
import Darwin
import ImageIO

@main struct PicShotMain {
    @MainActor static func main(){if GIFHelperMain.runIfRequested(){return};if RecordingRecoveryFixture.runIfRequested(){return};let app=NSApplication.shared;let delegate=AppDelegate();app.delegate=delegate;app.setActivationPolicy(AppLaunchPresentation.usesMenuBarOnly(isSmoke:delegate.smoke != nil) ? .accessory:.regular);app.run();withExtendedLifetime(delegate){}}
}

@MainActor final class AppDelegate:NSObject,NSApplicationDelegate {
    let history:HistoryStore
    let capture=CaptureService()
    let advancedCapture=AdvancedCaptureController()
    let recorder=RecordingService()
    var mainWindow:NSWindow!
    var recordingController:RecordingPanelController?
    let recordingPreviews=RecordingPreviewWindowStore()
    var recordingRecovery:RecordingRecoveryCoordinator?
    private var isTerminating=false
    var status:NSStatusItem?
    var controllers:[NSWindowController]=[]
    // Transient fallback only: smoke runs and unavailable/corrupt session storage.
    private lazy var saveWorkflows: SaveWorkflowPresenter = {
        let workflow = SaveWorkflowPresenter(isSmoke: smoke != nil)
        workflow.onSettings = { [weak self] parent in self?.settings(); self?.settingsController?.selectCategory(.save); self?.settingsController?.showAbove(parent) }
        return workflow
    }()
    var pins:[PinController]=[]
    var pinSession:PinSessionCoordinator?
    var pinSessionLoadError:Error?
    weak var formulaPinEditor: FormulaRenderController?
    weak var pinGroupsController:PinGroupsController?
    weak var settingsController:SettingsController?
    var hotKeys:HotKeyService?
    var busy=false
    private var captureTask:Task<Void,Never>?
    private var activePresetOperation: UUID?
    private var capturePresetStore: CapturePresetStore?
    weak var capturePresetController: CapturePresetController?
    private var barcodeTask: Task<Void, Never>?
    private var barcodeGeneration = UUID()
    weak var barcodeResultController: BarcodeResultController?
    private let frozenEditorAdmission = FrozenEditorCaptureAdmission<ImageEditorController>()
    private let editorAdmission = EditorAdmissionPolicy()
    private var editorAdmissionNotices = EditorAdmissionNotices()
    let smoke=ProcessInfo.processInfo.environment["PICSHOT_SMOKE_REPORT"]
    override init(){
        if ProcessInfo.processInfo.environment["PICSHOT_SMOKE_REPORT"] != nil {history=HistoryStore(directory:FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Smoke-\(UUID().uuidString)"))} else {history=HistoryStore()}
        super.init()
        // Smoke must neither read nor write the user's saved session or preferences.
        if smoke == nil {
            do {pinSession=PinSessionCoordinator(store:try PinSessionStore());pinSession?.onError={showError($0)}}
            catch {pinSessionLoadError=error}
        }
    }
    func applicationDidFinishLaunching(_ notification:Notification){
        AppAppearancePreference.applySaved(isSmoke:smoke != nil)
        setupMenu();setupWindow()
        NotificationCenter.default.addObserver(self,selector:#selector(windowClosed(_:)),name:NSWindow.willCloseNotification,object:nil)
        if smoke == nil {
            SaveWorkflowPresenter.application = saveWorkflows
            setupStatus();hotKeys=HotKeyService()
            hotKeys?.onAction={ [weak self] action in
                switch action {
                case .capture:self?.startCapture(.region)
                case .clipboardPin:self?.pastePin()
                case .history:self?.showMain()
                case .restoreLastPin:self?.restoreLastClosedPin()
                }
            }
            refreshHotkeys()
        }
        if AppLaunchPresentation.showsHistory(isSmoke:smoke != nil) {showMain()}
        if smoke == nil {
            do {try pinSession?.restoreOnLaunch(enabled:PinSessionStore.restoreOnLaunch,isSmoke:false)}catch{showError(error)}
            if let pinSessionLoadError {showError(pinSessionLoadError)}
            setupRecordingRecovery()
            recordingRecovery?.presentPending()
        }
        if smoke != nil {DispatchQueue.main.asyncAfter(deadline:.now()+0.5){Task{await self.runSmoke()}}}
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {false}
    func applicationWillTerminate(_ notification:Notification){
        isTerminating=true
        if smoke == nil { saveWorkflows.cancelAll(); SaveWorkflowPresenter.application = nil }
        // Saving/cancelling is awaited by applicationShouldTerminate. Starting
        // an async cancel here would race process exit and could discard a take.
        if recorder.controlState.hasSessionActivity {
            NSLog("PicShot exited before recording cleanup completed.")
        }
        hotKeys?.invalidate();captureTask?.cancel();barcodeTask?.cancel()
        do{try pinSession?.prepareForTermination()}catch{NSLog("Could not save pin presentation before exit: %@",error.localizedDescription)}
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        let state=recorder.controlState
        guard state.terminationAction != .none else{isTerminating=true;return .terminateNow}
        let alert=NSAlert()
        alert.messageText=state.hasPendingTake ? "保护未保存的录屏并退出？" : (state.canCancelCountdown ? "取消录屏倒计时并退出？" : "保存录屏并退出？")
        alert.informativeText=state.hasPendingTake ? "这段录屏尚未安全保留。只有成功保护原始文件后才能退出；下次打开 PicShot 时可尝试恢复。保护失败时请保持 PicShot 打开。" : "尚未开始的倒计时会取消；正在录制或暂停的内容会先保存到电影/PicShot。已保存的原片不会删除。"
        alert.addButton(withTitle:state.hasPendingTake ? "重试保护并退出" : (state.canCancelCountdown ? "取消倒计时并退出" : "保存并退出"))
        alert.addButton(withTitle:"留在 PicShot")
        guard alert.runModal() == .alertFirstButtonReturn else{return .terminateCancel}
        Task {
            do {
                // Re-read after the modal: a countdown can finish, or an
                // automatic stop can save the movie while the alert is open.
                try await RecordingTerminationCoordinator.finish(
                    snapshot:{self.recorder.controlState},
                    cancelCountdown:{await self.recorder.cancel()},
                    save:{_ = try await self.recorder.stop()},
                    preserve:{try await self.recorder.retryPendingTakePreservation(presentRecovery:false)})
                self.isTerminating=true
                sender.reply(toApplicationShouldTerminate:true)
            } catch {
                showError(error)
                sender.reply(toApplicationShouldTerminate:false)
            }
        }
        return .terminateLater
    }
    func application(_ sender:NSApplication,openFile filename:String)->Bool{importURL(URL(fileURLWithPath:filename));return true}
    func application(_ sender:NSApplication,openFiles filenames:[String]) {
        importURLs(filenames.map { URL(fileURLWithPath:$0) });sender.reply(toOpenOrPrint:.success)
    }
    func setupMenu(){
        let menu=NSMenu();NSApp.mainMenu=menu
        let appItem=NSMenuItem();menu.addItem(appItem);let app=NSMenu();appItem.submenu=app
        app.addItem(withTitle:"关于 PicShot",action:#selector(about),keyEquivalent:"").target=self
        app.addItem(withTitle:"设置…",action:#selector(settings),keyEquivalent:",").target=self;app.addItem(.separator());app.addItem(withTitle:"退出 PicShot",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let captureItem=NSMenuItem();menu.addItem(captureItem);let captureMenu=NSMenu(title:"截图");captureItem.submenu=captureMenu
        for (title,action) in [("区域截图",#selector(region)),("界面元素截图…",#selector(elementCapture)),("跨屏区域截图（系统选区）",#selector(systemRegion)),("窗口截图",#selector(windowCapture)),("当前屏幕",#selector(full)),("所有屏幕合成",#selector(allScreens))] {captureMenu.addItem(withTitle:title,action:action,keyEquivalent:"").target=self}
        captureMenu.addItem(withTitle:"截图预设",action:nil,keyEquivalent:"").submenu=capturePresetsMenu()
        captureMenu.addItem(.separator());captureMenu.addItem(withTitle:"取消当前截图",action:#selector(cancelCapture),keyEquivalent:".").target=self
        let editItem=NSMenuItem();menu.addItem(editItem);let edit=NSMenu(title:"编辑");editItem.submenu=edit
        edit.addItem(withTitle:"撤销",action:Selector(("undo:")),keyEquivalent:"z");let redo=edit.addItem(withTitle:"重做",action:Selector(("redo:")),keyEquivalent:"Z");redo.keyEquivalentModifierMask=[.command,.shift]
        for (title,selector,key) in [("剪切","cut:","x"),("复制","copy:","c"),("粘贴","paste:","v"),("全选","selectAll:","a")] {edit.addItem(withTitle:title,action:Selector(selector),keyEquivalent:key)}
        let windowItem=NSMenuItem();menu.addItem(windowItem);let wm=NSMenu(title:"窗口");windowItem.submenu=wm;NSApp.windowsMenu=wm
        wm.addItem(withTitle:"恢复未完成的录屏…",action:#selector(recoverRecordings),keyEquivalent:"").target=self
        wm.addItem(withTitle:"历史记录",action:#selector(showMain),keyEquivalent:"0").target=self;wm.addItem(withTitle:"贴图组与历史…",action:#selector(managePinGroups),keyEquivalent:"").target=self
        wm.addItem(withTitle:"文件或文件夹贴图…",action:#selector(importFilePin),keyEquivalent:"").target=self
        wm.addItem(withTitle:"动态 GIF / WebP 贴图…",action:#selector(importAnimationPin),keyEquivalent:"").target=self
        wm.addItem(withTitle:"LaTeX 公式贴图…",action:#selector(createFormulaPin),keyEquivalent:"").target=self
        wm.addItem(withTitle:"颜色贴图…",action:#selector(createColorPin),keyEquivalent:"").target=self
        wm.addItem(withTitle:"显示当前贴图组",action:#selector(showPins),keyEquivalent:"").target=self
        wm.addItem(withTitle:"恢复当前贴图组",action:#selector(restorePins),keyEquivalent:"").target=self
        wm.addItem(withTitle:"隐藏当前贴图组",action:#selector(hideCurrentPins),keyEquivalent:"").target=self
        wm.addItem(withTitle:"隐藏所有贴图",action:#selector(hidePins),keyEquivalent:"").target=self
    }
    func setupStatus(){
        status=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        status?.button?.image=NSImage(systemSymbolName:"viewfinder",accessibilityDescription:"PicShot")
        status?.button?.toolTip="PicShot · 截图与贴图"
        let menu=NSMenu();menu.delegate=self;status?.menu=menu;rebuildStatusMenu(menu)
    }
    func setupWindow(){
        mainWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:850,height:560),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false);mainWindow.title="PicShot · 历史记录";mainWindow.isReleasedWhenClosed=false;mainWindow.minSize=NSSize(width:680,height:430);mainWindow.center();mainWindow.contentView=NSHostingView(rootView:LibraryView(store:history,app:self))
    }
    @objc func showMain(){mainWindow.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    @objc func region(){startCapture(.region)}
    @objc func systemRegion(){
        let options=ScreenshotPreferences.options
        runCapture { [capture] in try await capture.capture(mode:.region,options:options) }
    }
    @objc func windowCapture(){startCapture(.window)}
    @objc func full(){startCapture(.fullScreen)}
    @objc func allScreens(){startCapture(.allScreens)}
    @objc func cancelCapture(){captureTask?.cancel()}
    func startCapture(_ mode:CaptureMode){
        let options=ScreenshotPreferences.options
        runCaptureForEditing { [capture] in try await capture.captureForEditing(mode:mode,options:options) }
    }
    func startDisplayCapture(_ id:CGDirectDisplayID){
        let options=ScreenshotPreferences.options
        runCapture { [capture] in try await capture.captureDisplay(displayID:id,options:options) }
    }
    func startAdvanced(_ style:AdvancedSelectionStyle){
        runCapture(title:"高级选区") { [advancedCapture] in try await advancedCapture.capture(style:style) }
    }
    private func runCapture(title:String="截图",operation:@escaping @MainActor () async throws -> CGImage){
        runCaptureForEditing(title:title) { CapturedImage(image:try await operation(),presentation:nil) }
    }
    private func runCaptureForEditing(title:String="截图",presetOperation:UUID?=nil,operation:@escaping @MainActor () async throws -> CapturedImage){
        // This check must precede window hiding, delays, and every capture API.
        guard frozenEditorAdmission.shouldStart(isBusy:busy || captureTask != nil,
            isClosed:{$0.isClosed},focus:{self.focusEditor($0)}) else{return}
        busy=true;activePresetOperation=presetOperation;mainWindow.orderOut(nil)
        captureTask=Task { [weak self] in
            guard let self else{return}
            defer{self.busy=false;self.captureTask=nil;self.activePresetOperation=nil}
            do{
                try await Task.sleep(nanoseconds:180_000_000)
                let result=try await operation()
                try Task.checkCancellation()
                try self.history.add(result.image,title:title,capturedAt:result.presentation?.capturedAt);self.openEditor(result.image,presentation:result.presentation)
            }catch CaptureError.cancelled{}catch is CancellationError{}catch{self.showMain();showError(error)}
        }
    }
    @objc func elementCapture() {
        let options = ScreenshotPreferences.options
        runCaptureForEditing { [capture] in
            try await capture.captureForEditing(mode: .region, options: options, elementSelection: true)
        }
    }
    private func presetCatalog() throws -> CapturePresetStore {
        if let capturePresetStore { return capturePresetStore }
        let store = try CapturePresetStore(); capturePresetStore = store; return store
    }
    func capturePresetsMenu() -> NSMenu {
        let menu = NSMenu(title: "截图预设"); menu.delegate = self
        populateCapturePresetsMenu(menu); return menu
    }
    func populateCapturePresetsMenu(_ menu: NSMenu) {
        menu.removeAllItems(); menu.autoenablesItems = false
        menu.addItem(withTitle: "管理截图预设…", action: #selector(manageCapturePresets), keyEquivalent: "").target = self
        guard smoke == nil else { return }
        do {
            let presets = try presetCatalog().presets
            if !presets.isEmpty { menu.addItem(.separator()) }
            for preset in presets {
                let item = menu.addItem(withTitle: "\(preset.name) · \(preset.delay.rawValue) 秒",
                    action: #selector(invokeCapturePresetItem(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = preset.id.uuidString; item.isEnabled = !busy
            }
        } catch {
            let item = menu.addItem(withTitle: "预设暂不可用，请打开管理查看", action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
    }
    @objc func manageCapturePresets() {
        if let capturePresetController {
            capturePresetController.showWindow(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        do {
            let manager = CapturePresetController(store: try presetCatalog())
            manager.onCreate = { [weak self, weak manager] name, delay in
                self?.createCapturePreset(name: name, delay: delay, manager: manager)
            }
            manager.onInvoke = { [weak self] preset in self?.invokeCapturePreset(preset) }
            manager.onCancel = { [weak self] in
                guard self?.activePresetOperation != nil else { return }; self?.captureTask?.cancel()
            }
            capturePresetController = manager; retain(manager); manager.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch { showError(error) }
    }
    private func createCapturePreset(name: String, delay: ScreenshotDelay, manager: CapturePresetController?) {
        guard frozenEditorAdmission.shouldStart(isBusy: busy || captureTask != nil,
            isClosed: { $0.isClosed }, focus: { self.focusEditor($0) }) else {
            manager?.showError(PicShotError.message("请先完成当前截图或编辑，再创建预设。")); return
        }
        busy = true; activePresetOperation = UUID(); mainWindow.orderOut(nil)
        captureTask = Task { [weak self, weak manager] in
            guard let self else { return }
            defer { self.busy = false; self.captureTask = nil; self.activePresetOperation = nil }
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                let preset = try await self.capture.createPreset(name: name, delay: delay)
                try Task.checkCancellation(); try self.presetCatalog().add(preset)
                manager?.reload(); manager?.showWindow(nil)
            } catch CaptureError.cancelled { manager?.showWindow(nil) }
            catch is CancellationError { }
            catch { manager?.showError(error) }
        }
    }
    private func invokeCapturePreset(_ preset: CapturePreset) {
        let cursor = ScreenshotPreferences.options.showsCursor
        runCaptureForEditing(title: "预设 · " + preset.name, presetOperation: UUID()) { [capture] in
            try await capture.capturePreset(preset, showsCursor: cursor)
        }
    }
    @objc func invokeCapturePresetItem(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String, let id = UUID(uuidString: value) else { return }
        do { guard let preset = try presetCatalog().preset(id: id) else { return }; invokeCapturePreset(preset) }
        catch { showError(error) }
    }
    func recognizeBarcodes(_ image: CGImage) {
        barcodeTask?.cancel(); let generation = UUID(); barcodeGeneration = generation
        barcodeTask = Task { [weak self] in
            do {
                let document = try await RecognitionService.recognizeBarcodes(image)
                guard !Task.isCancelled, let self, !self.isTerminating, self.barcodeGeneration == generation else { return }
                self.barcodeTask = nil; self.presentBarcodeResults(image, document: document)
            } catch is CancellationError { }
            catch {
                guard let self, !self.isTerminating, self.barcodeGeneration == generation else { return }
                self.barcodeTask = nil; showError(error)
            }
        }
    }
    func showBarcodeResults(_ image: CGImage, document: RecognizedBarcodeDocument) {
        barcodeTask?.cancel(); barcodeTask = nil; barcodeGeneration = UUID()
        presentBarcodeResults(image, document: document)
    }
    private func presentBarcodeResults(_ image: CGImage, document: RecognizedBarcodeDocument) {
        barcodeResultController?.close()
        let controller = BarcodeResultController(image: image, document: document)
        barcodeResultController = controller
        controller.onClose = { [weak self, weak controller] in
            if self?.barcodeResultController === controller { self?.barcodeResultController = nil }
        }
        retain(controller); controller.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func exportRecord(_ record: CaptureRecord) {
        guard let image = history.image(for: record), let window = mainWindow else { return }
        ImageExportController.present(image: image, from: window, suggestedName: "PicShot-history",
                                      sourceURL: history.url(for: record), saveWorkflow: smoke == nil ? saveWorkflows : nil)
    }
    func smartErase(_ image:CGImage){
        let c=SmartEraseController(image:image){[weak self] result in
            guard let self else{return false}
            do{
                try self.history.add(result,title:"智能消除")
                self.openEditor(result);return true
            }catch{showError(error);return false}
        };retain(c);c.showWindow(nil)
    }
    func recognizeFormula(_ image:CGImage){
        let c=FormulaRecognitionController(image:image,onPin:{ [weak self] request,result in
            guard let self else {throw CancellationError()}
            try self.pinRich(PreparedRichPin(formula:request,result:result))
        });retain(c);c.showWindow(nil)
    }
    func recognizeTable(_ image:CGImage){let c=TableRecognitionController(image:image){[weak self] table,warnings in guard let self else{return};let editor=TableEditorController(table:table,sourceImage:image);self.retain(editor);editor.showWindow(nil);if !warnings.isEmpty{let alert=NSAlert();alert.messageText="请核对表格识别结果";alert.informativeText=warnings.joined(separator:"\n");alert.runModal()}};retain(c);c.showWindow(nil)}
    func openEditor(_ image:CGImage,presentation:FrozenCapturePresentation?=nil,captureDate:Date?=nil){
        if presentation != nil, !frozenEditorAdmission.shouldStart(isBusy:false,
            isClosed:{$0.isClosed},focus:{self.focusEditor($0)}) { return }
        let editors=controllers.compactMap{$0 as? ImageEditorController}.filter{!$0.isClosed}
        guard editorAdmission.refusal(existingRasterBytes:editors.map(\.estimatedAdmissionRasterBytes),
            incomingRasterBytes:EditorRasterEstimate.openingBytes(image:image,presentation:presentation)) == nil else {
            if editorAdmissionNotices.recordRefusal(){showEditorAdmissionNotice()};return
        }
        let knownCaptureDate=presentation?.capturedAt ?? captureDate
        let c=ImageEditorController(image:image,presentation:presentation,onSave:{[weak self] img in do{try self?.history.add(img,title:"编辑",capturedAt:knownCaptureDate)}catch{showError(error)}},onPin:{[weak self] img in self?.pin(img)},onOCR:{[weak self] img in self?.recognize(img)},onTranslate:{[weak self] img in self?.translateImage(img)},captureDate:knownCaptureDate,saveWorkflow:smoke == nil ? saveWorkflows : nil)
        c.onClose={ [weak self,weak c] in
            guard let self,let c else{return}
            self.frozenEditorAdmission.editorDidClose(c)
            self.controllers.removeAll{$0 === c}
        }
        if presentation != nil {frozenEditorAdmission.register(c)}
        retain(c);focusEditor(c)
    }
    private func focusEditor(_ editor:ImageEditorController){
        editor.showWindow(nil);editor.window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    private func showEditorAdmissionNotice(importedCount:Int=0){
        let alert=NSAlert();alert.messageText="图片编辑窗口已达到资源保护上限"
        let saved=importedCount > 0 ? "\(importedCount) 张图片已保存到历史记录，暂未打开编辑窗口。\n" : "已保存到历史记录的图片仍可稍后打开。\n"
        alert.informativeText=saved+"最多同时打开 6 个编辑窗口，估算的保留图像预算为 768 MiB（不是总进程内存上限）。请先保存并关闭不再需要的编辑窗口，再从历史记录打开图片。"
        alert.addButton(withTitle:"知道了");alert.runModal()
    }
    func translateImage(_ image:CGImage){
        guard #available(macOS 15.0,*) else{translate("");return}
        Task{do{
            let result=try await RecognitionService.recognize(image)
            guard result.document?.isTruncated != true else{throw PicShotError.message("图片文字超过本机识别上限，暂未翻译。请先裁剪图片再试，以免遗漏内容。") }
            guard !result.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw PicShotError.message("未识别到可翻译的文字，请尝试更清晰的图片。")}
            translate(result.text)
        }catch{showError(error)}}
    }
    func retain(_ controller:NSWindowController){controllers.append(controller)}
    @objc func windowClosed(_ n:Notification){guard let w=n.object as? NSWindow else{return};let closedSettings=settingsController?.window === w;controllers.removeAll{$0.window === w};pins.removeAll{$0.window === w};if closedSettings{settingsController=nil;refreshHotkeys()}}
    func pin(_ image:CGImage){
        if let pinSession {do{try pinSession.add(image:image)}catch{showError(error)};return}
        let bytes=pins.reduce(0){$0+$1.image.bytesPerRow*$1.image.height}
        guard pins.count<20,bytes+image.bytesPerRow*image.height<400_000_000 else{showError(PicShotError.message("贴图已达到内存保护上限，请关闭一些贴图后重试"));return}
        let c=PinController(image:image);pins.append(c);c.showWindow(nil)
    }
    @objc func showPins(){
        do{try pinSession?.showCurrentGroup()}catch{showError(error)}
        pins.forEach{$0.showWindow(nil)}
    }
    @objc func restorePins(){
        do{try pinSession?.recoverCurrentGroup()}catch{showError(error)}
        pins.forEach{$0.restore()}
    }
    @objc func hideCurrentPins(){
        do{try pinSession?.hideCurrentGroup()}catch{showError(error)}
        pins.forEach{$0.hideTemporarily()}
    }
    @objc func hidePins(){
        do{try pinSession?.hideAll()}catch{showError(error)}
        pins.forEach{$0.hideTemporarily()}
    }
    @objc func managePinGroups(){
        guard let pinSession else{if let pinSessionLoadError{showError(pinSessionLoadError)};return}
        if let pinGroupsController{pinGroupsController.showWindow(nil);NSApp.activate(ignoringOtherApps:true);return}
        let controller=PinGroupsController(store:pinSession.store, transforms:pinSession.groupTransforms)
        controller.onSessionChange={ [weak pinSession] in do{try pinSession?.reconcileVisiblePins()}catch{showError(error)}}
        controller.onOpenPin={ [weak pinSession] id in do{try pinSession?.openPin(id:id)}catch{showError(error)}}
        pinGroupsController=controller;retain(controller);controller.showWindow(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func pinRich(_ prepared: PreparedRichPin) throws {
        guard let pinSession else { throw RichPinError.unavailableSession }
        try pinSession.add(rich: prepared)
    }
    @objc func createFormulaPin() {
        guard pinSession != nil else { showError(RichPinError.unavailableSession); return }
        if let formulaPinEditor { formulaPinEditor.showWindow(nil); formulaPinEditor.window?.makeKeyAndOrderFront(nil); return }
        // Explicit formula action only: ordinary clipboard text keeps its existing text-pin behavior.
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        let seed = clipboard.utf8.count <= FormulaRenderLimits.latexBytes && !clipboard.contains("\0") ? clipboard : ""
        let editor = FormulaRenderController(latex: seed, onPin: { [weak self] request, result in
            guard let self else { throw CancellationError() }
            try self.pinRich(PreparedRichPin(formula: request, result: result))
        })
        formulaPinEditor = editor; retain(editor); editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
    }
    @objc func pastePin(){
        let pasteboard = NSPasteboard.general
        do {
            // File references win over Finder's image thumbnail or text representations.
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                try pinRich(RichPinImport.files(urls)); return
            }
            for type in [NSPasteboard.PasteboardType("com.compuserve.gif"), NSPasteboard.PasteboardType("org.webmproject.webp")] {
                if let data = pasteboard.data(forType: type) {
                    switch try RichPinClipboardImage.prepare(data) {
                    case .still(let image): pin(image)
                    case .animated(let prepared): try pinRich(prepared)
                    }
                    return
                }
            }
            if let html = pasteboard.string(forType: .html), let text = RichPinClipboardRouting.preferredHTMLText(html) {
                try pinRich(PreparedRichPin(document: PinRichDocument(text: text), title: "HTML 文字贴图")); return
            }
            if let objects = pasteboard.readObjects(forClasses: [NSImage.self], options: nil), let image = objects.first as? NSImage,
               let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { pin(cg); return }
            if let text = pasteboard.string(forType: .string) {
                if let color = PinRGBColor.parse(text) { try pinRich(PreparedRichPin(document: PinRichDocument(color: color), title: color.hex)) }
                else { try pinRich(PreparedRichPin(document: PinRichDocument(text: PinTextContent(text: text)), title: "文字贴图")) }
                return
            }
            throw PicShotError.message("剪贴板中没有支持的图片、文字、HTML、颜色或本机文件引用")
        } catch { showError(error) }
    }
    @objc func importFilePin() {
        let panel = NSOpenPanel(); panel.title = "添加文件或文件夹引用"; panel.canChooseFiles = true
        panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { do { try pinRich(RichPinImport.files(panel.urls)) } catch { showError(error) } }
    }
    @objc func importAnimationPin() {
        let panel = NSOpenPanel(); panel.title = "动态 GIF / WebP 贴图"; panel.allowedContentTypes = [.gif, .webP]
        if panel.runModal() == .OK, let url = panel.url { do { try pinRich(RichPinImport.animationFile(url)) } catch { showError(error) } }
    }
    @objc func createColorPin() {
        let alert = NSAlert(); alert.messageText = "颜色贴图"; alert.informativeText = "输入 HEX（#RGB / #RRGGBB / #RRGGBBAA）或 rgb(255, 0, 0) / rgba(255, 0, 0, 0.5)"
        let field = NSTextField(string: "#4A90E2"); field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "创建贴图"); alert.addButton(withTitle: "取消"); alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let color = PinRGBColor.parse(field.stringValue) else { showError(PicShotError.message("无法识别颜色值，请使用有效的 HEX 或 RGB / RGBA 格式")); return }
        do { try pinRich(PreparedRichPin(document: PinRichDocument(color: color), title: color.hex)) } catch { showError(error) }
    }
    func recognize(_ image:CGImage,recordID:UUID?=nil){
        Task { [weak self] in
            guard let self else{return}
            do {
                let result=try await RecognitionService.recognize(image)
                if let id=recordID{try self.history.updateText(result.document?.isTruncated == true ? result.displayText : result.text,id:id)}
                let text=result.displayText
                if TextResultController.copyDirectlyNextTime && !text.isEmpty {
                    TextResultController.copyToPasteboard(text);return
                }
                let barcodeAction: (() -> Void)? = result.barcodeDocument.map { document in
                    { [weak self] in self?.showBarcodeResults(image, document: document) }
                }
                let controller=TextResultController(text:text,sourceImage:image,onTranslate:{[weak self] text in self?.translate(text)},onBarcodes:barcodeAction)
                self.retain(controller);controller.showWindow(nil);NSApp.activate(ignoringOtherApps:true)
            }catch{showError(error)}
        }
    }
    func translate(_ text:String){if #available(macOS 15.0,*){let c=LocalTranslationController(text:text);retain(c);c.showWindow(nil)}else{showError(PicShotError.message("本机翻译需要 macOS 15 或更新版本；当前系统可正常截图和识别文字。"))}}
    func openRecord(_ r:CaptureRecord){if let image=history.image(for:r){openEditor(image,captureDate:r.capturedAt)}}
    @objc func importImage(){let p=NSOpenPanel();p.allowedContentTypes=[.image];p.allowsMultipleSelection=true;if p.runModal() == .OK{importURLs(p.urls)}}
    private func importURLs(_ urls:[URL]){
        editorAdmissionNotices.beginBatch()
        defer{let refused=editorAdmissionNotices.endBatch();if refused > 0{showEditorAdmissionNotice(importedCount:refused)}}
        urls.forEach{importURL($0)}
    }
    func importURL(_ url:URL){
        if ["gif", "webp"].contains(url.pathExtension.lowercased()) {
            do {
                let data = try RichPinImport.boundedAnimationData(at: url)
                switch try RichPinClipboardImage.prepare(data) {
                case .animated(let prepared): try pinRich(prepared)
                case .still(let image):
                    try history.add(image,title:url.deletingPathExtension().lastPathComponent);openEditor(image)
                }
                return
            } catch { showError(error); return }
        }
        if let image=CGImage.read(url:url){do{try history.add(image,title:url.deletingPathExtension().lastPathComponent);openEditor(image)}catch{showError(error)}}else{showError(PicShotError.message("无法读取图片。支持 PNG、JPEG、GIF、TIFF 等系统可解码格式；动态 GIF / WebP 会作为动态贴图打开"))}
    }
    @objc func scroll(){guard frozenEditorAdmission.shouldStart(isBusy:busy || captureTask != nil,isClosed:{$0.isClosed},focus:{self.focusEditor($0)}) else{return};let c=ScrollCaptureController{[weak self] image in do{try self?.history.add(image,title:"长截图");self?.openEditor(image)}catch{showError(error)}};retain(c);c.showWindow(nil)}
    private func setupRecordingRecovery() {
        guard smoke == nil else{return}
        recorder.onPendingTakePreserved={ [weak self] in self?.recoverRecordings() }
        guard recordingRecovery == nil else{return}
        do {
            let recovery=try RecordingRecoveryCoordinator()
            recovery.onOpenPreview={ [weak self] url in self?.recordingPreviews.open(url:url) }
            recordingPreviews.onIntentionalClose={ [weak self] url in
                guard let self, !self.isTerminating else{return}
                self.recordingRecovery?.previewDidClose(url:url)
            }
            recordingRecovery=recovery
        } catch { showError(error) }
    }
    @objc func recoverRecordings() {
        setupRecordingRecovery();recordingRecovery?.presentPending(showIfEmpty:true)
        NSApp.activate(ignoringOtherApps:true)
    }
    @objc func record(){if recordingController == nil{recordingController=RecordingPanelController(service:recorder,capture:capture,previews:recordingPreviews)};recordingController?.showWindow(nil);NSApp.activate(ignoringOtherApps:true)}
    @objc func settings(){
        if let settingsController{settingsController.showWindow(nil);NSApp.activate(ignoringOtherApps:true);return}
        // Editing an existing global combination must not trigger capture behind Settings.
        let unavailable=hotKeys?.failures ?? []
        hotKeys?.register(HotKeyConfiguration(shortcuts:[]))
        let controller=SettingsController(onChange:{[weak self] in self?.pinSession?.reloadDesktopVisibility();do{try self?.history.prune()}catch{showError(error)}},unavailableShortcuts:unavailable,onManageCapturePresets:{[weak self] in self?.manageCapturePresets()})
        settingsController=controller;retain(controller);controller.showWindow(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func refreshHotkeys(){
        guard smoke == nil,settingsController == nil else{return}
        hotKeys?.register(HotKeyConfiguration.read())
        if let menu=status?.menu{rebuildStatusMenu(menu)}
        if let failures=hotKeys?.failures,!failures.isEmpty{NSLog("Some shortcuts are unavailable: %@",failures.map(\.title).joined(separator:", "))}
    }
    @objc func about(){let a=NSAlert();a.messageText="PicShot " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版");a.informativeText="原生截图、标注与贴图工具\n图片与文字识别在本机处理\n\n当前为开发预览版。完整 PixPin 功能对照见仓库 docs/PARITY.md。\nmacOS 14+ · 未经 Apple 公证";a.runModal()}
}

struct LibraryView:View {
    @ObservedObject var store:HistoryStore
    unowned let app:AppDelegate
    var body:some View {
        VStack(spacing:0){
            HStack(spacing:8){
                Button {app.region()} label:{Label("截图",systemImage:"viewfinder")}.keyboardShortcut("n").buttonStyle(.borderedProminent)
                Menu {Button("多选区域（可减选）"){app.startAdvanced(.multiRegion)};Button("多边形选区"){app.startAdvanced(.polygon)};Button("自由形状选区"){app.startAdvanced(.freehand)};Divider();Button("跨屏区域截图（系统选区）"){app.systemRegion()};Button("窗口截图"){app.windowCapture()};Button("当前屏幕"){app.full()};Button("所有屏幕合成"){app.allScreens()};Button("取消当前截图"){app.cancelCapture()};ForEach(Array(NSScreen.screens.enumerated()),id:\.offset){ index,screen in Button("屏幕 \(index+1) · \(screen.localizedName)"){if let id=screen.displayID{app.startDisplayCapture(id)}}}} label:{Image(systemName:"chevron.down")}.frame(width:30)
                Button {app.scroll()} label:{Label("长截图",systemImage:"rectangle.expand.vertical")}
                Button {app.record()} label:{Label("录屏",systemImage:"record.circle")}
                Divider().frame(height:20)
                Button {app.importImage()} label:{Image(systemName:"square.and.arrow.down")}.help("导入图片")
                Button {app.pastePin()} label:{Image(systemName:"pin")}.help("剪贴板贴图")
                Spacer()
                Button {app.settings()} label:{Image(systemName:"gearshape")}.help("设置")
            }.controlSize(.large).padding(14)
            Divider()
            HStack {Image(systemName:"clock").foregroundStyle(.secondary);Text("历史记录").fontWeight(.medium);Text("\(store.records.count)").foregroundStyle(.secondary);Spacer();Image(systemName:"magnifyingglass").foregroundStyle(.secondary);TextField("搜索名称或已识别文字",text:$store.query).textFieldStyle(.roundedBorder).frame(width:230)}.padding(.horizontal,18).padding(.vertical,12)
            if store.filtered.isEmpty {
                VStack(spacing:12){Image(systemName:"viewfinder").font(.system(size:42,weight:.ultraLight)).foregroundStyle(.secondary);Text(store.query.isEmpty ? "截取一点，留下重点" : "没有匹配的截图").font(.title3);Text("\((app.smoke == nil ? HotKeyConfiguration.read() : .defaults)[.capture]?.displayName ?? "菜单栏") 区域截图 · Esc 取消\n截图后标注、复制或贴在屏幕上").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)}.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ScrollView {LazyVGrid(columns:[GridItem(.adaptive(minimum:170,maximum:250),spacing:14)],spacing:14){ForEach(store.filtered){record in
                    VStack(alignment:.leading,spacing:6){
                        ZStack {RoundedRectangle(cornerRadius:8).fill(Color(nsColor:.controlBackgroundColor));if let thumb=store.thumbnail(for:record){Image(nsImage:thumb).resizable().scaledToFit().padding(6)}}.frame(height:116).onTapGesture(count:2){app.openRecord(record)}
                        HStack{Text(record.title).lineLimit(1).font(.system(size:12));Spacer();if record.starred{Image(systemName:"star.fill").foregroundStyle(.yellow)}}
                        Text("\(record.width) × \(record.height) · \(record.createdAt.formatted(date:.abbreviated,time:.shortened))").font(.system(size:10)).foregroundStyle(.secondary)
                    }.contextMenu{Button("编辑"){app.openRecord(record)};Button("导出新副本…"){app.exportRecord(record)};Button("识别二维码 / 条码"){if let i=store.image(for:record){app.recognizeBarcodes(i)}};Button("贴图"){if let i=store.image(for:record){app.pin(i)}};Button("复制"){if let i=store.image(for:record){copyImage(i)}};Button("识别文字与条码"){if let i=store.image(for:record){app.recognize(i,recordID:record.id)}};Button("智能消除（可选本机模型）"){if let i=store.image(for:record){app.smartErase(i)}};Button("识别公式（可选本机模型）"){if let i=store.image(for:record){app.recognizeFormula(i)}};Button("识别表格（可选本机模型）"){if let i=store.image(for:record){app.recognizeTable(i)}};Button(record.starred ? "取消收藏" : "收藏"){try? store.toggleStar(record)};Divider();Button("移到废纸篓"){do{try store.remove(record)}catch{showError(error)}}}
                }}.padding(.horizontal,18).padding(.bottom,18)}
            }
            Divider();HStack{Image(systemName:"lock.shield");Text("本机处理 · 历史上限 \(store.policy.maxDays) 天 / \(store.policy.maxItems) 张 / \(store.policy.maxBytes / 1_048_576) MB");Spacer();Text("双击编辑")}.font(.system(size:10)).foregroundStyle(.secondary).padding(.horizontal,16).padding(.vertical,8)
        }.frame(minWidth:660,minHeight:400)
    }
}
