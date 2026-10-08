import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin
import PicShotCore

/// PNG streams directly to a private sibling stage: no ImageExportSnapshot,
/// full encoded Data buffer, preview decode, or second full-size raster.
/// Publication is an exclusive link, so even a save-panel Replace response cannot
/// overwrite a previous file. Failures/cancellation leave recovery pixels owned.
enum PendingCaptureFileWriter {
    static func write(_ capture: PendingCapture, to url: URL,
                      cancellation: ImageExportCancellation = ImageExportCancellation(),
                      maximumEncodedBytes: Int = CaptureRecoveryPolicy.maximumPendingBytes,
                      beforeCommit: (() throws -> Void)? = nil) throws -> URL {
        try cancellation.check()
        guard url.isFileURL, url.pathExtension.lowercased() == "png", maximumEncodedBytes > 0,
              maximumEncodedBytes <= CaptureRecoveryPolicy.maximumPendingBytes,
              !url.lastPathComponent.isEmpty, !url.lastPathComponent.contains("\0") else {
            throw CaptureRecoveryError.writeFailed
        }
        let parentURL = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let parent = Darwin.open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw CaptureRecoveryError.writeFailed }
        defer { Darwin.close(parent) }
        let stageName = ".picshot-recovery-" + UUID().uuidString
        guard Darwin.mkdirat(parent, stageName, 0o700) == 0 else { throw CaptureRecoveryError.writeFailed }
        defer { _ = Darwin.unlinkat(parent, stageName, AT_REMOVEDIR) }
        let stage = Darwin.openat(parent, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stage >= 0 else { throw CaptureRecoveryError.writeFailed }
        defer { Darwin.close(stage) }
        let fd = Darwin.openat(stage, "capture.png", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CaptureRecoveryError.writeFailed }
        defer { Darwin.close(fd); _ = Darwin.unlinkat(stage, "capture.png", 0) }
        let writer = CapturePNGConsumer(fd: fd, limit: maximumEncodedBytes, cancellation: cancellation)
        try withExtendedLifetime(writer) {
            var callbacks = CGDataConsumerCallbacks(putBytes: { info, bytes, count in
                guard let info else { return 0 }
                return Unmanaged<CapturePNGConsumer>.fromOpaque(info).takeUnretainedValue().put(bytes, count: count)
            }, releaseConsumer: nil)
            guard let consumer = CGDataConsumer(info: Unmanaged.passUnretained(writer).toOpaque(), cbks: &callbacks),
                  let destination = CGImageDestinationCreateWithDataConsumer(consumer, UTType.png.identifier as CFString, 1, nil)
            else { throw CaptureRecoveryError.writeFailed }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            let metadata = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: formatter.string(from: capture.capturedAt)]] as CFDictionary
            CGImageDestinationAddImage(destination, capture.image, metadata)
            let finalized = CGImageDestinationFinalize(destination)
            if let failure = writer.failure { throw failure }
            guard finalized, writer.written > 0, Darwin.fsync(fd) == 0 else { throw CaptureRecoveryError.writeFailed }
        }
        try cancellation.check(); try beforeCommit?()
        try cancellation.commit {
            // Confirm the visible destination still resolves to our opened parent.
            var opened = stat(), visible = stat()
            guard Darwin.fstat(parent, &opened) == 0, parentURL.path.withCString({ lstat($0, &visible) }) == 0,
                  opened.st_dev == visible.st_dev, opened.st_ino == visible.st_ino else {
                throw CaptureRecoveryError.writeFailed
            }
            guard Darwin.linkat(stage, "capture.png", parent, url.lastPathComponent, 0) == 0 else {
                throw errno == EEXIST ? CaptureRecoveryError.destinationExists : CaptureRecoveryError.writeFailed
            }
        }
        // Publication won the cancellation fence; never misreport a committed PNG
        // as cancelled. Directory sync is best-effort, as in normal save workflows.
        _ = Darwin.fsync(parent)
        return parentURL.appendingPathComponent(url.lastPathComponent)
    }
}

private final class CapturePNGConsumer {
    let fd: Int32
    let limit: Int
    let cancellation: ImageExportCancellation
    private(set) var written = 0
    private(set) var failure: Error?
    init(fd: Int32, limit: Int, cancellation: ImageExportCancellation) {
        self.fd = fd; self.limit = limit; self.cancellation = cancellation
    }
    func put(_ pointer: UnsafeRawPointer, count: Int) -> Int {
        guard failure == nil else { return 0 }
        do {
            try cancellation.check()
            guard count >= 0, count <= limit - written else { throw CaptureRecoveryError.encodedLimit }
            var offset = 0
            while offset < count {
                try cancellation.check()
                let size = Darwin.write(fd, pointer.advanced(by: offset), count - offset)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { throw CaptureRecoveryError.writeFailed }
                offset += size; written += size
            }
            return count
        } catch { failure = error; return 0 }
    }
}
