import Foundation
import CoreGraphics

/// All input recording is explicitly opt-in, independently for each category.
struct RecordingInputEffectsOptions: Equatable, Sendable {
    var clicks = false
    var scrolls = false
    var shortcuts = false

    var isEnabled: Bool { clicks || scrolls || shortcuts }
}

enum RecordingInputClickButton: Equatable, Sendable {
    case left, right, other
}

struct RecordingShortcutModifiers: OptionSet, Equatable, Sendable {
    let rawValue: UInt8
    static let command = Self(rawValue: 1 << 0)
    static let control = Self(rawValue: 1 << 1)
    static let option = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)
    static let supported: Self = [.command, .control, .option, .shift]
}

/// Only hardware key codes and modifier bits enter this model. There is no API
/// accepting event characters, composed text, accessibility values or strings.
/// Labels describe whitelisted physical keys, independently of keyboard layout.
struct RecordingInputShortcut: Equatable, Sendable {
    let keyCode: UInt16
    let modifiers: RecordingShortcutModifiers

    init?(keyCode: UInt16, modifiers: RecordingShortcutModifiers) {
        guard modifiers.subtracting(.supported).isEmpty,
              !modifiers.intersection([.command, .control]).isEmpty,
              Self.keyLabels[keyCode] != nil else { return nil }
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    var label: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("CTRL") }
        if modifiers.contains(.option) { parts.append("OPT") }
        if modifiers.contains(.shift) { parts.append("SHIFT") }
        if modifiers.contains(.command) { parts.append("CMD") }
        if let key = Self.keyLabels[keyCode] { parts.append(key) }
        return parts.joined(separator: "+")
    }

    private static let keyLabels: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 25: "9", 26: "7", 28: "8", 29: "0", 31: "O", 32: "U",
        34: "I", 35: "P", 36: "RETURN", 37: "L", 38: "J", 40: "K",
        45: "N", 46: "M", 48: "TAB", 49: "SPACE", 51: "DELETE", 53: "ESC",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 109: "F10", 111: "F12", 115: "HOME", 116: "PAGEUP",
        117: "FORWARDDELETE", 118: "F4", 119: "END", 120: "F2",
        121: "PAGEDOWN", 122: "F1", 123: "LEFT", 124: "RIGHT", 125: "DOWN", 126: "UP"
    ]
}

enum RecordingInputEffectKind: Equatable {
    /// Unit-square points always use lower-left CoreGraphics coordinates.
    case click(button: RecordingInputClickButton, normalizedPoint: CGPoint)
    case scroll(deltaX: CGFloat, deltaY: CGFloat, normalizedPoint: CGPoint)
    case shortcut(RecordingInputShortcut)
}

struct RecordingInputEffect: Equatable {
    let timestamp: TimeInterval
    let kind: RecordingInputEffectKind

    var lifetime: TimeInterval {
        switch kind {
        case .click: return 0.7
        case .scroll: return 0.85
        case .shortcut: return RecordingInputEffectsState.maximumLifetime
        }
    }

    func isVisible(at time: TimeInterval) -> Bool {
        let age = time - timestamp
        return time.isFinite && timestamp.isFinite && age >= 0 && age < lifetime
    }
}

struct RecordingInputEffectsSnapshot {
    let revision: UInt64
    /// Freeze this value alongside the events when Stop establishes its barrier.
    let sampledAt: TimeInterval
    let events: [RecordingInputEffect]

    var hasVisibleEffects: Bool { events.contains { $0.isVisible(at: sampledAt) } }
}

/// Bounded values only: no event objects, window information, frames or images.
/// Caller supplies one monotonic host-time clock (ProcessInfo.systemUptime).
/// Session tokens reject delayed callbacks after end/restart; a resume boundary
/// rejects input queued during a pause even when it arrives after resuming.
final class RecordingInputEffectsState: @unchecked Sendable {
    static let maximumEvents = 48
    static let maximumLifetime: TimeInterval = 1.2
    static let maximumScrollDelta: CGFloat = 120

    private let lock = NSLock()
    private var options = RecordingInputEffectsOptions()
    private var token: UUID?
    private var paused = true
    private var minimumTimestamp: TimeInterval = 0
    private var lastTimestamp: TimeInterval = 0
    private var revision: UInt64 = 0
    private var events: [RecordingInputEffect] = []

    @discardableResult
    func beginSession(options: RecordingInputEffectsOptions, at time: TimeInterval) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let created = UUID()
        self.options = options
        token = Self.validTime(time) ? created : nil
        paused = !Self.validTime(time)
        minimumTimestamp = Self.validTime(time) ? time : 0
        lastTimestamp = minimumTimestamp
        events.removeAll(keepingCapacity: true)
        revision &+= 1
        return created
    }

    func setOptions(_ proposed: RecordingInputEffectsOptions) {
        lock.lock(); defer { lock.unlock() }
        guard options != proposed else { return }
        options = proposed
        events.removeAll { !allows($0.kind) }
        revision &+= 1
    }

    func setPaused(_ proposed: Bool, at time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        // Invalid lifecycle clocks fail closed, including a requested resume.
        paused = proposed || !Self.validTime(time)
        if Self.validTime(time) { minimumTimestamp = max(minimumTimestamp, time) }
        events.removeAll(keepingCapacity: true)
        revision &+= 1
    }

    func endSession() {
        lock.lock(); defer { lock.unlock() }
        token = nil; paused = true
        events.removeAll(keepingCapacity: true)
        revision &+= 1
    }

    func clearEvents(at time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if Self.validTime(time) {
            minimumTimestamp = max(minimumTimestamp, time)
        } else {
            // A broken privacy-boundary clock must not admit more input.
            paused = true
        }
        events.removeAll(keepingCapacity: true)
        revision &+= 1
    }

    func snapshot(at time: TimeInterval) -> RecordingInputEffectsSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard Self.validTime(time) else {
            return RecordingInputEffectsSnapshot(revision: revision, sampledAt: 0, events: [])
        }
        prune(at: time)
        return RecordingInputEffectsSnapshot(revision: revision, sampledAt: time,
            events: events.filter { $0.isVisible(at: time) })
    }

    @discardableResult
    func recordClick(button: RecordingInputClickButton, normalizedPoint point: CGPoint,
                     at time: TimeInterval, token: UUID) -> Bool {
        guard Self.validPoint(point) else { return false }
        return append(.click(button: button, normalizedPoint: point), at: time, token: token)
    }

    @discardableResult
    func recordScroll(deltaX: CGFloat, deltaY: CGFloat, normalizedPoint point: CGPoint,
                      at time: TimeInterval, token: UUID) -> Bool {
        guard Self.validPoint(point), deltaX.isFinite, deltaY.isFinite,
              deltaX != 0 || deltaY != 0 else { return false }
        let limit = Self.maximumScrollDelta
        return append(.scroll(deltaX: min(limit, max(-limit, deltaX)),
            deltaY: min(limit, max(-limit, deltaY)), normalizedPoint: point), at: time, token: token)
    }

    @discardableResult
    func recordShortcut(keyCode: UInt16, modifiers: RecordingShortcutModifiers,
                        at time: TimeInterval, token: UUID) -> Bool {
        guard let shortcut = RecordingInputShortcut(keyCode: keyCode, modifiers: modifiers) else { return false }
        return append(.shortcut(shortcut), at: time, token: token)
    }

    private func append(_ kind: RecordingInputEffectKind, at time: TimeInterval, token: UUID) -> Bool {
        guard Self.validTime(time) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard self.token == token, !paused, allows(kind),
              time >= minimumTimestamp, time >= lastTimestamp else { return false }
        prune(at: time)
        if events.count == Self.maximumEvents { events.removeFirst() }
        events.append(RecordingInputEffect(timestamp: time, kind: kind))
        lastTimestamp = time
        revision &+= 1
        return true
    }

    private func prune(at time: TimeInterval) {
        minimumTimestamp = max(minimumTimestamp, time - Self.maximumLifetime)
        let previousCount = events.count
        events.removeAll { time - $0.timestamp >= $0.lifetime }
        if events.count != previousCount { revision &+= 1 }
    }

    private func allows(_ kind: RecordingInputEffectKind) -> Bool {
        switch kind {
        case .click: return options.clicks
        case .scroll: return options.scrolls
        case .shortcut: return options.shortcuts
        }
    }

    private static func validTime(_ time: TimeInterval) -> Bool { time.isFinite && time >= 0 }
    private static func validPoint(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && (0...1).contains(point.x) && (0...1).contains(point.y)
    }
}

/// Paint directly into the encoder's existing pixel canvas. Geometry, color and
/// opacity depend only on this value snapshot, output size and supplied time.
/// A tiny ASCII vector alphabet avoids fonts, text shaping and typed-text APIs.
enum RecordingInputEffectsRenderer {
    static func draw(_ snapshot: RecordingInputEffectsSnapshot, in context: CGContext, size: CGSize) {
        draw(snapshot, in: context, size: size, at: snapshot.sampledAt)
    }

    static func draw(_ snapshot: RecordingInputEffectsSnapshot, in context: CGContext,
                     size: CGSize, at time: TimeInterval) {
        guard time.isFinite, time >= 0, size.width.isFinite, size.height.isFinite,
              size.width >= 2, size.height >= 2, size.width <= 3_840, size.height <= 3_840,
              size.width * size.height <= 8_294_400 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: CGRect(origin: .zero, size: size))
        context.setBlendMode(.normal)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setShouldAntialias(true)
        var latestShortcut: RecordingInputEffect?
        for event in snapshot.events.suffix(RecordingInputEffectsState.maximumEvents) where event.isVisible(at: time) {
            let progress = CGFloat((time - event.timestamp) / event.lifetime)
            let opacity = 1 - progress
            context.setAlpha(opacity)
            switch event.kind {
            case let .click(button, point):
                guard let center = pixelPoint(point, size: size) else { continue }
                drawClick(button, center: center, progress: progress, in: context)
            case let .scroll(dx, dy, point):
                guard let center = pixelPoint(point, size: size), dx.isFinite, dy.isFinite else { continue }
                drawScroll(dx: dx, dy: dy, center: center, in: context)
            case .shortcut:
                latestShortcut = event
            }
        }
        if let event = latestShortcut, case let .shortcut(shortcut) = event.kind {
            context.setAlpha(CGFloat(1 - (time - event.timestamp) / event.lifetime))
            drawShortcut(shortcut, in: context, size: size)
        }
    }

    private static func pixelPoint(_ point: CGPoint, size: CGSize) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        return CGPoint(x: floor(point.x * (size.width - 1)) + 0.5,
                       y: floor(point.y * (size.height - 1)) + 0.5)
    }

    private static func drawClick(_ button: RecordingInputClickButton, center: CGPoint,
                                  progress: CGFloat, in context: CGContext) {
        let radius = floor(13 + progress * 11)
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let color: CGColor
        let label: String
        switch button {
        case .left: color = CGColor(srgbRed: 1, green: 0.76, blue: 0.12, alpha: 1); label = "L"
        case .right: color = CGColor(srgbRed: 1, green: 0.3, blue: 0.68, alpha: 1); label = "R"
        case .other: color = CGColor(srgbRed: 0.2, green: 0.84, blue: 1, alpha: 1); label = "O"
        }
        context.setFillColor(CGColor(srgbRed: 0.04, green: 0.06, blue: 0.1, alpha: 0.68))
        context.fillEllipse(in: rect)
        context.setStrokeColor(color)
        context.setLineWidth(3)
        context.strokeEllipse(in: rect.insetBy(dx: 1.5, dy: 1.5))
        drawASCII(label, origin: CGPoint(x: floor(center.x) - 2, y: floor(center.y) - 3),
                  scale: 1, color: color, in: context)
    }

    private static func drawScroll(dx: CGFloat, dy: CGFloat, center: CGPoint, in context: CGContext) {
        let color = CGColor(srgbRed: 0.3, green: 0.96, blue: 0.74, alpha: 1)
        // Keep diagonal scrolling as two independently legible axis arrows.
        for (delta, horizontal) in [(dx, true), (dy, false)] where delta != 0 {
            let distance = floor(17 + min(1, abs(delta) / 40) * 13)
            let sign: CGFloat = delta > 0 ? 1 : -1
            let end = CGPoint(x: center.x + (horizontal ? sign * distance : 0),
                              y: center.y + (horizontal ? 0 : sign * distance))
            let base = CGPoint(x: end.x - (horizontal ? sign * 7 : 0),
                               y: end.y - (horizontal ? 0 : sign * 7))
            let first = CGPoint(x: base.x + (horizontal ? 0 : 5), y: base.y + (horizontal ? 5 : 0))
            let second = CGPoint(x: base.x - (horizontal ? 0 : 5), y: base.y - (horizontal ? 5 : 0))
            // A dark outline keeps the same cue readable on light screen pixels.
            for (width, stroke) in [(CGFloat(6), CGColor(srgbRed: 0.02, green: 0.05, blue: 0.08, alpha: 0.8)),
                                     (CGFloat(3), color)] {
                context.setStrokeColor(stroke); context.setLineWidth(width)
                context.beginPath(); context.move(to: center); context.addLine(to: end)
                context.move(to: first); context.addLine(to: end); context.addLine(to: second)
                context.strokePath()
            }
        }
    }

    private static func drawShortcut(_ shortcut: RecordingInputShortcut, in context: CGContext, size: CGSize) {
        let label = shortcut.label
        let margin = min(CGFloat(12), min(floor(size.width / 8), floor(size.height / 8)))
        let available = max(1, floor(size.width) - margin * 2)
        let scale: CGFloat = CGFloat(label.utf8.count * 6 * 2 + 20) <= available ? 2 : 1
        let textWidth = CGFloat(label.utf8.count * 6 - 1) * scale
        let width = min(available, textWidth + 20), height = min(floor(size.height) - margin * 2, 7 * scale + 16)
        let rect = CGRect(x: floor((size.width - width) / 2), y: margin, width: width, height: height)
        context.setFillColor(CGColor(srgbRed: 0.04, green: 0.06, blue: 0.1, alpha: 0.88))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: min(7, height / 2),
                               cornerHeight: min(7, height / 2), transform: nil))
        context.fillPath()
        context.saveGState()
        context.clip(to: rect)
        drawASCII(label, origin: CGPoint(x: floor(rect.midX - textWidth / 2), y: floor(rect.midY - 7 * scale / 2)),
                  scale: scale, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), in: context)
        context.restoreGState()
    }

    private static func drawASCII(_ label: String, origin: CGPoint, scale: CGFloat, color: CGColor, in context: CGContext) {
        context.saveGState(); defer { context.restoreGState() }
        context.setShouldAntialias(false)
        context.setFillColor(color)
        for (index, byte) in label.utf8.enumerated() {
            guard let rows = glyphs[byte] else { continue }
            for (row, bits) in rows.enumerated() {
                for column in 0..<5 where bits & (1 << (4 - column)) != 0 {
                    context.fill(CGRect(x: origin.x + CGFloat(index * 6 + column) * scale,
                        y: origin.y + CGFloat(6 - row) * scale, width: scale, height: scale))
                }
            }
        }
    }

    /// Seven rows of five bits per glyph; labels are strictly fixed ASCII.
    private static let glyphs: [UInt8: [UInt8]] = [
        65: [14,17,17,31,17,17,17], 66: [30,17,17,30,17,17,30],
        67: [14,17,16,16,16,17,14], 68: [30,17,17,17,17,17,30],
        69: [31,16,16,30,16,16,31], 70: [31,16,16,30,16,16,16],
        71: [14,17,16,23,17,17,15], 72: [17,17,17,31,17,17,17],
        73: [14,4,4,4,4,4,14], 74: [7,2,2,2,2,18,12],
        75: [17,18,20,24,20,18,17], 76: [16,16,16,16,16,16,31],
        77: [17,27,21,21,17,17,17], 78: [17,25,21,19,17,17,17],
        79: [14,17,17,17,17,17,14], 80: [30,17,17,30,16,16,16],
        81: [14,17,17,17,21,18,13], 82: [30,17,17,30,20,18,17],
        83: [15,16,16,14,1,1,30], 84: [31,4,4,4,4,4,4],
        85: [17,17,17,17,17,17,14], 86: [17,17,17,17,17,10,4],
        87: [17,17,17,21,21,21,10], 88: [17,17,10,4,10,17,17],
        89: [17,17,10,4,4,4,4], 90: [31,1,2,4,8,16,31],
        48: [14,17,19,21,25,17,14], 49: [4,12,4,4,4,4,14],
        50: [14,17,1,2,4,8,31], 51: [30,1,1,14,1,1,30],
        52: [2,6,10,18,31,2,2], 53: [31,16,16,30,1,1,30],
        54: [14,16,16,30,17,17,14], 55: [31,1,2,4,8,8,8],
        56: [14,17,17,14,17,17,14], 57: [14,17,17,15,1,1,14],
        43: [0,4,4,31,4,4,0]
    ]
}
