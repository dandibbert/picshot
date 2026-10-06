import AppKit

@MainActor final class PinController: NSWindowController, NSWindowDelegate {
    let image: CGImage
    var onClose: (() -> Void)?
    private let imageView = NSImageView()
    private var locked = false
    init(image: CGImage) {
        self.image = image
        let scale = min(1, 680 / CGFloat(max(image.width, image.height)))
        let size = NSSize(width: max(180, CGFloat(image.width) * scale), height: max(120, CGFloat(image.height) * scale) + 36)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled,.closable,.resizable,.utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = "贴图 · \(image.width) × \(image.height)"; panel.level = .floating; panel.isReleasedWhenClosed = false; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.delegate = self
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]; panel.center()
        imageView.image = image.nsImage; imageView.imageScaling = .scaleProportionallyUpOrDown
        let opacity = NSSlider(value: 1, minValue: 0.15, maxValue: 1, target: self, action: #selector(changeOpacity(_:))); opacity.toolTip = "不透明度"
        let copy = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制")!, target: self, action: #selector(copyPin)); copy.bezelStyle = .texturedRounded
        let lock = NSButton(image: NSImage(systemSymbolName: "lock", accessibilityDescription: "锁定")!, target: self, action: #selector(toggleLock)); lock.bezelStyle = .texturedRounded
        let through = NSButton(image: NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "鼠标穿透")!, target: self, action: #selector(clickThrough)); through.bezelStyle = .texturedRounded
        through.toolTip = "鼠标穿透。通过菜单栏「恢复所有贴图」恢复操作"
        let bar = NSStackView(views: [copy, lock, through, opacity]); bar.orientation = .horizontal; bar.spacing = 6; bar.edgeInsets = NSEdgeInsets(top:4,left:8,bottom:4,right:8)
        let root = NSView(); root.addSubview(imageView); root.addSubview(bar); panel.contentView = root
        imageView.translatesAutoresizingMaskIntoConstraints = false; bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([imageView.topAnchor.constraint(equalTo: root.topAnchor),imageView.leadingAnchor.constraint(equalTo: root.leadingAnchor),imageView.trailingAnchor.constraint(equalTo: root.trailingAnchor),imageView.bottomAnchor.constraint(equalTo: bar.topAnchor),bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),bar.heightAnchor.constraint(equalToConstant:36),opacity.widthAnchor.constraint(greaterThanOrEqualToConstant:60)])
        let menu = NSMenu(); menu.addItem(withTitle:"复制图片",action:#selector(copyPin),keyEquivalent:"").target = self; menu.addItem(withTitle:"原始尺寸",action:#selector(resetSize),keyEquivalent:"").target = self; menu.addItem(withTitle:"关闭贴图",action:#selector(closePin),keyEquivalent:"").target = self; imageView.menu = menu
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func copyPin(){ copyImage(image) }
    @objc private func changeOpacity(_ sender:NSSlider){ window?.alphaValue = sender.doubleValue }
    @objc private func toggleLock(){ locked.toggle(); window?.isMovable = !locked; if locked {window?.styleMask.remove(.resizable)} else {window?.styleMask.insert(.resizable)} }
    @objc private func clickThrough(){ window?.ignoresMouseEvents = true }
    @objc private func resetSize(){ let s=NSScreen.main?.visibleFrame.size ?? NSSize(width:1000,height:700); let scale=min(1,min(s.width/CGFloat(image.width),s.height/CGFloat(image.height))); window?.setContentSize(NSSize(width:max(180,CGFloat(image.width)*scale),height:max(120,CGFloat(image.height)*scale)+36)) }
    @objc private func closePin(){ close() }
    func restore(){ window?.ignoresMouseEvents=false; window?.alphaValue=1; window?.center(); showWindow(nil) }
    func windowWillClose(_ notification:Notification){ onClose?() }
}
