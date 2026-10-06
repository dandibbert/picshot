import Foundation

/// Source coordinates never change when a block is removed. Captured files remain immutable
/// until the session closes; cuts are a small, reversible projection over their contributed strips.
public struct ScrollSequenceBlock: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let sourceID: UUID
    public let documentStart: Int
    public let sourceStart: Int
    public let length: Int
}

public struct ScrollSequenceLayout: Sendable, Equatable {
    public struct Strip: Sendable, Equatable {
        public let block: ScrollSequenceBlock
        public let outputStart: Int
    }
    public let strips: [Strip]
    public let width: Int
    public let height: Int
}

public enum ScrollSequenceError: Error, LocalizedError, Equatable {
    case invalidGeometry, blockLimit, rangeLimit, emptySelection, unknownBlock
    public var errorDescription: String? {
        switch self {
        case .invalidGeometry: return "长截图片段坐标无效，已保留原图。"
        case .blockLimit: return "已达到100个源片段上限，请完成当前截图后重新开始。"
        case .rangeLimit: return "已达到100个裁剪范围或300个输出片段上限。请撤销部分裁剪或完成截图。"
        case .emptySelection: return "请至少保留一条像素带。"
        case .unknownBlock: return "当前截图中已没有该片段。"
        }
    }
}

/// A contiguous document-space union, independent of its edited output. Reversing inside
/// this union only moves the viewport. Extending either edge contributes exactly its new pixels.
public struct ScrollCaptureSequence: Sendable {
    public static let maximumBlocks = 100
    public static let maximumRenderedStrips = 300
    public static let maximumExcludedRanges = 100
    public static let maximumOutputPixels = 60_000_000
    public static let maximumOutputDimension = 32_768
    public static let maximumRasterBytes = 240_000_000
    public let axis: ScrollAxis
    public let frameWidth: Int
    public let frameHeight: Int
    public private(set) var viewportOffset = 0
    public private(set) var lowerBound = 0
    public private(set) var upperBound: Int
    public private(set) var blocks: [ScrollSequenceBlock]

    public init(axis: ScrollAxis, width: Int, height: Int, sourceID: UUID) throws {
        guard width > 0, height > 0, width <= ScrollFrame.maximumDimension,
              height <= ScrollFrame.maximumDimension, width <= ScrollFrame.maximumPixels / height else {
            throw ScrollSequenceError.invalidGeometry
        }
        try Self.validateRaster(width: width, height: height)
        self.axis = axis
        frameWidth = width
        frameHeight = height
        let length = axis == .vertical ? height : width
        upperBound = length
        blocks = [ScrollSequenceBlock(id: UUID(), sourceID: sourceID, documentStart: 0, sourceStart: 0, length: length)]
    }

    /// Call only after image matching verifies the signed motion. All checks precede mutation.
    /// A nil return is a verified revisit and needs no new file or output block.
    @discardableResult
    public mutating func accept(advance: Int, sourceID: UUID) throws -> ScrollSequenceBlock? {
        let length = axis == .vertical ? frameHeight : frameWidth
        guard advance > -length, advance < length, advance != 0 else { throw ScrollSequenceError.invalidGeometry }
        let start = viewportOffset.addingReportingOverflow(advance)
        guard !start.overflow else { throw ScrollStitchError.pixelLimit }
        let end = start.partialValue.addingReportingOverflow(length)
        guard !end.overflow else { throw ScrollStitchError.pixelLimit }
        let lower = min(lowerBound, start.partialValue), upper = max(upperBound, end.partialValue)
        let total = upper.subtractingReportingOverflow(lower)
        guard !total.overflow else { throw ScrollStitchError.pixelLimit }
        try Self.validateRaster(width: axis == .vertical ? frameWidth : total.partialValue,
                                height: axis == .vertical ? total.partialValue : frameHeight)
        let block: ScrollSequenceBlock?
        if lower < lowerBound {
            block = ScrollSequenceBlock(id: UUID(), sourceID: sourceID, documentStart: lower,
                                        sourceStart: 0, length: lowerBound - lower)
        } else if upper > upperBound {
            block = ScrollSequenceBlock(id: UUID(), sourceID: sourceID, documentStart: upperBound,
                                        sourceStart: upperBound - start.partialValue, length: upper - upperBound)
        } else { block = nil }
        if let block {
            guard blocks.count < Self.maximumBlocks,
                  !blocks.contains(where: { $0.sourceID == sourceID }) else { throw ScrollSequenceError.blockLimit }
            if lower < lowerBound { blocks.insert(block, at: 0) } else { blocks.append(block) }
        }
        viewportOffset = start.partialValue
        lowerBound = lower
        upperBound = upper
        return block
    }

    /// Projects immutable document strips into a compact output. A source block may
    /// contribute several strips; every fragment retains its original block/source ID.
    public func layout(removing removed: Set<UUID> = [], within activeRange: Range<Int>? = nil,
                       excluding excludedRanges: [Range<Int>] = []) throws -> ScrollSequenceLayout {
        guard removed.isSubset(of: Set(blocks.map(\.id))) else { throw ScrollSequenceError.unknownBlock }
        let union = lowerBound..<upperBound
        let lower = max(lowerBound, activeRange?.lowerBound ?? lowerBound)
        let upper = min(upperBound, activeRange?.upperBound ?? upperBound)
        guard upper > lower else { throw ScrollSequenceError.emptySelection }
        let excluded = Self.canonicalRanges(excludedRanges, within: union)
        guard excluded.count <= Self.maximumExcludedRanges else { throw ScrollSequenceError.rangeLimit }
        var offset = 0
        var strips: [ScrollSequenceLayout.Strip] = []
        func append(_ range: Range<Int>, from block: ScrollSequenceBlock) throws {
            guard !range.isEmpty else { return }
            guard strips.count < Self.maximumRenderedStrips else { throw ScrollSequenceError.rangeLimit }
            // All endpoints have been intersected with the bounded captured union.
            let length = range.upperBound - range.lowerBound
            let fragment = ScrollSequenceBlock(id: block.id, sourceID: block.sourceID,
                documentStart: range.lowerBound,
                sourceStart: block.sourceStart + range.lowerBound - block.documentStart, length: length)
            strips.append(ScrollSequenceLayout.Strip(block: fragment, outputStart: offset))
            offset += length
        }
        for block in blocks where !removed.contains(block.id) {
            let start = max(lower, block.documentStart)
            let end = min(upper, block.documentStart + block.length)
            guard end > start else { continue }
            var cursor = start
            for cut in excluded {
                guard cut.upperBound > cursor else { continue }
                if cut.lowerBound >= end { break }
                if cut.lowerBound > cursor { try append(cursor..<min(end, cut.lowerBound), from: block) }
                cursor = max(cursor, min(end, cut.upperBound))
                if cursor >= end { break }
            }
            if cursor < end { try append(cursor..<end, from: block) }
        }
        guard !strips.isEmpty else { throw ScrollSequenceError.emptySelection }
        let width = axis == .vertical ? frameWidth : offset
        let height = axis == .vertical ? offset : frameHeight
        try Self.validateRaster(width: width, height: height)
        return ScrollSequenceLayout(strips: strips, width: width, height: height)
    }

    /// Merge overlaps and adjacency without endpoint arithmetic. Clipping before
    /// subtraction also makes Int.min/Int.max external projection bounds safe.
    fileprivate static func canonicalRanges(_ ranges: [Range<Int>], within bounds: Range<Int>? = nil) -> [Range<Int>] {
        let clipped = ranges.compactMap { range -> Range<Int>? in
            let lower = max(range.lowerBound, bounds?.lowerBound ?? range.lowerBound)
            let upper = min(range.upperBound, bounds?.upperBound ?? range.upperBound)
            return upper > lower ? lower..<upper : nil
        }.sorted { $0.lowerBound == $1.lowerBound ? $0.upperBound < $1.upperBound : $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for range in clipped {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        return merged
    }

    public static func validateRaster(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= maximumOutputDimension, height <= maximumOutputDimension,
              width <= maximumOutputPixels / height,
              width <= maximumRasterBytes / 4 / height else { throw ScrollStitchError.pixelLimit }
    }
}

/// Metadata-only projection and bounded history. Capture alignment and immutable source
/// coverage never change when an edge is cropped or an arbitrary output band is removed.
public struct ScrollSequenceEdits: Sendable {
    private struct Snapshot: Sendable, Equatable {
        var removed: Set<UUID> = []
        var activeRange: Range<Int>? = nil
        var excludedRanges: [Range<Int>] = []
        var autoCropEnabled = false
        var establishedDirection: Int? = nil
    }
    private var state = Snapshot()
    public var removed: Set<UUID> { state.removed }
    public var activeRange: Range<Int>? { state.activeRange }
    public var excludedRanges: [Range<Int>] { state.excludedRanges }
    public var autoCropEnabled: Bool { state.autoCropEnabled }
    public var establishedDirection: Int? { state.establishedDirection }
    public private(set) var isEditing = false
    private var entry: Snapshot?
    private var entryUndo: [Snapshot] = []
    private var entryRedo: [Snapshot] = []
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    public var canUndo: Bool { isEditing && !undoStack.isEmpty }
    public var canRedo: Bool { isEditing && !redoStack.isEmpty }
    public init() {}

    public func layout(for sequence: ScrollCaptureSequence) throws -> ScrollSequenceLayout {
        try layout(state, for: sequence)
    }

    /// Call after tentative sequence.accept, before either sequence or source is committed.
    /// Zero initializes a first viewport without establishing a capture direction.
    public mutating func captureMoved(sequence: ScrollCaptureSequence, advance: Int) throws {
        let viewportLength = sequence.axis == .vertical ? sequence.frameHeight : sequence.frameWidth
        guard advance > -viewportLength, advance < viewportLength else { throw ScrollSequenceError.invalidGeometry }
        var next = state
        guard next.autoCropEnabled else {
            next.activeRange = nil; next.establishedDirection = nil
            try install(next, for: sequence)
            return
        }
        let viewport = sequence.viewportOffset..<(sequence.viewportOffset + viewportLength)
        let old = next.activeRange ?? (sequence.lowerBound..<sequence.upperBound)
        if advance == 0 {
            next.activeRange = old
        } else {
            let direction = next.establishedDirection ?? (advance > 0 ? 1 : -1)
            if direction > 0 {
                if viewport.lowerBound <= old.lowerBound {
                    next.activeRange = viewport; next.establishedDirection = nil
                } else {
                    let upper = advance > 0 ? max(old.upperBound, viewport.upperBound) : viewport.upperBound
                    next.activeRange = old.lowerBound..<upper
                    next.establishedDirection = direction
                }
            } else {
                if viewport.upperBound >= old.upperBound {
                    next.activeRange = viewport; next.establishedDirection = nil
                } else {
                    let lower = advance < 0 ? min(old.lowerBound, viewport.lowerBound) : viewport.lowerBound
                    next.activeRange = lower..<old.upperBound
                    next.establishedDirection = direction
                }
            }
        }
        let projected = try layout(next, for: sequence)
        let outputLength = sequence.axis == .vertical ? projected.height : projected.width
        if advance != 0, outputLength <= viewportLength { next.establishedDirection = nil }
        record(next)
    }

    /// Mode changes preserve explicit user cuts. Enabling starts from captured coverage;
    /// the first subsequent signed movement establishes the new direction.
    public mutating func setAutoCropEnabled(_ enabled: Bool, sequence: ScrollCaptureSequence) throws {
        var next = state
        next.autoCropEnabled = enabled
        next.activeRange = enabled ? sequence.lowerBound..<sequence.upperBound : nil
        next.establishedDirection = nil
        try install(next, for: sequence)
    }

    /// Explicit stop/restart resets motion interpretation, not output or user cuts.
    /// Internal capture retries and settling delays must not call this method.
    public mutating func resetCaptureDirection() { state.establishedDirection = nil }

    public mutating func begin() {
        guard !isEditing else { return }
        entry = state; entryUndo = undoStack; entryRedo = redoStack
        // Capture-generated history survives entry so Undo can recover a cropped edge.
        isEditing = true
    }

    public mutating func delete(_ id: UUID, from sequence: ScrollCaptureSequence) throws {
        guard isEditing, sequence.blocks.contains(where: { $0.id == id }), !state.removed.contains(id) else {
            throw ScrollSequenceError.unknownBlock
        }
        var next = state; next.removed.insert(id)
        try install(next, for: sequence)
    }

    /// Output coordinates refer to the current compact preview, not original document
    /// coordinates. A band crossing gaps or source boundaries produces several cuts.
    public mutating func deleteBand(_ outputRange: Range<Int>, from sequence: ScrollCaptureSequence) throws {
        guard isEditing else { throw ScrollSequenceError.invalidGeometry }
        let current = try layout(for: sequence)
        let length = sequence.axis == .vertical ? current.height : current.width
        guard !outputRange.isEmpty, outputRange.lowerBound >= 0, outputRange.upperBound <= length else {
            throw ScrollSequenceError.invalidGeometry
        }
        var cuts = state.excludedRanges
        for strip in current.strips {
            let lower = max(outputRange.lowerBound, strip.outputStart)
            let upper = min(outputRange.upperBound, strip.outputStart + strip.block.length)
            guard upper > lower else { continue }
            let documentStart = strip.block.documentStart + lower - strip.outputStart
            cuts.append(documentStart..<(documentStart + upper - lower))
        }
        var next = state
        next.excludedRanges = ScrollCaptureSequence.canonicalRanges(cuts)
        guard next.excludedRanges.count <= ScrollCaptureSequence.maximumExcludedRanges else { throw ScrollSequenceError.rangeLimit }
        try install(next, for: sequence)
    }

    /// Recover all captured edges without restoring intentional middle cuts or block cuts.
    /// This remains available even after the bounded Undo history drops old movements.
    public mutating func restoreCapturedCoverage(sequence: ScrollCaptureSequence) throws {
        guard isEditing else { throw ScrollSequenceError.invalidGeometry }
        var next = state
        next.activeRange = next.autoCropEnabled ? sequence.lowerBound..<sequence.upperBound : nil
        next.establishedDirection = nil
        try install(next, for: sequence)
    }

    /// Legacy whole-cut reset; does not change auto-cropped edges or the capture direction.
    public mutating func restoreAll() {
        guard isEditing, !state.removed.isEmpty || !state.excludedRanges.isEmpty else { return }
        var next = state; next.removed = []; next.excludedRanges = []
        record(next)
    }
    public mutating func undo() {
        guard isEditing, let previous = undoStack.popLast() else { return }
        redoStack.append(state); state = previous
    }
    public mutating func redo() {
        guard isEditing, let next = redoStack.popLast() else { return }
        undoStack.append(state); state = next
    }
    public mutating func apply() {
        guard isEditing else { return }
        isEditing = false; clearEntry()
    }
    public mutating func cancel() {
        guard isEditing, let entry else { return }
        state = entry; undoStack = entryUndo; redoStack = entryRedo
        isEditing = false; clearEntry()
    }
    private func layout(_ snapshot: Snapshot, for sequence: ScrollCaptureSequence) throws -> ScrollSequenceLayout {
        try sequence.layout(removing: snapshot.removed,
                            within: snapshot.autoCropEnabled ? snapshot.activeRange : nil,
                            excluding: snapshot.excludedRanges)
    }
    private mutating func install(_ next: Snapshot, for sequence: ScrollCaptureSequence) throws {
        _ = try layout(next, for: sequence)
        record(next)
    }
    private mutating func record(_ next: Snapshot) {
        guard next != state else { return }
        undoStack.append(state)
        if undoStack.count > 128 { undoStack.removeFirst() }
        redoStack.removeAll(); state = next
    }
    private mutating func clearEntry() { entry = nil; entryUndo.removeAll(); entryRedo.removeAll() }
}
