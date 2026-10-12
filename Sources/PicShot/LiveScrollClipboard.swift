import AppKit

/// Checked delivery for the live long-capture session. Encoding must finish
/// before replacing any pasteboard contents; a rejected write is not delivery.
enum LiveScrollClipboard {
    @MainActor
    static func copy(_ image: CGImage) throws {
        try copy(image, pasteboard: .general)
    }

    /// An explicit pasteboard keeps failure tests away from the user's clipboard.
    @MainActor
    static func copy(_ image: CGImage, pasteboard: NSPasteboard,
                     encoder: (CGImage) throws -> Data = { try LiveScrollClipboard.encodePNG($0) },
                     writer: (NSPasteboard, Data) -> Bool = { $0.setData($1, forType: .png) }) throws {
        let data = try encoder(image)
        guard !data.isEmpty else { throw ImageExportError.invalidOutput }
        pasteboard.clearContents()
        guard writer(pasteboard, data) else {
            throw PicShotError.message("无法将长截图写入剪贴板，请重试。")
        }
    }

    static func encodePNG(_ image: CGImage, limits: ImageExportLimits = .standard) throws -> Data {
        let snapshot = try ImageExportSnapshot(image: image, limits: limits)
        // Reuse the bounded, verified PNG byte path without making an unused
        // thumbnail. Snapshot admission and encoded-byte limits both apply.
        return try ImageExportService.encodePNGForCodecStaging(snapshot: snapshot, limits: limits)
    }
}
