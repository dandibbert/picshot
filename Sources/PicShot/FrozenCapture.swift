import CoreGraphics
import Foundation
import PicShotCore

/// Presentation metadata exists only when PicShot owns the frozen source frame
/// and knows the exact pixels selected from it. Imported/system captures omit it.
struct CapturedImage {
    let image: CGImage
    let presentation: FrozenCapturePresentation?

    static func frozenRegion(image: CGImage, displayID: CGDirectDisplayID,
                             displayFrame: CGRect, selection: CGRect, capturedAt: Date = Date()) throws -> CapturedImage {
        guard displayFrame.origin.x.isFinite, displayFrame.origin.y.isFinite,
              displayFrame.maxX.isFinite, displayFrame.maxY.isFinite else { throw CaptureError.invalidRegion }
        let geometry = try FrozenCaptureGeometry(pointSize: displayFrame.size,
                                                  pixelWidth: image.width, pixelHeight: image.height)
        let aligned = try geometry.alignedSelection(selection)
        return try frozenAlignedRegion(image: image, displayID: displayID, displayFrame: displayFrame,
                                       aligned: aligned, capturedAt: capturedAt)
    }

    /// Saved regions own integral pixel coordinates. Do not convert those pixels
    /// to points and floor them again: fractional densities can add an edge pixel.
    static func frozenPixelRegion(image: CGImage, displayID: CGDirectDisplayID,
                                  displayFrame: CGRect, pixelFrame: CGRect, capturedAt: Date = Date(), aspectRatio: CaptureAspectRatio? = nil) throws -> CapturedImage {
        guard displayFrame.minX.isFinite, displayFrame.minY.isFinite,
              displayFrame.maxX.isFinite, displayFrame.maxY.isFinite else { throw CaptureError.invalidRegion }
        let geometry = try FrozenCaptureGeometry(pointSize: displayFrame.size, pixelWidth: image.width, pixelHeight: image.height)
        let aligned = try geometry.selectionForPixels(pixelFrame)
        if let aspectRatio, pixelFrame.width * CGFloat(aspectRatio.denominator) != pixelFrame.height * CGFloat(aspectRatio.numerator) {
            throw CaptureError.invalidRegion
        }
        return try frozenAlignedRegion(image: image, displayID: displayID, displayFrame: displayFrame,
                                       aligned: aligned, capturedAt: capturedAt, aspectRatio: aspectRatio)
    }

    private static func frozenAlignedRegion(image: CGImage, displayID: CGDirectDisplayID,
                                            displayFrame: CGRect, aligned: FrozenCaptureGeometry.Selection,
                                            capturedAt: Date, aspectRatio: CaptureAspectRatio? = nil) throws -> CapturedImage {
        guard let crop = image.cropping(to: aligned.pixelFrame),
              crop.width == Int(aligned.pixelFrame.width), crop.height == Int(aligned.pixelFrame.height) else {
            throw CaptureError.failed("Could not prepare the selected pixels.")
        }
        // CGImage.cropping can retain the full desktop provider. History and
        // export receive only the selected raster; presentation alone owns the
        // frozen desktop, and the editor can release it when dismissed.
        try Task.checkCancellation()
        let colorSpace = image.colorSpace?.model == .rgb ? image.colorSpace : CGColorSpace(name: CGColorSpace.sRGB)
        guard let colorSpace,
              let context = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8,
                                      bytesPerRow: crop.width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw CaptureError.failed("Could not allocate the selected pixels.")
        }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        try Task.checkCancellation()
        guard let result = context.makeImage() else { throw CaptureError.failed("Could not prepare the selected pixels.") }
        return CapturedImage(image: result, presentation: FrozenCapturePresentation(
            frozenImage: image, displayID: displayID, displayFrame: displayFrame,
            selectionFrame: aligned.selectionFrame, capturedAt: capturedAt, aspectRatio: aspectRatio))
    }
}

struct FrozenCapturePresentation {
    let frozenImage: CGImage
    let displayID: CGDirectDisplayID
    /// Global AppKit points, Y upwards. This is the actual captured NSScreen frame.
    let displayFrame: CGRect
    /// Display-local AppKit points, Y upwards, aligned to the original image pixels.
    let selectionFrame: CGRect
    /// Fixed once when this frozen source capture is prepared.
    var capturedAt: Date = Date()
    /// Selection-only lock, measured in original source pixels.
    var aspectRatio: CaptureAspectRatio? = nil
}

/// Converts native selector coordinates to the exact frozen pixels, then derives
/// placement back from those pixels. Never use the crop's center as its origin or
/// round Retina selections to whole logical points.
struct FrozenCaptureGeometry {
    struct Selection: Equatable {
        /// CGImage crop coordinates, Y downwards, in integral source pixels.
        let pixelFrame: CGRect
        /// Selector-local points, Y downwards.
        let topLeftFrame: CGRect
        /// Editor-local points, Y upwards.
        let selectionFrame: CGRect
    }

    let pointSize: CGSize
    let pixelWidth: Int
    let pixelHeight: Int

    init(pointSize: CGSize, pixelWidth: Int, pixelHeight: Int) throws {
        guard pointSize.width.isFinite, pointSize.height.isFinite,
              pointSize.width >= 1, pointSize.height >= 1 else { throw CaptureError.invalidRegion }
        guard DisplayCompositeLayout.allowsSize(width: pixelWidth, height: pixelHeight) else {
            throw DisplayCompositeError.pixelLimit
        }
        self.pointSize = pointSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    func selectionForPixels(_ pixels: CGRect) throws -> Selection {
        guard pixels.minX.isFinite, pixels.minY.isFinite, pixels.width.isFinite, pixels.height.isFinite,
              pixels.maxX.isFinite, pixels.maxY.isFinite,
              [pixels.minX, pixels.minY, pixels.width, pixels.height].allSatisfy({ $0.rounded() == $0 }),
              pixels.minX >= 0, pixels.minY >= 0, pixels.width > 0, pixels.height > 0,
              pixels.maxX <= CGFloat(pixelWidth), pixels.maxY <= CGFloat(pixelHeight) else { throw CaptureError.invalidRegion }
        let scaleX = CGFloat(pixelWidth) / pointSize.width, scaleY = CGFloat(pixelHeight) / pointSize.height
        let local = CGRect(x: pixels.minX / scaleX, y: pixels.minY / scaleY, width: pixels.width / scaleX, height: pixels.height / scaleY)
        guard local.width >= 2, local.height >= 2 else { throw CaptureError.invalidRegion }
        return Selection(pixelFrame: pixels, topLeftFrame: local,
                         selectionFrame: CGRect(x: local.minX, y: pointSize.height - pixels.maxY / scaleY,
                                                width: local.width, height: local.height))
    }

    func alignedSelection(_ rectangle: CGRect, minimumPointSize: CGFloat = 2) throws -> Selection {
        guard rectangle.origin.x.isFinite, rectangle.origin.y.isFinite,
              rectangle.width.isFinite, rectangle.height.isFinite,
              rectangle.minX.isFinite, rectangle.minY.isFinite,
              rectangle.maxX.isFinite, rectangle.maxY.isFinite else { throw CaptureError.invalidRegion }
        let clipped = rectangle.standardized.intersection(CGRect(origin: .zero, size: pointSize))
        guard !clipped.isNull, !clipped.isEmpty,
              clipped.width >= minimumPointSize, clipped.height >= minimumPointSize else {
            throw CaptureError.invalidRegion
        }
        let scaleX = CGFloat(pixelWidth) / pointSize.width
        let scaleY = CGFloat(pixelHeight) / pointSize.height
        let left = max(0, min(CGFloat(pixelWidth), floor(clipped.minX * scaleX)))
        let top = max(0, min(CGFloat(pixelHeight), floor(clipped.minY * scaleY)))
        let right = max(left, min(CGFloat(pixelWidth), ceil(clipped.maxX * scaleX)))
        let bottom = max(top, min(CGFloat(pixelHeight), ceil(clipped.maxY * scaleY)))
        let pixelFrame = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        let topLeftFrame = CGRect(x: left / scaleX, y: top / scaleY,
                                  width: pixelFrame.width / scaleX, height: pixelFrame.height / scaleY)
        let selectionFrame = CGRect(x: topLeftFrame.minX, y: pointSize.height - bottom / scaleY,
                                     width: topLeftFrame.width, height: topLeftFrame.height)
        return Selection(pixelFrame: pixelFrame, topLeftFrame: topLeftFrame, selectionFrame: selectionFrame)
    }
}
