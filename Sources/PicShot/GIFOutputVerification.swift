import Foundation

/// Container-only parent verification. Reads at most 64 KiB at a time, never
/// instantiates ImageIO/AVFoundation or decodes a raster in the app process.
enum GIFOutputVerification {
    static func validate(file: FileHandle, bytes: Int, expectedFrames: Int, expectedDuration: Double,
                         options: GIFExportOptions, check: @escaping () throws -> Void = { }) throws {
        try check()
        try file.seek(toOffset: 0)
        var input = Reader(file: file, size: bytes, check: check)
        let signature = try input.bytes(6)
        guard signature == Array("GIF89a".utf8) || signature == Array("GIF87a".utf8) else { throw invalid() }
        let width = try input.word(), height = try input.word(), screenPacked = try input.byte()
        guard width > 0, height > 0, max(width, height) <= options.maximumDimension else { throw invalid() }
        try input.skip(2)
        var globalColors = 0
        if screenPacked & 0x80 != 0 {
            globalColors = 2 << Int(screenPacked & 7)
            try input.skip(globalColors * 3)
        }
        var frames = 0, centiseconds = 0
        var delay: Int?
        var transparent: Int?
        while true {
            try check()
            switch try input.byte() {
            case 0x21:
                let kind = try input.byte()
                if kind == 0xF9 {
                    guard delay == nil, try input.byte() == 4 else { throw invalid() }
                    let flags = try input.byte()
                    guard flags & 0xE0 == 0 else { throw invalid() }
                    let value = try input.word()
                    let index = Int(try input.byte())
                    guard value >= 2, try input.byte() == 0 else { throw invalid() }
                    delay = value; transparent = flags & 1 == 0 ? nil : index
                } else if kind == 0xFF || kind == 0xFE {
                    _ = try input.subblocks()
                } else { throw invalid() }
            case 0x2C:
                guard frames < options.maximumFrames, let frameDelay = delay else { throw invalid() }
                let left = try input.word(), top = try input.word(), imageWidth = try input.word(), imageHeight = try input.word()
                let packed = try input.byte()
                guard left == 0, top == 0, imageWidth == width, imageHeight == height, packed & 0x18 == 0 else { throw invalid() }
                let colors: Int
                if packed & 0x80 != 0 { colors = 2 << Int(packed & 7); try input.skip(colors * 3) }
                else { colors = globalColors }
                guard colors > 0, transparent.map({ $0 < colors }) ?? true,
                      (2...8).contains(Int(try input.byte())), try input.subblocks() > 0 else { throw invalid() }
                frames += 1; centiseconds += frameDelay; delay = nil; transparent = nil
                guard Double(centiseconds) / 100 <= options.maximumDuration + 0.011 else { throw invalid() }
            case 0x3B:
                guard input.position == bytes, frames == expectedFrames, delay == nil,
                      abs(Double(centiseconds) / 100 - expectedDuration) < 0.001 else { throw invalid() }
                return
            default: throw invalid()
            }
        }
    }
    private struct Reader {
        let file: FileHandle
        let size: Int
        var position = 0
        private var buffer = Data()
        private var offset = 0
        private let check: () throws -> Void
        init(file: FileHandle, size: Int, check: @escaping () throws -> Void) { self.file = file; self.size = size; self.check = check }
        mutating func fill() throws {
            try check()
            if offset < buffer.count { return }
            guard position < size else { throw GIFOutputVerification.invalid() }
            buffer = try autoreleasepool { try file.read(upToCount: min(65_536, size - position)) ?? Data() }
            offset = 0
            guard !buffer.isEmpty else { throw GIFOutputVerification.invalid() }
        }
        mutating func byte() throws -> UInt8 {
            try fill(); let value = buffer[offset]; offset += 1; position += 1; return value
        }
        mutating func word() throws -> Int { let low = Int(try byte()); return low | Int(try byte()) << 8 }
        mutating func bytes(_ count: Int) throws -> [UInt8] {
            var result: [UInt8] = []; result.reserveCapacity(count)
            for _ in 0..<count { result.append(try byte()) }
            return result
        }
        mutating func skip(_ count: Int) throws {
            try check()
            guard count >= 0, count <= size - position else { throw GIFOutputVerification.invalid() }
            var remaining = count
            while remaining > 0 {
                try fill(); let available = min(remaining, buffer.count - offset)
                offset += available; position += available; remaining -= available
            }
        }
        mutating func subblocks() throws -> Int {
            var total = 0
            while true { let count = Int(try byte()); if count == 0 { return total }; try skip(count); total += count }
        }
    }
    private static func invalid() -> GIFExportProcessError { .invalidProtocol }
}
