import AVFoundation

/// Shared configuration used by the real writer and abrupt-termination fixture.
/// Set before startWriting; no capture device or subprocess is created here.
enum RecordingRecoveryWriterSupport {
    static func configure(_ writer: AVAssetWriter) {
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
    }
}
