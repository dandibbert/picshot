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
        else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" { controller?.undo() }
        else { super.keyDown(with: event) }
    }
}

@MainActor
struct RecordingEffectsControls: View {
    @ObservedObject var camera: RecordingCameraController
    @ObservedObject var overlay: RecordingOverlayController
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
