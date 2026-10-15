import AppKit
import CoreGraphics
import PicShotCore

/// One serial matching owner. A rejected match/write never replaces the last
/// verified viewport. Once document work succeeds, matching state is accepted
/// before fallible preview work. Screen acquisition has one replaceable buffer.
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
        /// Verified body coverage extends beyond the durable document union.
        var previewIsTransient = false
        var previewUnavailable = false
    }
    struct Update: @unchecked Sendable {
        let state: State
        let preview: CGImage?
        let viewport: CGRect
    }

    private let axis: ScrollAxis
    private let generation: UInt64
    private let storageParent: URL
    private var firstImage: CGImage?
    private var anchorImage: CGImage?
    private var anchorGray: ScrollFrame?
    private var scrollingRect: CGRect?
    private var document: LiveScrollDocument?
    private var offset = 0
    private var state = State()
    private var cancelled = false
    private let commitDistance = 96
    private static let unsupportedCaptureMessage = "捕获区域太小，请换方向或重选；当前截图可完成"
    private var committedLower = 0
    private var committedUpper = 0
    enum PreviewFailureForTesting { case unavailable, cancelled }
    private var nextPreviewFailureForTesting: PreviewFailureForTesting?
    // One stationary retry per newly accepted anchor whose preview failed. Consume
    // it before display work, so a persistent failure cannot retry on every frame.
    private var stationaryPreviewRetryAvailable = false

    init(axis: ScrollAxis, generation: UInt64, storageParent: URL = FileManager.default.temporaryDirectory) {
        self.axis = axis; self.generation = generation; self.storageParent = storageParent
    }

    func observe(_ image: CGImage) async throws -> Update {
        try check()
        let gray = try autoreleasepool { try ScrollImageIO.luminance(image) }
        try check()
        guard let previous = anchorGray, let previousImage = anchorImage else {
            firstImage = image; anchorImage = image; anchorGray = gray
            state.width = image.width; state.height = image.height
            state.acceptedObservations = 1
            state.matched = LiveScrollMatcher.supportsCapture(width: image.width, height: image.height, axis: axis)
            if !state.matched { state.message = Self.unsupportedCaptureMessage }
            do {
                try injectPreviewFailureForTesting()
                return Update(state: state, preview: try Self.thumbnail(image), viewport: CGRect(x: 0, y: 0, width: 1, height: 1))
            } catch is CancellationError { throw CancellationError() }
            catch {
                // The original image is still finishable and available for an
                // explicit axis change, but unsupported geometry is not verified.
                guard state.matched else {
                    state.previewUnavailable = true
                    return Update(state: state, preview: nil, viewport: .zero)
                }
                return previewUnavailableUpdate()
            }
        }
        guard LiveScrollMatcher.supportsCapture(width: previous.width, height: previous.height, axis: axis) else {
            state.matched = false; state.message = Self.unsupportedCaptureMessage
            return Update(state: state, preview: nil, viewport: .zero)
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
            return try await stationaryUpdate()
        } catch is CancellationError { throw CancellationError() }
        catch {
            state.matched = false
            switch error {
            case ScrollStitchError.noOverlap:
                state.message = "暂未接上，可稍往回滚重试"
            case LiveScrollMatchError.uncertainContentBounds:
                state.message = "固定边界不明确，请慢滚重试"
            case LiveScrollMatchError.unsupportedFixedContent:
                state.message = "固定区域不支持；先完成，再重选正文"
            default:
                state.message = error.localizedDescription
            }
            return Update(state: state, preview: nil, viewport: .zero)
        }
        try check()
        guard match.displacement != 0 else {
            return try await stationaryUpdate()
        }
        let bounds = match.contentBounds.rect
        let detected = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
        if let scrollingRect, scrollingRect != detected {
            state.matched = false; state.message = "固定区域已变化，请缓慢滚动重试；已有内容可完成"
            return Update(state: state, preview: nil, viewport: .zero)
        }
        let sum = offset.addingReportingOverflow(match.displacement)
        guard !sum.overflow else { throw ScrollStitchError.pixelLimit }
        let nextOffset = sum.partialValue
        let bodyLength = axis == .vertical ? Int(detected.height) : Int(detected.width)
        let acceptedSnapshot: LiveScrollDocument.Snapshot
        let acceptedDocument: LiveScrollDocument
        if let document {
            acceptedDocument = document
            // A pending frontier may disappear from the next viewport on reversal.
            // Persist it before replacing the one owned full-image anchor. A large
            // verified step can also outrun the durable union on a short viewport.
            let pendingLeading = offset < committedLower
            let pendingTrailing = offset + bodyLength > committedUpper
            let retreats = (pendingLeading && nextOffset > offset) || (pendingTrailing && nextOffset < offset)
            let disconnects = nextOffset > committedUpper || nextOffset + bodyLength < committedLower
            if (pendingLeading || pendingTrailing) && (retreats || disconnects) {
                let flushed = try await document.append(image: previousImage, viewportOffset: offset, generation: generation)
                guard !cancelled else { throw CancellationError() }
                install(flushed.snapshot)
                // Even if this task was cancelled after the disk commit, metadata
                // is now reconciled with that existing, still-valid old anchor.
                try check()
            }
            let newExtent = max(committedLower - nextOffset, nextOffset + bodyLength - committedUpper)
            // Never accept an unflushable new pending frontier after the source cap.
            let atSourceLimit = state.committedSources >= LiveScrollDocument.Limits.default.maximumSources
            if newExtent >= commitDistance || (newExtent > 0 && atSourceLimit) {
                acceptedSnapshot = try await document.append(image: image, viewportOffset: nextOffset,
                                                               generation: generation).snapshot
            } else {
                acceptedSnapshot = try await document.updateViewport(offset: nextOffset, generation: generation)
            }
        } else {
            let created = try await LiveScrollDocument.create(firstImage: previousImage,
                scrollingContentRect: detected, axis: axis, generation: generation, storageParent: storageParent)
            do {
                acceptedSnapshot = try await created.append(image: image, viewportOffset: nextOffset,
                                                              generation: generation).snapshot
                try check()
            } catch {
                created.cancel(); await created.close(); throw error
            }
            document = created; acceptedDocument = created; scrollingRect = detected
            state.fixedLeading = axis == .vertical ? Int(detected.minY) : Int(detected.minX)
            state.fixedTrailing = axis == .vertical ? image.height - Int(detected.maxY) : image.width - Int(detected.maxX)
            firstImage = nil
        }
        // No suspension or fallible display work between successful document work
        // and the matching-state commit. Explicit close must not resurrect an anchor.
        guard !cancelled else { throw CancellationError() }
        anchorGray = gray; anchorImage = image; offset = nextOffset
        state.acceptedObservations += 1; state.viewportOffset = offset
        stationaryPreviewRetryAvailable = false
        install(acceptedSnapshot)
        // Logical dimensions include the verified pending viewport even if its
        // display cannot be regenerated. The old visible thumbnail stays intact.
        let verifiedLower = min(acceptedSnapshot.lowerBound, nextOffset)
        let verifiedUpper = max(acceptedSnapshot.upperBound, nextOffset + bodyLength)
        let verifiedLength = state.fixedLeading + verifiedUpper - verifiedLower + state.fixedTrailing
        if axis == .vertical { state.height = verifiedLength } else { state.width = verifiedLength }
        state.previewIsTransient = verifiedLower != acceptedSnapshot.lowerBound || verifiedUpper != acceptedSnapshot.upperBound
        state.matched = true
        try check()
        do {
            try injectPreviewFailureForTesting()
            let preview = try await acceptedDocument.preview(image: image, viewportOffset: nextOffset, generation: generation)
            try check()
            state.width = preview.outputWidth; state.height = preview.outputHeight
            state.previewUnavailable = false
            state.message = (state.fixedLeading + state.fixedTrailing) > 0
                ? "正在接长 · 固定页眉/页脚保留一次" : "正在接长 · 可向回滚动"
            return Update(state: state, preview: preview.image, viewport: preview.viewportFraction)
        } catch is CancellationError { throw CancellationError() }
        catch {
            try check()
            return previewUnavailableUpdate()
        }
    }

    func finish() async throws -> CGImage {
        try check()
        guard let document else {
            guard let firstImage else { throw CaptureError.invalidRegion }
            return firstImage
        }
        guard let anchorImage else { throw CaptureError.invalidRegion }
        let flushed = try await document.append(image: anchorImage, viewportOffset: offset, generation: generation)
        guard !cancelled else { throw CancellationError() }
        install(flushed.snapshot); state.previewIsTransient = false
        try check()
        let image = try await document.render()
        try check()
        return image
    }

    func documentSnapshotForResourceVerification() async -> LiveScrollDocument.Snapshot? {
        await document?.snapshot()
    }
    func currentState() -> State { state }
    func initialImageForAxisChange() -> CGImage? { document == nil ? anchorImage : nil }
    func close() async {
        cancelled = true; nextPreviewFailureForTesting = nil
        stationaryPreviewRetryAvailable = false
        document?.cancel()
        if let document { await document.close() }
        document = nil; anchorImage = nil; firstImage = nil; anchorGray = nil
    }

    func failNextPreviewForTesting(_ failure: PreviewFailureForTesting = .unavailable) {
        nextPreviewFailureForTesting = failure
    }
    private func injectPreviewFailureForTesting() throws {
        guard let failure = nextPreviewFailureForTesting else { return }
        nextPreviewFailureForTesting = nil
        switch failure {
        case .unavailable: throw LiveScrollDocument.Failure.previewLimit
        case .cancelled: throw CancellationError()
        }
    }
    private func previewUnavailableUpdate(allowStationaryRetry: Bool = true) -> Update {
        state.previewUnavailable = true
        stationaryPreviewRetryAvailable = allowStationaryRetry
        state.message = "预览暂时无法更新，已验证内容保留，可继续或完成"
        return Update(state: state, preview: nil, viewport: .zero)
    }

    /// Called only after the matcher verifies the current frame is stationary.
    /// Rebuild from the already accepted anchor, including an uncommitted frontier;
    /// the candidate frame never replaces it or changes the durable document.
    private func stationaryUpdate() async throws -> Update {
        try check()
        state.matched = true
        guard state.previewUnavailable, stationaryPreviewRetryAvailable, let anchorImage else {
            if !state.previewUnavailable { state.message = "已接上 · 继续滚动，或完成截图" }
            return Update(state: state, preview: nil, viewport: .zero)
        }
        stationaryPreviewRetryAvailable = false
        do {
            try injectPreviewFailureForTesting()
            let preview: CGImage
            let viewport: CGRect
            if let document {
                let recovered = try await document.preview(image: anchorImage, viewportOffset: offset, generation: generation)
                preview = recovered.image; viewport = recovered.viewportFraction
            } else {
                preview = try Self.thumbnail(anchorImage)
                viewport = CGRect(x: 0, y: 0, width: 1, height: 1)
            }
            try check()
            state.previewUnavailable = false
            state.message = "已接上 · 继续滚动，或完成截图"
            return Update(state: state, preview: preview, viewport: viewport)
        } catch is CancellationError { throw CancellationError() }
        catch {
            try check()
            // Keep the failure and the UI's last good preview. Only accepting new
            // motion opens another preview attempt; stationary polling is bounded.
            return previewUnavailableUpdate(allowStationaryRetry: false)
        }
    }

    private func install(_ snapshot: LiveScrollDocument.Snapshot) {
        state.width = snapshot.width; state.height = snapshot.height
        state.committedSources = snapshot.sourceCount; state.diskBytes = snapshot.diskBytes
        state.previewIsTransient = false
        committedLower = snapshot.lowerBound; committedUpper = snapshot.upperBound
    }
    private func check() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }
    private static func thumbnail(_ image: CGImage) throws -> CGImage {
        let scale = min(1, 800 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale)), height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height,
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
