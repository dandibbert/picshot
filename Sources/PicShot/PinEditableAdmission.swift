import AppKit
import CryptoKit
import PicShotCore

enum PinEditableWork { case readOnly, editor, hiddenPreview }

/// Admission for managed image-pin rasters and output reservations. This is not
/// total app RSS, and does not include unrelated editor windows or native caches.
@MainActor enum PinEditableAdmission {
    static func remaining(limit: Int, retained: Int, reportedProjection: Int,
                          globalProjection: Int, work: Int) throws -> Int {
        guard limit >= 0, retained >= 0, reportedProjection >= 0,
              globalProjection >= 0, work >= 0 else { throw PinSessionError.capacityExceeded }
        let draining = max(0, globalProjection - reportedProjection)
        let used = EditorAdmissionPolicy.sum([retained, draining, work])
        guard used <= limit else { throw PinSessionError.capacityExceeded }
        return limit - used
    }

    static func redraw(width: Int, height: Int) -> Int {
        EditorAdmissionPolicy.rasterBytes(bytesPerRow:
            EditorAdmissionPolicy.rasterBytes(bytesPerRow: width, height: 4), height: height)
    }

    static func workBytes(_ work: PinEditableWork, document: EditableAnnotationDocument?,
                          baseWidth: Int, baseHeight: Int) throws -> Int {
        switch work {
        case .readOnly: return 0
        case .editor: return redraw(width: baseWidth, height: baseHeight)
        case .hiddenPreview:
            guard let document else { return 0 }
            // visibleBase materializes a crop before the projection owns its input.
            let crop = document.cropViewportInBase.map { redraw(width: Int($0.width), height: Int($0.height)) } ?? 0
            return EditorAdmissionPolicy.sum([crop,
                document.outputDecoration.isIdentity ? 0 : EditorOutputProjection.combinedWorkingByteLimit])
        }
    }

    static func requiresProjection(_ work: PinEditableWork, document: EditableAnnotationDocument?) -> Bool {
        if case .hiddenPreview = work { return document?.outputDecoration.isIdentity == false }
        return false
    }

    static func additionalImages(_ images: [CGImage], alreadyOwned: [CGImage]) -> Int {
        var seen = Set(alreadyOwned.map(ObjectIdentifier.init))
        return EditorAdmissionPolicy.sum(images.compactMap { image in
            guard seen.insert(ObjectIdentifier(image)).inserted else { return nil }
            return EditorAdmissionPolicy.rasterBytes(bytesPerRow: image.bytesPerRow, height: image.height)
        })
    }

    /// Read only bounded, checksummed metadata before allocating original/base
    /// pixels. The persistence reader independently rechecks it during decoding.
    @MainActor static func document(_ asset: EditableCaptureAsset, directory: URL) throws -> EditableAnnotationDocument {
        guard asset.isValid else { throw PinSessionError.invalidManifest }
        let storage = EditableCaptureAssetStore(directory: directory)
        let url = try storage.url(asset.documentFilename)
        guard try storage.checkedFile(url).fileSize == Int(asset.documentByteCount) else { throw PinSessionError.invalidManifest }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        let limit = Int(asset.documentByteCount)
        while data.count <= limit {
            guard let part = try handle.read(upToCount: min(65_536, limit + 1 - data.count)), !part.isEmpty else { break }
            data.append(part)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == limit, digest == asset.documentSHA256 else { throw PinSessionError.invalidManifest }
        let document = try EditableAnnotationDocumentCodec.decode(data)
        try document.validateAssetReferences(originalID: asset.original.assetID, baseID: asset.base.assetID,
            originalWidth: asset.original.width, originalHeight: asset.original.height,
            baseWidth: asset.base.width, baseHeight: asset.base.height)
        return document
    }
}
