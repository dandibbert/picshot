import CoreGraphics
import PicShotCore

/// Deduplicate references within one controller. Different CGImage objects may
/// still share storage, so this deliberately errs toward overcounting. AppKit,
/// GPU surfaces and temporary export/capture allocations are outside this estimate.
enum EditorRasterEstimate {
    static func retainedBytes(_ images: [CGImage]) -> Int {
        var seen = Set<ObjectIdentifier>()
        return EditorAdmissionPolicy.sum(images.compactMap { image in
            guard seen.insert(ObjectIdentifier(image)).inserted else { return nil }
            return EditorAdmissionPolicy.rasterBytes(bytesPerRow: image.bytesPerRow, height: image.height)
        })
    }

    /// A freshly opened editor also needs a four-byte-per-pixel redraw cache.
    static func openingBytes(image: CGImage, presentation: FrozenCapturePresentation?) -> Int {
        let owned = [image] + (presentation.map { [$0.frozenImage] } ?? [])
        return EditorAdmissionPolicy.sum([retainedBytes(owned), redrawBytes(image)])
    }

    static func redrawBytes(_ image: CGImage) -> Int {
        EditorAdmissionPolicy.rasterBytes(bytesPerRow: EditorAdmissionPolicy.rasterBytes(bytesPerRow: image.width, height: 4), height: image.height)
    }
}
