import CoreGraphics
import Foundation
import Darwin

// Read-only numerical probe; no app, WindowServer, screen capture or model assets.
// The rendering context/image settings match MultiWindowCompositeRenderer's
// baseline. Results are observations, never a reason to relax exact pixel gates.
struct SamplingPlan {
    let label: String
    let sourceWidth: Int, sourceHeight: Int, width: Int, height: Int
    let left: Int, top: Int, canvasWidth: Int, canvasHeight: Int
    let mirrorX: Bool, mirrorY: Bool
    let clips: String
    init(_ label: String, sourceWidth: Int, sourceHeight: Int, width: Int, height: Int,
         left: Int = 0, top: Int = 0, right: Int = 0, bottom: Int = 0,
         mirrorX: Bool = false, mirrorY: Bool = false, clips: String = "strips128") {
        self.label = label; self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight
        self.width = width; self.height = height; self.left = left; self.top = top
        canvasWidth = left + width + right; canvasHeight = top + height + bottom
        self.mirrorX = mirrorX; self.mirrorY = mirrorY; self.clips = clips
    }
}
func fail(_ reason: String) -> NSError { NSError(domain: "PicShot.NearestSamplingProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
let began = ProcessInfo.processInfo.systemUptime
func checkDeadline() throws {
    guard ProcessInfo.processInfo.systemUptime - began < 90 else { throw fail("Probe exceeded its 90-second cooperative deadline") }
}
func observe(_ plan: SamplingPlan) throws -> [String: Any] {
    try checkDeadline()
    let sw = plan.sourceWidth, sh = plan.sourceHeight, w = plan.width, h = plan.height
    guard sw > 0, sh > 0, sw <= 4_095, sh <= 4_095, w > 0, h > 0,
          plan.canvasWidth <= 8_256, plan.canvasHeight <= 8_256,
          sw * sh * 4 <= 128 * 1_024, plan.canvasWidth * plan.canvasHeight * 4 <= 1_024 * 1_024 else {
        throw fail("Plan exceeds explicit probe raster bounds")
    }
    return try autoreleasepool {
        var source = [UInt8](repeating: 0, count: sw * sh * 4)
        for y in 0..<sh { for x in 0..<sw {
            let p = (y * sw + x) * 4
            source[p] = UInt8(x & 255); source[p + 1] = UInt8(y & 255)
            source[p + 2] = UInt8(((x >> 8) & 15) | (((y >> 8) & 15) << 4)); source[p + 3] = 255
        } }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(source) as CFData),
              let image = CGImage(width: sw, height: sh, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: sw * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw fail("Could not create coordinate image") }
        let outputBytes = plan.canvasWidth * plan.canvasHeight * 4
        guard let output = calloc(1, outputBytes) else { throw fail("Output allocation failed") }
        defer { free(output) }
        guard let context = CGContext(data: output, width: plan.canvasWidth, height: plan.canvasHeight,
            bitsPerComponent: 8, bytesPerRow: plan.canvasWidth * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw fail("Could not create output context") }
        context.clear(CGRect(x: 0, y: 0, width: plan.canvasWidth, height: plan.canvasHeight))
        context.interpolationQuality = .none; context.setShouldAntialias(false); context.setBlendMode(.normal)
        let rect = CGRect(x: plan.left, y: plan.canvasHeight - plan.top - h, width: w, height: h)
        var starts = Array(stride(from: 0, to: h, by: 128))
        if plan.clips == "tailFirst128", let last = starts.last, starts.count > 1 {
            starts.removeLast(); starts.insert(last, at: 0)
        }
        if plan.clips == "whole" { starts = [0] }
        for start in starts {
            try checkDeadline()
            context.saveGState()
            if plan.clips != "whole" {
                context.clip(to: CGRect(x: rect.minX, y: rect.minY + CGFloat(start), width: rect.width,
                    height: CGFloat(min(128, h - start))))
            }
            if plan.mirrorX { context.translateBy(x: 2 * rect.minX + rect.width, y: 0); context.scaleBy(x: -1, y: 1) }
            if plan.mirrorY { context.translateBy(x: 0, y: 2 * rect.minY + rect.height); context.scaleBy(x: 1, y: -1) }
            context.draw(image, in: rect)
            context.restoreGState()
        }
        context.flush()
        let pixels = output.assumingMemoryBound(to: UInt8.self)
        func coordinate(_ x: Int, _ y: Int) throws -> (Int, Int) {
            let p = ((plan.top + y) * plan.canvasWidth + plan.left + x) * 4
            let sx = Int(pixels[p]) | ((Int(pixels[p + 2]) & 15) << 8)
            let sy = Int(pixels[p + 1]) | ((Int(pixels[p + 2]) >> 4) << 8)
            guard pixels[p + 3] == 255, sx < sw, sy < sh else { throw fail("Non-coordinate pixel at \(plan.label) (\(x),\(y))") }
            return (sx, sy)
        }
        let xMap = try (0..<w).map { try coordinate($0, 0).0 }
        let yMap = try (0..<h).map { try coordinate(0, $0).1 }
        var nonseparable = [[Int]](), nonseparableCount = 0
        for y in 0..<h { for x in 0..<w {
            let sample = try coordinate(x, y)
            if sample.0 != xMap[x] || sample.1 != yMap[y] {
                nonseparableCount += 1
                if nonseparable.count < 16 { nonseparable.append([x,y,sample.0,sample.1]) }
            }
        } }
        var xTies = [[Int]](), yTies = [[Int]]()
        for x in 0..<w where ((2 * x + 1) * sw) % (2 * w) == 0 { xTies.append([x, ((2 * x + 1) * sw) / (2 * w), xMap[x]]) }
        for y in 0..<h where ((2 * y + 1) * sh) % (2 * h) == 0 { yTies.append([y, ((2 * y + 1) * sh) / (2 * h), yMap[y]]) }
        return ["label": plan.label, "sourceWidth": sw, "sourceHeight": sh, "width": w, "height": h,
            "left": plan.left, "top": plan.top, "canvasWidth": plan.canvasWidth, "canvasHeight": plan.canvasHeight,
            "mirrorX": plan.mirrorX, "mirrorY": plan.mirrorY, "clips": plan.clips,
            "clipStartsQuartzBottomUp": starts, "sourceBytes": sw * sh * 4, "outputBytes": outputBytes,
            "xMap": xMap, "yMap": yMap, "exactXTies": xTies, "exactYTies": yTies,
            "nonseparablePixelCount": nonseparableCount, "nonseparableExamples": nonseparable]
    }
}

var plans = [SamplingPlan]()
// Small exhaustive odd/even grid, including reduction ratios as a diagnostic.
for source in 2...17 { for destination in 2...33 {
    for translated in [false, true] {
        plans.append(SamplingPlan("grid-\(source)-\(destination)-\(translated ? "translated" : "origin")",
            sourceWidth: source, sourceHeight: source, width: destination, height: destination,
            left: translated ? 3 : 0, top: translated ? 5 : 0, right: translated ? 7 : 0, bottom: translated ? 9 : 0))
    }
} }
// The exact failing back-window geometry and the front-window geometry, alone.
plans.append(SamplingPlan("run100-back-exact-canvas", sourceWidth: 8, sourceHeight: 8, width: 13, height: 13, right: 15, bottom: 12))
plans.append(SamplingPlan("run100-back-translated-same-canvas", sourceWidth: 8, sourceHeight: 8, width: 13, height: 13, left: 3, top: 5, right: 12, bottom: 7))
plans.append(SamplingPlan("run100-front-exact-canvas", sourceWidth: 5, sourceHeight: 5, width: 13, height: 13, left: 4, top: 4, right: 11, bottom: 8))
for (source, destination) in [(2,3),(4,3),(6,9),(8,13),(5,13),(10,13),(12,13),(16,13),(8,15),(7,11),(17,31)] {
    for mirrorX in [false, true] { for mirrorY in [false, true] {
        for translated in [false, true] {
            plans.append(SamplingPlan("orientation-\(source)-\(destination)-\(mirrorX)-\(mirrorY)-\(translated)",
                sourceWidth: source, sourceHeight: source, width: destination, height: destination,
                left: translated ? 3 : 0, top: translated ? 5 : 0, right: translated ? 7 : 0, bottom: translated ? 9 : 0,
                mirrorX: mirrorX, mirrorY: mirrorY))
        }
    } }
}
// Long thin rasters expose accumulation/quantization away from exact ties and
// reinitialization at clip boundaries without allocating large square rasters.
let longRatios = [(8,129),(63,128),(64,129),(65,128),(127,128),(128,129),(129,255),(255,256),
                  (256,257),(257,511),(511,512),(512,513),(513,1025),(1024,1625),(2048,3251),(4095,8191)]
for (source, destination) in longRatios {
    for axis in ["x", "y"] { for clips in ["whole", "strips128", "tailFirst128"] {
        plans.append(SamplingPlan("long-\(source)-\(destination)-\(axis)-\(clips)",
            sourceWidth: axis == "x" ? source : 2, sourceHeight: axis == "y" ? source : 2,
            width: axis == "x" ? destination : 2, height: axis == "y" ? destination : 2,
            left: 3, top: 5, right: 7, bottom: 9, clips: clips))
    } }
}

guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasPrefix("/"),
      !FileManager.default.fileExists(atPath: CommandLine.arguments[1]), plans.count <= 1_600 else {
    fputs("Usage: swift probe-multiwindow-nearest.swift /absolute/new-report.json\n", stderr); exit(64)
}
let reportURL = URL(fileURLWithPath: CommandLine.arguments[1])
var records = [[String: Any]]()
var report: [String: Any] = ["schemaVersion": 1, "status": "running", "plannedCases": plans.count,
    "sourceCommitContext": "83406c0d CPU prototype; standalone probe",
    "sourceCommit": ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "local-unbound", "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
    "pid": getpid(), "sourceIndexEncoding": "12-bit X in R and low B nibble; 12-bit Y in G and high B nibble; alpha 255",
    "maximumSourceRasterBytes": 128 * 1_024, "maximumOutputRasterBytes": 1_024 * 1_024,
    "frameworkScratchBounded": false, "screenCaptureStarted": false, "permissionRequested": false,
    "productionChanged": false, "equivalenceEstablished": false]
#if arch(arm64)
report["compiledArchitecture"] = "arm64"
#elseif arch(x86_64)
report["compiledArchitecture"] = "x86_64"
#else
report["compiledArchitecture"] = "unknown"
#endif
do {
    for plan in plans { records.append(try observe(plan)) }
    report["status"] = "observed"
} catch {
    report["status"] = "failed"; report["error"] = error.localizedDescription
}
report["cases"] = records; report["completedCases"] = records.count
report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - began
try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: reportURL, options: [.atomic])
print("NEAREST_SAMPLING_PROBE \(report["status"]!) \(records.count)/\(plans.count) cases: \(reportURL.path)")
exit(report["status"] as? String == "observed" ? 0 : 1)
