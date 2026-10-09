import AppKit
import Combine
import CoreImage
import SwiftUI

/// Transparent, PicShot-excluded surface used only for interaction and preview.
/// The writer draws the same vector state into every accepted output frame.
@MainActor
final class RecordingOverlayController: ObservableObject {
    @Published var drawing = false { didSet { updateInteraction() } }
    @Published var cameraEditing = false { didSet { updateInteraction() } }
    @Published var tool: ImageEditorTool = .freehand
    @Published var color = NSColor.systemRed
    @Published var width: CGFloat = 5
    @Published private(set) var annotationCount = 0
    @Published private(set) var limitMessage: String?
    private(set) var state: RecordingCompositionState
    private var window: RecordingOverlayPanel?
    private var surface: RecordingOverlayView?
    private var timer: Timer?
    private var annotations: [ImageAnnotation] = []
    private var draft: ImageAnnotation?
    private var undoStack: [[ImageAnnotation]] = []
    private var cameraDragOrigin: CGPoint?
    private var cameraDragFrame: CGRect?
    private var resizingCamera = false

    init(state: RecordingCompositionState) { self.state = state }

    func show(frame: CGRect, canvasSize: CGSize) {
        hide()
        annotations.removeAll(); undoStack.removeAll(); draft = nil
        annotationCount = 0; limitMessage = nil
        state.setCanvasSize(canvasSize)
        let panel = RecordingOverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        let view = RecordingOverlayView(frame: CGRect(origin: .zero, size: frame.size), controller: self)
        panel.contentView = view; surface = view; window = panel
        updateInteraction(); panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak view] _ in
            Task { @MainActor in view?.needsDisplay = true }
        }
    }

    func hide() {
        timer?.invalidate(); timer = nil
        window?.orderOut(nil); window?.close(); window = nil; surface = nil
        drawing = false; cameraEditing = false
        draft = nil; cameraDragOrigin = nil; cameraDragFrame = nil
    }

    private func updateInteraction() {
        window?.ignoresMouseEvents = !drawing && !cameraEditing
        if drawing || cameraEditing { window?.makeKey(); window?.makeFirstResponder(surface) }
        surface?.needsDisplay = true
    }

    func cancelInteraction() {
        draft = nil; publish()
        cameraDragOrigin = nil; cameraDragFrame = nil
        drawing = false; cameraEditing = false
    }

    func clear() {
        guard !annotations.isEmpty || draft != nil else { return }
        rememberUndo(); annotations.removeAll(); draft = nil; limitMessage = nil; publish()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        annotations = previous; draft = nil; limitMessage = nil; publish()
    }

    private func rememberUndo() {
        // Bounded vector-only undo. Never save a screen/camera image in history.
        if undoStack.count == 8 { undoStack.removeFirst() }
        undoStack.append(annotations)
    }

    private func publish() {
        var current = annotations
        if let draft { current.append(draft) }
        if state.setAnnotations(current) { annotationCount = annotations.count; surface?.needsDisplay = true }
    }

    func begin(at point: CGPoint, resizeCamera: Bool) {
        limitMessage = nil
        if cameraEditing {
            let snapshot = state.snapshot()
            let normalized = CGPoint(x: point.x / snapshot.canvasSize.width, y: point.y / snapshot.canvasSize.height)
            guard snapshot.cameraLayout.frame.insetBy(dx: -0.025, dy: -0.025).contains(normalized) else { return }
            cameraDragOrigin = normalized; cameraDragFrame = snapshot.cameraLayout.frame
            resizingCamera = resizeCamera || hypot(normalized.x - snapshot.cameraLayout.frame.maxX,
                normalized.y - snapshot.cameraLayout.frame.minY) < 0.04
            return
        }
        guard drawing, annotations.count < RecordingCompositionState.maximumAnnotations else {
            limitMessage = "已达 256 条标注；请撤销或清空后继续。"; return
        }
        draft = ImageAnnotation(tool: tool, points: [point, point], color: color.cgColor, lineWidth: width)
        publish()
    }

    func drag(to point: CGPoint) {
        if let origin = cameraDragOrigin, let initial = cameraDragFrame {
            var layout = state.snapshot().cameraLayout
            let size = state.snapshot().canvasSize
            let delta = CGPoint(x: point.x / size.width - origin.x, y: point.y / size.height - origin.y)
            if resizingCamera {
                layout.frame = CGRect(x: initial.minX, y: initial.minY + delta.y,
                    width: initial.width + delta.x, height: initial.height - delta.y)
            } else { layout.frame = initial.offsetBy(dx: delta.x, dy: delta.y) }
            state.setLayout(layout); surface?.needsDisplay = true
            return
        }
        guard var current = draft else { return }
        if current.tool == .freehand || current.tool == .eraser {
            guard current.points.count < RecordingCompositionState.maximumPointsPerStroke else {
                limitMessage = "此笔画已达长度限制；松开鼠标后可继续下一笔。"; return
            }
            current.points.append(point)
        } else { current.points = [current.points[0], point] }
        draft = current; publish()
    }

    func end(at point: CGPoint) {
        drag(to: point)
        if let draft {
            rememberUndo(); annotations.append(draft); self.draft = nil; publish()
        }
        cameraDragOrigin = nil; cameraDragFrame = nil
    }

    func setCameraScale(_ scale: CGFloat) {
        var layout = state.snapshot().cameraLayout
        let center = CGPoint(x: layout.frame.midX, y: layout.frame.midY)
        layout.frame.size = CGSize(width: scale, height: scale * 1.2)
        layout.frame.origin = CGPoint(x: center.x - layout.frame.width / 2, y: center.y - layout.frame.height / 2)
        state.setLayout(layout)
    }

    func setCameraCrop(zoom: CGFloat, horizontal: CGFloat, vertical: CGFloat) {
        var layout = state.snapshot().cameraLayout
        let side = 1 / max(1, zoom)
        layout.crop = CGRect(x: horizontal * (1 - side), y: vertical * (1 - side), width: side, height: side)
        state.setLayout(layout)
    }
}

private final class RecordingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class RecordingOverlayView: NSView {
    private weak var controller: RecordingOverlayController?
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    init(frame: CGRect, controller: RecordingOverlayController) { self.controller = controller; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller, let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        let snapshot = controller.state.snapshot()
        RecordingFrameCompositor.drawCamera(snapshot, context: context, size: bounds.size, imageContext: imageContext)
        context.saveGState()
        context.scaleBy(x: bounds.width / snapshot.canvasSize.width, y: bounds.height / snapshot.canvasSize.height)
        let complete = ImageEditorRenderer.drawAnnotations(snapshot.annotations, in: context,
            extent: CGRect(origin: .zero, size: snapshot.canvasSize))
        if complete {
            RecordingInputEffectsRenderer.draw(snapshot.inputEffects, in: context, size: snapshot.canvasSize)
        }
        context.restoreGState()
        guard complete else { context.clear(bounds); return }
        if controller.cameraEditing {
            let rect = snapshot.cameraLayout.pixelFrame(in: bounds.size)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(2)
            context.stroke(rect)
            context.setFillColor(NSColor.controlAccentColor.cgColor)
            context.fill(CGRect(x: rect.maxX - 6, y: rect.minY - 6, width: 12, height: 12))
        }
    }

    private func canvasPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let size = controller?.state.snapshot().canvasSize ?? bounds.size
        return CGPoint(x: min(size.width, max(0, point.x / max(1, bounds.width) * size.width)),
                       y: min(size.height, max(0, point.y / max(1, bounds.height) * size.height)))
    }
    override func mouseDown(with event: NSEvent) { controller?.begin(at: canvasPoint(event), resizeCamera: event.modifierFlags.contains(.shift)) }
    override func mouseDragged(with event: NSEvent) { controller?.drag(to: canvasPoint(event)) }
    override func mouseUp(with event: NSEvent) { controller?.end(at: canvasPoint(event)) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { controller?.cancelInteraction() }
        else if event.modifierFlags.contains(.command), event.keyCode == 6 { controller?.undo() }
        else { super.keyDown(with: event) }
    }
}

@MainActor
struct RecordingEffectsControls: View {
    @ObservedObject var camera: RecordingCameraController
    @ObservedObject var overlay: RecordingOverlayController
    @ObservedObject var inputMonitor: RecordingInputMonitor
    let isRecording: Bool
    @State private var settings = false
    @State private var mirror = true
    @State private var circle = false
    @State private var scale = 0.23
    @State private var zoom = 1.0
    @State private var cropX = 0.5
    @State private var cropY = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("摄像头", isOn: Binding(get: { camera.requested }, set: { enabled in
                    Task { if enabled { await camera.enable() } else { await camera.disable() } }
                }))
                Button { settings.toggle() } label: { Image(systemName: "camera.aperture") }
                    .help("摄像头选择、裁剪与镜像")
                    .popover(isPresented: $settings) { cameraSettings }
                if isRecording {
                    Toggle("标注", isOn: $overlay.drawing).onChange(of: overlay.drawing) { _, value in
                        if value { overlay.cameraEditing = false }
                    }
                    Button("撤销") { overlay.undo() }.disabled(overlay.annotationCount == 0)
                    Button("清空") { overlay.clear() }.disabled(overlay.annotationCount == 0)
                }
            }
            RecordingInputEffectsControls(monitor: inputMonitor)
            if isRecording, overlay.drawing {
                HStack(spacing: 6) {
                    Picker("工具", selection: $overlay.tool) {
                        ForEach([ImageEditorTool.freehand, .arrow, .rectangle, .ellipse, .highlighter, .eraser], id: \.self) {
                            Text($0.title).tag($0)
                        }
                    }.labelsHidden().frame(width: 82)
                    ColorPicker("颜色", selection: Binding(get: { Color(nsColor: overlay.color) },
                        set: { overlay.color = NSColor($0) })).labelsHidden().frame(width: 28)
                    Slider(value: $overlay.width, in: 2...40).frame(width: 90)
                    Text("Esc 返回操作").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if let limit = overlay.limitMessage {
                Text(limit).font(.system(size: 10)).foregroundStyle(.orange)
            }
            if camera.status != .off {
                Text(camera.status.message).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var cameraSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("摄像头", selection: $camera.selectedID) {
                ForEach(camera.devices) { Text($0.name).tag($0.id) }
            }.onChange(of: camera.selectedID) { old, new in
                if old != new, camera.requested { Task { await camera.enable() } }
            }
            Button("刷新设备") { Task { await camera.refreshDevices() } }
            Toggle("镜像", isOn: $mirror).onChange(of: mirror) { _, value in
                var layout = overlay.state.snapshot().cameraLayout; layout.mirrored = value; overlay.state.setLayout(layout)
            }
            Toggle("椭圆裁剪", isOn: $circle).onChange(of: circle) { _, value in
                var layout = overlay.state.snapshot().cameraLayout; layout.circular = value; overlay.state.setLayout(layout)
            }
            HStack { Text("大小"); Slider(value: $scale, in: 0.1...0.5) }
                .onChange(of: scale) { _, value in overlay.setCameraScale(value) }
            HStack { Text("裁剪放大"); Slider(value: $zoom, in: 1...4) }.onChange(of: zoom) { _, _ in updateCrop() }
            HStack { Text("裁剪横移"); Slider(value: $cropX, in: 0...1) }.onChange(of: cropX) { _, _ in updateCrop() }
            HStack { Text("裁剪纵移"); Slider(value: $cropY, in: 0...1) }.onChange(of: cropY) { _, _ in updateCrop() }
            if isRecording {
                Toggle("拖动画中画位置 / 右下角缩放", isOn: $overlay.cameraEditing)
                    .onChange(of: overlay.cameraEditing) { _, value in if value { overlay.drawing = false } }
            }
            Text("画中画和标注会写入视频。Esc 退出拖动或绘画。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(14).frame(width: 300).task { await camera.refreshDevices() }
    }
    private func updateCrop() { overlay.setCameraCrop(zoom: zoom, horizontal: cropX, vertical: cropY) }
}


/// In-memory settings default off and are never persisted as background capture. Opening instructions or checking
/// current authorization never invokes an OS permission request or grants access.
@MainActor
struct RecordingInputEffectsControls: View {
    @ObservedObject var monitor: RecordingInputMonitor
    @State private var showsHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("输入提示").font(.system(size: 11)).foregroundStyle(.secondary)
                RecordingInputCheckbox(title: "点击", identifier: "recording-input-clicks", isOn: $monitor.options.clicks)
                RecordingInputCheckbox(title: "滚动", identifier: "recording-input-scrolls", isOn: $monitor.options.scrolls)
                RecordingInputCheckbox(title: "快捷键", identifier: "recording-input-shortcuts", isOn: $monitor.options.shortcuts)
                RecordingInputActionButton(title: "输入提示的隐私和权限说明", identifier: "recording-input-help",
                                           systemImage: "info.circle") {
                    monitor.refreshPermissions(); showsHelp.toggle()
                }
                .help("输入提示的隐私和权限说明")
                .popover(isPresented: $showsHelp) { privacyHelp }
            }.controlSize(.small)
            if monitor.options.isEnabled {
                RecordingInputStatusLabel(text: status)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var status: String {
        if !monitor.permissions.inputMonitoring { return "输入提示未启用：请在系统设置中检查「输入监控」权限。" }
        if monitor.options.shortcuts, !monitor.permissions.accessibility {
            return "快捷键提示未启用：需「辅助功能」权限；已开启的点击 / 滚动可单独使用。"
        }
        if monitor.installationFailed { return "输入提示监听未能启动；请检查权限后点击「重新检查」。" }
        if monitor.privacySuppressed { return "安全输入或无法确认的焦点：键盘提示已隐藏。" }
        return monitor.isMonitoring ? "提示会写入视频；只显示 ⌘ / ⌃ 组合，不读取输入文字。" : "开始 / 继续录制后生效；暂停会清空提示。"
    }

    private var privacyHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("输入提示默认关闭").font(.headline)
            Text("点击、滚动和快捷键提示会写入视频。PicShot 自己的窗口操作不会产生提示。")
            Text("快捷键只用按键位置和 ⌘ / ⌃ 组合生成固定名称；不读取普通输入、剪贴板或控件文字。键名按固定键位标识，不随输入法变化。")
            Text("检测到安全键盘输入、安全文本框或无法确认的焦点时，快捷键提示会隐藏。应用可能未正确标记敏感字段，无法保证识别所有密码框；输入敏感信息前请关闭提示或暂停录制。")
            Text("输入监控：\(monitor.permissions.inputMonitoring ? "已允许" : "未允许") · 辅助功能：\(monitor.permissions.accessibility ? "已允许" : "未允许")")
            Text("如需使用，请自行前往「系统设置 → 隐私与安全性 → 输入监控」允许 PicShot；快捷键还需「辅助功能」。完成后点击重新检查，必要时重新打开 PicShot。")
            HStack {
                Button("打开系统设置") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
                        NSWorkspace.shared.open(url)
                    }
                }
                RecordingInputActionButton(title: "重新检查", identifier: "recording-input-refresh") {
                    monitor.refreshPermissions()
                }
            }
        }
        .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        .padding(14).frame(width: 345)
    }
}


/// The input row uses real AppKit controls so mouse/keyboard, accessibility and
/// the owned preview fixture all exercise the same native target/action path.
/// SwiftUI can reuse a representable across model changes: refresh both the
/// binding/action and native state in updateNSView, including inherited disable.
@MainActor
struct RecordingInputCheckbox: NSViewRepresentable {
    let title: String
    let identifier: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(isOn: $isOn) }

    func makeNSView(context: Context) -> NSButton {
        let button = RecordingInputNativeButton(checkboxWithTitle: title, target: context.coordinator,
                              action: #selector(Coordinator.toggle(_:)))
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.isOn = $isOn
        button.title = title
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(title)
        button.state = isOn ? .on : .off
        button.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    @MainActor final class Coordinator: NSObject {
        var isOn: Binding<Bool>
        init(isOn: Binding<Bool>) { self.isOn = isOn }
        @objc func toggle(_ sender: NSButton) { isOn.wrappedValue = sender.state == .on }
    }
}

@MainActor
struct RecordingInputActionButton: NSViewRepresentable {
    let title: String
    let identifier: String
    var systemImage: String? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = RecordingInputNativeButton(title: title, target: context.coordinator,
                              action: #selector(Coordinator.press(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = title
        button.image = systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) }
        button.imagePosition = systemImage == nil ? .noImage : .imageOnly
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(title)
        button.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func press(_ sender: NSButton) { action() }
    }
}

@MainActor
private struct RecordingInputStatusLabel: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextField {
        let label = RecordingInputNativeStatusField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        label.identifier = NSUserInterfaceItemIdentifier("recording-input-status")
        label.setAccessibilityIdentifier("recording-input-status")
        return label
    }

    func updateNSView(_ label: NSTextField, context: Context) { label.stringValue = text }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? nsView.intrinsicContentSize.width)
        // Ask the actual native cell for its wrapping height, preserving the
        // compact row while allowing permission guidance to occupy two lines.
        let size = nsView.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size?.height ?? nsView.intrinsicContentSize.height))
    }
}


/// SwiftUI positions representables by their AppKit alignment rectangles. Native
/// ornament insets must not expand the real control frame into the next row:
/// these compact input controls reserve their complete drawing/hit-test bounds.
/// This changes layout allocation, never the frame used by fixture validation.
@MainActor
private final class RecordingInputNativeButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override func alignmentRect(forFrame frame: NSRect) -> NSRect { frame }
    override func frame(forAlignmentRect alignmentRect: NSRect) -> NSRect { alignmentRect }
}

@MainActor
private final class RecordingInputNativeStatusField: NSTextField {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override func alignmentRect(forFrame frame: NSRect) -> NSRect { frame }
    override func frame(forAlignmentRect alignmentRect: NSRect) -> NSRect { alignmentRect }
}
