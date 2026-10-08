import AppKit
import XCTest

/// Public provider callbacks and a Swift owner, never weak Core Foundation refs.
final class CaptureTestProviderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var callbackCount = 0, deallocationCount = 0, activeBytes = 0
    var callbacks: Int { lock.lock(); defer { lock.unlock() }; return callbackCount }
    var deallocations: Int { lock.lock(); defer { lock.unlock() }; return deallocationCount }
    var liveBytes: Int { lock.lock(); defer { lock.unlock() }; return activeBytes }
    private func allocated(_ bytes: Int) { lock.lock(); activeBytes += bytes; lock.unlock() }
    private func callback(_ bytes: Int) {
        lock.lock(); callbackCount += 1; lock.unlock()
    }
    private func deallocated(_ bytes: Int) {
        lock.lock(); deallocationCount += 1; activeBytes -= bytes; lock.unlock()
    }

    private final class Storage {
        let pointer: UnsafeMutableRawPointer, byteCount: Int
        let counter: CaptureTestProviderCounter
        init(bytes: Int, counter: CaptureTestProviderCounter) {
            byteCount = bytes; self.counter = counter
            pointer = .allocate(byteCount: bytes, alignment: 16)
            let pixels = pointer.bindMemory(to: UInt8.self, capacity: bytes)
            for offset in stride(from: 0, to: bytes, by: 4) {
                pixels[offset] = 64; pixels[offset + 1] = 128
                pixels[offset + 2] = 192; pixels[offset + 3] = 255
            }
            counter.allocated(bytes)
        }
        deinit { pointer.deallocate(); counter.deallocated(byteCount) }
    }

    static func image(width: Int, height: Int, counter: CaptureTestProviderCounter) throws -> CGImage {
        precondition((1...64).contains(width) && (1...64).contains(height))
        let storage = Storage(bytes: width * height * 4, counter: counter)
        let retained = Unmanaged.passRetained(storage)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: storage.pointer,
            size: storage.byteCount, releaseData: { info, _, size in
                guard let info else { return }
                let storage = Unmanaged<Storage>.fromOpaque(info).takeRetainedValue()
                storage.counter.callback(size)
            }) else {
            retained.release(); throw NSError(domain: "CaptureProviderTest", code: 1)
        }
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}
