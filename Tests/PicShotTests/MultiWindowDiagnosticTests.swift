import XCTest
import Foundation
import CoreGraphics
import PicShotCore
@testable import PicShot

final class MultiWindowDiagnosticTests: XCTestCase {
    func testTailFirstKeepsAlphaZOrderPixelsAndExactClipPartition() async throws {
        let front = try window(101, x: -4, y: -7)
        let back = try window(202, x: 0, y: 0)
        let layout = try MultiWindowCaptureLayout(frontToBack: [front, back])
        let images = [try image(seed: 19), try image(seed: 81)]
        var outputs: [Data] = []
        for tailFirst in [false, true] {
            let log = MultiWindowDiagnosticDrawLog()
            let renderer = try MultiWindowCompositeRenderer(layout: layout,
                diagnosticTailStripFirst: tailFirst, diagnosticObserve: { event, window, top in
                    if event == .drawBefore { log.append(window: window, top: top) }
                })
            for (index, placement) in layout.placements.enumerated() {
                try await renderer.append(images[index], windowID: placement.window.id, deadline: deadline)
            }
            let result = try await renderer.finish(deadline: deadline)
            outputs.append(try XCTUnwrap(result.dataProvider?.data) as Data)
            XCTAssertEqual(log.tops(window: 202), tailFirst ? [256, 0, 128] : [0, 128, 256])
            XCTAssertEqual(log.tops(window: 101), tailFirst ? [256, 0, 128] : [0, 128, 256])
        }
        XCTAssertEqual(outputs[0], outputs[1], "Reordering disjoint bands must preserve every output byte, including alpha overlap")
    }

    func testTailFirstStillObservesCancellationBetweenStrips() async throws {
        let layout = try MultiWindowCaptureLayout(frontToBack: [window(101, x: 0, y: 0)])
        let source = try image(seed: 19)
        let log = MultiWindowDiagnosticDrawLog()
        let task = Task {
            let renderer = try MultiWindowCompositeRenderer(layout: layout,
                diagnosticTailStripFirst: true, diagnosticObserve: { event, window, top in
                    if event == .drawAfter {
                        log.append(window: window, top: top)
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                })
            do {
                try await renderer.append(source, windowID: 101, deadline: self.deadline)
                _ = try await renderer.finish(deadline: self.deadline)
            } catch {
                await renderer.discard()
                throw error
            }
        }
        do { try await task.value; XCTFail("Cancelled diagnostic returned a completed image") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(log.tops(window: 101), [256], "Cancellation must prevent the next strip")
    }

    private var deadline: TimeInterval { ProcessInfo.processInfo.systemUptime + 10 }
    private func window(_ id: UInt32, x: CGFloat, y: CGFloat) throws -> MultiWindowDescriptor {
        try MultiWindowDescriptor(id: id, ownerPID: Int32(id), ownerStartedAt: 1,
            label: "Diagnostic", bounds: CGRect(x: x, y: y, width: 16, height: 368), maximumScale: 1)
    }
    private func image(seed: Int) throws -> CGImage {
        var bytes = Data(count: 16 * 368 * 4)
        bytes.withUnsafeMutableBytes { raw in
            let pointer = raw.bindMemory(to: UInt8.self)
            for y in 0..<368 { for x in 0..<16 {
                let offset = (y * 16 + x) * 4
                let alpha = (x + y) % 5 == 0 ? 128 : 255
                pointer[offset] = UInt8((x + seed) % (alpha + 1))
                pointer[offset + 1] = UInt8((y + seed) % (alpha + 1))
                pointer[offset + 2] = UInt8(seed % (alpha + 1))
                pointer[offset + 3] = UInt8(alpha)
            } }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        return try XCTUnwrap(CGImage(width: 16, height: 368, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 16 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}

private final class MultiWindowDiagnosticDrawLog: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [(UInt32, Int)] = []
    func append(window: UInt32, top: Int) { lock.lock(); rows.append((window, top)); lock.unlock() }
    func tops(window: UInt32) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return rows.filter { $0.0 == window }.map { $0.1 }
    }
}
