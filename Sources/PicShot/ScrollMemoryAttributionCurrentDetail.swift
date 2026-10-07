import AppKit
import PicShotCore

/// Current-build-only adapter. Never backport this renderer to a baseline build.
enum ScrollMemoryAttributionCurrentDetail {
    nonisolated static func render(_ sources: [StoredScrollSource], _ layout: ScrollSequenceLayout,
                                   _ axis: ScrollAxis) throws -> [String: Int] {
        let output = CGSize(width: layout.width, height: layout.height)
        let alongLength = axis == .vertical ? layout.height : layout.width
        let span = min(1024, alongLength)
        var pixels = 0
        for start in [0, alongLength - span] {
            try Task.checkCancellation()
            try autoreleasepool {
                let rect = axis == .vertical
                    ? CGRect(x: 0, y: start, width: layout.width, height: span)
                    : CGRect(x: start, y: 0, width: span, height: layout.height)
                let request = try ScrollPreviewTileRequest(outputSize: output, visibleRect: rect, displayScale: 1)
                let image = try ScrollImageIO.sequencePreviewTile(sources, layout: layout, axis: axis, request: request)
                guard image.width == request.pixelWidth, image.height == request.pixelHeight,
                      image.width * image.height <= ScrollPreviewTileRequest.maximumTilePixels else {
                    throw ScrollSequenceError.invalidGeometry
                }
                pixels += image.width * image.height
            }
        }
        return ["tiles": 2, "totalRenderedPixels": pixels,
                "maximumTilePixels": ScrollPreviewTileRequest.maximumTilePixels,
                "maximumSourceSamplePixels": ScrollPreviewTileRequest.maximumSourceSamplePixels]
    }
}
