import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import PicShot

@MainActor
final class LiveScrollClipboardTests: XCTestCase {
    func testSuccessfulCopyWritesDecodablePNGWithTheFullImagePixels() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("previous clipboard", forType: .string))
        let image = try fixture()

        try LiveScrollClipboard.copy(image, pasteboard: board)

        XCTAssertNil(board.string(forType: .string))
        let data = try XCTUnwrap(board.data(forType: .png))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, image.width); XCTAssertEqual(decoded.height, image.height)
        XCTAssertEqual(try pixels(decoded), try pixels(image))
    }

    func testEncodingFinishesBeforeClearAndWritesTheSameBytesOnlyOnce() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("keep until encoded", forType: .string))
        let initialChangeCount = board.changeCount
        let image = try fixture(), encoded = try LiveScrollClipboard.encodePNG(image)
        var calls: [String] = []

        try LiveScrollClipboard.copy(image, pasteboard: board, encoder: { input in
            calls.append("encode")
            XCTAssertTrue(input === image)
            XCTAssertEqual(board.string(forType: .string), "keep until encoded")
            XCTAssertEqual(board.changeCount, initialChangeCount)
            return encoded
        }, writer: { target, data in
            calls.append("write")
            XCTAssertTrue(target === board)
            XCTAssertNil(target.string(forType: .string))
            XCTAssertGreaterThan(target.changeCount, initialChangeCount)
            XCTAssertEqual(data, encoded)
            return target.setData(data, forType: .png)
        })

        XCTAssertEqual(calls, ["encode", "write"])
        XCTAssertEqual(board.data(forType: .png), encoded)
    }

    func testEncodingFailurePreservesAllPriorContentsAndNeverCallsWriter() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let sentinel = Data([0x42, 0x01, 0xFF])
        XCTAssertTrue(board.setString("previous text", forType: .string))
        XCTAssertTrue(board.setData(sentinel, forType: .png))
        let initialChangeCount = board.changeCount
        let image = try fixture()
        var writeCalls = 0

        XCTAssertThrowsError(try LiveScrollClipboard.copy(image, pasteboard: board, encoder: { _ in
            throw ImageExportError.encodeFailed
        }, writer: { _, _ in writeCalls += 1; return true })) {
            guard case ImageExportError.encodeFailed = $0 else { return XCTFail("Unexpected error: \($0)") }
        }

        XCTAssertEqual(writeCalls, 0)
        XCTAssertEqual(board.changeCount, initialChangeCount)
        XCTAssertEqual(board.string(forType: .string), "previous text")
        XCTAssertEqual(board.data(forType: .png), sentinel)
    }

    func testEmptyEncoderOutputFailsBeforeClearingTheClipboard() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("previous text", forType: .string))
        let initialChangeCount = board.changeCount
        let image = try fixture()
        var writeCalls = 0

        XCTAssertThrowsError(try LiveScrollClipboard.copy(image, pasteboard: board, encoder: { _ in Data() },
            writer: { _, _ in writeCalls += 1; return true })) {
            guard case ImageExportError.invalidOutput = $0 else { return XCTFail("Unexpected error: \($0)") }
        }

        XCTAssertEqual(writeCalls, 0)
        XCTAssertEqual(board.changeCount, initialChangeCount)
        XCTAssertEqual(board.string(forType: .string), "previous text")
    }

    func testRejectedPasteboardWriteThrowsAndTheSameImageCanBeRetried() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("previous text", forType: .string))
        let image = try fixture()
        var writeCalls = 0

        XCTAssertThrowsError(try LiveScrollClipboard.copy(image, pasteboard: board, writer: { target, data in
            writeCalls += 1
            XCTAssertTrue(target === board)
            XCTAssertNil(target.string(forType: .string))
            XCTAssertFalse(data.isEmpty)
            return false
        })) {
            guard case PicShotError.message(let message) = $0 else { return XCTFail("Unexpected error: \($0)") }
            XCTAssertTrue(message.contains("剪贴板"))
        }

        XCTAssertEqual(writeCalls, 1)
        XCTAssertNil(board.data(forType: .png))
        try LiveScrollClipboard.copy(image, pasteboard: board)
        XCTAssertNotNil(board.data(forType: .png))
    }

    func testSourceAndEncodedByteLimitsFailBeforeClipboardMutation() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("preserve on limit failure", forType: .string))
        let initialChangeCount = board.changeCount
        let image = try fixture(), expected = try LiveScrollClipboard.encodePNG(image)
        var limits = ImageExportLimits.standard
        limits.maximumSourcePixels = image.width * image.height
        limits.maximumEncodedBytes = expected.count
        XCTAssertEqual(try LiveScrollClipboard.encodePNG(image, limits: limits), expected)

        for sourceLimit in [true, false] {
            var failingLimits = limits
            if sourceLimit { failingLimits.maximumSourcePixels -= 1 }
            else { failingLimits.maximumEncodedBytes -= 1 }
            var writeCalls = 0
            XCTAssertThrowsError(try LiveScrollClipboard.copy(image, pasteboard: board, encoder: {
                try LiveScrollClipboard.encodePNG($0, limits: failingLimits)
            }, writer: { _, _ in writeCalls += 1; return true })) { error in
                if sourceLimit {
                    guard case ImageExportError.sourceTooLarge = error else { return XCTFail("Unexpected error: \(error)") }
                } else {
                    guard case ImageExportError.outputTooLarge = error else { return XCTFail("Unexpected error: \(error)") }
                }
            }
            XCTAssertEqual(writeCalls, 0)
            XCTAssertEqual(board.changeCount, initialChangeCount)
            XCTAssertEqual(board.string(forType: .string), "preserve on limit failure")
        }
    }

    private func fixture() throws -> CGImage {
        let context = try bitmap(width: 17, height: 29)
        context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 17, height: 29))
        context.clear(CGRect(x: 0, y: 0, width: 4, height: 7))
        context.setFillColor(CGColor(red: 0.5, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 5))
        return try XCTUnwrap(context.makeImage())
    }

    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try bitmap(width: image.width, height: image.height)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * image.height)
    }
}
