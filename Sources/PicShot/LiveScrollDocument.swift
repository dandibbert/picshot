import AppKit
import PicShotCore
import Darwin

/// Disk-backed, contiguous union of verified viewports. Matching belongs to the caller.
/// All rectangles use integer pixels with a top-left origin in the captured CGImage.
/// Only newly exposed body pixels are persisted; no source frame or encoded PNG is kept.
actor LiveScrollDocument {
    struct Limits: Sendable {
        var maximumOutputPixels = 60_000_000
        var maximumOutputDimension = 32_768
        var maximumDiskBytes: Int64 = 512 * 1_024 * 1_024
        var maximumSources = 100
        static let `default` = Limits()
    }

    enum Failure: Error, LocalizedError, Equatable {
        case invalidGeometry, disconnectedViewport, pixelLimit, storageLimit, sourceLimit
        case staleGeneration, closed, writeFailed, missingStrip, previewLimit

        var errorDescription: String? {
            switch self {
            case .invalidGeometry: return "长截图区域尺寸发生变化，已保留已捕获的内容。"
            case .disconnectedViewport: return "当前画面与已捕获的内容不连续。请稍微回滚后继续。"
            case .pixelLimit: return "长截图已达到像素或边长上限，请完成当前截图。"
            case .storageLimit: return "长截图已达到临时存储上限，请完成当前截图。"
            case .sourceLimit: return "长截图已达到100个源片段上限，请完成当前截图。"
            case .staleGeneration, .closed: return "此次长截图会话已结束。"
            case .writeFailed: return "无法保存长截图的新内容，已保留先前的截图。"
            case .missingStrip: return "长截图临时片段缺失或损坏。"
            case .previewLimit: return "无法创建长截图预览。"
            }
        }
    }

    /// Durable coverage excludes fixed leading/trailing edges. Offset zero denotes the
    /// first viewport's scrolling body. sourceCount includes the first durable viewport.
    struct Snapshot: Sendable, Equatable {
        let width: Int
        let height: Int
        let lowerBound: Int
        let upperBound: Int
        let viewportOffset: Int
        let viewportLength: Int
        let sourceCount: Int
        let diskBytes: Int64
        let generation: UInt64
        let stripCount: Int
        let cachedPreviewBytes: Int
        let sourceReadCount: Int
    }

    struct Update: Sendable {
        /// Number of new pixels along the scroll axis; zero means a file-free revisit.
        let addedPixels: Int
        let snapshot: Snapshot
    }

    struct Preview {
        let image: CGImage
        /// Normalized top-left rectangle of visible body, clipped to preview coverage.
        let viewportFraction: CGRect
        /// Always the durable snapshot, including for a transient preview.
        let snapshot: Snapshot
        let outputWidth: Int
        let outputHeight: Int
        let isTransient: Bool
    }

    // Bounds include rounding overhead for at most 100 body tiles plus two fixed edges.
    static let maximumPreviewPixels = 1_024 * 1_024
    static let maximumPreviewEdge = 1_024
    static let maximumCachedPreviewBytes = 4 * 1_024 * 1_024

    nonisolated let storageDirectory: URL
    nonisolated let axis: ScrollAxis
    nonisolated let generation: UInt64
    nonisolated let scrollingContentRect: CGRect
    nonisolated let viewportCrop: CGRect
    private nonisolated let lifetime = LiveScrollLifetime()
    private let geometry: Geometry
    private let limits: Limits
    private let storage: LiveScrollStripStorage
    private var leading: Strip?
    private var body: [Strip] = []
    private var trailing: Strip?
    private var lowerBound = 0
    private var upperBound: Int
    private var viewportOffset = 0
    private var sourceCount = 0
    private var sourceReadCount = 0
    private var closed = false
    private var beforeCommitForTesting: (@Sendable () -> Void)?

    private struct Strip {
        let url: URL
        let width: Int
        let height: Int
        let start: Int
        let length: Int
        let thumbnail: CGImage
        var thumbnailBytes: Int { thumbnail.bytesPerRow * thumbnail.height }
        func sampled(_ image: CGImage) -> Strip {
            Strip(url: url, width: width, height: height, start: start, length: length, thumbnail: image)
        }
    }

    private struct Geometry: Sendable {
        let frameWidth: Int
        let frameHeight: Int
        let crop: CGRect
        let content: CGRect
        let axis: ScrollAxis
        let cross: Int
        let length: Int
        let leading: Int
        let trailing: Int

        init(image: CGImage, content: CGRect, crop: CGRect?, axis: ScrollAxis) throws {
            let frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let crop = crop ?? frame
            func isPixelRect(_ rect: CGRect) -> Bool {
                [rect.minX, rect.minY, rect.width, rect.height].allSatisfy { $0.isFinite && $0.rounded() == $0 }
                    && rect.width > 0 && rect.height > 0
            }
            guard image.width > 0, image.height > 0, image.width <= 32_768, image.height <= 32_768,
                  isPixelRect(crop), isPixelRect(content),
                  frame.contains(crop), crop.contains(content),
                  (axis == .vertical ? (content.minX == crop.minX && content.width == crop.width)
                                     : (content.minY == crop.minY && content.height == crop.height)) else {
                throw Failure.invalidGeometry
            }
            frameWidth = image.width; frameHeight = image.height
            self.crop = crop; self.content = content; self.axis = axis
            cross = Int(axis == .vertical ? crop.width : crop.height)
            length = Int(axis == .vertical ? content.height : content.width)
            leading = Int(axis == .vertical ? content.minY - crop.minY : content.minX - crop.minX)
            trailing = Int(axis == .vertical ? crop.maxY - content.maxY : crop.maxX - content.maxX)
        }

        func dimensions(bodyLength: Int) -> (width: Int, height: Int) {
            let along = leading + bodyLength + trailing
            return axis == .vertical ? (cross, along) : (along, cross)
        }

        func rectangle(bodyStart: Int, length: Int) -> CGRect {
            axis == .vertical
                ? CGRect(x: content.minX, y: content.minY + CGFloat(bodyStart), width: CGFloat(cross), height: CGFloat(length))
                : CGRect(x: content.minX + CGFloat(bodyStart), y: content.minY, width: CGFloat(length), height: CGFloat(cross))
        }

        var leadingRect: CGRect { rectangle(bodyStart: -leading, length: leading) }
        var trailingRect: CGRect { rectangle(bodyStart: length, length: trailing) }
    }

    /// Async factory keeps initial raster work off the caller's MainActor. An explicit
    /// crop is required to remove cross-axis sidebars; default never silently crops them.
    static func create(firstImage: CGImage, scrollingContentRect: CGRect, axis: ScrollAxis = .vertical,
                       viewportCrop: CGRect? = nil, generation: UInt64 = 0, limits: Limits = .default,
                       storageParent: URL = FileManager.default.temporaryDirectory) async throws -> LiveScrollDocument {
        try Task.checkCancellation()
        let geometry = try Geometry(image: firstImage, content: scrollingContentRect, crop: viewportCrop, axis: axis)
        // Callers may tighten these limits, never expand the original product safeguards.
        guard limits.maximumOutputPixels > 0, limits.maximumOutputPixels <= 60_000_000,
              limits.maximumOutputDimension > 0, limits.maximumOutputDimension <= 32_768,
              limits.maximumDiskBytes > 0, limits.maximumDiskBytes <= 512 * 1_024 * 1_024,
              limits.maximumSources > 0, limits.maximumSources <= 100 else { throw Failure.invalidGeometry }
        let dimensions = geometry.dimensions(bodyLength: geometry.length)
        try validateRaster(width: dimensions.width, height: dimensions.height, limits: limits)
        let storage = try LiveScrollStripStorage(parent: storageParent)
        let document = LiveScrollDocument(geometry: geometry, generation: generation, limits: limits, storage: storage)
        do { try await document.seed(firstImage); return document }
        catch { await document.close(); throw error }
    }

    private init(geometry: Geometry, generation: UInt64, limits: Limits, storage: LiveScrollStripStorage) {
        self.geometry = geometry; self.generation = generation; self.limits = limits; self.storage = storage
        axis = geometry.axis; scrollingContentRect = geometry.content; viewportCrop = geometry.crop
        storageDirectory = storage.directory; upperBound = geometry.length
    }

    /// Interrupts a running write/export immediately, without waiting for the actor queue.
    /// Cancellation permanently invalidates this document; close also removes its files.
    nonisolated func cancel() { lifetime.cancel() }

    func close() {
        cancel()
        guard !closed else { return }
        closed = true; leading = nil; body.removeAll(); trailing = nil; beforeCommitForTesting = nil
        storage.cleanup()
    }

    func snapshot() -> Snapshot {
        let dimensions = geometry.dimensions(bodyLength: upperBound - lowerBound)
        return Snapshot(width: dimensions.width, height: dimensions.height, lowerBound: lowerBound,
                        upperBound: upperBound, viewportOffset: viewportOffset, viewportLength: geometry.length,
                        sourceCount: sourceCount, diskBytes: storage.diskBytes, generation: generation,
                        stripCount: body.count, cachedPreviewBytes: strips.reduce(0) { $0 + $1.thumbnailBytes },
                        sourceReadCount: sourceReadCount)
    }

    /// Tracking frames does not consume durable source slots. The caller may accumulate
    /// motion before append, then append its most recent frame to flush a small remainder.
    @discardableResult
    func updateViewport(offset: Int, generation: UInt64 = 0) throws -> Snapshot {
        try check(generation)
        _ = try coverage(offset: offset)
        try lifetime.commit {
            try check(generation)
            viewportOffset = offset
        }
        return snapshot()
    }

    /// Only invoke after a matcher has verified this absolute body offset. No candidate
    /// images are retained. Revisited content is immutable and needs no write or decode.
    @discardableResult
    func append(image: CGImage, viewportOffset offset: Int, generation: UInt64 = 0) throws -> Update {
        try check(generation); try validate(image)
        let union = try coverage(offset: offset)
        let added = union.upperBound - union.lowerBound - (upperBound - lowerBound)
        guard added > 0 else {
            let current = try updateViewport(offset: offset, generation: generation)
            return Update(addedPixels: 0, snapshot: current)
        }
        guard sourceCount < limits.maximumSources else { throw Failure.sourceLimit }
        let addedStart = union.lowerBound < lowerBound ? union.lowerBound : upperBound
        let bodyRect = geometry.rectangle(bodyStart: addedStart - offset, length: added)
        let newBytes = Int64(geometry.cross) * Int64(added + geometry.trailing) * 4
        try storage.checkCapacity(adding: newBytes, limit: limits.maximumDiskBytes)
        let scale = previewScale(bodyLength: union.count)
        let previousFiles = storage.ownedURLs
        var committed = false
        defer { if !committed { storage.removeCreated(since: previousFiles) } }
        let addedStrip = try persist(image, rectangle: bodyRect, start: addedStart, length: added, scale: scale)
        let newTrailing = geometry.trailing > 0
            ? try persist(image, rectangle: geometry.trailingRect, start: 0, length: geometry.trailing, scale: scale) : nil
        var newBody = try body.map { try resample($0, scale: scale) }
        if union.lowerBound < lowerBound { newBody.insert(addedStrip, at: 0) } else { newBody.append(addedStrip) }
        let newLeading = try leading.map { try resample($0, scale: scale) }
        try validateCache(([newLeading].compactMap { $0 }) + newBody + [newTrailing].compactMap { $0 })
        let commitHook = beforeCommitForTesting
        beforeCommitForTesting = nil
        commitHook?()
        let oldTrailing = trailing
        try lifetime.commit {
            try check(generation)
            leading = newLeading; body = newBody; trailing = newTrailing
            lowerBound = union.lowerBound; upperBound = union.upperBound
            viewportOffset = offset; sourceCount += 1
            committed = true
        }
        // Retiring an obsolete footer cannot damage the immutable current transaction.
        // If unlink fails it remains owned and counted against the disk limit until close.
        if let oldTrailing { storage.remove(oldTrailing.url) }
        return Update(addedPixels: added, snapshot: snapshot())
    }

    func preview() throws -> Preview {
        try check(generation)
        return try compose(leading: leading?.thumbnail, body: body.map { ($0.start, $0.length, $0.thumbnail) },
                           trailing: trailing?.thumbnail, coverage: lowerBound..<upperBound,
                           offset: viewportOffset, transient: false)
    }

    /// Bounded speculative display of a VERIFIED pending frame. It extends only unseen
    /// edge pixels and the latest footer; committed pixels and durable metadata stay put.
    func preview(image: CGImage, viewportOffset offset: Int, generation: UInt64 = 0) throws -> Preview {
        try check(generation); try validate(image)
        let union = try coverage(offset: offset), scale = previewScale(bodyLength: union.count)
        var tiles = body.map { ($0.start, $0.length, $0.thumbnail) }
        if union.lowerBound < lowerBound {
            let length = lowerBound - union.lowerBound
            let tile = try thumbnail(image, rectangle: geometry.rectangle(bodyStart: 0, length: length), scale: scale)
            tiles.insert((union.lowerBound, length, tile), at: 0)
        } else if union.upperBound > upperBound {
            let length = union.upperBound - upperBound
            let tile = try thumbnail(image, rectangle: geometry.rectangle(bodyStart: upperBound - offset, length: length), scale: scale)
            tiles.append((upperBound, length, tile))
        }
        let footer = geometry.trailing > 0 ? try thumbnail(image, rectangle: geometry.trailingRect, scale: scale) : nil
        return try compose(leading: leading?.thumbnail, body: tiles, trailing: footer, coverage: union,
                           offset: offset, transient: true)
    }

    /// Full resolution is allocated only on explicit export. Raw strips are streamed in
    /// bounded chunks into one output bitmap; no encoded image or entire source is decoded.
    func render() throws -> CGImage {
        try check(generation)
        let current = snapshot()
        let context = try makeContext(width: current.width, height: current.height)
        guard let destination = context.data else { throw Failure.pixelLimit }
        var outputStart = 0
        for strip in strips {
            try check(generation)
            let expectedBytes = strip.width * strip.height * 4
            let handle = try storage.read(strip.url, expectedBytes: expectedBytes)
            sourceReadCount += 1
            defer { try? handle.close() }
            let rowBytes = strip.width * 4
            let rowsPerChunk = max(1, (1_024 * 1_024) / rowBytes)
            var firstRow = 0
            while firstRow < strip.height {
                try check(generation)
                let rows = min(rowsPerChunk, strip.height - firstRow), count = rows * rowBytes
                // Copy every byte before draining temporary Foundation read objects.
                // Neither Data nor its borrowed pointer escapes this bounded chunk.
                try autoreleasepool {
                    guard let data = try handle.read(upToCount: count), data.count == count else { throw Failure.missingStrip }
                    data.withUnsafeBytes { source in
                        guard let base = source.baseAddress else { return }
                        if axis == .vertical {
                            destination.advanced(by: (outputStart + firstRow) * current.width * 4).copyMemory(from: base, byteCount: count)
                        } else {
                            for row in 0..<rows {
                                destination.advanced(by: ((firstRow + row) * current.width + outputStart) * 4)
                                    .copyMemory(from: base.advanced(by: row * rowBytes), byteCount: rowBytes)
                            }
                        }
                    }
                }
                firstRow += rows
            }
            outputStart += strip.length
        }
        guard outputStart == (axis == .vertical ? current.height : current.width),
              let image = context.makeImage() else { throw Failure.missingStrip }
        try check(generation)
        return image
    }

    // Deterministic cancellation at the transaction boundary, without sleeps or I/O races.
    func setBeforeCommitHookForTesting(_ hook: (@Sendable () -> Void)?) { beforeCommitForTesting = hook }

    private var strips: [Strip] { [leading].compactMap { $0 } + body + [trailing].compactMap { $0 } }

    private func seed(_ image: CGImage) throws {
        try check(generation)
        let scale = previewScale(bodyLength: geometry.length)
        let size = geometry.dimensions(bodyLength: geometry.length)
        try storage.checkCapacity(adding: Int64(size.width) * Int64(size.height) * 4, limit: limits.maximumDiskBytes)
        let firstLeading = geometry.leading > 0
            ? try persist(image, rectangle: geometry.leadingRect, start: 0, length: geometry.leading, scale: scale) : nil
        let firstBody = try persist(image, rectangle: geometry.content, start: 0, length: geometry.length, scale: scale)
        let firstTrailing = geometry.trailing > 0
            ? try persist(image, rectangle: geometry.trailingRect, start: 0, length: geometry.trailing, scale: scale) : nil
        try validateCache([firstLeading, firstBody, firstTrailing].compactMap { $0 })
        try lifetime.commit {
            try check(generation)
            leading = firstLeading; body = [firstBody]; trailing = firstTrailing; sourceCount = 1
        }
    }

    private func check(_ expectedGeneration: UInt64) throws {
        guard !closed else { throw Failure.closed }
        guard expectedGeneration == generation else { throw Failure.staleGeneration }
        try Task.checkCancellation()
        try lifetime.check()
    }

    private func validate(_ image: CGImage) throws {
        guard image.width == geometry.frameWidth, image.height == geometry.frameHeight else { throw Failure.invalidGeometry }
    }

    private func coverage(offset: Int) throws -> Range<Int> {
        let end = offset.addingReportingOverflow(geometry.length)
        guard !end.overflow else { throw Failure.invalidGeometry }
        guard offset <= upperBound, end.partialValue >= lowerBound else { throw Failure.disconnectedViewport }
        let lower = min(lowerBound, offset), upper = max(upperBound, end.partialValue)
        let length = upper.subtractingReportingOverflow(lower)
        guard !length.overflow, length.partialValue <= limits.maximumOutputDimension else { throw Failure.pixelLimit }
        let size = geometry.dimensions(bodyLength: length.partialValue)
        try Self.validateRaster(width: size.width, height: size.height, limits: limits)
        return lower..<upper
    }

    private static func validateRaster(width: Int, height: Int, limits: Limits) throws {
        guard width > 0, height > 0, width <= limits.maximumOutputDimension, height <= limits.maximumOutputDimension,
              width <= limits.maximumOutputPixels / height else { throw Failure.pixelLimit }
    }

    private func previewScale(bodyLength: Int) -> Double {
        min(1, min(512 / Double(geometry.cross), 1_024 / Double(geometry.leading + bodyLength + geometry.trailing)))
    }

    private func makeContext(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw Failure.pixelLimit
        }
        context.setBlendMode(.copy); context.interpolationQuality = .none
        return context
    }

    private func thumbnail(_ image: CGImage, rectangle: CGRect? = nil, scale: Double) throws -> CGImage {
        try check(generation)
        let source: CGImage
        if let rectangle {
            guard let crop = image.cropping(to: rectangle) else { throw Failure.invalidGeometry }
            source = crop
        } else { source = image }
        let width = max(1, Int(ceil(Double(source.width) * scale)))
        let height = max(1, Int(ceil(Double(source.height) * scale)))
        let context = try makeContext(width: width, height: height)
        context.interpolationQuality = .low
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw Failure.previewLimit }
        return result
    }

    private func resample(_ strip: Strip, scale: Double) throws -> Strip {
        let width = max(1, Int(ceil(Double(strip.width) * scale)))
        let height = max(1, Int(ceil(Double(strip.height) * scale)))
        guard width != strip.thumbnail.width || height != strip.thumbnail.height else { return strip }
        // Committed coverage only grows, so cached samples only shrink. They are never
        // reconstructed by reopening sources, and never retain a full-size crop provider.
        guard width <= strip.thumbnail.width, height <= strip.thumbnail.height else { throw Failure.previewLimit }
        let context = try makeContext(width: width, height: height)
        context.interpolationQuality = .low
        context.draw(strip.thumbnail, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw Failure.previewLimit }
        return strip.sampled(image)
    }

    private func persist(_ image: CGImage, rectangle: CGRect, start: Int, length: Int, scale: Double) throws -> Strip {
        try autoreleasepool {
            try check(generation)
            guard let crop = image.cropping(to: rectangle) else { throw Failure.invalidGeometry }
            let context = try makeContext(width: crop.width, height: crop.height)
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            guard let pixels = context.data else { throw Failure.writeFailed }
            let url = try storage.write(pixels, count: crop.width * crop.height * 4) { try self.check(self.generation) }
            let small = try thumbnail(crop, scale: scale)
            return Strip(url: url, width: crop.width, height: crop.height, start: start, length: length, thumbnail: small)
        }
    }

    private func validateCache(_ tiles: [Strip]) throws {
        guard tiles.reduce(0, { $0 + $1.thumbnailBytes }) <= Self.maximumCachedPreviewBytes else { throw Failure.previewLimit }
    }

    private func compose(leading: CGImage?, body: [(Int, Int, CGImage)], trailing: CGImage?,
                         coverage: Range<Int>, offset: Int, transient: Bool) throws -> Preview {
        let size = geometry.dimensions(bodyLength: coverage.count)
        let scale = previewScale(bodyLength: coverage.count)
        let width = max(1, Int(ceil(Double(size.width) * scale))), height = max(1, Int(ceil(Double(size.height) * scale)))
        guard width <= Self.maximumPreviewEdge, height <= Self.maximumPreviewEdge,
              width * height <= Self.maximumPreviewPixels else { throw Failure.previewLimit }
        let context = try makeContext(width: width, height: height)
        context.interpolationQuality = .low
        let alongPixels = axis == .vertical ? height : width
        let alongLength = axis == .vertical ? size.height : size.width
        func draw(_ image: CGImage, at start: Int, length: Int) {
            // Shared integer boundaries leave neither transparent gaps nor overdraw seams.
            let a = Int((Double(start) / Double(alongLength) * Double(alongPixels)).rounded())
            let b = Int((Double(start + length) / Double(alongLength) * Double(alongPixels)).rounded())
            guard b > a else { return }
            let target = axis == .vertical ? CGRect(x: 0, y: height - b, width: width, height: b - a)
                                           : CGRect(x: a, y: 0, width: b - a, height: height)
            context.draw(image, in: target)
        }
        if let leading { draw(leading, at: 0, length: geometry.leading) }
        for (start, length, image) in body {
            try check(generation)
            draw(image, at: geometry.leading + start - coverage.lowerBound, length: length)
        }
        if let trailing { draw(trailing, at: geometry.leading + coverage.count, length: geometry.trailing) }
        guard let image = context.makeImage() else { throw Failure.previewLimit }
        let visibleStart = max(coverage.lowerBound, min(coverage.upperBound, offset))
        let visibleEnd = max(visibleStart, min(coverage.upperBound, offset + geometry.length))
        let start = Double(geometry.leading + visibleStart - coverage.lowerBound) / Double(alongLength)
        let length = Double(visibleEnd - visibleStart) / Double(alongLength)
        let fraction = axis == .vertical ? CGRect(x: 0, y: start, width: 1, height: length)
                                         : CGRect(x: start, y: 0, width: length, height: 1)
        try check(generation)
        return Preview(image: image, viewportFraction: fraction, snapshot: snapshot(), outputWidth: size.width,
                       outputHeight: size.height, isTransient: transient)
    }
}

/// The lock covers only cancellation and the small metadata commit, never disk I/O.
/// This makes cancellation linearizable even while the actor performs a synchronous write.
private final class LiveScrollLifetime: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var cancelled = false
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
    func commit<T>(_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try Task.checkCancellation()
        return try operation()
    }
}

/// Owns an exclusive session directory and an explicit set of its own files. Cleanup
/// unlinks that set and uses rmdir (never recursively deletes an arbitrary parent).
private final class LiveScrollStripStorage {
    let directory: URL
    private var files: [URL: Int64] = [:]
    var ownedURLs: Set<URL> { Set(files.keys) }
    var diskBytes: Int64 { files.values.reduce(0, +) }

    init(parent: URL) throws {
        directory = parent.appendingPathComponent("PicShot-LiveScroll-" + UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700]) }
        catch { throw LiveScrollDocument.Failure.writeFailed }
    }

    deinit { cleanup() }

    func checkCapacity(adding bytes: Int64, limit: Int64) throws {
        guard bytes > 0, bytes <= limit, diskBytes <= limit - bytes else { throw LiveScrollDocument.Failure.storageLimit }
    }

    func write(_ pixels: UnsafeRawPointer, count: Int, check: () throws -> Void) throws -> URL {
        let name = UUID().uuidString
        let partial = directory.appendingPathComponent(name + ".partial")
        let final = directory.appendingPathComponent(name + ".rgba")
        let descriptor = partial.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)) } ?? -1
        }
        guard descriptor >= 0 else { throw LiveScrollDocument.Failure.writeFailed }
        // Reserve the full size even if a failed write leaves an unremovable partial.
        files[partial] = Int64(count)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var complete = false
        defer {
            try? handle.close()
            if !complete { remove(partial); remove(final) }
        }
        do {
            var written = 0
            while written < count {
                try check()
                let amount = min(1_024 * 1_024, count - written)
                let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pixels.advanced(by: written)), count: amount, deallocator: .none)
                try handle.write(contentsOf: data)
                written += amount
            }
            try check(); try handle.synchronize(); try handle.close()
            try FileManager.default.moveItem(at: partial, to: final)
            files.removeValue(forKey: partial); files[final] = Int64(count)
            complete = true
            return final
        } catch is CancellationError { throw CancellationError() }
        catch let error as LiveScrollDocument.Failure { throw error }
        catch { throw LiveScrollDocument.Failure.writeFailed }
    }

    func read(_ url: URL, expectedBytes: Int) throws -> FileHandle {
        guard files[url] == Int64(expectedBytes) else { throw LiveScrollDocument.Failure.missingStrip }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw LiveScrollDocument.Failure.missingStrip }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size == Int64(expectedBytes) else {
            try? handle.close(); throw LiveScrollDocument.Failure.missingStrip
        }
        return handle
    }

    func remove(_ url: URL) {
        guard files[url] != nil else { return }
        let status = url.withUnsafeFileSystemRepresentation { path in path.map { unlink($0) } ?? -1 }
        if status == 0 || errno == ENOENT { files.removeValue(forKey: url) }
    }

    func removeCreated(since previous: Set<URL>) {
        for url in ownedURLs.subtracting(previous) { remove(url) }
    }

    func cleanup() {
        for url in Array(files.keys) { remove(url) }
        _ = directory.withUnsafeFileSystemRepresentation { path in path.map { rmdir($0) } ?? -1 }
    }
}
