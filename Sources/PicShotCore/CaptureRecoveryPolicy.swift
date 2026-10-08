/// Managed retained capture backing, separate from editor admission and process RSS.
/// Decoder caches, graphics surfaces, transient work and framework overhead are not
/// measurable through these byte counts and are not covered by this ceiling.
public enum CaptureRecoveryPolicy {
    public static let maximumRasterBytes = 512 * 1024 * 1024
    public static let maximumEncodedBytes = 128 * 1024 * 1024
    public static let maximumPendingBytes = maximumRasterBytes + maximumEncodedBytes
    public static let maximumSystemPixels = 100_000_000

    public static func retainedBytes(rasterBytes: Int, encodedBytes: Int) -> Int? {
        guard rasterBytes > 0, rasterBytes <= maximumRasterBytes,
              encodedBytes >= 0, encodedBytes <= maximumEncodedBytes else { return nil }
        return EditorAdmissionPolicy.sum([rasterBytes, encodedBytes])
    }

    /// Header-only check precedes ImageIO image creation. A decoder's actual row
    /// stride is checked again on its uncached image before application drawing.
    /// ImageIO can still allocate or decode internally during image creation.
    public static func allowsSystemHeader(width: Int, height: Int, depth: Int, encodedBytes: Int) -> Bool {
        guard width > 0, height > 0, width <= maximumSystemPixels / height,
              depth > 0, depth <= 16, encodedBytes > 0, encodedBytes <= maximumEncodedBytes else { return false }
        let bytesPerPixel = depth <= 8 ? 4 : 8
        let row = EditorAdmissionPolicy.rasterBytes(bytesPerRow: width, height: bytesPerPixel)
        return retainedBytes(rasterBytes: EditorAdmissionPolicy.rasterBytes(bytesPerRow: row, height: height),
                             encodedBytes: encodedBytes) != nil
    }

    /// Reject only already-full capacity before acquisition, not a speculative
    /// worst-case image size. A valid acquired result can use the separate pool.
    public static func preflight(editorPolicy: EditorAdmissionPolicy, existingRasterBytes: [Int],
                                 drainingBytes: Int, pendingBytes: Int) -> EditorAdmissionPolicy.Refusal? {
        editorPolicy.refusal(existingRasterBytes: existingRasterBytes,
            incomingRasterBytes: EditorAdmissionPolicy.sum([drainingBytes, pendingBytes, 1]))
    }

    /// A retry transfers the same image reference into the editor. Only that exact
    /// handoff omits the pending reservation; all unrelated opens include it.
    public static func admissionBytes(incomingBytes: Int, drainingBytes: Int,
                                      pendingBytes: Int, transferringPending: Bool) -> Int {
        EditorAdmissionPolicy.sum([incomingBytes, drainingBytes, transferringPending ? 0 : pendingBytes])
    }
}
