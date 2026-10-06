import AppKit
import SwiftUI
import PicShotCore
import ScreenCaptureKit
import Darwin

@main struct PicShotMain {
    @MainActor static func main(){let app=NSApplication.shared;let delegate=AppDelegate();app.delegate=delegate;app.setActivationPolicy(.regular);app.run();withExtendedLifetime(delegate){}}
}

@MainActor final class AppDelegate:NSObject,NSApplicationDelegate {
    let history:HistoryStore
    let capture=CaptureService()
    let advancedCapture=AdvancedCaptureController()
    let recorder=RecordingService()
    var mainWindow:NSWindow!
    var recordingController:RecordingPanelController?
    var status:NSStatusItem?
    var controllers:[NSWindowController]=[]
    var pins:[PinController]=[]
    var hotKeys:HotKeyService?
    var busy=false
    let smoke=ProcessInfo.processInfo.environment["PICSHOT_SMOKE_REPORT"]
    override init(){
        if ProcessInfo.processInfo.environment["PICSHOT_SMOKE_REPORT"] != nil {history=HistoryStore(directory:FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-Smoke-\(UUID().uuidString)"))} else {history=HistoryStore()}
        super.init()
    }
    func applicationDidFinishLaunching(_ notification:Notification){
        setupMenu();setupWindow()
        NotificationCenter.default.addObserver(self,selector:#selector(windowClosed(_:)),name:NSWindow.willCloseNotification,object:nil)
        if smoke == nil {setupStatus();hotKeys=HotKeyService();hotKeys?.onAction={ [weak self] action in switch action {case 0:self?.startCapture(.region);case 1:self?.pastePin();default:self?.showMain()}};refreshHotkeys()}
        showMain()
        if smoke != nil {DispatchQueue.main.asyncAfter(deadline:.now()+0.5){Task{await self.runSmoke()}}}
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {false}
    func applicationWillTerminate(_ notification:Notification){hotKeys?.invalidate()}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        guard recorder.isRecording || recorder.isStopping else{return .terminateNow}
        let alert=NSAlert();alert.messageText="停止录屏并退出？";alert.informativeText="录屏会先保存到电影/PicShot，再退出。";alert.addButton(withTitle:"保存并退出");alert.addButton(withTitle:"继续录制")
        guard alert.runModal() == .alertFirstButtonReturn else{return .terminateCancel}
        Task {do{_ = try await recorder.stop();sender.reply(toApplicationShouldTerminate:true)}catch{showError(error);sender.reply(toApplicationShouldTerminate:false)}}
        return .terminateLater
    }
    func application(_ sender:NSApplication,openFile filename:String)->Bool{importURL(URL(fileURLWithPath:filename));return true}
    func setupMenu(){
        let menu=NSMenu();NSApp.mainMenu=menu
        let appItem=NSMenuItem();menu.addItem(appItem);let app=NSMenu();appItem.submenu=app
        app.addItem(withTitle:"关于 PicShot",action:#selector(about),keyEquivalent:"").target=self
        app.addItem(withTitle:"设置…",action:#selector(settings),keyEquivalent:",").target=self;app.addItem(.separator());app.addItem(withTitle:"退出 PicShot",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editItem=NSMenuItem();menu.addItem(editItem);let edit=NSMenu(title:"编辑");editItem.submenu=edit
        edit.addItem(withTitle:"撤销",action:Selector(("undo:")),keyEquivalent:"z");let redo=edit.addItem(withTitle:"重做",action:Selector(("redo:")),keyEquivalent:"Z");redo.keyEquivalentModifierMask=[.command,.shift]
        for (title,selector,key) in [("剪切","cut:","x"),("复制","copy:","c"),("粘贴","paste:","v"),("全选","selectAll:","a")] {edit.addItem(withTitle:title,action:Selector(selector),keyEquivalent:key)}
        let windowItem=NSMenuItem();menu.addItem(windowItem);let wm=NSMenu(title:"窗口");windowItem.submenu=wm;NSApp.windowsMenu=wm
        wm.addItem(withTitle:"历史记录",action:#selector(showMain),keyEquivalent:"0").target=self;wm.addItem(withTitle:"恢复所有贴图",action:#selector(restorePins),keyEquivalent:"").target=self
    }
    func setupStatus(){
        status=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength);status?.button?.image=NSImage(systemSymbolName:"viewfinder",accessibilityDescription:"PicShot")
        let m=NSMenu();for (t,s) in [("区域截图",#selector(region)),("窗口截图",#selector(windowCapture)),("全屏截图",#selector(full)),("滚动长截图…",#selector(scroll)),("录屏…",#selector(record)),("粘贴为贴图",#selector(pastePin)),("恢复所有贴图",#selector(restorePins)),("隐藏所有贴图",#selector(hidePins)),("历史记录",#selector(showMain)),("设置…",#selector(settings))]{m.addItem(withTitle:t,action:s,keyEquivalent:"").target=self};m.addItem(.separator());m.addItem(withTitle:"退出",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");status?.menu=m
    }
    func setupWindow(){
        mainWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:850,height:560),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false);mainWindow.title="PicShot";mainWindow.isReleasedWhenClosed=false;mainWindow.minSize=NSSize(width:680,height:430);mainWindow.center();mainWindow.contentView=NSHostingView(rootView:LibraryView(store:history,app:self))
    }
    @objc func showMain(){mainWindow.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    @objc func region(){startCapture(.region)}
    @objc func windowCapture(){startCapture(.window)}
    @objc func full(){startCapture(.fullScreen)}
    func startCapture(_ mode:CaptureMode){
        guard !busy else{return};busy=true;mainWindow.orderOut(nil)
        Task {defer{busy=false};do{try await Task.sleep(nanoseconds:180_000_000);let image=try await capture.capture(mode:mode);try history.add(image);openEditor(image)}catch CaptureError.cancelled{}catch is CancellationError{}catch{showMain();showError(error)}}
    }
    func startDisplayCapture(_ id:CGDirectDisplayID){guard !busy else{return};busy=true;mainWindow.orderOut(nil);Task{defer{busy=false};do{try await Task.sleep(nanoseconds:180_000_000);let img=try await capture.captureDisplay(displayID:id);try history.add(img);openEditor(img)}catch{showMain();showError(error)}}}
    func startAdvanced(_ style:AdvancedSelectionStyle){guard !busy else{return};busy=true;mainWindow.orderOut(nil);Task{defer{busy=false};do{try await Task.sleep(nanoseconds:180_000_000);let image=try await advancedCapture.capture(style:style);try history.add(image,title:"高级选区");openEditor(image)}catch CaptureError.cancelled{}catch is CancellationError{}catch{showMain();showError(error)}}}
    func smartErase(_ image:CGImage){let c=SmartEraseController(image:image){[weak self] result in self?.openEditor(result)};retain(c);c.showWindow(nil)}
    func recognizeFormula(_ image:CGImage){let c=FormulaRecognitionController(image:image);retain(c);c.showWindow(nil)}
    func recognizeTable(_ image:CGImage){let c=TableRecognitionController(image:image){[weak self] table,warnings in guard let self else{return};let editor=TableEditorController(table:table,sourceImage:image);self.retain(editor);editor.showWindow(nil);if !warnings.isEmpty{let alert=NSAlert();alert.messageText="请核对表格识别结果";alert.informativeText=warnings.joined(separator:"\n");alert.runModal()}};retain(c);c.showWindow(nil)}
    func openEditor(_ image:CGImage){
        let c=ImageEditorController(image:image,onSave:{[weak self] img in do{try self?.history.add(img,title:"编辑")}catch{showError(error)}},onPin:{[weak self] img in self?.pin(img)},onOCR:{[weak self] img in self?.recognize(img)});retain(c);c.showWindow(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func retain(_ controller:NSWindowController){controllers.append(controller)}
    @objc func windowClosed(_ n:Notification){guard let w=n.object as? NSWindow else{return};controllers.removeAll{$0.window === w};pins.removeAll{$0.window === w}}
    func pin(_ image:CGImage){
        let bytes=pins.reduce(0){$0+$1.image.bytesPerRow*$1.image.height}
        guard pins.count<20,bytes+image.bytesPerRow*image.height<400_000_000 else{showError(PicShotError.message("贴图已达到内存保护上限，请关闭一些贴图后重试"));return}
        let c=PinController(image:image);pins.append(c);c.showWindow(nil)
    }
    @objc func restorePins(){pins.forEach{$0.restore()}}
    @objc func hidePins(){pins.forEach{$0.window?.orderOut(nil)}}
    @objc func pastePin(){
        if let objects=NSPasteboard.general.readObjects(forClasses:[NSImage.self],options:nil),let image=objects.first as? NSImage,let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil){pin(cg)}
        else if let text=NSPasteboard.general.string(forType:.string){let c=TextResultController(text:text,title:"文字贴图",onTranslate:{[weak self] text in self?.translate(text)});c.window?.level = .floating;retain(c);c.showWindow(nil)}
        else{showError(PicShotError.message("剪贴板中没有图片或文字"))}
    }
    func recognize(_ image:CGImage,recordID:UUID?=nil){
        Task{do{let result=try await RecognitionService.recognize(image);if let id=recordID{try history.updateText(result.text,id:id)};let text=result.text+(result.barcodes.isEmpty ? "" : "\n\n识别码：\n"+result.barcodes.joined(separator:"\n"));let c=TextResultController(text:text.isEmpty ? "未识别到文字或条码，请尝试更清晰的图片。" : text,onTranslate:{[weak self] text in self?.translate(text)});retain(c);c.showWindow(nil);NSApp.activate(ignoringOtherApps:true)}catch{showError(error)}}
    }
    func translate(_ text:String){if #available(macOS 15.0,*){let c=LocalTranslationController(text:text);retain(c);c.showWindow(nil)}else{showError(PicShotError.message("本机翻译需要 macOS 15 或更新版本；当前系统可正常截图和识别文字。"))}}
    func openRecord(_ r:CaptureRecord){if let image=history.image(for:r){openEditor(image)}}
    @objc func importImage(){let p=NSOpenPanel();p.allowedContentTypes=[.image];p.allowsMultipleSelection=true;if p.runModal() == .OK{p.urls.forEach{importURL($0)}}}
    func importURL(_ url:URL){
        if let image=CGImage.read(url:url){do{try history.add(image,title:url.deletingPathExtension().lastPathComponent);openEditor(image)}catch{showError(error)}}else{showError(PicShotError.message("无法读取图片。支持 PNG、JPEG、GIF、TIFF 等系统可解码格式；动态图片编辑当前首帧"))}
    }
    @objc func scroll(){let c=ScrollCaptureController{[weak self] image in do{try self?.history.add(image,title:"长截图");self?.openEditor(image)}catch{showError(error)}};retain(c);c.showWindow(nil)}
    @objc func record(){if recordingController == nil{recordingController=RecordingPanelController(service:recorder,capture:capture)};recordingController?.showWindow(nil);NSApp.activate(ignoringOtherApps:true)}
    @objc func settings(){let c=SettingsController(onChange:{[weak self] in self?.refreshHotkeys();do{try self?.history.prune()}catch{showError(error)}});retain(c);c.showWindow(nil)}
    func refreshHotkeys(){let bindings=(UserDefaults.standard.data(forKey:"hotkeys").flatMap{try? JSONDecoder().decode([HotKeyBinding].self,from:$0)}) ?? HotKeyBinding.defaults;hotKeys?.register(bindings);if let failures=hotKeys?.failures,!failures.isEmpty{NSLog("Some shortcuts are unavailable: %@",failures.description)}}
    @objc func about(){let a=NSAlert();a.messageText="PicShot " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版");a.informativeText="原生截图、标注与贴图工具\n图片与文字识别在本机处理\n\n当前为开发预览版。完整 PixPin 功能对照见仓库 docs/PARITY.md。\nmacOS 14+ · 未经 Apple 公证";a.runModal()}
}

struct LibraryView:View {
    @ObservedObject var store:HistoryStore
    unowned let app:AppDelegate
    var body:some View {
        VStack(spacing:0){
            HStack(spacing:8){
                Button {app.region()} label:{Label("截图",systemImage:"viewfinder")}.keyboardShortcut("n").buttonStyle(.borderedProminent)
                Menu {Button("多选区域（可减选）"){app.startAdvanced(.multiRegion)};Button("多边形选区"){app.startAdvanced(.polygon)};Button("自由形状选区"){app.startAdvanced(.freehand)};Divider();Button("窗口截图"){app.windowCapture()};Button("当前屏幕"){app.full()};ForEach(Array(NSScreen.screens.enumerated()),id:\.offset){ index,screen in Button("屏幕 \(index+1) · \(screen.localizedName)"){if let id=screen.displayID{app.startDisplayCapture(id)}}}} label:{Image(systemName:"chevron.down")}.frame(width:30)
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
                VStack(spacing:12){Image(systemName:"viewfinder").font(.system(size:42,weight:.ultraLight)).foregroundStyle(.secondary);Text(store.query.isEmpty ? "截取一点，留下重点" : "没有匹配的截图").font(.title3);Text("⌃⌘A 区域截图 · Esc 取消\n截图后标注、复制或贴在屏幕上").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)}.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ScrollView {LazyVGrid(columns:[GridItem(.adaptive(minimum:170,maximum:250),spacing:14)],spacing:14){ForEach(store.filtered){record in
                    VStack(alignment:.leading,spacing:6){
                        ZStack {RoundedRectangle(cornerRadius:8).fill(Color(nsColor:.controlBackgroundColor));if let thumb=store.thumbnail(for:record){Image(nsImage:thumb).resizable().scaledToFit().padding(6)}}.frame(height:116).onTapGesture(count:2){app.openRecord(record)}
                        HStack{Text(record.title).lineLimit(1).font(.system(size:12));Spacer();if record.starred{Image(systemName:"star.fill").foregroundStyle(.yellow)}}
                        Text("\(record.width) × \(record.height) · \(record.createdAt.formatted(date:.abbreviated,time:.shortened))").font(.system(size:10)).foregroundStyle(.secondary)
                    }.contextMenu{Button("编辑"){app.openRecord(record)};Button("贴图"){if let i=store.image(for:record){app.pin(i)}};Button("复制"){if let i=store.image(for:record){copyImage(i)}};Button("识别文字与条码"){if let i=store.image(for:record){app.recognize(i,recordID:record.id)}};Button("智能消除（可选本机模型）"){if let i=store.image(for:record){app.smartErase(i)}};Button("识别公式（可选本机模型）"){if let i=store.image(for:record){app.recognizeFormula(i)}};Button("识别表格（可选本机模型）"){if let i=store.image(for:record){app.recognizeTable(i)}};Button(record.starred ? "取消收藏" : "收藏"){try? store.toggleStar(record)};Divider();Button("移到废纸篓"){do{try store.remove(record)}catch{showError(error)}}}
                }}.padding(.horizontal,18).padding(.bottom,18)}
            }
            Divider();HStack{Image(systemName:"lock.shield");Text("本机处理 · 历史上限 \(store.policy.maxDays) 天 / \(store.policy.maxItems) 张 / \(store.policy.maxBytes / 1_048_576) MB");Spacer();Text("双击编辑")}.font(.system(size:10)).foregroundStyle(.secondary).padding(.horizontal,16).padding(.vertical,8)
        }.frame(minWidth:660,minHeight:400)
    }
}
