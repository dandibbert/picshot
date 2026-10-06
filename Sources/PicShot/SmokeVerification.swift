import AppKit
import Darwin

@MainActor extension AppDelegate {
    func runSmoke() async {
        guard let report=smoke else{return}
        let url=URL(fileURLWithPath:report);let directory=url.deletingLastPathComponent()
        do{
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let sample=ImageEditorRenderer.makeSampleImage()
            let record=try history.add(sample,title:"示例截图")
            try history.updateText("PicShot native screenshot fixture",id:record.id)
            try await Task.sleep(nanoseconds:200_000_000)
            mainWindow.displayIfNeeded()
            try snapshot(mainWindow,to:directory.appendingPathComponent("history.png"))
            let annotations = [ImageAnnotation(tool:.arrow,points:[CGPoint(x:455,y:180),CGPoint(x:645,y:270)],color:CGColor(srgbRed:1,green:0.25,blue:0.3,alpha:1),lineWidth:8),ImageAnnotation(tool:.text,points:[CGPoint(x:450,y:105)],color:CGColor(gray:1,alpha:1),lineWidth:6,text:"Review this detail"),ImageAnnotation(tool:.rectangle,points:[CGPoint(x:50,y:425),CGPoint(x:425,y:465)],color:CGColor(srgbRed:1,green:0.78,blue:0.2,alpha:1),lineWidth:4)]
            let annotated = ImageEditorRenderer.render(image:sample,annotations:annotations)!
            let editor=ImageEditorController(image:sample,onSave:{_ in},onPin:{_ in},onOCR:{_ in});editor.setVerificationAnnotations(annotations);editor.showWindow(nil)
            try await Task.sleep(nanoseconds:200_000_000)
            guard let ew=editor.window else{throw PicShotError.message("Editor missing window")};ew.displayIfNeeded();try snapshot(ew,to:directory.appendingPathComponent("editor.png"));editor.close()
            let pin=PinController(image:annotated);pin.showWindow(nil);if let w=pin.window {try snapshot(w,to:directory.appendingPathComponent("pin.png"))};pin.close()
            let settings=SettingsController(onChange:{});settings.showWindow(nil);if let w=settings.window{try snapshot(w,to:directory.appendingPathComponent("settings.png"))};settings.close()
            var weakWindows:[SmokeWeakWindow]=[]
            for _ in 0..<10 {autoreleasepool{weakWindows += cycleFixture()};try await Task.sleep(nanoseconds:40_000_000)}
            try await Task.sleep(nanoseconds:300_000_000)
            let baseline=residentBytes();let baselineWindows=windowCount();var peak=baseline;var samples:[UInt64]=[];var windowCounts:[Int]=[];var weakCounts:[Int]=[]
            for index in 0..<40 {autoreleasepool{weakWindows += cycleFixture()};try await Task.sleep(nanoseconds:40_000_000);peak=max(peak,residentBytes());if (index+1)%10==0{samples.append(residentBytes());windowCounts.append(windowCount());weakCounts.append(weakWindows.filter{$0.window != nil}.count)}}
            try await Task.sleep(nanoseconds:300_000_000)
            let final=residentBytes();let growth=Int64(final)-Int64(baseline);let lastIntervalGrowth=Int64(samples.last ?? final)-Int64(samples.dropLast().last ?? baseline);let windowsStable=windowCount()<=baselineWindows+3 && weakWindows.allSatisfy{$0.window == nil}
            let visible=mainWindow.isVisible && mainWindow.contentView != nil
            let source=(Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String) ?? "unknown"
            let payload:[String:Any] = ["status":visible && growth<160*1024*1024 && lastIntervalGrowth<32*1024*1024 && windowsStable ? "passed":"failed","bundlePath":Bundle.main.bundlePath,"bundleIdentifier":Bundle.main.bundleIdentifier ?? "", "sourceCommit":source,"mainWindowVisible":visible,"arguments":CommandLine.arguments,"safeMode":true,"captureStarted":false,"windowTitle":mainWindow.title,"resourceCycleCount":40,"warmupCycleCount":10,"rssSamplesEveryTenCycles":samples,"windowCountsEveryTenCycles":windowCounts,"baselineWindowCount":baselineWindows,"finalWindowCount":windowCount(),"weakCycleWindowCounts":weakCounts,"finalRetainedCycleWindows":weakWindows.filter{$0.window != nil}.count,"lastTenCyclesGrowthBytes":lastIntervalGrowth,"baselineRSSBytes":baseline,"peakRSSBytes":peak,"finalRSSBytes":final,"growthRSSBytes":growth,"resourceScope":"10 warm-up plus 40 synthetic editor/pin create-render-close cycles; not a screen-capture or recording leak test"]
            try JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
            try? FileManager.default.removeItem(at:history.directory)
        }catch{try? JSONSerialization.data(withJSONObject:["status":"failed","error":error.localizedDescription]).write(to:url)}
        NSApp.terminate(nil)
    }
    private func cycleFixture()->[SmokeWeakWindow]{let image=ImageEditorRenderer.makeSampleImage();let c=ImageEditorController(image:image,onSave:{_ in},onPin:{_ in},onOCR:{_ in});c.showWindow(nil);c.window?.displayIfNeeded();c.close();let p=PinController(image:image);p.showWindow(nil);p.close();return [SmokeWeakWindow(c.window),SmokeWeakWindow(p.window)]}
    private func snapshot(_ window:NSWindow,to url:URL)throws{
        guard let view=window.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)else{throw PicShotError.message("Native snapshot unavailable")}
        view.layoutSubtreeIfNeeded();view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let image=bitmap.cgImage,let context=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{throw PicShotError.message("Snapshot encoding failed")}
        window.effectiveAppearance.performAsCurrentDrawingAppearance {context.setFillColor(window.backgroundColor.cgColor)}
        context.fill(CGRect(x:0,y:0,width:image.width,height:image.height));context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));try context.makeImage()!.writePNG(to:url)
    }
    private func windowCount()->Int{autoreleasepool{NSApp.windows.count}}
    private func residentBytes()->UInt64{
        var info=mach_task_basic_info();var count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<natural_t>.size)
        let result=withUnsafeMutablePointer(to:&info){ptr in ptr.withMemoryRebound(to:integer_t.self,capacity:Int(count)){task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)}}
        return result==KERN_SUCCESS ? info.resident_size:0
    }
}

private final class SmokeWeakWindow {weak var window:NSWindow?;init(_ window:NSWindow?){self.window=window}}
