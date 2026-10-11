import XCTest
import AppKit
import Darwin
import ImageIO
@testable import PicShot

@MainActor
final class LiveScrollPNGWriterTests: XCTestCase {
    private let backends: [ScrollPNGWriteBackend] = [.foundation, .posix]
    private let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PicShot-PNGWriter-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Color channels differ so losing chroma cannot pass. The alpha fixture uses
    /// exact premultiplied channel endpoints to avoid an unrelated rounding oracle.
    private func image(varyingAlpha: Bool = false) throws -> CGImage {
        let width = 73, height = 61
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let index = (y * width + x) * 4
            let alpha: UInt8 = varyingAlpha ? [0, 85, 170, 255][(x + y) % 4] : 255
            bytes[index] = varyingAlpha ? (x % 2 == 0 ? alpha : 0) : UInt8((x * 37 + y * 11) % 256)
            bytes[index + 1] = varyingAlpha ? (y % 2 == 0 ? alpha : 0) : UInt8((x * 7 + y * 41) % 256)
            bytes[index + 2] = varyingAlpha ? ((x + y) % 3 == 0 ? alpha : 0) : UInt8((x * 19 + y * 23) % 256)
            bytes[index + 3] = alpha
        } }
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy); context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }

    private func assertPNG(_ url: URL, matches expected: CGImage,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(Array(try Data(contentsOf: url).prefix(8)), pngSignature, file: file, line: line)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), file: file, line: line)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), file: file, line: line)
        XCTAssertEqual(decoded.width, expected.width, file: file, line: line)
        XCTAssertEqual(decoded.height, expected.height, file: file, line: line)
        XCTAssertEqual(try pixels(decoded), try pixels(expected), file: file, line: line)
    }

    private func assertStorageLimit(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let error = error as? ScrollSequenceImageError, case .storageLimit = error else {
            XCTFail("Expected storage limit, got \(error)", file: file, line: line); return
        }
    }

    private func assertWriteFailed(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let error = error as? ScrollSequenceImageError, case .writeFailed = error else {
            XCTFail("Expected write failure, got \(error)", file: file, line: line); return
        }
    }

    func testDefaultBackendUsesFoundation() throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let input = try image(), output = parent.appendingPathComponent("default.png")
        var posixCalls = 0
        try ScrollImageIO.writeBoundedPNG(input, to: output, maximumBytes: 1_000_000,
            writeForTesting: { _, _, _ in posixCalls += 1; errno = EIO; return -1 })
        XCTAssertEqual(posixCalls, 0, "An omitted backend must retain the Foundation path")
        try assertPNG(output, matches: input)
    }

    func testBothBackendsPreservePNGSignatureAndDecodedColorAndAlphaPixels() throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        for varyingAlpha in [false, true] {
            let input = try image(varyingAlpha: varyingAlpha)
            var encodings: [Data] = []
            for backend in backends {
                let output = parent.appendingPathComponent("\(backend.rawValue)-\(varyingAlpha).png")
                try ScrollImageIO.writeBoundedPNG(input, to: output, maximumBytes: 1_000_000, backend: backend)
                try assertPNG(output, matches: input)
                encodings.append(try Data(contentsOf: output))
            }
            XCTAssertEqual(encodings[0], encodings[1], "The consumer backend must not change the ImageIO byte stream")
        }
    }

    func testBothBackendsRefuseOverwriteAndPreserveOriginalBytes() throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let input = try image(), original = Data("immutable source".utf8)
        for backend in backends {
            let output = parent.appendingPathComponent("\(backend.rawValue).png")
            try original.write(to: output)
            XCTAssertThrowsError(try ScrollImageIO.writeBoundedPNG(input, to: output,
                maximumBytes: 1_000_000, backend: backend)) { self.assertWriteFailed($0) }
            XCTAssertEqual(try Data(contentsOf: output), original)
        }
    }

    func testBothBackendsAcceptExactByteCapAndRejectOneByteLess() throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let input = try image(), baseline = parent.appendingPathComponent("baseline.png")
        try ScrollImageIO.writeBoundedPNG(input, to: baseline, maximumBytes: 1_000_000)
        let encoded = try Data(contentsOf: baseline), size = Int64(encoded.count)
        for backend in backends {
            let exact = parent.appendingPathComponent("exact-\(backend.rawValue).png")
            try ScrollImageIO.writeBoundedPNG(input, to: exact, maximumBytes: size, backend: backend)
            XCTAssertEqual(try Data(contentsOf: exact), encoded)
            try assertPNG(exact, matches: input)
            let short = parent.appendingPathComponent("short-\(backend.rawValue).png")
            XCTAssertThrowsError(try ScrollImageIO.writeBoundedPNG(input, to: short,
                maximumBytes: size - 1, backend: backend)) { self.assertStorageLimit($0) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: short.path))
        }
    }

    func testBothBackendsRejectNonpositiveCapsWithoutCreatingFile() throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let input = try image()
        for backend in backends { for cap in [Int64(0), -1, Int64.min] {
            let output = parent.appendingPathComponent("\(backend.rawValue)-\(cap).png")
            XCTAssertThrowsError(try ScrollImageIO.writeBoundedPNG(input, to: output,
                maximumBytes: cap, backend: backend)) { self.assertStorageLimit($0) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        } }
    }

    func testBothBackendsFailForMissingDestinationParent() throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let input = try image()
        for backend in backends {
            let output = parent.appendingPathComponent("missing/\(backend.rawValue).png")
            XCTAssertThrowsError(try ScrollImageIO.writeBoundedPNG(input, to: output,
                maximumBytes: 1_000_000, backend: backend)) { self.assertWriteFailed($0) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    func testBothBackendsRemovePartialFileWhenCancelledBeforeEncoding() async throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let input = try image()
        for backend in backends {
            let output = parent.appendingPathComponent("\(backend.rawValue).png")
            let task = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                try ScrollImageIO.writeBoundedPNG(input, to: output, maximumBytes: 1_000_000, backend: backend)
            }
            do { try await task.value; XCTFail("Expected cancellation") }
            catch is CancellationError { }
            catch { XCTFail("Unexpected \(error)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testPOSIXShortWritesAndRepeatedEINTRPreserveEveryEncodedByte() throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let input = try image(), baseline = parent.appendingPathComponent("baseline.png")
        try ScrollImageIO.writeBoundedPNG(input, to: baseline, maximumBytes: 1_000_000)
        let output = parent.appendingPathComponent("short-writes.png")
        var calls = 0, interruptions = 0, shortWrites = 0
        try ScrollImageIO.writeBoundedPNG(input, to: output, maximumBytes: 1_000_000, backend: .posix,
            writeForTesting: { fd, bytes, count in
                calls += 1
                if calls % 4 == 1 { interruptions += 1; errno = EINTR; return -1 }
                let requested = min(count, 11)
                if requested < count { shortWrites += 1 }
                return Darwin.write(fd, bytes, requested)
            })
        XCTAssertGreaterThan(interruptions, 1); XCTAssertGreaterThan(shortWrites, 1)
        XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: baseline))
        try assertPNG(output, matches: input)
    }

    func testPOSIXNeverOffersOrWritesBytesBeyondTheCap() throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let input = try image(), baseline = parent.appendingPathComponent("baseline.png")
        try ScrollImageIO.writeBoundedPNG(input, to: baseline, maximumBytes: 1_000_000)
        let size = Int64(try Data(contentsOf: baseline).count)
        for cap in [Int64(1), 8, 32, size - 1] {
            let output = parent.appendingPathComponent("cap-\(cap).png")
            var accepted: Int64 = 0
            XCTAssertThrowsError(try ScrollImageIO.writeBoundedPNG(input, to: output,
                maximumBytes: cap, backend: .posix, writeForTesting: { fd, bytes, count in
                    XCTAssertLessThanOrEqual(Int64(count), cap - accepted)
                    let amount = Darwin.write(fd, bytes, min(count, 7))
                    if amount > 0 { accepted += Int64(amount) }
                    XCTAssertLessThanOrEqual(accepted, cap)
                    return amount
                })) { self.assertStorageLimit($0) }
            if cap == 1 { XCTAssertEqual(accepted, 0, "An oversized encoder chunk must be rejected before writing") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testPOSIXDiskFullAndIOErrorAfterPartialWritesRemoveFileAndCloseDescriptor() throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let input = try image()
        for code in [ENOSPC, EIO] {
            let output = parent.appendingPathComponent("error-\(code).png")
            var calls = 0, accepted = 0
            var descriptor: Int32 = -1
            XCTAssertThrowsError(try ScrollImageIO.writeBoundedPNG(input, to: output,
                maximumBytes: 1_000_000, backend: .posix, writeForTesting: { fd, bytes, count in
                    descriptor = fd; calls += 1
                    if calls == 1 {
                        let amount = Darwin.write(fd, bytes, min(count, 7))
                        accepted += max(0, amount)
                        return amount
                    }
                    errno = code; return -1
                })) { XCTAssertEqual(($0 as? POSIXError)?.code, POSIXErrorCode(rawValue: code)) }
            XCTAssertGreaterThan(accepted, 0); XCTAssertEqual(calls, 2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            let descriptorStatus = fcntl(descriptor, F_GETFD), descriptorError = errno
            XCTAssertEqual(descriptorStatus, -1)
            XCTAssertEqual(descriptorError, EBADF, "Failed encoding must close its FileHandle descriptor")
        }
    }

    func testPOSIXZeroWriteAfterPartialWriteFailsWithoutRetryAndRemovesFile() throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let input = try image(), output = parent.appendingPathComponent("zero-write.png")
        var calls = 0, accepted = 0
        XCTAssertThrowsError(try ScrollImageIO.writeBoundedPNG(input, to: output,
            maximumBytes: 1_000_000, backend: .posix, writeForTesting: { fd, bytes, count in
                calls += 1
                if calls == 1 {
                    let amount = Darwin.write(fd, bytes, min(count, 7)); accepted += max(0, amount); return amount
                }
                if calls == 2 { return 0 }
                errno = EIO; return -1 // Bound the test even if zero were incorrectly retried.
            })) { self.assertWriteFailed($0) }
        XCTAssertGreaterThan(accepted, 0); XCTAssertEqual(calls, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testPOSIXCancellationAfterPartialWriteStopsBeforeNextSyscallAndRemovesFile() async throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let input = try image(), output = parent.appendingPathComponent("cancel-partial.png")
        var calls = 0, accepted = 0
        let task = Task { @MainActor in
            try ScrollImageIO.writeBoundedPNG(input, to: output, maximumBytes: 1_000_000, backend: .posix,
                writeForTesting: { fd, bytes, count in
                    calls += 1
                    let amount = Darwin.write(fd, bytes, min(count, 1)); accepted += max(0, amount)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return amount
                })
        }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(calls, 1); XCTAssertEqual(accepted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testPOSIXCancellationAfterEINTRStopsBeforeRetryAndRemovesFile() async throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let input = try image(), output = parent.appendingPathComponent("cancel-eintr.png")
        var calls = 0
        let task = Task { @MainActor in
            try ScrollImageIO.writeBoundedPNG(input, to: output, maximumBytes: 1_000_000, backend: .posix,
                writeForTesting: { _, _, _ in
                    calls += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                    errno = calls == 1 ? EINTR : EIO
                    return -1 // Bound the test if cancellation is incorrectly ignored.
                })
        }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
