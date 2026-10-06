import Foundation
import Darwin
import PicShotCodecCore

enum CodecFileIO {
    static func read(_ handle: FileHandle, maximum: Int, isCancelled: () -> Bool) throws -> Data {
        var data = Data()
        while true {
            guard !isCancelled() else { throw CodecExportFailure(.cancelled) }
            let remaining = maximum - data.count
            guard let chunk = try handle.read(upToCount: min(65_536, remaining + 1)), !chunk.isEmpty else { break }
            guard chunk.count <= remaining else { throw CodecExportFailure(.tooLarge) }
            data.append(chunk)
        }
        guard !data.isEmpty else { throw CodecExportFailure(.invalidSource) }
        return data
    }
    static func write(_ data: Data, to descriptor: Int32, isCancelled: () -> Bool) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw CodecExportFailure(.invalidOutput) }
            try write(base, count: data.count, to: descriptor, isCancelled: isCancelled)
        }
    }
    static func write(_ base: UnsafeRawPointer, count: Int, to descriptor: Int32, isCancelled: () -> Bool) throws {
        var offset = 0
        while offset < count {
            guard !isCancelled() else { throw CodecExportFailure(.cancelled) }
            let amount = Darwin.write(descriptor, base.advanced(by: offset), min(65_536, count - offset))
            if amount > 0 { offset += amount }
            else if amount < 0 && errno == EINTR { continue }
            else { throw CodecExportFailure(.invalidOutput) }
        }
    }
}
