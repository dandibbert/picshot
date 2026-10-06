import Foundation

/// Bounded ISO-BMFF admission for both Apple mdat→moof and moof→mdat layouts.
/// Metadata is admitted only when all sample bytes it references are inside
/// complete mdat payloads. Original offsets are retained, never rewritten.
public enum RecordingRecoveryMP4 {
    public static let maximumAtoms = 16_384
    public static let maximumSamples = 1_000_000
    private static let maximumMetadataBytes = 67_108_864

    public static func completePrefix(fileSize: Int64, finalized: Bool = false,
                                      read: (Int64, Int) throws -> Data) throws -> RecordingRecoveryPrefix {
        guard fileSize > 0, fileSize <= RecordingRecoveryJournal.maximumBytes else { throw RecordingRecoveryError.limitExceeded }
        var offset: Int64 = 0, safeEnd: Int64 = 0
        var hasFileType = false, movie: Movie?, pending: Unit?
        var fragments = 0, topAtoms = 0, metadataBytes = 0, totalSamples = 0
        var sequence: UInt32 = 0
        var rangeChecks = 0
        var media: [Range<Int64>] = []
        while offset < fileSize {
            topAtoms += 1
            guard topAtoms <= maximumAtoms else { throw RecordingRecoveryError.limitExceeded }
            guard fileSize - offset >= 8 else { break }
            let header = try read(offset, 8)
            guard header.count == 8 else { break }
            let type = String(bytes: header[4..<8], encoding: .ascii) ?? ""
            var length = header.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            var headerSize: Int64 = 8
            if length == 1 {
                guard fileSize - offset >= 16 else { break }
                let extended = try read(offset + 8, 8)
                guard extended.count == 8 else { break }
                length = extended.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }; headerSize = 16
            } else if length == 0 {
                // An unclosed active mdat is never a committed fragment.
                guard finalized, type == "mdat" else { break }
                length = UInt64(fileSize - offset)
            }
            guard length >= UInt64(headerSize) else { throw malformed() }
            guard length <= UInt64(fileSize - offset) else { break }
            let end = offset + Int64(length)
            switch type {
            case "ftyp":
                guard offset == 0, !hasFileType, length <= 4_096 else { throw malformed() }
                hasFileType = true
            case "mdat":
                guard hasFileType else { throw malformed() }
                media.append((offset + headerSize)..<end)
            case "moov", "moof":
                guard hasFileType else { throw malformed() }
                // Never cross a fragment with unresolved media references.
                if pending != nil { return try result(end: safeEnd, fragments: fragments, size: fileSize) }
                let limit = type == "moov" ? 16_777_216 : 4_194_304
                guard length <= UInt64(limit), metadataBytes <= maximumMetadataBytes - Int(length) else {
                    throw RecordingRecoveryError.limitExceeded
                }
                metadataBytes += Int(length)
                let data = try read(offset, Int(length))
                guard data.count == Int(length) else { return try result(end: safeEnd, fragments: fragments, size: fileSize) }
                let box = Bytes(data: data)
                if type == "moov" {
                    guard movie == nil else { throw malformed() }
                    let parsed = try parseMovie(box, body: Int(headerSize)..<data.count)
                    movie = parsed.movie; pending = parsed.unit
                } else {
                    guard let movie else { throw malformed() }
                    let parsed = try parseFragment(box, body: Int(headerSize)..<data.count, offset: offset, movie: movie)
                    guard parsed.sequence > sequence else { throw malformed() }
                    sequence = parsed.sequence; pending = parsed.unit
                }
                if let pending {
                    guard totalSamples <= maximumSamples - pending.samples else { throw RecordingRecoveryError.limitExceeded }
                    totalSamples += pending.samples
                }
            case "free", "skip", "wide", "uuid", "sidx", "mfra", "styp", "prft": break
            default: throw malformed()
            }
            if var unit = pending, type == "mdat" || type == "moov" || type == "moof" {
                // Sorted ranges advance once; a late unresolved range must not
                // make each subsequent atom rescan millions of earlier chunks.
                while unit.nextRange < unit.ranges.count {
                    rangeChecks += 1
                    guard rangeChecks <= maximumSamples + maximumAtoms else { throw RecordingRecoveryError.limitExceeded }
                    guard contained(unit.ranges[unit.nextRange], in: media) else { break }
                    unit.nextRange += 1
                }
                if unit.nextRange == unit.ranges.count {
                    if unit.samples > 0 { safeEnd = end; fragments += 1 }
                    pending = nil
                } else { pending = unit }
            }
            offset = end
        }
        guard movie != nil else { throw malformed() }
        // Even finalized input is trimmed to validated metadata/media, avoiding
        // an unreferenced or unvalidated trailer. Non-media trailing atoms can
        // remain omitted without changing any original sample offsets.
        return try result(end: safeEnd, fragments: fragments, size: fileSize)
    }

    private static func result(end: Int64, fragments: Int, size: Int64) throws -> RecordingRecoveryPrefix {
        guard end > 0, fragments > 0 else { throw malformed() }
        return RecordingRecoveryPrefix(byteCount: end, completeFragments: fragments, ignoredTailBytes: size - end)
    }
    private static func malformed(_ function: String = #function, line: Int = #line) -> RecordingRecoveryError {
        .io("MP4 元数据未通过安全校验（\(function):\(line)），原始录屏已保留。")
    }
    private static func contained(_ range: Range<Int64>, in media: [Range<Int64>]) -> Bool {
        guard range.lowerBound >= 0, !range.isEmpty else { return false }
        var low = 0, high = media.count
        while low < high {
            let middle = (low + high) / 2
            if media[middle].lowerBound <= range.lowerBound { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return false }
        return range.upperBound <= media[low - 1].upperBound
    }
    private struct Defaults {
        var duration: UInt32 = 0
        var size: UInt32 = 0
        var descriptionCount: UInt32 = 1
        var descriptionIndex: UInt32 = 1
    }
    private struct Movie { var tracks: [UInt32: Defaults] }
    private struct Unit {
        let ranges: [Range<Int64>]
        let samples: Int
        var nextRange = 0
        init(ranges: [Range<Int64>], samples: Int) {
            self.ranges = ranges.sorted { $0.lowerBound < $1.lowerBound }
            self.samples = samples
        }
    }
    private struct Atom { let type: String; let body: Range<Int> }

    private struct Bytes {
        let data: Data
        func integer(_ at: Int, _ bytes: Int, within range: Range<Int>) throws -> UInt64 {
            guard at >= range.lowerBound, bytes >= 0, bytes <= 8, at <= range.upperBound - bytes else { throw malformed() }
            return data[at..<(at + bytes)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        func u32(_ at: Int, _ range: Range<Int>) throws -> UInt32 { UInt32(try integer(at, 4, within: range)) }
        func children(_ range: Range<Int>, maximum: Int = 4_096) throws -> [Atom] {
            var result: [Atom] = [], offset = range.lowerBound
            while offset < range.upperBound {
                guard result.count < maximum, range.upperBound - offset >= 8 else { throw malformed() }
                var length = try integer(offset, 4, within: range), header = 8
                let type = String(bytes: data[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""
                if length == 1 { length = try integer(offset + 8, 8, within: range); header = 16 }
                guard length >= UInt64(header), length <= UInt64(range.upperBound - offset) else { throw malformed() }
                result.append(Atom(type: type, body: (offset + header)..<(offset + Int(length))))
                offset += Int(length)
            }
            return result
        }
        func one(_ type: String, in atoms: [Atom]) throws -> Atom {
            let matches = atoms.filter { $0.type == type }
            guard matches.count == 1 else { throw malformed() }; return matches[0]
        }
        func full(_ atom: Atom, versions: [UInt8] = [0]) throws -> UInt32 {
            let raw = try u32(atom.body.lowerBound, atom.body)
            guard versions.contains(UInt8(raw >> 24)) else { throw malformed() }
            return raw & 0x00ff_ffff
        }
    }

    private static func parseMovie(_ box: Bytes, body: Range<Int>) throws -> (movie: Movie, unit: Unit) {
        let children = try box.children(body)
        // Reference movies can resolve external alternatives outside dref.
        guard !children.contains(where: { ["rmra", "cmov"].contains($0.type) }) else { throw malformed() }
        let tracks = children.filter { $0.type == "trak" }
        guard !tracks.isEmpty, tracks.count <= 3 else { throw malformed() }
        var defaults: [UInt32: Defaults] = [:], ranges: [Range<Int64>] = []
        var samples = 0, videos = 0, audios = 0
        for track in tracks {
            let atoms = try box.children(track.body)
            let header = try box.one("tkhd", in: atoms)
            _ = try box.full(header, versions: [0, 1])
            let version = try box.integer(header.body.lowerBound, 1, within: header.body)
            let id = try box.u32(header.body.lowerBound + (version == 1 ? 20 : 12), header.body)
            guard id > 0, defaults[id] == nil else { throw malformed() }
            defaults[id] = Defaults()
            let media = try box.children(box.one("mdia", in: atoms).body)
            let handler = try box.one("hdlr", in: media)
            let handlerOffset = handler.body.lowerBound + 8
            _ = try box.integer(handlerOffset, 4, within: handler.body)
            let kind = String(bytes: box.data[handlerOffset..<(handlerOffset + 4)], encoding: .ascii)
            if kind == "vide" { videos += 1 } else if kind == "soun" { audios += 1 } else { throw malformed() }
            let information = try box.children(box.one("minf", in: media).body)
            let references = try box.children(box.one("dinf", in: information).body)
            let reference = try box.one("dref", in: references)
            guard try box.full(reference) == 0 else { throw malformed() }
            let referenceCount = try box.u32(reference.body.lowerBound + 4, reference.body)
            guard (1...16).contains(referenceCount) else { throw malformed() }
            let entries = try box.children((reference.body.lowerBound + 8)..<reference.body.upperBound, maximum: 16)
            guard entries.count == Int(referenceCount) else { throw malformed() }
            for entry in entries {
                // Never permit AVFoundation to follow external media URLs.
                guard entry.type == "url ", try box.full(entry) == 1, entry.body.count == 4 else { throw malformed() }
            }
            let table = try box.children(box.one("stbl", in: information).body)
            let descriptions = try box.one("stsd", in: table)
            guard try box.full(descriptions) == 0 else { throw malformed() }
            let descriptionCount = try box.u32(descriptions.body.lowerBound + 4, descriptions.body)
            guard (1...16).contains(descriptionCount) else { throw malformed() }
            defaults[id]?.descriptionCount = descriptionCount
            let formats = try box.children((descriptions.body.lowerBound + 8)..<descriptions.body.upperBound, maximum: 16)
            guard formats.count == Int(descriptionCount) else { throw malformed() }
            for format in formats {
                guard ["avc1", "avc3", "mp4a"].contains(format.type) else { throw malformed() }
                let referenceIndex = try box.integer(format.body.lowerBound + 6, 2, within: format.body)
                guard referenceIndex > 0, referenceIndex <= UInt64(referenceCount) else { throw malformed() }
            }
            let sampleSizes = try box.one("stsz", in: table)
            guard try box.full(sampleSizes) == 0 else { throw malformed() }
            let uniformSize = try box.u32(sampleSizes.body.lowerBound + 4, sampleSizes.body)
            let count = Int(try box.u32(sampleSizes.body.lowerBound + 8, sampleSizes.body))
            guard count <= maximumSamples - samples else { throw RecordingRecoveryError.limitExceeded }
            samples += count
            guard sampleSizes.body.count == 12 + (uniformSize == 0 ? count * 4 : 0) else { throw malformed() }
            let offsetTables = table.filter { $0.type == "stco" || $0.type == "co64" }
            guard offsetTables.count == 1 else { throw malformed() }
            let offsets = offsetTables[0], offsetWidth = offsets.type == "stco" ? 4 : 8
            guard try box.full(offsets) == 0 else { throw malformed() }
            let chunks = Int(try box.u32(offsets.body.lowerBound + 4, offsets.body))
            guard chunks <= maximumSamples, offsets.body.count == 8 + chunks * offsetWidth else { throw malformed() }
            let sampleToChunk = try box.one("stsc", in: table)
            guard try box.full(sampleToChunk) == 0 else { throw malformed() }
            let mappings = Int(try box.u32(sampleToChunk.body.lowerBound + 4, sampleToChunk.body))
            guard mappings <= chunks, sampleToChunk.body.count == 8 + mappings * 12 else { throw malformed() }
            if count == 0 { guard chunks == 0, mappings == 0 else { throw malformed() }; continue }
            guard chunks > 0, mappings > 0 else { throw malformed() }
            var mapping = 0, nextMappingChunk = 0, perChunk = 0, sample = 0
            for chunk in 1...chunks {
                if mapping == 0 || chunk == nextMappingChunk {
                    let start = sampleToChunk.body.lowerBound + 8 + mapping * 12
                    let first = Int(try box.u32(start, sampleToChunk.body))
                    perChunk = Int(try box.u32(start + 4, sampleToChunk.body))
                    let description = try box.u32(start + 8, sampleToChunk.body)
                    guard first == chunk, perChunk > 0, description > 0, description <= descriptionCount else { throw malformed() }
                    mapping += 1
                    nextMappingChunk = mapping < mappings ? Int(try box.u32(start + 12, sampleToChunk.body)) : chunks + 1
                    guard nextMappingChunk > chunk, nextMappingChunk <= chunks + 1 else { throw malformed() }
                }
                guard perChunk <= count - sample else { throw malformed() }
                var bytes: UInt64 = 0
                for _ in 0..<perChunk {
                    let size: UInt32
                    if uniformSize > 0 { size = uniformSize }
                    else { size = try box.u32(sampleSizes.body.lowerBound + 12 + sample * 4, sampleSizes.body) }
                    guard size > 0 else { throw malformed() }; bytes += UInt64(size); sample += 1
                }
                let offset = try box.integer(offsets.body.lowerBound + 8 + (chunk - 1) * offsetWidth, offsetWidth, within: offsets.body)
                ranges.append(try sampleRange(offset: offset, bytes: bytes))
            }
            guard sample == count, mapping == mappings else { throw malformed() }
        }
        guard videos == 1, audios <= 2 else { throw malformed() }
        let extensions = children.filter { $0.type == "mvex" }
        guard extensions.count <= 1 else { throw malformed() }
        if let ext = extensions.first {
            var seen = Set<UInt32>()
            for atom in try box.children(ext.body) where atom.type == "trex" {
                guard try box.full(atom) == 0, atom.body.count == 24 else { throw malformed() }
                let id = try box.u32(atom.body.lowerBound + 4, atom.body)
                guard defaults[id] != nil, seen.insert(id).inserted else { throw malformed() }
                guard var existing = defaults[id] else { throw malformed() }
                existing.descriptionIndex = try box.u32(atom.body.lowerBound + 8, atom.body)
                guard existing.descriptionIndex > 0, existing.descriptionIndex <= existing.descriptionCount else { throw malformed() }
                existing.duration = try box.u32(atom.body.lowerBound + 12, atom.body)
                existing.size = try box.u32(atom.body.lowerBound + 16, atom.body)
                defaults[id] = existing
            }
        }
        return (Movie(tracks: defaults), Unit(ranges: ranges, samples: samples))
    }

    private static func parseFragment(_ box: Bytes, body: Range<Int>, offset: Int64, movie: Movie) throws -> (sequence: UInt32, unit: Unit) {
        let children = try box.children(body)
        let header = try box.one("mfhd", in: children)
        guard try box.full(header) == 0, header.body.count == 8 else { throw malformed() }
        let sequence = try box.u32(header.body.lowerBound + 4, header.body)
        let tracks = children.filter { $0.type == "traf" }
        guard !tracks.isEmpty, tracks.count <= 3 else { throw malformed() }
        var ranges: [Range<Int64>] = [], samples = 0, previousTrackEnd = offset
        var seen = Set<UInt32>()
        for track in tracks {
            let atoms = try box.children(track.body)
            let header = try box.one("tfhd", in: atoms)
            let flags = try box.full(header)
            guard flags & ~0x03003b == 0 else { throw malformed() }
            let id = try box.u32(header.body.lowerBound + 4, header.body)
            guard let defaults = movie.tracks[id], seen.insert(id).inserted else { throw malformed() }
            var cursor = header.body.lowerBound + 8
            let base: Int64
            if flags & 1 != 0 {
                let raw = try box.integer(cursor, 8, within: header.body); cursor += 8
                guard raw <= UInt64(RecordingRecoveryJournal.maximumBytes) else { throw malformed() }; base = Int64(raw)
            } else { base = flags & 0x020000 != 0 ? offset : previousTrackEnd }
            var description = defaults.descriptionIndex
            if flags & 2 != 0 { description = try box.u32(cursor, header.body); cursor += 4 }
            guard description > 0, description <= defaults.descriptionCount else { throw malformed() }
            var duration = defaults.duration, size = defaults.size
            if flags & 8 != 0 { duration = try box.u32(cursor, header.body); cursor += 4 }
            if flags & 0x10 != 0 { size = try box.u32(cursor, header.body); cursor += 4 }
            if flags & 0x20 != 0 { _ = try box.u32(cursor, header.body); cursor += 4 }
            guard cursor == header.body.upperBound else { throw malformed() }
            let runs = atoms.filter { $0.type == "trun" }
            guard !runs.isEmpty, runs.count <= 4_096 else { throw malformed() }
            var runEnd = base
            for run in runs {
                let runFlags = try box.full(run, versions: [0, 1])
                guard runFlags & ~0x000f05 == 0, runFlags & 0x404 != 0x404 else { throw malformed() }
                let count = Int(try box.u32(run.body.lowerBound + 4, run.body))
                guard count <= maximumSamples - samples else { throw RecordingRecoveryError.limitExceeded }
                samples += count; cursor = run.body.lowerBound + 8
                if runFlags & 1 != 0 {
                    let signed = Int32(bitPattern: try box.u32(cursor, run.body)); cursor += 4
                    runEnd = base + Int64(signed)
                }
                if runFlags & 4 != 0 { _ = try box.u32(cursor, run.body); cursor += 4 }
                var bytes: UInt64 = 0
                for _ in 0..<count {
                    let sampleDuration: UInt32, sampleSize: UInt32
                    if runFlags & 0x100 != 0 { sampleDuration = try box.u32(cursor, run.body); cursor += 4 } else { sampleDuration = duration }
                    if runFlags & 0x200 != 0 { sampleSize = try box.u32(cursor, run.body); cursor += 4 } else { sampleSize = size }
                    guard sampleDuration > 0, sampleSize > 0, flags & 0x010000 == 0 else { throw malformed() }
                    bytes += UInt64(sampleSize)
                    if runFlags & 0x400 != 0 { _ = try box.u32(cursor, run.body); cursor += 4 }
                    if runFlags & 0x800 != 0 { _ = try box.u32(cursor, run.body); cursor += 4 }
                }
                guard cursor == run.body.upperBound else { throw malformed() }
                if count > 0 {
                    guard runEnd >= 0 else { throw malformed() }
                    let range = try sampleRange(offset: UInt64(runEnd), bytes: bytes)
                    ranges.append(range); runEnd = range.upperBound
                }
            }
            previousTrackEnd = runEnd
        }
        guard samples > 0 else { throw malformed() }
        return (sequence, Unit(ranges: ranges, samples: samples))
    }
    private static func sampleRange(offset: UInt64, bytes: UInt64) throws -> Range<Int64> {
        let maximum = UInt64(RecordingRecoveryJournal.maximumBytes)
        guard bytes > 0, offset <= maximum, bytes <= maximum - offset else { throw malformed() }
        return Int64(offset)..<Int64(offset + bytes)
    }
}
