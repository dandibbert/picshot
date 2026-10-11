import AppKit
import CoreGraphics
import PicShotCore

/// One serial matching owner. A failed candidate never replaces the last verified
/// viewport, the document position, or the committed strips. Screen acquisition
/// runs independently with one replaceable pending buffer.
actor LiveScrollAssembler {
    struct State: Sendable {
        var width = 0
        var height = 0
        var viewportOffset = 0
        var acceptedObservations = 0
        var committedSources = 0
        var diskBytes: Int64 = 0
        var matched = false
        var message = "滚动页面，图片会自动接长"
        var fixedLeading = 0
        var fixedTrailing = 0
        var previewIsTransient = false
    }
    struct Update: @unchecked Sendable {
        let state: State
        let preview: CGImage?
        let viewport: CGRect
    }

    private let axis: ScrollAxis
    private let generation: UInt64
    private var firstImage: CGImage?
    private var anchorImage: CGImage?
    private var anchorGray: ScrollFrame?
    private var scrollingRect: CGRect?
    private var document: LiveScrollDocument?
    private var offset = 0
    private var state = State()
    private var cancelled = false
    private let commitDistance = 96
    private var committedLower = 0
    private var committedUpper = 0

    init(axis: ScrollAxis, generation: UInt64) {
        self.axis = axis; self.generation = generation
    }

    func observe(_ image: CGImage) async throws -> Update {
        try check()
        let gray = try autoreleasepool { try ScrollImageIO.luminance(image) }
        try check()
        guard let previous = anchorGray, let previousImage = anchorImage else {
            firstImage = image; anchorImage = image; anchorGray = gray
            state.width = image.width; state.height = image.height
            state.acceptedObservations = 1; state.matched = true
            return Update(state: state, preview: try Self.thumbnail(image), viewport: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let match: LiveScrollMatch
        do {
            var configuration = LiveScrollMatcher.Configuration()
            if let scrollingRect {
                configuration.lockedContentBounds = LiveScrollPixelRect(x: Int(scrollingRect.minX), y: Int(scrollingRect.minY),
                    width: Int(scrollingRect.width), height: Int(scrollingRect.height))
            }
            match = try LiveScrollMatcher.match(previous: previous, next: gray, axis: axis, configuration: configuration)
        } catch ScrollStitchError.duplicate {
            state.matched = true; state.message = "已接上 · 继续滚动，或完成截图"
            return Update(state: state, preview: nil, viewport: .zero)
        } catch is CancellationError { throw CancellationError() }
        catch {
            state.matched = false
            state.message = "暂未接上，稍往回滚即可继续"
            return Update(state: state, preview: nil, viewport: .zero)
        }
        try check()
        guard match.displacement != 0 else {
            state.matched = true; state.message = "已接上 · 继续滚动，或完成截图"
            return Update(state: state, preview: nil, viewport: .zero)
        }
        let bounds = match.contentBounds.rect
        let detected = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
        if let scrollingRect, scrollingRect != detected {
            state.matched = false; state.message = "页面固定区域变了，往回滚到已捕获位置重接"
            return Update(state: state, preview: nil, viewport: .zero)
        }
        let sum = offset.addingReportingOverflow(match.displacement)
        guard !sum.overflow else { throw ScrollStitchError.pixelLimit }
        let nextOffset = sum.partialValue
        let bodyLength = axis == .vertical ? Int(detected.height) : Int(detected.width)
        if document == nil {
            let created = try await LiveScrollDocument.create(firstImage: previousImage,
                scrollingContentRect: detected, axis: axis, generation: generation)
            do {
                _ = try await created.append(image: image, viewportOffset: nextOffset, generation: generation)
                try check()
            } catch {
                created.cancel(); await created.close(); throw error
            }
            document = created; scrollingRect = detected
            committedLower = min(0, nextOffset); committedUpper = max(bodyLength, nextOffset + bodyLength)
            state.fixedLeading = axis == .vertical ? Int(detected.minY) : Int(detected.minX)
            state.fixedTrailing = axis == .vertical ? image.height - Int(detected.maxY) : image.width - Int(detected.maxX)
            firstImage = nil
        }
        guard let document else { throw ScrollSequenceError.invalidGeometry }
        let newExtent = max(committedLower - nextOffset, nextOffset + bodyLength - committedUpper)
        if newExtent >= commitDistance {
            _ = try await document.append(image: image, viewportOffset: nextOffset, generation: generation)
        } else {
            _ = try await document.updateViewport(offset: nextOffset, generation: generation)
        }
        try check()
        let preview = try await document.preview(image: image, viewportOffset: nextOffset, generation: generation)
        try check()
        anchorGray = gray; anchorImage = image; offset = nextOffset
        state.acceptedObservations += 1; state.viewportOffset = offset
        install(preview.snapshot)
        state.width = preview.outputWidth; state.height = preview.outputHeight
        state.previewIsTransient = preview.isTransient
        state.matched = true
        state.message = (state.fixedLeading + state.fixedTrailing) > 0
            ? "正在接长 · 固定页眉/页脚保留一次" : "正在接长 · 可向回滚动"
        return Update(state: state, preview: preview.image, viewport: preview.viewportFraction)
    }

    func finish() async throws -> CGImage {
        try check()
        guard let document else {
            guard let firstImage else { throw CaptureError.invalidRegion }
            return firstImage
        }
        guard let anchorImage else { throw CaptureError.invalidRegion }
        _ = try await document.append(image: anchorImage, viewportOffset: offset, generation: generation)
        try check()
        return try await document.render()
    }

    func currentState() -> State { state }
    func initialImageForAxisChange() -> CGImage? { document == nil ? anchorImage : nil }
    func close() async {
        cancelled = true
        document?.cancel()
        if let document { await document.close() }
        document = nil; anchorImage = nil; firstImage = nil; anchorGray = nil
    }

    private func install(_ snapshot: LiveScrollDocument.Snapshot) {
        state.width = snapshot.width; state.height = snapshot.height
        state.committedSources = snapshot.sourceCount; state.diskBytes = snapshot.diskBytes
        committedLower = snapshot.lowerBound; committedUpper = snapshot.upperBound
    }
    private func check() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }
    private static func thumbnail(_ image: CGImage) throws -> CGImage {
        let scale = min(1, 800 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale)), height = max(1, Int(CGFloat(image.height) * scale))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        return try bytes.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ScrollSequenceError.invalidGeometry
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let result = context.makeImage() else { throw ScrollSequenceError.invalidGeometry }
            return result
        }
    }
}
