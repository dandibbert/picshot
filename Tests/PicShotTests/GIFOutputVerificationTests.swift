import XCTest
import Foundation
@testable import PicShot

final class GIFOutputVerificationTests: XCTestCase {
    func testValidMetadataIsCheckedWithoutDecodingPixels() throws {
        try inspect(validGIF(), frames: 1, duration: 1)
        XCTAssertThrowsError(try inspect(validGIF(), frames: 2, duration: 1))
        XCTAssertThrowsError(try inspect(validGIF(), frames: 1, duration: 0.5))
        var wrongSize = validGIF(); wrongSize[6] = 2
        XCTAssertThrowsError(try inspect(wrongSize, frames: 1, duration: 1))
        var huge = validGIF(); huge[6] = 255; huge[7] = 255
        XCTAssertThrowsError(try inspect(huge, frames: 1, duration: 1))
    }
    func testAllTruncationsAndTrailingBytesFailClosed() throws {
        let valid = validGIF()
        for length in 0..<valid.count { XCTAssertThrowsError(try inspect(Data(valid.prefix(length)), frames: 1, duration: 1)) }
        var trailing = valid; trailing.append(0)
        XCTAssertThrowsError(try inspect(trailing, frames: 1, duration: 1))
    }
    func testMissingControlPaletteAndIllegalBlocksAreRejected() throws {
        let valid = validGIF()
        var noControl = Data(valid.prefix(19)); noControl.append(valid[27...])
        XCTAssertThrowsError(try inspect(noControl, frames: 1, duration: 1))
        var noPalette = valid; noPalette[10] = 0
        XCTAssertThrowsError(try inspect(noPalette, frames: 1, duration: 1))
        var badControl = valid; badControl[21] = 3
        XCTAssertThrowsError(try inspect(badControl, frames: 1, duration: 1))
        var zeroDelay = valid; zeroDelay[23] = 0
        XCTAssertThrowsError(try inspect(zeroDelay, frames: 1, duration: 1))
        var badCodeSize = valid; badCodeSize[37] = 1
        XCTAssertThrowsError(try inspect(badCodeSize, frames: 1, duration: 1))
    }
    func testMetadataAcrossReadBoundaryAndLargeImageSubblocksStayBounded() throws {
        var data = Data(validGIF().prefix(19))
        // Comment subblocks cross the 64 KiB refill boundary without becoming a
        // retained comment string or a whole-file Data allocation in the reader.
        data.append(contentsOf: [0x21, 0xFE])
        for _ in 0..<300 { data.append(255); data.append(Data(repeating: 65, count: 255)) }
        data.append(0); data.append(validGIF()[19...])
        XCTAssertGreaterThan(data.count, 65_536)
        try inspect(data, frames: 1, duration: 1)
        var truncated = data; truncated.removeLast(5)
        XCTAssertThrowsError(try inspect(truncated, frames: 1, duration: 1))
    }
    func testCancellationChecksPropagateDuringContainerWalk() throws {
        var data = Data(validGIF().prefix(19))
        data.append(contentsOf: [0x21, 0xFE])
        for _ in 0..<300 { data.append(255); data.append(Data(repeating: 65, count: 255)) }
        data.append(0); data.append(validGIF()[19...])
        let counter = GIFOutputCheckCounter()
        XCTAssertThrowsError(try inspect(data, frames: 1, duration: 1) {
            if counter.next() > 40 { throw CancellationError() }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertGreaterThan(counter.value, 40)
    }
    private func inspect(_ data: Data, frames: Int, duration: Double,
                         check: @escaping () throws -> Void = { }) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gif-container-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        try GIFOutputVerification.validate(file: file, bytes: data.count, expectedFrames: frames, expectedDuration: duration,
                                          options: .init(maximumDimension: 16), check: check)
    }
    private func validGIF() -> Data {
        // Original 1x1 red pixel with a one-second GCE and native GIF LZW codes.
        Data(Array("GIF89a".utf8) + [1,0,1,0,128,0,0,255,0,0,0,255,0,
            33,249,4,0,100,0,0,0,44,0,0,0,0,1,0,1,0,0,2,2,68,1,0,59])
    }
}
private final class GIFOutputCheckCounter {
    private(set) var value = 0
    func next() -> Int { value += 1; return value }
}
