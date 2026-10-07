import AppKit
import Darwin
import PicShotCore
import PicShotFormulaRenderCore

@MainActor extension AppDelegate {
    func runSmoke() async {
        guard let report=smoke else{return}
        let url=URL(fileURLWithPath:report);let directory=url.deletingLastPathComponent()
        do{
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            if ProcessInfo.processInfo.environment["PICSHOT_ANNOTATION_DETAILS_ONLY"] == "1" {
                var payload = try await AnnotationDetailAcceptanceFixture.verify(evidenceDirectory: directory, includeResourceCycles: ProcessInfo.processInfo.environment["PICSHOT_UI_PREVIEW_ONLY"] != "1")
                payload["arguments"] = CommandLine.arguments
                try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
                try? FileManager.default.removeItem(at: history.directory)
                NSApp.terminate(nil); return
            }
            if ProcessInfo.processInfo.environment["PICSHOT_AUTOMATIC_MOSAIC_ONLY"] == "1" {
                let full = ProcessInfo.processInfo.environment["PICSHOT_UI_PREVIEW_ONLY"] != "1"
                let payload = try await AutomaticMosaicWorkflowSmokeFixture.verify(evidenceDirectory: directory, includeResourceCycles: full)
                try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
                try? FileManager.default.removeItem(at: history.directory)
                NSApp.terminate(nil); return
            }
            if ProcessInfo.processInfo.environment["PICSHOT_PIN_GROUP_TRANSFORMS_ONLY"] == "1" {
                var payload = try await PinGroupTransformSmokeFixture.verify(evidenceDirectory: directory)
                payload["sourceCommit"] = Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown"
                payload["bundlePath"] = Bundle.main.bundlePath
                payload["arguments"] = CommandLine.arguments
                try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
                try? FileManager.default.removeItem(at: history.directory)
                NSApp.terminate(nil); return
            }
            if ProcessInfo.processInfo.environment["PICSHOT_PIN_DESKTOP_VISIBILITY_ONLY"] == "1" {
                var payload = try await PinDesktopVisibilityFixture.verify(evidenceDirectory: directory)
                payload["sourceCommit"] = Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown"
                payload["bundlePath"] = Bundle.main.bundlePath
                payload["arguments"] = CommandLine.arguments
                try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
                try? FileManager.default.removeItem(at: history.directory)
                NSApp.terminate(nil); return
            }
            if ProcessInfo.processInfo.environment["PICSHOT_LATEX_PIN_VERIFY"] == "1" {
                var payload = try await LaTeXPinSmokeFixture.verify(evidenceDirectory: directory)
                payload["bundlePath"] = Bundle.main.bundlePath
                payload["arguments"] = CommandLine.arguments
                try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
                try? FileManager.default.removeItem(at: history.directory)
                NSApp.terminate(nil); return
            }
            if let payload = try await CodecExportAttributionFixture.runIfRequested(evidenceDirectory: directory) {
                try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
                try? FileManager.default.removeItem(at: history.directory)
                NSApp.terminate(nil); return
            }
            if let value=ProcessInfo.processInfo.environment["PICSHOT_GIF_DIAGNOSTIC_MODE"] {
                guard let mode=GIFResourceAttributionFixture.Mode(rawValue:value) else {throw PicShotError.message("Unknown GIF diagnostic mode")}
                let extractionValue=ProcessInfo.processInfo.environment["PICSHOT_GIF_EXTRACTION"] ?? GIFFrameExtraction.asynchronous.rawValue
                guard let extraction=GIFFrameExtraction(rawValue:extractionValue) else {throw PicShotError.message("Unknown GIF diagnostic frame extraction")}
                let executionValue=ProcessInfo.processInfo.environment["PICSHOT_GIF_EXECUTION"] ?? GIFResourceAttributionFixture.Execution.inProcessBaseline.rawValue
                guard let execution=GIFResourceAttributionFixture.Execution(rawValue:executionValue) else {throw PicShotError.message("Unknown GIF diagnostic execution boundary")}
                let payload=try await GIFResourceAttributionFixture.verify(evidenceDirectory:directory,mode:mode,frameExtraction:extraction,execution:execution)
                try JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
                try? FileManager.default.removeItem(at:history.directory)
                NSApp.terminate(nil);return
            }
            if ProcessInfo.processInfo.environment["PICSHOT_UI_PREVIEW_ONLY"] == "1" {
                let previews=try await CaptureUIPreviewFixture.verify(evidenceDirectory:directory)
                let annotationEffects=try await AnnotationEffectsPreviewFixture.verify(evidenceDirectory:directory)
                let interactionParity=try await InteractionParitySmokeFixture.verify(evidenceDirectory:directory)
                let captureExportRecognition=try await CaptureExportRecognitionSmokeFixture.verify(evidenceDirectory:directory,includeResourceCycles:false)
                let codecUIPreview=try await CodecExportUIPreviewFixture.verify(evidenceDirectory:directory)
                let saveWorkflowUI=try await SaveWorkflowUIPreviewFixture.verify(evidenceDirectory:directory)
                let pinOCRWorkflow=try await PinOCRWorkflowSmokeFixture.verify(evidenceDirectory:directory.appendingPathComponent("pin-ocr"),includeResourceCycles:false)
                let automaticMosaicWorkflow=try await AutomaticMosaicWorkflowSmokeFixture.verify(evidenceDirectory:directory.appendingPathComponent("automatic-mosaic"),includeResourceCycles:false)
                let annotationDetails=try await AnnotationDetailAcceptanceFixture.verify(evidenceDirectory:directory.appendingPathComponent("annotation-details"),includeResourceCycles:false)
                let originalAppearance=NSApp.appearance
                for dark in [false,true] {
                    NSApp.appearance=NSAppearance(named:dark ? .darkAqua : .aqua)
                    let settings=SettingsController(onChange:{},isSmoke:true,onManageCapturePresets:{})
                    settings.selectCategory(dark ? .capture : .shortcuts);settings.showWindow(nil)
                    try await Task.sleep(nanoseconds:200_000_000)
                    if let window=settings.window {try snapshot(window,to:directory.appendingPathComponent(dark ? "ui-settings-dark.png" : "ui-settings-light.png"))}
                    settings.close()
                }
                NSApp.appearance=originalAppearance
                let payload:[String:Any] = ["status":"passed","uiPreviewOnly":true,"captureStarted":false,"bundlePath":Bundle.main.bundlePath,"sourceCommit":Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String ?? "unknown","previews":previews,"annotationEffects":annotationEffects,"interactionParity":interactionParity,"captureExportRecognition":captureExportRecognition,"codecUIPreview":codecUIPreview,"saveWorkflowUI":saveWorkflowUI,"pinOCRWorkflow":pinOCRWorkflow,"automaticMosaicWorkflow":automaticMosaicWorkflow,"annotationDetails":annotationDetails,"scope":"Real native AppKit UI over an original synthetic frozen-desktop fixture; no screen-capture permission or live desktop capture"]
                try JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
                NSApp.terminate(nil);return
            }
            var modelEvidence:[String:Any]=[:]
            let env=ProcessInfo.processInfo.environment
            if let formulaPath=env["PICSHOT_SMOKE_FORMULA_MODEL_DIR"],let formulaInput=env["PICSHOT_SMOKE_FORMULA_INPUT"],let formulaImage=CGImage.read(url:URL(fileURLWithPath:formulaInput)) {
                let result=try await MLHelperService.shared.formula(image:formulaImage,modelDirectory:URL(fileURLWithPath:formulaPath))
                guard result.latex.replacingOccurrences(of:" ",with:"")=="E=mc^{2}" else{throw PicShotError.message("Packaged helper formula fixture mismatch")}
                modelEvidence["formulaLaTeX"]=result.latex
            }
            if let tablePath=env["PICSHOT_SMOKE_TABLE_MODEL_DIR"],let tableInput=env["PICSHOT_SMOKE_TABLE_INPUT"],let tableImage=CGImage.read(url:URL(fileURLWithPath:tableInput)) {
                let result=try await MLHelperService.shared.table(image:tableImage,modelDirectory:URL(fileURLWithPath:tablePath))
                guard result.table.rowCount==4,result.table.columnCount==3,result.table.cells.first?.columnSpan==3 else{throw PicShotError.message("Packaged helper table fixture mismatch")}
                modelEvidence["tableRows"]=result.table.rowCount;modelEvidence["tableColumns"]=result.table.columnCount
                let table=TableEditorController(table:result.table,sourceImage:tableImage);table.showWindow(nil);try await Task.sleep(nanoseconds:150_000_000);if let w=table.window{try snapshot(w,to:directory.appendingPathComponent("table-editor.png"))};table.close()
            }
            if let erasePath=env["PICSHOT_SMOKE_ERASE_MODEL_DIR"] {
                modelEvidence["smartErase"]=try await SmartEraseSmokeFixture.verifyPackagedHelper(modelDirectory:URL(fileURLWithPath:erasePath),evidenceDirectory:directory)
            }
            let resourceMetrics=LocalInferenceResources.shared.snapshot()
            guard resourceMetrics.activeJob == nil else {throw PicShotError.message("Inference gate remained occupied after helper completion")}
            let resourceJSON=try JSONSerialization.jsonObject(with:JSONEncoder().encode(resourceMetrics))
            modelEvidence["processResources"]=resourceJSON
            let formulaPreview=FormulaRenderController(latex:"E=mc^{2}")
            formulaPreview.showWindow(nil)
            let renderedFormula=try await formulaPreview.renderForVerification()
            if let w=formulaPreview.window {try snapshot(w,to:directory.appendingPathComponent("formula-preview.png"))}
            formulaPreview.close()
            guard renderedFormula.mathML.contains("<math"),renderedFormula.svg.contains("<svg"),!renderedFormula.png.isEmpty,!renderedFormula.pdf.isEmpty else{throw PicShotError.message("Packaged formula renderer returned empty exports")}
            try renderedFormula.png.write(to:directory.appendingPathComponent("formula-render.png"))
            try renderedFormula.pdf.write(to:directory.appendingPathComponent("formula-render.pdf"))
            modelEvidence["formulaRender"]=["width":renderedFormula.width,"height":renderedFormula.height,"pngBytes":renderedFormula.png.count,"pdfBytes":renderedFormula.pdf.count,"mathMLBytes":renderedFormula.mathML.utf8.count,"svgBytes":renderedFormula.svg.utf8.count]
            try JSONSerialization.data(withJSONObject:modelEvidence,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("model-evidence.json"),options:.atomic)
            let pinSessionEvidence=try await PinSessionSmokeFixture.verify(evidenceDirectory:directory)
            try JSONSerialization.data(withJSONObject:pinSessionEvidence,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("pin-session.json"),options:.atomic)
            let pinGroupEvidence=try await PinGroupTransformSmokeFixture.verify(evidenceDirectory:directory)
            try JSONSerialization.data(withJSONObject:pinGroupEvidence,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("pin-group-transforms.json"),options:.atomic)
            let recordingCompositionEvidence=try await RecordingCompositionSmokeFixture.verify(evidenceDirectory:directory)
            let interactionParityEvidence=try await InteractionParitySmokeFixture.verify(evidenceDirectory:directory)
            let captureExportRecognitionEvidence=try await CaptureExportRecognitionSmokeFixture.verify(evidenceDirectory:directory,includeResourceCycles:true)
            let codecExportEvidence=try await CodecExportResourceFixture.verify(evidenceDirectory:directory)
            let saveWorkflowEvidence=try await SaveWorkflowUIPreviewFixture.verify(evidenceDirectory:directory)
            let pinOCRWorkflow=try await PinOCRWorkflowSmokeFixture.verify(evidenceDirectory:directory.appendingPathComponent("pin-ocr"),includeResourceCycles:true)
            let automaticMosaicWorkflow=try await AutomaticMosaicWorkflowSmokeFixture.verify(evidenceDirectory:directory.appendingPathComponent("automatic-mosaic"),includeResourceCycles:true)
            let annotationDetails=try await AnnotationDetailAcceptanceFixture.verify(evidenceDirectory:directory.appendingPathComponent("annotation-details"),includeResourceCycles:true)
            let recordingWebPEvidence=try await RecordingWebPSmokeFixture.verify(evidenceDirectory:directory)
            var gifResourceEvidence:[String:Any]=["status":"not-run","scope":"Full GIF resource fixture is run from the ZIP install only"]
            if env["PICSHOT_SMOKE_GIF_RESOURCES"] == "1" {gifResourceEvidence=try await GIFResourceSmokeFixture.verify(evidenceDirectory:directory)}
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
            let settings=SettingsController(onChange:{},isSmoke:true,onManageCapturePresets:{});settings.showWindow(nil);if let w=settings.window{try snapshot(w,to:directory.appendingPathComponent("settings.png"))};settings.close()
            var weakWindows:[SmokeWeakWindow]=[]
            for _ in 0..<10 {autoreleasepool{weakWindows += cycleFixture()};try await Task.sleep(nanoseconds:40_000_000)}
            try await Task.sleep(nanoseconds:300_000_000)
            let baseline=residentBytes();let baselineWindows=windowCount();var peak=baseline;var samples:[UInt64]=[];var windowCounts:[Int]=[];var weakCounts:[Int]=[]
            for index in 0..<40 {autoreleasepool{weakWindows += cycleFixture()};try await Task.sleep(nanoseconds:40_000_000);peak=max(peak,residentBytes());if (index+1)%10==0{samples.append(residentBytes());windowCounts.append(windowCount());weakCounts.append(liveCycleWindows(weakWindows).count)}}
            mainWindow.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds:800_000_000)
            let retained=liveCycleWindows(weakWindows);let retainedOwned=retainedCycleContentCount(weakWindows)
            let final=residentBytes();let growth=Int64(final)-Int64(baseline);let lastIntervalGrowth=Int64(samples.last ?? final)-Int64(samples.dropLast().last ?? baseline);let windowsStable=windowCount()<=baselineWindows+3 && retainedOwned == 0
            let visible=mainWindow.isVisible && mainWindow.contentView != nil
            let source=(Bundle.main.infoDictionary?["PicShotSourceCommit"] as? String) ?? "unknown"
            let payload:[String:Any] = ["status":visible && growth<160*1024*1024 && lastIntervalGrowth<32*1024*1024 && windowsStable ? "passed":"failed","bundlePath":Bundle.main.bundlePath,"bundleIdentifier":Bundle.main.bundleIdentifier ?? "", "sourceCommit":source,"mainWindowVisible":visible,"arguments":CommandLine.arguments,"safeMode":true,"captureStarted":false,"packagedModelEvidence":modelEvidence,"pinSessionEvidence":pinSessionEvidence,"pinGroupTransformEvidence":pinGroupEvidence,"gifResourceEvidence":gifResourceEvidence,"recordingCompositionEvidence":recordingCompositionEvidence,"interactionParityEvidence":interactionParityEvidence,"captureExportRecognitionEvidence":captureExportRecognitionEvidence,"codecExportEvidence":codecExportEvidence,"saveWorkflowEvidence":saveWorkflowEvidence,"pinOCRWorkflow":pinOCRWorkflow,"automaticMosaicWorkflow":automaticMosaicWorkflow,"annotationDetails":annotationDetails,"recordingWebPEvidence":recordingWebPEvidence,"windowTitle":mainWindow.title,"resourceCycleCount":40,"warmupCycleCount":10,"rssSamplesEveryTenCycles":samples,"windowCountsEveryTenCycles":windowCounts,"baselineWindowCount":baselineWindows,"finalWindowCount":windowCount(),"weakCycleWindowCounts":weakCounts,"finalRetainedCycleWindows":retained.count,"retainedCycleWindowDetails":retained,"finalRetainedAppControllersOrContent":retainedOwned,"lastTenCyclesGrowthBytes":lastIntervalGrowth,"baselineRSSBytes":baseline,"peakRSSBytes":peak,"finalRSSBytes":final,"growthRSSBytes":growth,"resourceScope":"10 warm-up plus 40 synthetic editor/pin create-render-close cycles; not a screen-capture or recording leak test"]
            try JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
            try? FileManager.default.removeItem(at:history.directory)
        }catch{try? JSONSerialization.data(withJSONObject:["status":"failed","error":error.localizedDescription]).write(to:url)}
        if ProcessInfo.processInfo.environment["PICSHOT_GIF_DIAGNOSTIC_MODE"] != nil {try? FileManager.default.removeItem(at:history.directory)}
        NSApp.terminate(nil)
    }
    private func cycleFixture()->[SmokeWeakWindow]{let image=ImageEditorRenderer.makeSampleImage();let c=ImageEditorController(image:image,onSave:{_ in},onPin:{_ in},onOCR:{_ in});c.showWindow(nil);c.window?.displayIfNeeded();let editorProbe=SmokeWeakWindow(c);c.close();let p=PinController(image:image);p.showWindow(nil);let pinProbe=SmokeWeakWindow(p);p.close();return [editorProbe,pinProbe]}
    private func snapshot(_ window:NSWindow,to url:URL)throws{
        guard let view=window.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)else{throw PicShotError.message("Native snapshot unavailable")}
        view.layoutSubtreeIfNeeded();view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let image=bitmap.cgImage,let context=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{throw PicShotError.message("Snapshot encoding failed")}
        window.effectiveAppearance.performAsCurrentDrawingAppearance {context.setFillColor(window.backgroundColor.cgColor)}
        context.fill(CGRect(x:0,y:0,width:image.width,height:image.height));context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));try context.makeImage()!.writePNG(to:url)
    }
    private func retainedCycleContentCount(_ refs:[SmokeWeakWindow])->Int{autoreleasepool{refs.filter{$0.controller != nil || $0.content != nil}.count}}
    private func liveCycleWindows(_ refs:[SmokeWeakWindow])->[String]{autoreleasepool{refs.compactMap{ref in guard let w=ref.window else{return nil};return "\(ref.kind): window=\(w.title), visible=\(w.isVisible), controllerAlive=\(ref.controller != nil), contentAlive=\(ref.content != nil), key=\(w.isKeyWindow)"}}}
    private func windowCount()->Int{autoreleasepool{NSApp.windows.count}}
    private func residentBytes()->UInt64{
        var info=mach_task_basic_info();var count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<natural_t>.size)
        let result=withUnsafeMutablePointer(to:&info){ptr in ptr.withMemoryRebound(to:integer_t.self,capacity:Int(count)){task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)}}
        return result==KERN_SUCCESS ? info.resident_size:0
    }
}

private final class SmokeWeakWindow {weak var window:NSWindow?;weak var controller:NSWindowController?;weak var content:NSView?;let kind:String;init(_ controller:NSWindowController){self.window=controller.window;self.controller=controller;self.content=controller.window?.contentView;kind=String(describing:type(of:controller))}}
