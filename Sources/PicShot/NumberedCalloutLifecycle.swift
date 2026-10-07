import AppKit

struct NumberedCalloutLifecycleEvidence: Codable {
    let contract = "owned-graph-prompt_native-input-deadline-v2"
    var status = "running"
    let expectedCycles: Int
    let promptOwnershipCheckMilliseconds = 10
    let pollIntervalMilliseconds = 10
    let deferredInputDeadlineMilliseconds = 2000
    let maximumSamples = 256
    let zeroLeakClaim = false
    let frameworkRetirementOnly = true
    let boundRationale = "307e native controls, including an untyped callout and plain NSTextView, retained detached input at 10/100 ms and released it by the 1000 ms observation. The new 2000 ms per-input/context deadline is a bounded verification requirement, not an existing pass, a process-memory bound or a leak claim. Application owners and text backing must pass the original scheduled 10 ms prompt check."
    var cycles: [NumberedCalloutClosedCycleEvidence] = []
    var samples: [NumberedCalloutDrainSample] = []
    var peakDeferredInputs = 0
    var peakDeferredContexts = 0
    var finalDeferredInputs = 0
    var finalDeferredContexts = 0
}

struct NumberedCalloutClosedCycleEvidence: Codable {
    let cycle: Int
    let closedAtMilliseconds: Double
    let synchronousCheckedAtMilliseconds: Double
    let synchronousRetainedOwners: Int
    let synchronousRetainedTextSystemObjects: Int
    var promptCheckedAtMilliseconds = 0.0
    var promptRetainedOwners = 0
    var promptRetainedTextSystemObjects = 0
    let requiredGraphTracked: Bool
    let contextWasTracked: Bool
    let textKit1WasTracked: Bool
    let textKit2WasTracked: Bool
    var lastRetainedAfterMilliseconds: Double?
    var releasedAfterMilliseconds: Double?
}

struct NumberedCalloutDrainSample: Codable {
    let elapsedMilliseconds: Double
    let createdCycles: Int
    let pendingInputCycles: [Int]
    let pendingContextCycles: [Int]
    let retainedOwnedGraphObjects: Int
}

/// All references are weak. No diagnostic getter may switch TextKit modes or
/// create an input context; only the already-active context is tracked.
@MainActor
final class NumberedCalloutClosedInputProbe {
    weak var editor: ImageEditorController?
    weak var window: NSWindow?
    weak var box: NSView?
    weak var session: AnyObject?
    weak var undoManager: UndoManager?
    weak var input: NSTextView?
    weak var context: NSTextInputContext?
    weak var storage: NSTextStorage?
    weak var container: NSTextContainer?
    weak var layout: NSLayoutManager?
    weak var textLayout: NSTextLayoutManager?
    let requiredGraphTracked: Bool
    let contextWasTracked: Bool
    let textKit1WasTracked: Bool
    let textKit2WasTracked: Bool
    private(set) var closedAt = ProcessInfo.processInfo.systemUptime

    init(editor: ImageEditorController, input: NSTextView, undoManager: UndoManager) {
        self.editor = editor; window = input.window; box = input.superview; session = input.delegate
        self.undoManager = undoManager; self.input = input
        storage = input.textStorage; container = input.textContainer; textLayout = input.textLayoutManager
        if input.textLayoutManager == nil { layout = input.textStorage?.layoutManagers.first }
        if let active = NSTextInputContext.current, (active.client as AnyObject) === input { context = active }
        contextWasTracked = context != nil
        textKit1WasTracked = layout != nil; textKit2WasTracked = textLayout != nil
        requiredGraphTracked = window != nil && box != nil && session != nil && storage != nil && container != nil
            && (textKit1WasTracked != textKit2WasTracked)
    }

    func didClose() { closedAt = ProcessInfo.processInfo.systemUptime }
    var retainedOwners: Int {
        autoreleasepool { [editor as AnyObject?, window, box, session, undoManager].compactMap { $0 }.count }
    }
    var retainedTextSystemObjects: Int {
        autoreleasepool { [storage as AnyObject?, container, layout, textLayout].compactMap { $0 }.count }
    }
}

/// A prompt ownership gate and a separately reported native-retirement gate.
/// Six overlapping inputs are a bounded fixture workload, not an app-wide quota.
@MainActor
final class NumberedCalloutReleaseMonitor {
    private let began = ProcessInfo.processInfo.systemUptime
    private var probes: [NumberedCalloutClosedInputProbe] = []
    private(set) var evidence: NumberedCalloutLifecycleEvidence
    init(expectedCycles: Int) throws {
        guard (1...6).contains(expectedCycles) else { throw Self.failure("Close fixture requires 1 through 6 cycles") }
        evidence = NumberedCalloutLifecycleEvidence(expectedCycles: expectedCycles)
    }

    func append(_ probe: NumberedCalloutClosedInputProbe) async throws {
        guard probes.count < evidence.expectedCycles else { throw failure("Unexpected extra close cycle") }
        probes.append(probe)
        evidence.cycles.append(NumberedCalloutClosedCycleEvidence(cycle: probes.count,
            closedAtMilliseconds: (probe.closedAt - began) * 1000,
            synchronousCheckedAtMilliseconds: (ProcessInfo.processInfo.systemUptime - began) * 1000,
            synchronousRetainedOwners: probe.retainedOwners, synchronousRetainedTextSystemObjects: probe.retainedTextSystemObjects,
            requiredGraphTracked: probe.requiredGraphTracked, contextWasTracked: probe.contextWasTracked,
            textKit1WasTracked: probe.textKit1WasTracked, textKit2WasTracked: probe.textKit2WasTracked))
        guard probe.requiredGraphTracked else { throw failure("Close cycle did not track the required owner/text-system graph") }
        try await Task.sleep(nanoseconds: UInt64(evidence.promptOwnershipCheckMilliseconds) * 1_000_000)
        try sample(promptCycle: probes.count - 1)
    }

    func finish() async throws {
        guard probes.count == evidence.expectedCycles else { throw failure("Missing close cycles") }
        while evidence.cycles.contains(where: { $0.releasedAfterMilliseconds == nil }) {
            let now = ProcessInfo.processInfo.systemUptime
            let nextDeadline = probes.enumerated().filter { evidence.cycles[$0.offset].releasedAfterMilliseconds == nil }
                .map { $0.element.closedAt + Double(evidence.deferredInputDeadlineMilliseconds) / 1000 }.min()!
            let delay = max(0, min(Double(evidence.pollIntervalMilliseconds) / 1000, nextDeadline - now))
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            try sample()
        }
        evidence.status = "passed"
    }

    func failedEvidence() -> NumberedCalloutLifecycleEvidence {
        var result = evidence; result.status = "failed"; return result
    }

    private func sample(promptCycle: Int? = nil) throws {
        guard evidence.samples.count < evidence.maximumSamples else { throw failure("Native retirement sample bound exceeded") }
        let inputs = probes.enumerated().compactMap { $0.element.input != nil ? $0.offset + 1 : nil }
        let contexts = probes.enumerated().compactMap { $0.element.context != nil ? $0.offset + 1 : nil }
        let owned = probes.reduce(0) { $0 + $1.retainedOwners + $1.retainedTextSystemObjects }
        let now = ProcessInfo.processInfo.systemUptime
        if let index = promptCycle {
            evidence.cycles[index].promptCheckedAtMilliseconds = (now - began) * 1000
            evidence.cycles[index].promptRetainedOwners = probes[index].retainedOwners
            evidence.cycles[index].promptRetainedTextSystemObjects = probes[index].retainedTextSystemObjects
        }
        evidence.samples.append(NumberedCalloutDrainSample(elapsedMilliseconds: (now - began) * 1000,
            createdCycles: probes.count, pendingInputCycles: inputs, pendingContextCycles: contexts, retainedOwnedGraphObjects: owned))
        evidence.peakDeferredInputs = max(evidence.peakDeferredInputs, inputs.count)
        evidence.peakDeferredContexts = max(evidence.peakDeferredContexts, contexts.count)
        evidence.finalDeferredInputs = inputs.count; evidence.finalDeferredContexts = contexts.count
        guard owned == 0 else { throw failure("Application owner or detached text-system graph survived the prompt close gate") }
        for (index, probe) in probes.enumerated() {
            let pending = inputs.contains(index + 1) || contexts.contains(index + 1)
            let firstRelease = !pending && evidence.cycles[index].releasedAfterMilliseconds == nil
            let elapsed = (now - probe.closedAt) * 1000
            if pending {
                guard evidence.cycles[index].releasedAfterMilliseconds == nil else { throw failure("Released native input/context reappeared") }
                evidence.cycles[index].lastRetainedAfterMilliseconds = elapsed
            } else if firstRelease {
                evidence.cycles[index].releasedAfterMilliseconds = elapsed
            }
            if pending || firstRelease {
                guard elapsed <= Double(evidence.deferredInputDeadlineMilliseconds) else {
                    throw failure("Detached native input/context missed its 2000 ms retirement deadline")
                }
            }
        }
    }

    /// Focused tests pass a closure over weak variables, never a strong input.
    static func awaitNativeRetirement(since closedAt: Double, _ isReleased: () -> Bool) async throws {
        let deadline = closedAt + 2
        while true {
            let released = autoreleasepool(invoking: isReleased)
            let now = ProcessInfo.processInfo.systemUptime
            guard now <= deadline else { throw failure("Detached native input missed its 2000 ms test deadline") }
            if released { return }
            try await Task.sleep(nanoseconds: UInt64(min(0.01, deadline - now) * 1_000_000_000))
        }
    }

    private static func failure(_ message: String) -> Error { PicShotError.message("Numbered callout lifecycle: \(message)") }
    private func failure(_ message: String) -> Error { Self.failure(message) }
}
