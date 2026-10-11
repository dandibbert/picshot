import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Original public-domain-style fixture text in a separate process. No screen,
/// Accessibility, input posting, browser, network, or permission APIs are used.
@MainActor
private enum Page {
    static let width: CGFloat = 640, height: CGFloat = 480, header: CGFloat = 36
    static let maximumOffset: CGFloat = 1320, rowHeight: CGFloat = 72
    static func heading() {
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: header).fill()
        ("PicShot • Plain numbered document" as NSString).draw(at: NSPoint(x: 16, y: 9),
            withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.black])
        NSColor(calibratedWhite: 0.4, alpha: 1).setFill()
        NSRect(x: 0, y: header - 1, width: width, height: 1).fill()
    }
    static func rows(in rect: NSRect) {
        NSColor.white.setFill(); rect.fill()
        let first = max(0, Int(rect.minY / rowHeight)), last = Int(ceil(rect.maxY / rowHeight))
        let lines = [
            "A clear morning brings a fresh page and a quiet place to begin.",
            "This short paragraph describes the shape of an ordinary day.",
            "Readers can follow each numbered section as the page moves.",
            "The next sentence leaves enough room for a useful observation.",
            "Small details give every paragraph a different line of thought.",
            "A simple document can still show where each new idea begins.",
            "The final phrase closes the section before another one follows."
        ]
        for row in first...last {
            let y = CGFloat(row) * rowHeight
            (String(format: "%03d  Section %d: notes from an ordinary document", row + 1, row + 1) as NSString)
                .draw(at: NSPoint(x: 18, y: y + 6), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.black])
            (lines[(row * 3) % lines.count] as NSString).draw(at: NSPoint(x: 18, y: y + 27), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1)])
            let detail = (row.isMultiple(of: 2) ? "Observation \(row + 1): " : "Details \(row + 1): ") + lines[(row * 5 + 1) % lines.count]
            (detail as NSString).draw(at: NSPoint(x: 18, y: y + 46), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(calibratedWhite: 0.22, alpha: 1)])
        }
    }
    static func reference(scale: CGFloat, destination: URL) throws {
        let total = height + maximumOffset, w = Int(width * scale), h = Int(total * scale)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "LiveScrollTarget", code: 1)
        }
        context.translateBy(x: 0, y: CGFloat(h)); context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        heading()
        context.translateBy(x: 0, y: header)
        rows(in: NSRect(x: 0, y: 0, width: width, height: total - header))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage(),
              let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "LiveScrollTarget", code: 2)
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw NSError(domain: "LiveScrollTarget", code: 3) }
    }
}

@MainActor
private final class Document: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { Page.rows(in: bounds) }
}

@MainActor
private final class Viewport: NSView {
    let scroll = NSScrollView()
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.frame = NSRect(x: 0, y: Page.header, width: Page.width, height: Page.height - Page.header)
        scroll.borderType = .noBorder; scroll.drawsBackground = true; scroll.backgroundColor = .white
        scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none; scroll.horizontalScrollElasticity = .none
        scroll.documentView = Document(frame: NSRect(x: 0, y: 0, width: Page.width, height: 6000))
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func draw(_ dirtyRect: NSRect) { NSColor.white.setFill(); bounds.fill(); Page.heading() }
}

@MainActor
private final class TargetDelegate: NSObject, NSApplicationDelegate {
    let directory: URL
    var window: NSWindow!, viewport: Viewport!, timer: Timer?
    let launchedAt = ProcessInfo.processInfo.systemUptime
    var scrollingAt: TimeInterval?, samples: [[String: Any]] = [], status = "ready", referenceReady = false
    var maximumObservedOffset: CGFloat = 0
    init(directory: URL) { self.directory = directory }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main, screen.visibleFrame.width >= 660, screen.visibleFrame.height >= 540 else {
            status = "failed: display too small"; save(); NSApp.terminate(nil); return
        }
        let visible = screen.visibleFrame
        let frame = CGRect(x: floor(visible.minX + 24), y: floor(visible.midY - Page.height / 2), width: Page.width, height: Page.height)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.title = "PicShot Owned Scroll Target"
        window.isReleasedWhenClosed = false; window.hasShadow = false; window.backgroundColor = .white
        window.isOpaque = true; window.appearance = NSAppearance(named: .aqua)
        viewport = Viewport(frame: CGRect(origin: .zero, size: frame.size)); window.contentView = viewport
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); window.displayIfNeeded()
        do {
            try Page.reference(scale: window.backingScaleFactor, destination: directory.appendingPathComponent("reference.png"))
            referenceReady = true
        } catch { status = "failed: reference rendering" }
        save()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - launchedAt >= 24 || FileManager.default.fileExists(atPath: directory.appendingPathComponent("stop").path) {
            status = "closed"; save(); timer?.invalidate(); window?.close(); NSApp.terminate(nil); return
        }
        if scrollingAt == nil, referenceReady,
           FileManager.default.fileExists(atPath: directory.appendingPathComponent("start").path) { scrollingAt = now }
        if let scrollingAt {
            let t = min(15, now - scrollingAt)
            let offset: CGFloat
            if t <= 6 { offset = CGFloat(floor(t * 30)) * 4 }
            else if t <= 8 { offset = 720 - CGFloat(floor((t - 6) * 30)) * 4 }
            else { offset = 480 + CGFloat(floor((t - 8) * 30)) * 4 }
            viewport.scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            viewport.scroll.reflectScrolledClipView(viewport.scroll.contentView)
            window.displayIfNeeded()
            maximumObservedOffset = max(maximumObservedOffset, viewport.scroll.contentView.bounds.minY)
            status = t >= 15 ? "finished" : "scrolling"
            if samples.count < 480 && (samples.last?["offset"] as? Double != Double(offset)) {
                samples.append(["seconds": t, "offset": Double(viewport.scroll.contentView.bounds.minY),
                                "direction": t > 6 && t <= 8 ? -1 : 1])
            }
        }
        save()
    }
    func save() {
        var payload: [String: Any] = ["schemaVersion": 1, "pid": ProcessInfo.processInfo.processIdentifier,
            "status": status, "uptimeSeconds": ProcessInfo.processInfo.systemUptime,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - launchedAt,
            "referenceReady": referenceReady, "maximumLifetimeSeconds": 24,
            "maximumOffset": Double(maximumObservedOffset), "offsets": samples,
            "globalInputPosted": false, "permissionRequested": false, "plainTextOnly": true]
        if let window, let screen = window.screen,
           let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let bounds = CGDisplayBounds(id.uint32Value), frame = window.frame
            let crop = CGRect(x: frame.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY,
                              width: frame.width, height: frame.height)
            payload["windowID"] = window.windowNumber; payload["displayID"] = id.uint32Value
            payload["viewportDisplayPoints"] = values(crop)
            payload["windowGlobalCGPoints"] = values(crop.offsetBy(dx: bounds.minX, dy: bounds.minY))
            payload["displayPoints"] = values(bounds)
            payload["pixelScale"] = window.backingScaleFactor
            payload["offset"] = Double(viewport.scroll.contentView.bounds.minY)
            payload["headerPoints"] = Double(Page.header)
            payload["expectedFinalOffset"] = Double(Page.maximumOffset)
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("target.json"), options: .atomic)
        }
    }
    func values(_ rect: CGRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
    }
}

@main
private enum LiveScrollTarget {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2 else { exit(64) }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { exit(65) }
        let application = NSApplication.shared
        let delegate = TargetDelegate(directory: directory)
        application.setActivationPolicy(.regular); application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
