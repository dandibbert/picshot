import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin
import PicShotCodecCore

/// A cancellation/commit fence: cancellation that wins the lock prevents all
/// publication. A successfully committed file is complete and never rolled back.
final class ImageExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func check() throws { if isCancelled { throw CancellationError() } }
    func commit(_ action: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try action()
    }
}

/// Queued operations retain only this small holder. Cancelling clears an input
/// immediately even when OperationQueue has not removed the cancelled block.
/// take() transfers ownership to the single running worker exactly once.
final class ImageExportJobInput<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    init(_ value: Value) { self.value = value }
    func take() -> Value? { lock.lock(); defer { lock.unlock() }; let result = value; value = nil; return result }
    func clear() { lock.lock(); value = nil; lock.unlock() }
}

typealias ImageExportBundledEncoder = @Sendable (ImageExportSnapshot, ImageExportOptions) async throws -> ImageExportArtifact

typealias ImageExportEncoder = @Sendable (ImageExportSnapshot, ImageExportOptions, ImageExportCancellation) throws -> ImageExportArtifact

/// Owns pixels, not the editor model or a file-backed data provider. All callers
/// must flatten/redact before constructing this snapshot. Later edits and file
/// deletion cannot alter an in-flight preview or export.
struct ImageExportSnapshot: @unchecked Sendable {
    let image: CGImage
    let sourceURL: URL?
    init(image: CGImage, sourceURL: URL? = nil, limits: ImageExportLimits = .standard,
         drawingRaster: DrawingRasterConfiguration = .process) throws {
        try limits.validate()
        guard image.width > 0, image.height > 0, image.width <= limits.maximumSourcePixels / image.height else {
            throw ImageExportError.sourceTooLarge
        }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw ImageExportError.sourceTooLarge
        }
        context.interpolationQuality = .none
        try DrawingRaster.seedFreshSRGB8Context(context, from: image, configuration: drawingRaster)
        guard let owned = context.makeImage() else { throw ImageExportError.encodeFailed }
        self.image = owned; self.sourceURL = sourceURL?.standardizedFileURL.resolvingSymlinksInPath()
    }
}

struct ImageExportArtifact: @unchecked Sendable {
    let data: Data
    let options: ImageExportOptions
    let width: Int
    let height: Int
    let pageCount: Int
    let firstPreview: CGImage
    let sourceURL: URL?
    var byteCount: Int { data.count }
}

enum ImageExportService {
    /// One shared worker bounds in-process ImageIO/PDF encoders across all sessions.
    /// UI coalescing cancels obsolete pending jobs before adding a replacement.
    static let queue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "PicShot.image-export"
        queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Reviewed bundled writers execute only in a signed child. Native ImageIO
    /// writer availability never enables or substitutes either of these formats.
    static func encodeBundled(snapshot: ImageExportSnapshot, options: ImageExportOptions,
                              service: CodecExportProcessService = .shared) async throws -> ImageExportArtifact {
        try await encodeBundled(snapshot: snapshot, options: options,
            prepare: { try await service.prepare(snapshot: $0, options: $1) })
    }

    /// The production wrapper and deterministic scheduling fixtures share this
    /// exact cancellable retry loop. Injection tests admission/lifecycle only;
    /// it is not a substitute for the real signed-helper codec fixtures.
    static func encodeBundled(snapshot: ImageExportSnapshot, options: ImageExportOptions,
        prepare: @Sendable (ImageExportSnapshot, CodecExportRequest) async throws -> CodecPreparedArtifact,
        admissionWaitSeconds: TimeInterval = CodecExportLimits.wallSeconds) async throws -> ImageExportArtifact {
        guard admissionWaitSeconds.isFinite, admissionWaitSeconds > 0,
              admissionWaitSeconds <= CodecExportLimits.wallSeconds else { throw ImageExportError.invalidOptions }
        try options.validate(); try Task.checkCancellation()
        guard options.format.usesBundledCodec else { throw ImageExportError.invalidOptions }
        try CodecExportLimits.validateStillDimensions(width: snapshot.image.width, height: snapshot.image.height)
        let request = CodecExportRequest(format: options.format == .webp ? .webp : .avif,
            quality: Int((options.quality * 100).rounded()), lossless: options.lossless,
            preserveAlpha: options.preserveAlpha, alphaQuality: Int((options.alphaQuality * 100).rounded()))
        // The shared lease may belong to a cancelling old request, another
        // export sheet or GIF. The running child must exit and clean up before
        // any waiter is admitted. Waiting has a finite deadline and cancellation
        // interrupts its sleep; a format change clears the obsolete UI input.
        let deadline = ProcessInfo.processInfo.systemUptime + admissionWaitSeconds
        while true {
            do {
                try Task.checkCancellation()
                let result = try await prepare(snapshot, request)
                try Task.checkCancellation()
                return ImageExportArtifact(data: result.data, options: options, width: result.width, height: result.height,
                                           pageCount: 1, firstPreview: result.preview, sourceURL: snapshot.sourceURL)
            } catch CodecExportProcessError.busy {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw CodecExportProcessError.busy }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    static func encode(snapshot: ImageExportSnapshot, options: ImageExportOptions,
                       cancellation: ImageExportCancellation = ImageExportCancellation(),
                       limits: ImageExportLimits = .standard) throws -> ImageExportArtifact {
        try limits.validate(); try options.validate(); try cancellation.check()
        guard !options.format.usesBundledCodec else { throw ImageExportError.unavailable(options.format.title + "（需要已签名的独立编码进程）") }
        let image = snapshot.image
        guard image.width <= limits.maximumSourcePixels / image.height else { throw ImageExportError.sourceTooLarge }
        let buffer = ImageExportBuffer(maximumBytes: limits.maximumEncodedBytes, cancellation: cancellation)
        let consumer = try buffer.consumer()
        let pages: Int
        if options.format == .pdf {
            let layout = try ImageExportPDFLayout.make(width: image.width, height: image.height, options: options, limits: limits)
            var box = layout.mediaBox
            guard let context = CGContext(consumer: consumer, mediaBox: &box,
                [kCGPDFContextCreator: "PicShot"] as CFDictionary) else { throw ImageExportError.encodeFailed }
            for page in layout.pages {
                try cancellation.check()
                guard let slice = image.cropping(to: page.source) else { throw ImageExportError.encodeFailed }
                context.beginPDFPage(nil)
                context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
                context.interpolationQuality = .none
                context.draw(slice, in: page.destination)
                context.endPDFPage()
                if let failure = buffer.failure { throw failure }
            }
            context.closePDF()
            pages = layout.pages.count
        } else {
            let type = options.format.contentType.identifier
            guard (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(type),
                  let destination = CGImageDestinationCreateWithDataConsumer(consumer, type as CFString, 1, nil) else {
                throw ImageExportError.unavailable(options.format.title)
            }
            let output = options.format.preservesAlpha ? image : try opaque(image)
            CGImageDestinationAddImage(destination, output,
                [kCGImageDestinationLossyCompressionQuality: options.quality] as CFDictionary)
            try cancellation.check()
            guard CGImageDestinationFinalize(destination) else { throw buffer.failure ?? ImageExportError.encodeFailed }
            pages = 1
        }
        if let failure = buffer.failure { throw failure }
        try cancellation.check()
        guard !buffer.data.isEmpty else { throw ImageExportError.invalidOutput }
        try verify(data: buffer.data, options: options, width: image.width, height: image.height, expectedPages: pages, limits: limits)
        let preview = try preview(data: buffer.data, format: options.format, page: 0, limits: limits)
        try cancellation.check()
        return ImageExportArtifact(data: buffer.data, options: options, width: image.width, height: image.height,
                                   pageCount: pages, firstPreview: preview, sourceURL: snapshot.sourceURL)
    }

    /// Reopens the actual compressed/container bytes. Never renders the source
    /// drawing as a stand-in for a JPEG/PDF preview.
    static func preview(data: Data, format: ImageExportFormat, page: Int = 0,
                        limits: ImageExportLimits = .standard) throws -> CGImage {
        try limits.validate()
        guard !data.isEmpty, data.count <= limits.maximumEncodedBytes, page >= 0 else { throw ImageExportError.invalidOutput }
        // The byte cap also limits dimensions when callers choose a lower cap.
        let dimension = min(limits.previewDimension, Int(sqrt(Double(limits.maximumPreviewBytes / 4))))
        if format == .pdf {
            guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
                  page < document.numberOfPages, let pdfPage = document.page(at: page + 1) else { throw ImageExportError.invalidOutput }
            let box = pdfPage.getBoxRect(.mediaBox)
            guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { throw ImageExportError.invalidOutput }
            let scale = min(1, CGFloat(dimension) / max(box.width, box.height))
            let width = max(1, Int(floor(box.width * scale))), height = max(1, Int(floor(box.height * scale)))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw ImageExportError.invalidOutput }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.concatenate(pdfPage.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(pdfPage)
            guard let result = context.makeImage() else { throw ImageExportError.invalidOutput }
            return result
        }
        guard page == 0, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: dimension,
                 kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width <= dimension, image.height <= dimension,
              image.bytesPerRow <= limits.maximumPreviewBytes / image.height else { throw ImageExportError.invalidOutput }
        return image
    }

    static func verify(data: Data, options: ImageExportOptions, width: Int, height: Int, expectedPages: Int,
                       limits: ImageExportLimits = .standard) throws {
        guard !data.isEmpty, data.count <= limits.maximumEncodedBytes else { throw ImageExportError.outputTooLarge }
        if options.format == .pdf {
            guard data.starts(with: Data("%PDF-".utf8)), let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider), document.numberOfPages == expectedPages else { throw ImageExportError.invalidOutput }
            let layout = try ImageExportPDFLayout.make(width: width, height: height, options: options, limits: limits)
            for index in 1...expectedPages {
                guard let page = document.page(at: index) else { throw ImageExportError.invalidOutput }
                let box = page.getBoxRect(.mediaBox)
                guard abs(box.width - layout.mediaBox.width) < 0.02, abs(box.height - layout.mediaBox.height) < 0.02 else { throw ImageExportError.invalidOutput }
            }
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
                  let identifier = CGImageSourceGetType(source) as String?, identifier == options.format.contentType.identifier,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  properties[kCGImagePropertyPixelWidth] as? Int == width,
                  properties[kCGImagePropertyPixelHeight] as? Int == height else { throw ImageExportError.invalidOutput }
        }
    }

    /// Durable sibling staging followed by exclusive hard-link publication.
    /// link(2) is atomic and refuses collisions, including symlinks; no replace,
    /// remove-original, or check-then-rename race is used. Partial staging files
    /// are private (0600) and deleted on every cancellation/error path.
    static func publish(_ artifact: ImageExportArtifact, to url: URL,
                        cancellation: ImageExportCancellation = ImageExportCancellation(),
                        beforeCommit: (() throws -> Void)? = nil) throws {
        try cancellation.check()
        guard url.isFileURL, !url.lastPathComponent.isEmpty,
              validExtension(url.pathExtension, format: artifact.options.format),
              artifact.data.count > 0, artifact.data.count <= ImageExportLimits.standard.maximumEncodedBytes else {
            throw ImageExportError.invalidDestination
        }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical != artifact.sourceURL else { throw ImageExportError.destinationExists }
        try requireUnoccupied(url)
        let directory = url.deletingLastPathComponent()
        let stage = directory.appendingPathComponent(".picshot-export-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw ImageExportError.writeFailed }
        defer { Darwin.close(descriptor); Darwin.unlink(stage.path) }
        try artifact.data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw ImageExportError.invalidOutput }
            var offset = 0
            while offset < bytes.count {
                try cancellation.check()
                let count = Darwin.write(descriptor, base.advanced(by: offset), min(1_048_576, bytes.count - offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ImageExportError.writeFailed }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw ImageExportError.writeFailed }
        try beforeCommit?()
        try cancellation.commit {
            guard Darwin.link(stage.path, url.path) == 0 else {
                if errno == EEXIST { throw ImageExportError.destinationExists }
                throw ImageExportError.writeFailed
            }
        }
    }

    static func requireUnoccupied(_ url: URL) throws {
        guard url.isFileURL else { throw ImageExportError.invalidDestination }
        var value = stat()
        if Darwin.lstat(url.path, &value) == 0 { throw ImageExportError.destinationExists }
        guard errno == ENOENT else { throw ImageExportError.writeFailed }
    }

    private static func validExtension(_ value: String, format: ImageExportFormat) -> Bool {
        let value = value.lowercased()
        if format == .jpeg { return value == "jpg" || value == "jpeg" }
        if format == .tiff { return value == "tif" || value == "tiff" }
        return value == format.filenameExtension
    }
    private static func opaque(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw ImageExportError.encodeFailed }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw ImageExportError.encodeFailed }; return result
    }
}

private final class ImageExportBuffer {
    private(set) var data = Data()
    private(set) var failure: Error?
    let maximumBytes: Int
    let cancellation: ImageExportCancellation
    init(maximumBytes: Int, cancellation: ImageExportCancellation) { self.maximumBytes = maximumBytes; self.cancellation = cancellation }
    func consumer() throws -> CGDataConsumer {
        var callbacks = CGDataConsumerCallbacks(putBytes: { info, bytes, count in
            guard let info else { return 0 }
            return Unmanaged<ImageExportBuffer>.fromOpaque(info).takeUnretainedValue().append(bytes, count: count)
        }, releaseConsumer: { info in
            if let info { Unmanaged<ImageExportBuffer>.fromOpaque(info).release() }
        })
        let retained = Unmanaged.passRetained(self)
        guard let consumer = CGDataConsumer(info: retained.toOpaque(), cbks: &callbacks) else {
            retained.release(); throw ImageExportError.encodeFailed
        }
        return consumer
    }
    private func append(_ bytes: UnsafeRawPointer, count: Int) -> Int {
        guard failure == nil else { return 0 }
        if cancellation.isCancelled { failure = CancellationError(); return 0 }
        guard count >= 0, count <= maximumBytes - data.count else { failure = ImageExportError.outputTooLarge; return 0 }
        data.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
        return count
    }
}
