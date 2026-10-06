import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo

/// Normalized, bottom-left coordinates. All layout changes are sampled together
/// at a screen-frame boundary, so the preview and encoder use the same geometry.
struct RecordingCameraLayout: Equatable {
    var frame = CGRect(x: 0.73, y: 0.04, width: 0.23, height: 0.28)
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var mirrored = true
    var circular = false

    mutating func constrain() {
        frame = Self.unitRect(frame, minimum: 0.08)
        crop = Self.unitRect(crop, minimum: 0.1)
    }

    static func unitRect(_ rect: CGRect, minimum: CGFloat) -> CGRect {
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else {
            return CGRect(x: 0, y: 0, width: minimum, height: minimum)
        }
        let width = min(1, max(minimum, rect.width)), height = min(1, max(minimum, rect.height))
        return CGRect(x: min(1 - width, max(0, rect.minX)), y: min(1 - height, max(0, rect.minY)),
                      width: width, height: height)
    }

    func pixelFrame(in size: CGSize) -> CGRect {
        CGRect(x: frame.minX * size.width, y: frame.minY * size.height,
               width: frame.width * size.width, height: frame.height * size.height)
    }
}

struct RecordingCompositionSnapshot {
    let revision: UInt64
    let camera: CVPixelBuffer?
    let cameraLayout: RecordingCameraLayout
    let annotations: [ImageAnnotation]
    let canvasSize: CGSize
}

/// Exactly one camera surface, one immutable vector snapshot, no frame history.
/// The camera token rejects callbacks from a disabled/replaced capture session.
final class RecordingCompositionState: @unchecked Sendable {
    static let maximumAnnotations = 256
    static let maximumPointsPerStroke = 4_096
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var cameraToken: UUID?
    private var camera: CVPixelBuffer?
    private var layout = RecordingCameraLayout()
    private var annotations: [ImageAnnotation] = []
    private var canvasSize = CGSize(width: 1_920, height: 1_080)

    func snapshot() -> RecordingCompositionSnapshot {
        lock.lock(); defer { lock.unlock() }
        return RecordingCompositionSnapshot(revision: revision, camera: camera, cameraLayout: layout,
            annotations: annotations, canvasSize: canvasSize)
    }

    func setCameraSession(_ token: UUID?) {
        lock.lock(); defer { lock.unlock() }
        cameraToken = token; camera = nil; revision &+= 1
    }

    func receiveCamera(_ frame: CVPixelBuffer, token: UUID) {
        guard CVPixelBufferGetWidth(frame) <= 1_920, CVPixelBufferGetHeight(frame) <= 1_920 else { return }
        lock.lock(); defer { lock.unlock() }
        guard cameraToken == token else { return }
        camera = frame; revision &+= 1
    }

    func setLayout(_ proposed: RecordingCameraLayout) {
        lock.lock(); defer { lock.unlock() }
        layout = proposed; layout.constrain(); revision &+= 1
    }

    func setCanvasSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return }
        lock.lock(); defer { lock.unlock() }
        // A new recording has a fresh coordinate system. Never stretch old marks
        // from one display/region across a different recording target.
        canvasSize = size; annotations.removeAll(); revision &+= 1
    }

    @discardableResult
    func setAnnotations(_ proposed: [ImageAnnotation]) -> Bool {
        let liveTools: Set<ImageEditorTool> = [.freehand, .arrow, .rectangle, .ellipse, .highlighter, .eraser]
        guard proposed.count <= Self.maximumAnnotations,
              proposed.allSatisfy({ liveTools.contains($0.tool) && $0.lineWidth.isFinite &&
                  (1...80).contains($0.lineWidth) && $0.rotation.isFinite && $0.opacity.isFinite &&
                  $0.points.count <= Self.maximumPointsPerStroke &&
                  $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite } }) else { return false }
        lock.lock(); defer { lock.unlock() }
        annotations = proposed; revision &+= 1
        return true
    }
}

/// One output pool with a hard three-surface allocation threshold. The caller
/// drops a frame on encoder backpressure rather than growing a pixel queue.
final class RecordingFrameCompositor {
    /// Match the sRGB raster produced below. Without explicit primaries, an SD
    /// H.264 track may be tagged SMPTE-C and turn pure green into visible red
    /// after the decoder's color-managed conversion back to sRGB.
    static let videoColorProperties: [String: String] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
    ]

    let state: RecordingCompositionState
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let size: CGSize
    private let pool: CVPixelBufferPool
    private var format: CMVideoFormatDescription?
    private var frozenSnapshot: RecordingCompositionSnapshot?
    private(set) var lastRevision: UInt64?

    init(size: CGSize, state: RecordingCompositionState) throws {
        guard size.width.isFinite, size.height.isFinite, size.width >= 2, size.height >= 2,
              size.width <= 3_840, size.height <= 3_840, size.width * size.height <= 8_294_400 else {
            throw RecordingError.failed("The recording overlay size is outside the bounded encoder dimensions.")
        }
        self.size = size; self.state = state
        var created: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created) == kCVReturnSuccess,
              let created else { throw RecordingError.failed("The recording overlay pool could not be created.") }
        pool = created
    }

    var needsRefresh: Bool { frozenSnapshot == nil && state.snapshot().revision != lastRevision }

    /// Called on the encoder queue at its stop barrier. Pending-resume output
    /// must not sample a camera frame or annotation changed after Stop.
    func freeze() { if frozenSnapshot == nil { frozenSnapshot = state.snapshot() } }
    func releaseFrozenSnapshot() { frozenSnapshot = nil }

    /// Source sample timing is replaced only by RecordingWriter's shared timeline.
    func composite(_ source: CMSampleBuffer) throws -> CMSampleBuffer? {
        let snapshot = frozenSnapshot ?? state.snapshot()
        guard let sourcePixels = CMSampleBufferGetImageBuffer(source) else { return nil }
        if snapshot.camera == nil, snapshot.annotations.isEmpty {
            lastRevision = snapshot.revision
            return source
        }
        var allocated: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey as String: 3] as CFDictionary, &allocated)
        if status == kCVReturnWouldExceedAllocationThreshold { return nil }
        guard status == kCVReturnSuccess, let pixels = allocated else {
            throw RecordingError.failed("A recording overlay surface could not be allocated.")
        }
        // Color conversion into an sRGB CGContext does not tag the new CV
        // surface. Attach its actual output space before making the sample's
        // format description, so VideoToolbox need not guess from dimensions.
        CVBufferSetAttachment(pixels, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        let extent = CGRect(origin: .zero, size: size)
        let sourceImage = CIImage(cvPixelBuffer: sourcePixels)
        let scale = CGAffineTransform(scaleX: size.width / sourceImage.extent.width, y: size.height / sourceImage.extent.height)
        context.render(sourceImage.transformed(by: scale), to: pixels, bounds: extent, colorSpace: colorSpace)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        guard let drawing = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw RecordingError.failed("The recording overlay context could not be created.")
        }
        Self.drawCamera(snapshot, context: drawing, size: size, imageContext: context)
        drawing.saveGState()
        drawing.scaleBy(x: size.width / snapshot.canvasSize.width, y: size.height / snapshot.canvasSize.height)
        ImageEditorRenderer.drawAnnotations(snapshot.annotations, in: drawing,
            extent: CGRect(origin: .zero, size: snapshot.canvasSize))
        drawing.restoreGState()
        if format == nil {
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                formatDescriptionOut: &format) == noErr else { throw RecordingError.failed("Invalid overlay pixel format.") }
        }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(source),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(source), decodeTimeStamp: .invalid)
        var output: CMSampleBuffer?
        guard let format, CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixels, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &output) == noErr,
              let output else { throw RecordingError.failed("The recording overlay frame could not be prepared.") }
        lastRevision = snapshot.revision
        return output
    }

    static func drawCamera(_ snapshot: RecordingCompositionSnapshot, context: CGContext,
                           size: CGSize, imageContext: CIContext) {
        guard let pixels = snapshot.camera else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        let crop = snapshot.cameraLayout.crop
        let region = CGRect(x: image.extent.minX + crop.minX * image.extent.width,
            y: image.extent.minY + crop.minY * image.extent.height,
            width: crop.width * image.extent.width, height: crop.height * image.extent.height)
        guard let cameraImage = imageContext.createCGImage(image.cropped(to: region), from: region) else { return }
        let target = snapshot.cameraLayout.pixelFrame(in: size)
        context.saveGState()
        let radius = snapshot.cameraLayout.circular ? min(target.width, target.height) / 2 : min(16, target.height * 0.08)
        let path = snapshot.cameraLayout.circular ? CGPath(ellipseIn: target, transform: nil) :
            CGPath(roundedRect: target, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path); context.clip()
        if snapshot.cameraLayout.mirrored {
            context.translateBy(x: 2 * target.midX, y: 0); context.scaleBy(x: -1, y: 1)
        }
        let factor = max(target.width / CGFloat(cameraImage.width), target.height / CGFloat(cameraImage.height))
        let drawn = CGSize(width: CGFloat(cameraImage.width) * factor, height: CGFloat(cameraImage.height) * factor)
        context.interpolationQuality = .medium
        context.draw(cameraImage, in: CGRect(x: target.midX - drawn.width / 2, y: target.midY - drawn.height / 2,
                                           width: drawn.width, height: drawn.height))
        context.restoreGState()
    }
}
