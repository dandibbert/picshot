import AppKit
import ApplicationServices
import Foundation

/// Only role and geometry leave the AX worker. Labels, values and document text
/// are deliberately never requested or persisted by capture element selection.
struct CaptureElementNode: Equatable, Sendable {
    let frame: CGRect // Global Quartz points: top-left, Y down.
    let role: String
    var parent: Int?
    var children: [Int]
}

struct CaptureElementSnapshot: Equatable, Sendable {
    let nodes: [CaptureElementNode]
    let hit: Int
    let sampledAt: Date
    let frozenAt: Date
    let point: CGPoint

    func validated(displayBounds: CGRect) -> Bool {
        guard !nodes.isEmpty, nodes.count <= CaptureElementLimits.maximumNodes,
              nodes.indices.contains(hit), nodes[hit].frame.contains(point), sampledAt.timeIntervalSince1970.isFinite,
              frozenAt.timeIntervalSince1970.isFinite else { return false }
        for (index, node) in nodes.enumerated() {
            guard CaptureElementGeometry.localFrame(node.frame, displayBounds: displayBounds) != nil,
                  node.role.utf8.count <= 80, node.children.count <= CaptureElementLimits.maximumNodes,
                  Set(node.children).count == node.children.count else { return false }
            if let parent = node.parent {
                guard nodes.indices.contains(parent), parent != index,
                      nodes[parent].children.contains(index) else { return false }
            }
            for child in node.children {
                guard nodes.indices.contains(child), child != index, nodes[child].parent == index else { return false }
            }
            var visited = Set<Int>(), cursor: Int? = index
            while let current = cursor {
                guard nodes.indices.contains(current), visited.insert(current).inserted,
                      visited.count <= CaptureElementLimits.maximumDepth else { return false }
                cursor = nodes[current].parent
            }
        }
        return true
    }
}

enum CaptureElementGeometry {
    static func localFrame(_ global: CGRect, displayBounds: CGRect) -> CGRect? {
        guard finite(global), finite(displayBounds), global.width >= 2, global.height >= 2,
              displayBounds.contains(global) else { return nil }
        return global.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
    }
    static func finite(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.maxX.isFinite && frame.maxY.isFinite &&
        frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0
    }
}

struct CaptureElementWindow: Equatable, Sendable {
    let id: UInt32
    let pid: Int32
    let frame: CGRect

    /// Snapshot before PicShot opens its overlay. Ordering is front-to-back and
    /// own-app windows remain blockers; we must not select invisible content.
    static func visible() -> [CaptureElementWindow] {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return rows.prefix(512).compactMap { row in
            guard let id = row[kCGWindowNumber as String] as? NSNumber,
                  let pid = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let raw = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: raw as CFDictionary), CaptureElementGeometry.finite(frame),
                  ((row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0 else { return nil }
            return CaptureElementWindow(id: id.uint32Value, pid: pid.int32Value, frame: frame)
        }
    }
}

struct CaptureElementRequest: Sendable {
    let point: CGPoint
    let displayBounds: CGRect
    let windows: [CaptureElementWindow]
    let frozenAt: Date
    /// Used only by the native own-app fixture, never by production selection.
    var permitsOwnProcessForFixture = false
}

enum CaptureElementUnavailable: String, Sendable {
    case permission, unsupported, timedOut, stale, cancelled
    var message: String {
        switch self {
        case .permission: return "需在系统设置 → 隐私与安全性 → 辅助功能中手动开启；可拖动选区"
        case .unsupported: return "此位置没有可用元素，可拖动选择矩形"
        case .timedOut: return "元素响应超时，可拖动选择矩形"
        case .stale: return "窗口已变化，请重新截图；也可按冻结画面拖动选区"
        case .cancelled: return "可拖动选择矩形"
        }
    }
}

enum CaptureElementResult: Sendable {
    case snapshot(CaptureElementSnapshot)
    case unavailable(CaptureElementUnavailable)
}

final class CaptureElementCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

enum CaptureElementLimits {
    static let maximumNodes = 80
    static let maximumDepth = 12
    static let maximumCalls = 240
    static let seconds: TimeInterval = 0.20
    static let messagingSeconds: Float = 0.025
}

struct CaptureElementBudget {
    let started: TimeInterval
    private(set) var calls = 0
    mutating func admit(now: TimeInterval, cancelled: Bool) -> Bool {
        guard !cancelled, now.isFinite, now >= started,
              now - started < CaptureElementLimits.seconds, calls < CaptureElementLimits.maximumCalls else { return false }
        calls += 1; return true
    }
}

protocol CaptureElementProviding: Sendable {
    func snapshot(_ request: CaptureElementRequest, cancellation: CaptureElementCancellation) async -> CaptureElementResult
}

/// Official API contracts:
/// https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout
/// https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition
/// https://developer.apple.com/documentation/applicationservices/1462060-axuielementcopyattributevalues
/// Serial worker bounds total concurrent AX IPC to one. Every request is bounded
/// by calls, nodes, depth and monotonic elapsed time. AX IPC itself has a 25 ms
/// timeout; the total deadline can overrun by at most one in-flight AX call.
final class AXCaptureElementProvider: CaptureElementProviding, @unchecked Sendable {
    private let queue = DispatchQueue(label: "PicShot.capture-elements", qos: .userInitiated)

    func snapshot(_ request: CaptureElementRequest, cancellation: CaptureElementCancellation) async -> CaptureElementResult {
        await withCheckedContinuation { continuation in
            queue.async {
                guard !cancellation.isCancelled else { continuation.resume(returning: .unavailable(.cancelled)); return }
                continuation.resume(returning: AXCaptureElementReader(request: request, cancellation: cancellation).read())
            }
        }
    }
}

private final class AXCaptureElementReader {
    let request: CaptureElementRequest
    let cancellation: CaptureElementCancellation
    var budget = CaptureElementBudget(started: ProcessInfo.processInfo.systemUptime)
    var nodes: [CaptureElementNode] = []
    var elements: [AXUIElement] = []
    var expired = false
    init(request: CaptureElementRequest, cancellation: CaptureElementCancellation) {
        self.request = request; self.cancellation = cancellation
    }
    func admit() -> Bool {
        guard budget.admit(now: ProcessInfo.processInfo.systemUptime, cancelled: cancellation.isCancelled) else {
            expired = true; return false
        }
        return true
    }
    func prepare(_ element: AXUIElement) -> Bool {
        guard admit() else { return false }
        return AXUIElementSetMessagingTimeout(element, CaptureElementLimits.messagingSeconds) == .success
    }
    func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        guard admit() else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }
    func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        let frame = CGRect(origin: point, size: dimensions)
        return CaptureElementGeometry.localFrame(frame, displayBounds: request.displayBounds) == nil ? nil : frame
    }
    func append(_ element: AXUIElement, parent: Int?) -> Int? {
        guard nodes.count < CaptureElementLimits.maximumNodes,
              !elements.contains(where: { CFEqual($0, element) }), prepare(element), admit() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              request.windows.first(where: { $0.frame.contains(request.point) })?.pid == pid,
              let rect = frame(element) else { return nil }
        let role = (attribute(element, kAXRoleAttribute) as? String) ?? "AXElement"
        let index = nodes.count
        nodes.append(CaptureElementNode(frame: rect, role: String(role.prefix(64)), parent: parent, children: []))
        elements.append(element)
        if let parent { nodes[parent].children.append(index) }
        return index
    }
    func childElements(_ element: AXUIElement) -> [AXUIElement] {
        guard admit() else { return [] }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success,
              count > 0, admit() else { return [] }
        var result: CFArray?
        let remaining = CaptureElementLimits.maximumNodes - nodes.count
        guard remaining > 0, AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0,
                min(count, remaining), &result) == .success, let result else { return [] }
        return (result as NSArray).compactMap { value in
            let object = value as CFTypeRef
            return CFGetTypeID(object) == AXUIElementGetTypeID() ? unsafeBitCast(object, to: AXUIElement.self) : nil
        }
    }
    func descendants(_ index: Int, depth: Int) {
        guard depth < CaptureElementLimits.maximumDepth, !expired else { return }
        for child in childElements(elements[index]) {
            guard !expired, !cancellation.isCancelled, nodes.count < CaptureElementLimits.maximumNodes else { return }
            if let childIndex = append(child, parent: index) { descendants(childIndex, depth: depth + 1) }
        }
    }
    func read() -> CaptureElementResult {
        guard !Thread.isMainThread else { return .unavailable(.unsupported) }
        // Read-only availability check: no AXIsProcessTrustedWithOptions prompt.
        guard AXIsProcessTrusted() else { return .unavailable(.permission) }
        guard request.point.x.isFinite, request.point.y.isFinite, request.displayBounds.contains(request.point),
              let target = request.windows.first(where: { $0.frame.contains(request.point) }),
              request.permitsOwnProcessForFixture || target.pid != ProcessInfo.processInfo.processIdentifier else { return .unavailable(.unsupported) }
        let live = CaptureElementWindow.visible().filter {
            request.permitsOwnProcessForFixture || $0.pid != ProcessInfo.processInfo.processIdentifier
        }
        guard live.first(where: { $0.frame.contains(request.point) }) == target else { return .unavailable(.stale) }
        let application = AXUIElementCreateApplication(target.pid)
        guard prepare(application), admit() else { return .unavailable(.timedOut) }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application, Float(request.point.x), Float(request.point.y), &hit) == .success,
              let hit, let hitIndex = append(hit, parent: nil), nodes[hitIndex].frame.contains(request.point),
              target.frame.contains(nodes[hitIndex].frame) else {
            return .unavailable(expired ? .timedOut : .unsupported)
        }
        var current = hitIndex, depth = 1
        while depth < CaptureElementLimits.maximumDepth, !expired {
            guard let value = attribute(elements[current], kAXParentAttribute), CFGetTypeID(value) == AXUIElementGetTypeID(),
                  let parentIndex = append(unsafeBitCast(value, to: AXUIElement.self), parent: nil) else { break }
            nodes[current].parent = parentIndex
            nodes[parentIndex].children.append(current)
            current = parentIndex; depth += 1
        }
        // Descend from the hit only; ancestors expose the path back to the hit.
        // No full application or window-tree crawl is needed on pointer motion.
        descendants(hitIndex, depth: depth)
        if cancellation.isCancelled { return .unavailable(.cancelled) }
        if expired || !admit() { return .unavailable(.timedOut) }
        let currentWindows = CaptureElementWindow.visible().filter {
            request.permitsOwnProcessForFixture || $0.pid != ProcessInfo.processInfo.processIdentifier
        }
        guard currentWindows.first(where: { $0.frame.contains(request.point) }) == target else { return .unavailable(.stale) }
        if cancellation.isCancelled { return .unavailable(.cancelled) }
        guard admit() else { return .unavailable(.timedOut) }
        let snapshot = CaptureElementSnapshot(nodes: nodes, hit: hitIndex, sampledAt: Date(), frozenAt: request.frozenAt, point: request.point)
        guard snapshot.validated(displayBounds: request.displayBounds) else { return .unavailable(.unsupported) }
        return .snapshot(snapshot)
    }
}

/// Presentation-scoped generation guard. Cancelled/older results cannot replace
/// a newer hover, a manual drag, a completed selection or the next capture.
@MainActor final class CaptureElementSession {
    private let provider: any CaptureElementProviding
    private var task: Task<Void, Never>?
    private var cancellation: CaptureElementCancellation?
    private var generation = UUID()
    private(set) var snapshot: CaptureElementSnapshot?
    private(set) var index: Int?
    private var history: [Int] = []
    var changed: ((CaptureElementResult) -> Void)?
    init(provider: any CaptureElementProviding = AXCaptureElementProvider()) { self.provider = provider }
    func request(_ request: CaptureElementRequest, debounceNanoseconds: UInt64 = 60_000_000) {
        invalidate()
        let generation = self.generation, token = CaptureElementCancellation()
        cancellation = token
        task = Task { [weak self, provider] in
            do { try await Task.sleep(nanoseconds: debounceNanoseconds) } catch { return }
            guard !Task.isCancelled else { return }
            let result = await provider.snapshot(request, cancellation: token)
            guard let self, self.generation == generation, !Task.isCancelled, !token.isCancelled else { return }
            switch result {
            case .snapshot(let snapshot):
                guard snapshot.validated(displayBounds: request.displayBounds), snapshot.point == request.point,
                      snapshot.frozenAt == request.frozenAt else {
                    self.changed?(.unavailable(.stale)); return
                }
                self.snapshot = snapshot; self.index = snapshot.hit
            case .unavailable: break
            }
            self.changed?(result)
        }
    }
    func invalidate() {
        generation = UUID(); cancellation?.cancel(); cancellation = nil; task?.cancel(); task = nil
        snapshot = nil; index = nil; history.removeAll()
    }
    var selectedNode: CaptureElementNode? {
        guard let snapshot, let index, snapshot.nodes.indices.contains(index) else { return nil }
        return snapshot.nodes[index]
    }
    @discardableResult func traverse(parent: Bool) -> Bool {
        guard let snapshot, let index else { return false }
        let next = parent ? snapshot.nodes[index].parent : snapshot.nodes[index].children.first
        guard let next else { return false }
        history.append(index); if history.count > 80 { history.removeFirst() }
        self.index = next; return true
    }
    @discardableResult func undoTraversal() -> Bool {
        guard let previous = history.popLast() else { return false }; index = previous; return true
    }
    func stop() { invalidate(); changed = nil }
}

struct CaptureElementContext {
    let displayBounds: CGRect
    let windows: [CaptureElementWindow]
    let frozenAt: Date
    var initiallyEnabled = false
    var provider: any CaptureElementProviding = AXCaptureElementProvider()
}
