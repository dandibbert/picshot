import Foundation

/// Cheap framing checks supplement native decoder validation. They are never a
/// substitute for decoding the final bytes in the disposable helper.
public enum CodecOutputMagic {
    public static func validate(_ data: Data, format: CodecExportFormat) throws {
        switch format {
        case .webp:
            guard data.count >= 20, Array(data.prefix(4)) == Array("RIFF".utf8), Array(data[8..<12]) == Array("WEBP".utf8)
            else { throw CodecExportFailure(.invalidOutput) }
            let size = data[4..<8].enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
            guard size + 8 == UInt64(data.count) else { throw CodecExportFailure(.invalidOutput) }
        case .avif:
            guard data.count >= 24, Array(data[4..<8]) == Array("ftyp".utf8) else { throw CodecExportFailure(.invalidOutput) }
            let size = data.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard size >= 24, size <= UInt64(min(data.count, 4_096)), size % 4 == 0 else { throw CodecExportFailure(.invalidOutput) }
            let brands = [Array(data[8..<12])] + stride(from: 16, to: Int(size), by: 4).map { Array(data[$0..<($0 + 4)]) }
            guard brands.contains(Array("avif".utf8)), !brands.contains(Array("avis".utf8))
            else { throw CodecExportFailure(.invalidOutput) }
        }
    }
}
