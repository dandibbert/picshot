import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import PicShotCodecCore

@MainActor
final class RecordingPreviewController: NSWindowController, NSWindowDelegate {
    let model: RecordingPreviewModel
    var onClose: (() -> Void)?
    private var closed = false

    init(url: URL) {
        model = RecordingPreviewModel(url: url)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Recording Preview · \(url.lastPathComponent)"
        window.representedURL = url
        window.minSize = NSSize(width: 760, height: 640)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: RecordingPreviewView(model: model) { [weak self] kind in
            guard let self, let window = self.window else { return }
            self.model.chooseExport(kind: kind, window: window)
        })
        window.center()
        model.load()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        model.close()
        let completion = onClose
        onClose = nil
        // AppKit may cache a closed window. Detach the hosting view so that its
        // AVPlayerView/model graph does not outlive the user's preview window.
        let closingWindow = notification.object as? NSWindow ?? window
        closingWindow?.makeFirstResponder(nil)
        closingWindow?.contentView = nil
        closingWindow?.delegate = nil
        completion?()
    }
}

enum RecordingPreviewExportKind: Equatable, Sendable { case mp4, gif, webp }

/// Holds no decoded frame collection. AVPlayer handles streaming decode and
/// AVFoundation time observers are paired with removal, including deinit.
private final class RecordingPlaybackResources {
    let player = AVPlayer()
    var timeObserver: Any?
    var endObserver: NSObjectProtocol?
    var itemObservation: NSKeyValueObservation?

    func release() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        itemObservation?.invalidate()
        itemObservation = nil
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
    }

    deinit { release() }
}

@MainActor
final class RecordingPreviewModel: ObservableObject {
    static let gifOptions = GIFExportOptions(frameRate: 12, maximumDimension: 1_280, maximumDuration: 30, maximumFrames: 360)
    let url: URL
    private let playback = RecordingPlaybackResources()
    var player: AVPlayer { playback.player }
    @Published private(set) var duration: Double = 0
    @Published private(set) var position: Double = 0
    @Published private(set) var start: Double = 0
    @Published private(set) var end: Double = 0
    @Published var startText = "0.000000"
    @Published var endText = "0.000000"
    @Published private(set) var ready = false
    @Published private(set) var playing = false
    @Published private(set) var selectingDestination = false
    @Published private(set) var exporting = false
    @Published private(set) var cancelling = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = "Loading recording…"
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastExportURL: URL?
    @Published var webpFrameRate = 15
    @Published var webpMaximumDimension = 1_280
    @Published var webpQuality = 80
    @Published var webpLossless = false
    var webpOptions: CodecExportRequest {
        CodecExportRequest(kind: .animation, format: .webp, quality: webpQuality,
            lossless: webpLossless, preserveAlpha: true,
            animation: CodecAnimationOptions(frameRate: webpFrameRate, maximumDimension: webpMaximumDimension))
    }
    @Published var speed: Float = 1 { didSet { if playing { player.rate = speed } } }
    @Published var volume: Double = 1 { didSet { player.volume = Float(min(1, max(0, volume))) } }
    private(set) var closed = false
    private var nominalFrameDuration: Double = 1.0 / 30
    private var loadTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var exportID: UUID?
    private var savePanel: NSSavePanel?
    private var seekID = 0
    private var seeking = false

    init(url: URL) { self.url = url }

    var canEdit: Bool { ready && !closed && !exporting && !selectingDestination }
    var canStepBackward: Bool { canEdit && !seeking && player.currentItem?.canStepBackward == true }
    var canStepForward: Bool { canEdit && !seeking && player.currentItem?.canStepForward == true }
    var selectionDuration: Double { max(0, end - start) }
    var selection: VideoTrimRange? { try? VideoTrimRange(start: start, end: end, sourceDuration: duration) }

    func load() {
        guard loadTask == nil, !closed else { return }
        let sourceURL = url
        loadTask = Task { [weak self] in
            do {
                let asset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                let duration = try await asset.load(.duration).seconds
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first, duration.isFinite, duration > 0,
                      try await asset.load(.isPlayable) else { throw VideoTrimError.noVideo }
                let frameRate = try await track.load(.nominalFrameRate)
                try Task.checkCancellation()
                guard let self, !self.closed else { return }
                self.duration = duration
                self.nominalFrameDuration = frameRate > 0 ? 1 / Double(frameRate) : 1.0 / 30
                self.setRange(start: 0, end: duration)
                self.installPlayer(asset: asset)
            } catch is CancellationError {
                // Closing a preview is intentionally quiet.
            } catch {
                guard let self, !self.closed else { return }
                self.errorMessage = error.localizedDescription
                self.status = "The original recording has not been changed."
            }
        }
    }

    private func installPlayer(asset: AVAsset) {
        let item = AVPlayerItem(asset: asset)
        player.actionAtItemEnd = .pause
        player.replaceCurrentItem(with: item)
        playback.itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                if item.status == .readyToPlay {
                    self.ready = true
                    self.status = "Original preserved. Exports use the selected in/out range."
                } else if item.status == .failed {
                    self.ready = false
                    self.errorMessage = item.error?.localizedDescription ?? VideoTrimError.noVideo.localizedDescription
                }
            }
        }
        playback.timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                if !self.seeking, time.seconds.isFinite { self.position = min(self.duration, max(0, time.seconds)) }
                self.playing = self.player.rate != 0
            }
        }
        playback.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                                       object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                self.playing = false
            }
        }
    }

    func togglePlayback() {
        guard canEdit else { return }
        if playing || seeking { pause(); return }
        player.currentItem?.forwardPlaybackEndTime = .invalid
        if position >= duration - 0.001 { seek(to: 0, resume: true) }
        else { player.playImmediately(atRate: speed); playing = true }
    }

    func pause() {
        // Invalidate pending seek completions before cancelling them, so a
        // delayed "play selection" callback cannot restart a paused/exporting UI.
        seekID += 1
        seeking = false
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        playing = false
    }

    func seek(to seconds: Double, resume: Bool = false) {
        guard ready, !closed, seconds.isFinite else { return }
        pause()
        position = min(duration, max(0, seconds))
        seeking = true
        seekID += 1
        let id = seekID
        let time = CMTime(seconds: position, preferredTimescale: VideoTrimRange.timescale)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, !self.closed, self.seekID == id else { return }
                self.seeking = false
                if finished, self.player.currentTime().seconds.isFinite {
                    self.position = min(self.duration, max(0, self.player.currentTime().seconds))
                }
                if finished, resume, self.canEdit { self.player.playImmediately(atRate: self.speed); self.playing = true }
            }
        }
    }

    func step(by count: Int) {
        guard (count == -1 ? canStepBackward : canStepForward) else { return }
        pause()
        player.currentItem?.forwardPlaybackEndTime = .invalid
        // AVPlayerItem steps by actual decoded samples, including variable FPS.
        player.currentItem?.step(byCount: count)
    }

    func markStart() {
        guard canEdit, !seeking else { return }
        pause()
        let time = player.currentTime().seconds
        guard time.isFinite else { return }
        guard let range = try? VideoTrimRange(start: max(0, time), end: end, sourceDuration: duration) else {
            errorMessage = "Move the playhead before the selected out point."
            return
        }
        setRange(start: range.start, end: range.end)
    }

    func markEnd() {
        guard canEdit, !seeking else { return }
        pause()
        let time = player.currentTime().seconds
        guard time.isFinite else { return }
        guard let range = try? VideoTrimRange(start: start, end: min(duration, time), sourceDuration: duration) else {
            errorMessage = "Move the playhead after the selected in point."
            return
        }
        setRange(start: range.start, end: range.end)
    }

    private var minimumSelectionDuration: Double { min(nominalFrameDuration, duration) }

    func moveStart(to seconds: Double) {
        guard canEdit else { return }
        setRange(start: min(max(0, seconds), max(0, end - minimumSelectionDuration)), end: end)
        seek(to: start)
    }

    func moveEnd(to seconds: Double) {
        guard canEdit else { return }
        setRange(start: start, end: max(min(duration, seconds), min(duration, start + minimumSelectionDuration)))
        seek(to: end)
    }

    func resetSelection() {
        guard canEdit else { return }
        setRange(start: 0, end: duration)
        player.currentItem?.forwardPlaybackEndTime = .invalid
    }

    @discardableResult
    func applyRangeFields() -> Bool {
        // Unedited fields are presentation only; preserve sample-exact mark times.
        let proposedStart = startText == Self.editTime(start) ? start : Double(startText.trimmingCharacters(in: .whitespacesAndNewlines))
        let proposedEnd = endText == Self.editTime(end) ? end : Double(endText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let proposedStart, let proposedEnd,
              let range = try? VideoTrimRange(start: proposedStart, end: proposedEnd, sourceDuration: duration) else {
            errorMessage = VideoTrimError.invalidRange.localizedDescription
            return false
        }
        setRange(start: range.start, end: range.end)
        return true
    }

    private func setRange(start: Double, end: Double) {
        self.start = start
        self.end = end
        startText = Self.editTime(start)
        endText = Self.editTime(end)
        errorMessage = nil
    }

    func playSelection() {
        guard canEdit, applyRangeFields(), let selection else { return }
        player.currentItem?.forwardPlaybackEndTime = selection.timeRange.end
        seek(to: selection.start, resume: true)
    }

    func chooseExport(kind: RecordingPreviewExportKind, window: NSWindow) {
        guard canEdit, applyRangeFields(), let range = selection else { return }
        if kind == .gif, range.duration > Self.gifOptions.maximumDuration {
            errorMessage = "GIF export supports at most 30 seconds. Shorten the selected range first."
            return
        }
        if kind == .webp, range.duration > CodecExportLimits.animationDuration {
            errorMessage = VideoTrimError.webpDurationLimit(CodecExportLimits.animationDuration).localizedDescription
            return
        }
        pause()
        let panel = NSSavePanel()
        switch kind {
        case .mp4: panel.allowedContentTypes = [.mpeg4Movie]
        case .gif: panel.allowedContentTypes = [.gif]
        case .webp: panel.allowedContentTypes = [ImageExportFormat.webp.contentType]
        }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "-trimmed." + (kind == .mp4 ? "mp4" : kind == .gif ? "gif" : "webp")
        panel.directoryURL = url.deletingLastPathComponent()
        panel.message = "Save a separate clip. The original recording is kept."
        savePanel = panel
        selectingDestination = true
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self else { return }
            let selectedURL = panel?.url
            self.selectingDestination = false
            self.savePanel = nil
            guard !self.closed, response == .OK, let destinationURL = selectedURL else { return }
            do {
                // NSSavePanel supplies the native Replace/Cancel confirmation.
                // Capture the confirmed file identity before asynchronous work.
                let destination = try VideoExportDestination(url: destinationURL, preserving: self.url,
                    overwriteConfirmed: FileManager.default.fileExists(atPath: destinationURL.path))
                self.beginExport(kind: kind, range: range, destination: destination)
            } catch { self.errorMessage = error.localizedDescription }
        }
    }

    private func beginExport(kind: RecordingPreviewExportKind, range: VideoTrimRange, destination: VideoExportDestination) {
        guard !closed, !exporting else { return }
        exporting = true
        cancelling = false
        progress = 0
        errorMessage = nil
        lastExportURL = nil
        switch kind {
        case .mp4: status = "Exporting selected MP4…"
        case .gif: status = "Preparing selected clip for GIF…"
        case .webp: status = "Preparing selected clip for animated WebP…"
        }
        let id = UUID()
        exportID = id
        let sourceURL = url
        let webpOptions = self.webpOptions
        exportTask = Task { [weak self] in
            let report: @Sendable (Double) -> Void = { [weak self] value in
                Task { @MainActor [weak self] in
                    guard let self, !self.closed, self.exportID == id else { return }
                    self.progress = max(self.progress, min(1, value))
                }
            }
            do {
                let result: URL
                switch kind {
                case .mp4:
                    result = try await VideoTrimExporter.export(sourceURL: sourceURL, destination: destination, range: range, progress: report)
                case .gif:
                    result = try await VideoTrimExporter.exportGIF(sourceURL: sourceURL, destination: destination,
                        range: range, options: Self.gifOptions, progress: report)
                case .webp:
                    result = try await VideoTrimExporter.exportWebP(sourceURL: sourceURL, destination: destination,
                        range: range, options: webpOptions, progress: report)
                }
                guard let self, !self.closed, self.exportID == id else { return }
                self.progress = 1
                self.lastExportURL = result
                self.status = "Saved \(result.lastPathComponent). Original recording preserved."
                self.finishExport(id)
            } catch {
                guard let self, !self.closed, self.exportID == id else { return }
                if error is CancellationError { self.status = "Export cancelled. Original recording preserved." }
                else { self.errorMessage = error.localizedDescription; self.status = "Export was not saved." }
                self.finishExport(id)
            }
        }
    }

    private func finishExport(_ id: UUID) {
        guard exportID == id else { return }
        exporting = false
        cancelling = false
        exportID = nil
        exportTask = nil
    }

    func cancelExport() {
        guard exporting, !cancelling else { return }
        cancelling = true
        status = "Cancelling export…"
        exportTask?.cancel()
    }

    func close() {
        guard !closed else { return }
        closed = true
        ready = false
        loadTask?.cancel()
        loadTask = nil
        exportTask?.cancel()
        exportTask = nil
        exportID = nil
        savePanel?.cancel(nil)
        savePanel = nil
        playback.release()
        playing = false
    }

    deinit { loadTask?.cancel(); exportTask?.cancel() }

    static func editTime(_ seconds: Double) -> String { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), seconds) }
    static func displayTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00.000" }
        let milliseconds = Int((seconds * 1_000).rounded())
        return String(format: "%02d:%02d.%03d", milliseconds / 60_000, (milliseconds / 1_000) % 60, milliseconds % 1_000)
    }
}

@MainActor
private struct RecordingPlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) { nsView.player = player }
    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) { nsView.player = nil }
}

@MainActor
private struct RecordingPreviewView: View {
    @ObservedObject var model: RecordingPreviewModel
    let export: (RecordingPreviewExportKind) -> Void
    private var timeline: ClosedRange<Double> { 0...max(0.001, model.duration) }

    var body: some View {
        VStack(spacing: 12) {
            RecordingPlayerView(player: model.player)
                .frame(minHeight: 220).background(Color.black)
            ScrollView {
                VStack(spacing: 12) {
                    HStack {
                        Button(action: model.togglePlayback) {
                            Label(model.playing ? "Pause" : "Play", systemImage: model.playing ? "pause.fill" : "play.fill")
                        }.disabled(!model.canEdit)
                        Button("Previous frame") { model.step(by: -1) }.disabled(!model.canStepBackward)
                        Button("Next frame") { model.step(by: 1) }.disabled(!model.canStepForward)
                        Text(RecordingPreviewModel.displayTime(model.position) + " / " + RecordingPreviewModel.displayTime(model.duration))
                            .monospacedDigit()
                        Spacer()
                    }
                    Slider(value: Binding(get: { model.position }, set: { model.seek(to: $0) }), in: timeline)
                        .disabled(!model.canEdit).accessibilityLabel("Recording playhead")
                    HStack {
                        Text("Playback speed")
                        Picker("Playback speed", selection: $model.speed) {
                            Text("0.25×").tag(Float(0.25)); Text("0.5×").tag(Float(0.5)); Text("1×").tag(Float(1))
                            Text("1.5×").tag(Float(1.5)); Text("2×").tag(Float(2))
                        }.labelsHidden().frame(width: 90)
                        Text("Volume")
                        Slider(value: $model.volume, in: 0...1).frame(width: 110).accessibilityLabel("Playback volume")
                        Spacer()
                        Text("Speed and volume affect preview only").font(.caption).foregroundStyle(.secondary)
                    }.disabled(!model.canEdit)
                    Divider()
                    HStack {
                        Text("In (seconds)").frame(width: 88, alignment: .leading)
                        TextField("Start", text: $model.startText).frame(width: 110).monospacedDigit().onSubmit { model.applyRangeFields() }
                        Slider(value: Binding(get: { model.start }, set: { model.moveStart(to: $0) }), in: timeline)
                            .accessibilityLabel("Selection start")
                        Button("Set at playhead", action: model.markStart)
                    }.disabled(!model.canEdit)
                    HStack {
                        Text("Out (seconds)").frame(width: 88, alignment: .leading)
                        TextField("End", text: $model.endText).frame(width: 110).monospacedDigit().onSubmit { model.applyRangeFields() }
                        Slider(value: Binding(get: { model.end }, set: { model.moveEnd(to: $0) }), in: timeline)
                            .accessibilityLabel("Selection end")
                        Button("Set at playhead", action: model.markEnd)
                    }.disabled(!model.canEdit)
                    HStack {
                        Text("Selected: " + RecordingPreviewModel.displayTime(model.selectionDuration)).monospacedDigit()
                        Button("Play selection", action: model.playSelection).disabled(!model.canEdit)
                        Button("Reset range", action: model.resetSelection).disabled(!model.canEdit)
                        Spacer()
                        Button("Export MP4…") { export(.mp4) }.disabled(!model.canEdit)
                        Button("Export GIF…") { export(.gif) }.disabled(!model.canEdit)
                    }
                    Text("GIF: selected range ≤30 seconds · 12 FPS · ≤360 frames · ≤1280 px · ≤64 MiB · no audio")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Text("WebP")
                        Picker("WebP frame rate", selection: $model.webpFrameRate) {
                            ForEach([10, 12, 15, 24, 30], id: \.self) { Text("\($0) FPS").tag($0) }
                        }.labelsHidden().frame(width: 90)
                        Picker("WebP maximum dimension", selection: $model.webpMaximumDimension) {
                            ForEach([640, 1_280, 1_920], id: \.self) { Text("\($0) px").tag($0) }
                        }.labelsHidden().frame(width: 100)
                        Toggle("Lossless", isOn: $model.webpLossless).toggleStyle(.checkbox)
                        Picker("WebP quality", selection: $model.webpQuality) {
                            ForEach([60, 80, 95], id: \.self) { Text("Q \($0)").tag($0) }
                        }.labelsHidden().frame(width: 80).disabled(model.webpLossless)
                        Spacer(minLength: 0)
                        Button("Export WebP…") { export(.webp) }
                    }.disabled(!model.canEdit)
                    Text("WebP: ≤60 seconds · ≤600 frames · ≤64 MiB · no audio. Sampling is reduced if the frame cap is reached.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    if model.exporting {
                        HStack {
                            ProgressView(value: model.progress).frame(maxWidth: .infinity)
                            Text("\(Int(model.progress * 100))%").monospacedDigit()
                            Button(model.cancelling ? "Cancelling…" : "Cancel", action: model.cancelExport).disabled(model.cancelling)
                        }
                    }
                    if let error = model.errorMessage {
                        Text(error).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer()
                        if let output = model.lastExportURL {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                        }
                    }
                }.padding([.horizontal, .bottom], 16)
            }.frame(minHeight: 320, idealHeight: 410, maxHeight: 440)
        }.buttonStyle(.bordered)
    }
}
