import AppKit

/// Viewport and decoration are projections of an immutable base. Pin preview,
/// editor placement and current export therefore agree on pixel geometry.
enum EditableCapturePresentation {
    static func visibleBase(_ payload: EditableCapturePayload) throws -> CGImage {
        guard let crop = payload.document.cropViewportInBase else { return payload.baseImage }
        guard let image = ImageEditorRenderer.crop(image: payload.baseImage, to: crop) else {
            throw ImageOutputDecorationError.allocationFailed
        }
        return image
    }

    static func editorPlacement(for document: EditableAnnotationDocument,
                                projected: PinEditorPresentation) throws -> PinEditorPresentation {
        let visible = document.cropViewportInBase ?? CGRect(x: 0, y: 0,
            width: document.basePixelWidth, height: document.basePixelHeight)
        let layout = try ImageOutputDecorationLayout.make(width: Int(visible.width), height: Int(visible.height),
                                                          decoration: document.outputDecoration)
        let sx = projected.imageFrame.width / CGFloat(layout.width)
        let sy = projected.imageFrame.height / CGFloat(layout.height)
        let content = layout.imageRect
        return PinEditorPresentation(viewportFrame: projected.viewportFrame,
            imageFrame: CGRect(x: projected.imageFrame.minX + content.minX * sx,
                y: projected.imageFrame.minY + content.minY * sy,
                width: content.width * sx, height: content.height * sy),
            opacity: projected.opacity, level: projected.level)
    }
}

extension ImageAnnotation {
    /// Rebase the whole source coordinate system, including mosaic associations.
    /// Ordinary annotation movement keeps its established synchronization policy.
    func rebasedForEditableCapture(by delta: CGSize) -> ImageAnnotation {
        var result = translated(by: delta)
        if var link = mosaicLink {
            link.target = link.target.offsetBy(dx: delta.width, dy: delta.height)
            link.includedTargets = link.includedTargets.map { $0.offsetBy(dx: delta.width, dy: delta.height) }
            link.excludedTargets = link.excludedTargets.map { $0.offsetBy(dx: delta.width, dy: delta.height) }
            result.mosaicLink = link
        }
        return result
    }
}
