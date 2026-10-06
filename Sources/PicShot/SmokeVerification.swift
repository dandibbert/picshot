import AppKit
import Darwin

@MainActor extension AppDelegate {
    func runSmoke(){
        guard let report=smoke else{return}
        let url=URL(fileURLWithPath:report);let directory=url.deletingLastPathComponent()
        do{
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let sample=ImageEditorRenderer.makeSampleImage()
            let record=try history.add(sample,title:"示例截图")
            try history.updateText("PicShot native screenshot fixture",id:record.id)
            mainWindow.displayIfNeeded()
            try snapshot(mainWindow,to:directory.appendingPathComponent("history.png"))
            let editor=ImageEditorController(image:sample,onSave:{_ in},onPin:{_ in},onOCR:{_ in});editor.showWindow(nil)
            guard let ew=editor.window else{throw PicShotError.message("Editor missing window")};ew.displayIfNeeded();try snapshot(ew,to:directory.appendingPathComponent("editor.png"));editor.close()
            let pin=PinController(image:sample);pin.showWindow(nil);if let w=pin.window {try snapshot(w,to:directory.appendingPathComponent("pin.png"))};pin.close()
            let baseline=residentBytes();var peak=baseline
            for _ in 0..<40 {autoreleasepool{let image=ImageEditorRenderer.makeSampleImage();let c=ImageEditorController(image:image,onSave:{_ in},onPin:{_ in},onOCR:{_ in});c.showWindow(nil);c.window?.displayIfNeeded();c.close();let p=PinController(image:image);p.showWindow(nil);p.close()};RunLoop.current.run(until:Date().addingTimeInterval(0.01));peak=max(peak,residentBytes())}
            let final=residentBytes();let growth=Int64(final)-Int64(baseline)
            let visible=mainWindow.isVisible && mainWindow.contentView != nil
            let source=(Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String) ?? "unknown"
            let payload:[String:Any] = ["status":visible && growth<160*1024*1024 ? "passed":"failed","bundlePath":Bundle.main.bundlePath,"bundleIdentifier":Bundle.main.bundleIdentifier ?? "", "sourceCommit":source,"mainWindowVisible":visible,"arguments":CommandLine.arguments,"safeMode":true,"captureStarted":false,"windowTitle":mainWindow.title,"resourceCycleCount":40,"baselineRSSBytes":baseline,"peakRSSBytes":peak,"finalRSSBytes":final,"growthRSSBytes":growth,"resourceScope":"40 synthetic editor/pin create-render-close cycles; not a screen-capture or recording leak test"]
            try JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
            try? FileManager.default.removeItem(at:history.directory)
        }catch{try? JSONSerialization.data(withJSONObject:["status":"failed","error":error.localizedDescription]).write(to:url)}
        NSApp.terminate(nil)
    }
    private func snapshot(_ window:NSWindow,to url:URL)throws{
        guard let view=window.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)else{throw PicShotError.message("Native snapshot unavailable")}
        view.layoutSubtreeIfNeeded();view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let data=bitmap.representation(using:.png,properties:[:])else{throw PicShotError.message("Snapshot encoding failed")};try data.write(to:url)
    }
    private func residentBytes()->UInt64{
        var info=mach_task_basic_info();var count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<natural_t>.size)
        let result=withUnsafeMutablePointer(to:&info){ptr in ptr.withMemoryRebound(to:integer_t.self,capacity:Int(count)){task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)}}
        return result==KERN_SUCCESS ? info.resident_size:0
    }
}
