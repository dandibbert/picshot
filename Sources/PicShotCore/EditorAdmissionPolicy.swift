/// Admission accounting for owned editor rasters, not a process-RSS limit.
/// Existing edits may grow after admission; this never evicts a document.
public struct EditorAdmissionPolicy {
    public enum Refusal: Equatable { case windowLimit, rasterBudget }
    public let maximumEditors: Int
    public let maximumRasterBytes: Int

    public init(maximumEditors: Int = 6, maximumRasterBytes: Int = 768 * 1024 * 1024) {
        self.maximumEditors = max(0, maximumEditors)
        self.maximumRasterBytes = max(0, maximumRasterBytes)
    }

    public func refusal(existingRasterBytes: [Int], incomingRasterBytes: Int) -> Refusal? {
        guard existingRasterBytes.count < maximumEditors else { return .windowLimit }
        let retained = Self.sum(existingRasterBytes)
        guard incomingRasterBytes >= 0, retained <= maximumRasterBytes,
              incomingRasterBytes <= maximumRasterBytes - retained else { return .rasterBudget }
        return nil
    }

    public static func rasterBytes(bytesPerRow: Int, height: Int) -> Int {
        guard bytesPerRow >= 0, height >= 0 else { return Int.max }
        let product = bytesPerRow.multipliedReportingOverflow(by: height)
        return product.overflow ? Int.max : product.partialValue
    }

    public static func sum(_ costs: [Int]) -> Int {
        var total = 0
        for cost in costs {
            guard cost >= 0 else { return Int.max }
            let result = total.addingReportingOverflow(cost)
            guard !result.overflow else { return Int.max }
            total = result.partialValue
        }
        return total
    }
}

/// Owns no editor. All capture entry points consult this before hiding windows
/// or invoking the injected capture operation, preserving any unfinished edits.
@MainActor
public final class FrozenEditorCaptureAdmission<Editor: AnyObject> {
    public private(set) weak var activeEditor: Editor?
    public init() {}
    public func register(_ editor: Editor) { activeEditor = editor }
    public func editorDidClose(_ editor: Editor) {
        if activeEditor === editor { activeEditor = nil }
    }
    public func shouldStart(isBusy: Bool, isClosed: (Editor) -> Bool, focus: (Editor) -> Void) -> Bool {
        if let editor = activeEditor {
            if isClosed(editor) { activeEditor = nil }
            else { focus(editor); return false }
        }
        return !isBusy
    }
}

/// Coalesces refusals from a multi-file import into one end-of-batch notice.
public struct EditorAdmissionNotices {
    private var depth = 0
    private var refused = 0
    public init() {}
    public mutating func beginBatch() { depth += 1 }
    /// True means show a standalone notice now; false defers it to endBatch.
    public mutating func recordRefusal() -> Bool {
        guard depth > 0 else { return true }
        refused += 1
        return false
    }
    public mutating func endBatch() -> Int {
        guard depth > 0 else { return 0 }
        depth -= 1
        guard depth == 0 else { return 0 }
        defer { refused = 0 }
        return refused
    }
}
