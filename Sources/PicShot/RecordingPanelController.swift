import AppKit
import SwiftUI
import ScreenCaptureKit

@MainActor final class RecordingPanelController:NSWindowController {
    init(service:RecordingService,capture:CaptureService){let w=NSWindow(contentRect:NSRect(x:0,y:0,width:420,height:310),styleMask:[.titled,.closable],backing:.buffered,defer:false);super.init(window:w);w.title="录屏";w.isReleasedWhenClosed=false;w.level = .floating;w.center();w.contentView=NSHostingView(rootView:RecordingPanel(service:service,capture:capture))}
    required init?(coder:NSCoder){fatalError()}
}
struct RecordingPanel:View {
    @ObservedObject var service:RecordingService
    let capture:CaptureService
    @State private var displays:[SCDisplay]=[]
    @State private var selected:CGDirectDisplayID=CGMainDisplayID()
    @State private var audio=false
    @State private var microphone=false
    @State private var region=false
    @State private var frameRate=30
    @State private var output:URL?
    @State private var lastSource:URL?
    @State private var working=false
    @State private var message="录屏直接写入磁盘，最长 10 分钟 / 1 GB"
    var body:some View {
        VStack(alignment:.leading,spacing:14){
            if service.isRecording || service.isStopping {
                HStack{Circle().fill(.red).frame(width:10,height:10);Text(service.isStopping ? "正在完成文件…" : "正在录制 · \(Int(service.elapsed)) 秒").monospacedDigit()}
                Text("回到此窗口停止录制。录屏内容不会上传。").foregroundStyle(.secondary)
                Button("停止并保存 MP4"){working=true;Task{defer{working=false};do{acceptOutput(try await service.stop())}catch{message=error.localizedDescription}}}.buttonStyle(.borderedProminent).disabled(working)
            }else{
                Picker("显示器",selection:$selected){ForEach(displays,id:\.displayID){display in Text("显示器 \(display.displayID) · \(display.width) × \(display.height)").tag(display.displayID)}}
                HStack{Toggle("选择区域",isOn:$region);Spacer();Picker("帧率",selection:$frameRate){ForEach([5,16,24,30,60],id:\.self){Text("\($0) FPS").tag($0)}}.frame(width:150)}
                HStack{Toggle("系统声音",isOn:$audio);Toggle("麦克风 (macOS 15+)",isOn:$microphone)}
                HStack{Button("开始录制"){working=true;Task{defer{working=false};do{let rect=region ? try await capture.selectRegion(displayID:selected) : nil;try await service.start(displayID:selected,region:rect,options:RecordingOptions(frameRate:frameRate,capturesSystemAudio:audio,capturesMicrophone:microphone))}catch{message=error.localizedDescription}}}.buttonStyle(.borderedProminent).disabled(working || displays.isEmpty)
                    if let output {Button("显示文件"){NSWorkspace.shared.activateFileViewerSelecting([output])};Button("导出 GIF…"){exportGIF(output)}.disabled(working)}
                }
            }
            Divider();Text(service.error ?? message).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Text("开发预览：暂不含暂停、摄像头画中画与录制中标注").font(.system(size:10)).foregroundStyle(.secondary)
        }.padding(20).frame(width:420,height:310).onChange(of:service.outputURL){ _,url in if let url {acceptOutput(url)} }.task {do{displays=try await service.availableDisplays();if !displays.contains(where:{$0.displayID==selected}){selected=displays.first?.displayID ?? CGMainDisplayID()}}catch{message=error.localizedDescription}}
    }
    func acceptOutput(_ source:URL){
        guard lastSource != source else{return}
        do {let folder=FileManager.default.urls(for:.moviesDirectory,in:.userDomainMask)[0].appendingPathComponent("PicShot",isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let name="PicShot-"+ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-")+"-"+UUID().uuidString.prefix(6)+".mp4"
            let target=folder.appendingPathComponent(name);try FileManager.default.copyItem(at:source,to:target);output=target;lastSource=source;message="MP4 已保存在电影/PicShot"
        }catch{output=source;message="录屏已完成但无法移入电影目录："+error.localizedDescription}
    }
    func exportGIF(_ source:URL){let p=NSSavePanel();p.allowedContentTypes=[.gif];p.nameFieldStringValue="录屏.gif";guard p.runModal() == .OK,let target=p.url else{return};working=true;message="正在导出最多 30 秒 GIF…";Task{defer{working=false};do{_ = try await GIFExporter.export(sourceURL:source,destinationURL:target);message="GIF 已导出"}catch{message=error.localizedDescription}}}
}
