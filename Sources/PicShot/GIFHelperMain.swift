import Darwin
import Foundation
import ImageIO

/// This hook runs before NSApplication, AppDelegate, capture services or model
/// initialization. The ordinary signed app binary doubles as a one-job worker.
enum GIFHelperMain {
    static let argument = "--picshot-gif-helper"

    @MainActor
    static func runIfRequested() -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.contains(argument) else { return false }

        // A dedicated queue provides a backstop even if native decoding, the
        // main run loop, or a pipe consumer stops cooperating. The parent also
        // terminates/kills and reaps this process under its independent limits.
        DispatchQueue(label: "PicShot.GIFHelper.hard-deadline").asyncAfter(deadline: .now() + GIFHelperLimits.wallSeconds + 3) {
            Darwin._exit(70)
        }
        _ = signal(SIGPIPE, SIG_IGN)
        _ = umask(0o077)
        let writer = GIFHelperEventWriter()
        do {
            try makeNonblocking(STDIN_FILENO)
            try makeNonblocking(STDOUT_FILENO)
            guard arguments == [argument] else { throw GIFHelperProtocolError.invalidMessage }
            let parent = getppid()
            let files = try GIFHelperJobFiles.validate(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
            guard parent > 1 else {
                _ = files.cleanupAfterParentLoss()
                throw CancellationError()
            }
            let state = GIFHelperRunState()
            let start = ProcessInfo.processInfo.systemUptime
            var nextSample = start
            var input = GIFHelperInputDecoder()
            var stdinOpen = true
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while !state.isComplete {
                let now = ProcessInfo.processInfo.systemUptime
                if now - start >= GIFHelperLimits.wallSeconds { state.cancel(code: "deadline", message: "GIF export exceeded its time limit.") }
                if getppid() != parent || (kill(parent, 0) != 0 && errno == ESRCH) {
                    state.markParentLost()
                    state.cancel(code: "cancelled", message: "The GIF export parent process exited.")
                }
                if now >= nextSample {
                    let reading = GIFResourceMemoryReading.current()
                    do { try writer.memory(reading) }
                    catch { state.cancel(code: "protocol", message: "The GIF helper output pipe stopped accepting events.") }
                    if (reading.residentBytes ?? 0) > GIFHelperLimits.residentBytes ||
                        (reading.physicalFootprintBytes ?? 0) > GIFHelperLimits.residentBytes {
                        state.cancel(code: "memoryLimit", message: "The GIF export exceeded its process memory limit.")
                    }
                    nextSample = now + GIFHelperLimits.sampleIntervalSeconds
                }
                if stdinOpen, !state.isCancelled {
                    let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                    if count > 0 {
                        do {
                            let messages = try input.consume(Data(buffer.prefix(count)))
                            for message in messages {
                                switch message {
                                case .request(let request):
                                    let task = Task.detached(priority: .utility) {
                                        await export(request, files: files, writer: writer, state: state)
                                    }
                                    state.install(task)
                                case .cancel:
                                    state.cancel(code: "cancelled", message: "GIF export was cancelled.")
                                }
                            }
                        } catch {
                            state.cancel(code: "protocol", message: "The GIF helper received an invalid request or control message.")
                        }
                    } else if count == 0 {
                        stdinOpen = false
                        state.markParentLost()
                        do {
                            try input.finish()
                            // The parent deliberately holds stdin open until
                            // process exit. EOF therefore means loss of parent
                            // supervision, including after a complete request.
                            state.cancel(code: "cancelled", message: "The GIF export control pipe closed.")
                        } catch {
                            state.cancel(code: "protocol", message: "The GIF helper request ended before its newline.")
                        }
                    } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                        state.cancel(code: "protocol", message: "The GIF helper could not read its control pipe.")
                    }
                }
                if state.isCancelled, !state.hasTask {
                    try? writer.finish(state.cancellationEvent)
                    state.complete(succeeded: false)
                }
                if let cancelledAt = state.cancelledAt, now - cancelledAt >= 2 {
                    try? writer.finish(state.cancellationEvent)
                    if state.parentWasLost { _ = files.cleanupAfterParentLoss() }
                    Darwin._exit(70)
                }
                if !state.isComplete {
                    // Some AVFoundation paths dispatch work to the main queue.
                    // Pump only this bounded run loop; never create NSApplication.
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                    if !state.isComplete { Thread.sleep(forTimeInterval: 0.002) }
                }
            }
            if getppid() != parent || (kill(parent, 0) != 0 && errno == ESRCH) { state.markParentLost() }
            if state.parentWasLost { _ = files.cleanupAfterParentLoss() }
            if !state.succeeded { Darwin._exit(1) }
            return true
        } catch {
            try? writer.finish(errorEvent(error))
            Darwin._exit(64)
        }
    }

    private static func makeNonblocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw GIFHelperProtocolError.invalidMessage }
    }

    private static func export(_ request: GIFHelperRequest, files: GIFHelperJobFiles,
                               writer: GIFHelperEventWriter, state: GIFHelperRunState) async {
        do {
            try Task.checkCancellation()
            // A file URL can name an HLS playlist or a reference movie. Admit
            // only bounded, in-file H.264/AAC MP4 before AVFoundation sees it.
            try GIFHelperMP4Validation.validate(sourceURL: files.sourceURL)
            try Task.checkCancellation()
            _ = try await GIFInProcessEngine.exportDirect(sourceURL: files.sourceURL, destinationURL: files.outputURL,
                options: request.options, frameExtraction: request.frameExtraction) { fraction in
                    guard !state.isCancelled else { return }
                    do { try writer.progress(fraction) }
                    catch { state.cancel(code: "protocol", message: "The GIF helper could not publish bounded progress.") }
                }
            try Task.checkCancellation()
            let outputBytes = try files.validateOutput()
            // Read GIF metadata only. No complete animation or decoded rasters
            // are retained merely to construct the terminal protocol message.
            guard let source = CGImageSourceCreateWithURL(files.outputURL as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary) else { throw GIFExportError.failed("The result is not a readable GIF.") }
            let frames = CGImageSourceGetCount(source)
            guard frames > 0, frames <= request.options.maximumFrames else { throw GIFExportError.failed("The GIF frame count is invalid.") }
            var duration: Double = 0
            for index in 0..<frames {
                try Task.checkCancellation()
                guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                      let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
                      let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] ?? gif[kCGImagePropertyGIFDelayTime]) as? NSNumber,
                      delay.doubleValue.isFinite, delay.doubleValue > 0 else { throw GIFExportError.failed("The GIF timing is invalid.") }
                duration += delay.doubleValue
            }
            try Task.checkCancellation()
            guard !state.isCancelled else { throw CancellationError() }
            try writer.finish(GIFHelperEvent(kind: .result, outputBytes: outputBytes, frameCount: frames, duration: duration))
            state.complete(succeeded: true)
        } catch {
            let event = state.isCancelled ? state.cancellationEvent : errorEvent(error)
            try? writer.finish(event)
            state.complete(succeeded: false)
        }
    }

    private static func errorEvent(_ error: Error) -> GIFHelperEvent {
        let code: String
        switch error {
        case is CancellationError: code = "cancelled"
        case GIFExportError.invalidOptions: code = "invalidOptions"
        case GIFExportError.noVideo: code = "noVideo"
        case GIFExportError.destinationExists: code = "destinationExists"
        case GIFExportError.tooLarge: code = "tooLarge"
        case GIFExportError.unsupportedTransparency: code = "unsupportedTransparency"
        case is GIFSourceAdmissionFailure: code = "invalidSource"
        case GIFHelperProtocolError.invalidSource: code = "invalidSource"
        case GIFHelperProtocolError.invalidJobDirectory, GIFHelperProtocolError.unexpectedOutput:
            code = "invalidJobDirectory"
        case is GIFHelperProtocolError: code = "protocol"
        default: code = "failed"
        }
        var message = ""
        var byteCount = 0
        for scalar in error.localizedDescription.unicodeScalars {
            let piece = CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
            guard byteCount + piece.utf8.count <= 768 else { break }
            message += piece
            byteCount += piece.utf8.count
        }
        return GIFHelperEvent(kind: .error, errorCode: code, errorMessage: message)
    }
}

/// Bounded, path-free diagnostics for a rejected source. These describe only
/// our admission predicate and a whitelisted box type/offset, never media data.
struct GIFSourceAdmissionFailure: LocalizedError, Equatable, Sendable {
    enum Stage: String, Sendable { case jobSource, mp4Path, mp4Open, mp4Stat, mp4Parser }
    let stage: Stage
    let check: String
    let function: String
    let line: UInt
    let atomType: String?
    let offset: UInt64?
    let count: Int?

    init(stage: Stage, check: StaticString, function: StaticString = #function, line: UInt = #line,
         atomType: String? = nil, offset: UInt64? = nil, count: Int? = nil) {
        self.stage = stage
        self.check = Self.safeLabel(String(describing: check), limit: 48)
        self.function = Self.safeLabel(String(describing: function), limit: 96)
        self.line = line
        if let atomType { self.atomType = Self.knownAtomTypes.contains(atomType) ? atomType : "unrecognized" }
        else { self.atomType = nil }
        self.offset = offset
        self.count = count
    }

    var errorDescription: String? {
        var text = "Source admission stage=\(stage.rawValue) check=\(check) function=\(function) line=\(line)"
        if let atomType { text += " atom=\(atomType)" }
        if let offset { text += " offset=\(offset)" }
        if let count { text += " count=\(count)" }
        return text
    }

    private static func safeLabel(_ value: String, limit: Int) -> String {
        String(value.unicodeScalars.prefix(limit).map { scalar -> Character in
            let allowed = (65...90).contains(scalar.value) || (97...122).contains(scalar.value) ||
                (48...57).contains(scalar.value) || "_():.-".unicodeScalars.contains(scalar)
            return allowed ? Character(String(scalar)) : "_"
        })
    }
    private static let knownAtomTypes: Set<String> = [
        "ftyp", "moov", "mdat", "moof", "mfra", "free", "skip", "wide", "mvhd", "trak", "mvex", "udta", "meta", "iods",
        "tkhd", "mdia", "edts", "tapt", "mdhd", "hdlr", "minf", "elng", "vmhd", "smhd", "dinf", "dref", "stbl", "url ", "urn ", "alis",
        "stsd", "stts", "ctts", "stsc", "stsz", "stz2", "stco", "co64", "stss", "stps", "sdtp", "sgpd", "sbgp", "padb", "stsh", "subs",
        "avc1", "avc3", "mp4a", "esds", "btrt", "avcC", "pasp", "colr", "clap", "fiel", "gama", "cspc", "mdcv", "clli", "chrm",
        "rmra", "rmda", "rdrf", "cmov", "sinf", "wave", "encv", "enca", "hvc1", "hev1", "jpeg", "mp4s"
    ]
}

/// A deliberately narrow input gate for PicShot's recorded/trimmed MP4 files.
/// This is not a general media validator or an alternate media decoder. It
/// rejects reference/playlist/other-codec inputs before a framework can resolve
/// them. Every admitted track's data references point into this same file.
enum GIFHelperMP4Validation {
    static let maximumAtoms = 16_384
    static let maximumDepth = 12
    static let maximumMetadataBytesRead = 1_048_576
    static let maximumMetadataBytesSpanned: UInt64 = 16_777_216
    struct Report {
        let atomCount: Int
        let metadataBytesRead: Int
        let mediaDataBytesSkipped: UInt64
        let trackCount: Int
    }

    @discardableResult
    static func validate(sourceURL: URL) throws -> Report {
        guard sourceURL.isFileURL else { throw GIFSourceAdmissionFailure(stage: .mp4Path, check: "file-url") }
        guard sourceURL.standardizedFileURL.resolvingSymlinksInPath().path == sourceURL.standardizedFileURL.path
        else { throw GIFSourceAdmissionFailure(stage: .mp4Path, check: "canonical-path") }
        // Nonblocking admission prevents a substituted FIFO/device from
        // trapping open() before the post-open regular-file identity check.
        let descriptor = Darwin.open(sourceURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw GIFSourceAdmissionFailure(stage: .mp4Open, check: "open") }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0 else { throw GIFSourceAdmissionFailure(stage: .mp4Stat, check: "fstat") }
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw GIFSourceAdmissionFailure(stage: .mp4Stat, check: "regular") }
        guard information.st_uid == getuid() else { throw GIFSourceAdmissionFailure(stage: .mp4Stat, check: "uid") }
        guard information.st_nlink == 1 else { throw GIFSourceAdmissionFailure(stage: .mp4Stat, check: "nlink") }
        guard information.st_size > 0, information.st_size <= GIFHelperLimits.sourceBytes
        else { throw GIFSourceAdmissionFailure(stage: .mp4Stat, check: "size") }
        return try Reader(descriptor: descriptor, size: UInt64(information.st_size)).validate()
    }

    private struct Atom {
        let type: String
        let offset: UInt64
        let payload: UInt64
        let end: UInt64
        var payloadBytes: UInt64 { end - payload }
    }
    private struct Sample {
        let codec: String
        let reference: Int
    }
    private final class Reader {
        let descriptor: Int32
        let size: UInt64
        var atomCount = 0
        var bytesRead = 0
        init(descriptor: Int32, size: UInt64) { self.descriptor = descriptor; self.size = size }

        func validate() throws -> Report {
            let roots = try atoms(from: 0, to: size, depth: 0)
            let topTypes: Set<String> = ["ftyp", "moov", "mdat", "moof", "mfra", "free", "skip", "wide"]
            try allowed(roots, topTypes)
            let fileType = try one("ftyp", in: roots)
            let movie = try one("moov", in: roots)
            try validateFileType(fileType)
            var mediaBytes: UInt64 = 0
            var metadataBytes: UInt64 = 0
            for atom in roots {
                if atom.type == "mdat" { mediaBytes += atom.payloadBytes }
                else if !["free", "skip", "wide"].contains(atom.type) {
                    try require(atom.payloadBytes <= maximumMetadataBytesSpanned - metadataBytes)
                    metadataBytes += atom.payloadBytes
                }
            }
            try require(mediaBytes > 0)
            let movieChildren = try atoms(in: movie, depth: 1)
            try allowed(movieChildren, ["mvhd", "trak", "mvex", "udta", "meta", "iods", "free", "skip"])
            let tracks = movieChildren.filter { $0.type == "trak" }
            try require(!tracks.isEmpty && tracks.count <= 32)
            var videoTracks = 0
            for track in tracks {
                let trackChildren = try atoms(in: track, depth: 2)
                try allowed(trackChildren, ["tkhd", "mdia", "edts", "udta", "meta", "tapt", "free", "skip"])
                let media = try one("mdia", in: trackChildren)
                let mediaChildren = try atoms(in: media, depth: 3)
                try allowed(mediaChildren, ["mdhd", "hdlr", "minf", "elng", "udta", "meta", "free", "skip"])
                let handler = try one("hdlr", in: mediaChildren)
                try require(handler.payloadBytes >= 12)
                let handlerPrefix = try read(at: handler.payload, count: 12)
                try require(number(handlerPrefix.prefix(4)) == 0)
                let kind = String(decoding: handlerPrefix[8..<12], as: UTF8.self)
                try require(kind == "vide" || kind == "soun")
                if kind == "vide" { videoTracks += 1 }
                let information = try one("minf", in: mediaChildren)
                let informationChildren = try atoms(in: information, depth: 4)
                try allowed(informationChildren, ["vmhd", "smhd", "hdlr", "dinf", "stbl", "free", "skip"])
                let references = try dataReferences(try one("dinf", in: informationChildren))
                let samples = try sampleDescriptions(try one("stbl", in: informationChildren))
                for sample in samples {
                    try require(sample.reference > 0 && sample.reference <= references)
                    try require(kind == "vide" ? ["avc1", "avc3"].contains(sample.codec) : sample.codec == "mp4a")
                }
            }
            try require(videoTracks > 0)
            return Report(atomCount: atomCount, metadataBytesRead: bytesRead, mediaDataBytesSkipped: mediaBytes, trackCount: tracks.count)
        }

        private func validateFileType(_ atom: Atom) throws {
            try require(atom.payloadBytes >= 8 && atom.payloadBytes <= 1_024 && atom.payloadBytes % 4 == 0)
            let data = try read(at: atom.payload, count: Int(atom.payloadBytes))
            let supported: Set<String> = ["isom", "iso2", "iso3", "iso4", "iso5", "iso6", "mp41", "mp42", "avc1"]
            let major = String(decoding: data.prefix(4), as: UTF8.self)
            try require(supported.contains(major))
        }

        private func dataReferences(_ information: Atom) throws -> Int {
            let children = try atoms(in: information, depth: 5)
            try allowed(children, ["dref", "free", "skip"])
            let table = try one("dref", in: children)
            let count = try entryCount(table)
            let entries = try atoms(from: table.payload + 8, to: table.end, depth: 6, allowSelfContainedURL: true)
            try require(entries.count == count)
            for entry in entries {
                // Full-box version 0, flags exactly 1, and no location bytes.
                // Reject urn, alias, external url, and ambiguous trailing data.
                try require(entry.type == "url " && entry.payloadBytes == 4)
                try require(number(try read(at: entry.payload, count: 4)) == 1)
            }
            return count
        }

        private func sampleDescriptions(_ table: Atom) throws -> [Sample] {
            let children = try atoms(in: table, depth: 5)
            try allowed(children, ["stsd", "stts", "ctts", "stsc", "stsz", "stz2", "stco", "co64", "stss", "stps", "sdtp",
                                   "sgpd", "sbgp", "padb", "stsh", "subs", "free", "skip"])
            let descriptions = try one("stsd", in: children)
            let count = try entryCount(descriptions)
            let entries = try atoms(from: descriptions.payload + 8, to: descriptions.end, depth: 6)
            try require(entries.count == count)
            return try entries.map { entry in
                try require(["avc1", "avc3", "mp4a"].contains(entry.type))
                let headerBytes = entry.type == "mp4a" ? 28 : 78
                try require(entry.payloadBytes >= UInt64(headerBytes))
                let prefix = try read(at: entry.payload, count: 10)
                try require(prefix.prefix(6).allSatisfy { $0 == 0 })
                let reference = Int(number(prefix[6..<8]))
                if entry.type == "mp4a" { try require(number(prefix[8..<10]) == 0) } // Version-0 audio sample entry.
                let extensions = try atoms(from: entry.payload + UInt64(headerBytes), to: entry.end, depth: 7,
                    allowNativeChrmLeaf: entry.type == "avc1" || entry.type == "avc3")
                if entry.type == "mp4a" {
                    try allowed(extensions, ["esds", "btrt"])
                    try validateAudioDescriptor(try one("esds", in: extensions))
                } else {
                    try allowed(extensions, ["avcC", "pasp", "colr", "clap", "btrt", "fiel", "gama", "cspc", "mdcv", "clli", "chrm"])
                    // Native evidence contains one opaque 00 00 leaf. Admit
                    // only that representation without inferring its semantics.
                    try require(extensions.filter { $0.type == "chrm" }.count <= 1)
                    let configuration = try one("avcC", in: extensions)
                    try require(configuration.payloadBytes > 0 && configuration.payloadBytes <= 65_536)
                }
                return Sample(codec: entry.type, reference: reference)
            }
        }

        private func validateAudioDescriptor(_ atom: Atom) throws {
            try require(atom.payloadBytes >= 9 && atom.payloadBytes <= 65_536)
            let data = try read(at: atom.payload, count: min(Int(atom.payloadBytes), 16))
            try require(number(data.prefix(4)) == 0 && data[4] == 3) // ES_Descriptor.
            var position = 5
            var length = 0
            var ended = false
            for _ in 0..<4 {
                try require(position < data.count)
                let byte = data[position]; position += 1
                length = (length << 7) | Int(byte & 0x7F)
                if byte & 0x80 == 0 { ended = true; break }
            }
            try require(ended && length >= 3 && UInt64(position + length) == atom.payloadBytes && position + 2 < data.count)
            // ES_ID is followed by flags; URL_Flag would supply another source.
            try require(data[position + 2] & 0x40 == 0)
        }

        private func entryCount(_ atom: Atom) throws -> Int {
            try require(atom.payloadBytes >= 8)
            let prefix = try read(at: atom.payload, count: 8)
            let count = Int(number(prefix[4..<8]))
            try require(number(prefix.prefix(4)) == 0 && (1...16).contains(count))
            return count
        }
        private func allowed(_ atoms: [Atom], _ types: Set<String>, function: StaticString = #function, line: UInt = #line) throws {
            if let rejected = atoms.first(where: { !types.contains($0.type) }) {
                throw GIFSourceAdmissionFailure(stage: .mp4Parser, check: "unexpected-atom", function: function, line: line,
                    atomType: rejected.type, offset: rejected.offset)
            }
        }
        private func one(_ type: String, in atoms: [Atom], function: StaticString = #function, line: UInt = #line) throws -> Atom {
            let matches = atoms.filter { $0.type == type }
            guard matches.count == 1 else {
                throw GIFSourceAdmissionFailure(stage: .mp4Parser, check: "atom-count", function: function, line: line,
                    atomType: type, offset: matches.first?.offset, count: matches.count)
            }
            return matches[0]
        }
        private func atoms(in parent: Atom, depth: Int) throws -> [Atom] {
            try atoms(from: parent.payload, to: parent.end, depth: depth)
        }
        private func atoms(from start: UInt64, to end: UInt64, depth: Int, allowSelfContainedURL: Bool = false,
                           allowNativeChrmLeaf: Bool = false) throws -> [Atom] {
            try require(depth <= maximumDepth && start <= end && end <= size)
            var offset = start
            var result: [Atom] = []
            while offset < end {
                try Task.checkCancellation()
                try require(atomCount < maximumAtoms && end - offset >= 8)
                atomCount += 1
                let header = try read(at: offset, count: 8)
                let type = String(decoding: header[4..<8], as: UTF8.self)
                // Compressed movies hide the reference tree from this gate.
                try require(!["rmra", "rmda", "rdrf", "cmov", "urn ", "alis"].contains(type))
                try require(type != "url " || allowSelfContainedURL)
                var length = number(header.prefix(4))
                var headerBytes: UInt64 = 8
                if length == 1 {
                    try require(end - offset >= 16)
                    length = number(try read(at: offset + 8, count: 8))
                    headerBytes = 16
                } else if length == 0 {
                    // ISO-BMFF permits the final media-data box to extend to EOF.
                    try require(depth == 0 && type == "mdat")
                    length = end - offset
                }
                try require(length >= headerBytes && length <= end - offset)
                if type == "chrm" {
                    // Compatibility is confined to one normal-header leaf in
                    // avc1/avc3. Every other traversed container rejects it.
                    try require(allowNativeChrmLeaf && headerBytes == 8 && length == 10)
                    try require(number(try read(at: offset + headerBytes, count: 2)) == 0)
                }
                result.append(Atom(type: type, offset: offset, payload: offset + headerBytes, end: offset + length))
                offset += length
            }
            return result
        }
        private func read(at offset: UInt64, count: Int) throws -> Data {
            try Task.checkCancellation()
            try require(count >= 0 && count <= maximumMetadataBytesRead - bytesRead && offset <= size && UInt64(count) <= size - offset)
            bytesRead += count
            var data = Data(count: count)
            try data.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                var obtained = 0
                while obtained < count {
                    try Task.checkCancellation()
                    let result = pread(descriptor, base.advanced(by: obtained), count - obtained, off_t(offset + UInt64(obtained)))
                    if result < 0 && errno == EINTR { continue }
                    try require(result > 0)
                    obtained += result
                }
            }
            return data
        }
        private func number<T: Sequence>(_ bytes: T) -> UInt64 where T.Element == UInt8 {
            bytes.reduce(0) { ($0 << 8) | UInt64($1) }
        }
        private func require(_ condition: Bool, function: StaticString = #function, line: UInt = #line) throws {
            guard condition else {
                throw GIFSourceAdmissionFailure(stage: .mp4Parser, check: "predicate", function: function, line: line)
            }
        }
    }
}

struct GIFHelperJobFiles: Sendable {
    let sourceURL: URL
    let outputURL: URL
    private let directoryDevice: dev_t
    private let directoryInode: ino_t
    private let sourceDevice: dev_t
    private let sourceInode: ino_t

    static func validate(directory: URL) throws -> Self {
        let canonical = directory.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = ".picshot-gif-job-"
        guard directory.isFileURL, canonical.path == directory.standardizedFileURL.path,
              canonical.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(canonical.lastPathComponent.dropFirst(prefix.count))) != nil
        else { throw GIFHelperProtocolError.invalidJobDirectory }
        var information = stat()
        guard lstat(canonical.path, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              information.st_uid == getuid(), information.st_mode & 0o7777 == 0o700
        else { throw GIFHelperProtocolError.invalidJobDirectory }
        let directoryDevice = information.st_dev, directoryInode = information.st_ino
        let source = canonical.appendingPathComponent("source.mp4")
        guard lstat(source.path, &information) == 0 else { throw GIFSourceAdmissionFailure(stage: .jobSource, check: "lstat") }
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw GIFSourceAdmissionFailure(stage: .jobSource, check: "regular") }
        guard information.st_uid == getuid() else { throw GIFSourceAdmissionFailure(stage: .jobSource, check: "uid") }
        guard information.st_nlink == 1 else { throw GIFSourceAdmissionFailure(stage: .jobSource, check: "nlink") }
        guard information.st_mode & 0o7077 == 0, information.st_mode & 0o400 != 0
        else { throw GIFSourceAdmissionFailure(stage: .jobSource, check: "permission") }
        guard information.st_size > 0, information.st_size <= GIFHelperLimits.sourceBytes
        else { throw GIFSourceAdmissionFailure(stage: .jobSource, check: "size") }
        let sourceDevice = information.st_dev, sourceInode = information.st_ino
        let output = canonical.appendingPathComponent("result.gif")
        guard lstat(output.path, &information) != 0, errno == ENOENT else { throw GIFHelperProtocolError.unexpectedOutput }
        return Self(sourceURL: source, outputURL: output, directoryDevice: directoryDevice, directoryInode: directoryInode,
                    sourceDevice: sourceDevice, sourceInode: sourceInode)
    }

    func validateOutput() throws -> Int {
        var information = stat()
        guard lstat(outputURL.path, &information) == 0, Self.isPrivateRegularFile(information),
              information.st_size > 0, information.st_size <= Int64(GIFHelperLimits.outputBytes)
        else { throw GIFHelperProtocolError.unexpectedOutput }
        return Int(information.st_size)
    }

    /// Orphan-only, best-effort cleanup. Never enumerate recursively or follow
    /// a link; operate relative to the originally validated directory's fd.
    /// On changed identity, unknown contents, or I/O failure, exit anyway and
    /// allow a residue rather than risk deleting a substituted/user-owned file.
    /// The process-wide independent watchdog still bounds stalled cleanup I/O.
    func cleanupAfterParentLoss() -> Bool {
        let directory = sourceURL.deletingLastPathComponent()
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0, isOriginalDirectory(information),
              fstatat(descriptor, "source.mp4", &information, AT_SYMLINK_NOFOLLOW) == 0,
              isOriginalSource(information) else { return false }
        let listingDescriptor = dup(descriptor)
        guard listingDescriptor >= 0 else { return false }
        guard let listing = fdopendir(listingDescriptor) else { Darwin.close(listingDescriptor); return false }
        defer { closedir(listing) }
        var candidates: [String] = []
        var unknown = false
        var entries = 0
        errno = 0
        while let entry = readdir(listing) {
            entries += 1
            guard entries <= 64 else { return false }
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            if Self.isRecognizedArtifact(name) { candidates.append(name) }
            else { unknown = true }
            errno = 0
        }
        guard errno == 0 else { return false }
        var clean = !unknown
        // Recheck the original source identity before deleting any artifact.
        guard fstatat(descriptor, "source.mp4", &information, AT_SYMLINK_NOFOLLOW) == 0,
              isOriginalSource(information) else { return false }
        for name in candidates {
            guard fstatat(descriptor, name, &information, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.isPrivateRegularFile(information),
                  name != "source.mp4" || isOriginalSource(information) else { clean = false; continue }
            if unlinkat(descriptor, name, 0) != 0 { clean = false }
        }
        guard clean, lstat(directory.path, &information) == 0, isOriginalDirectory(information) else { return false }
        return rmdir(directory.path) == 0
    }

    private func isOriginalDirectory(_ information: stat) -> Bool {
        information.st_dev == directoryDevice && information.st_ino == directoryInode && information.st_uid == getuid() &&
            information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) && information.st_mode & 0o7777 == 0o700
    }
    private func isOriginalSource(_ information: stat) -> Bool {
        information.st_dev == sourceDevice && information.st_ino == sourceInode && Self.isPrivateRegularFile(information)
    }
    private static func isRecognizedArtifact(_ name: String) -> Bool {
        if name == "source.mp4" || name == "result.gif" { return true }
        let prefix = ".picshot-", suffix = ".gif"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let uuid = name.dropFirst(prefix.count).dropLast(suffix.count)
        return UUID(uuidString: String(uuid)) != nil
    }

    private static func isPrivateRegularFile(_ information: stat) -> Bool {
        information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && information.st_uid == getuid() &&
            information.st_nlink == 1 && information.st_mode & 0o7077 == 0 && information.st_mode & 0o400 != 0
    }
}

private final class GIFHelperRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var finished = false
    private var success = false
    private var cancellation: GIFHelperEvent?
    private var cancellationTime: TimeInterval?
    private var parentLost = false
    var isComplete: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    var succeeded: Bool { lock.lock(); defer { lock.unlock() }; return success }
    var hasTask: Bool { lock.lock(); defer { lock.unlock() }; return task != nil }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancellation != nil }
    var cancelledAt: TimeInterval? { lock.lock(); defer { lock.unlock() }; return cancellationTime }
    var parentWasLost: Bool { lock.lock(); defer { lock.unlock() }; return parentLost }
    func markParentLost() { lock.lock(); parentLost = true; lock.unlock() }
    var cancellationEvent: GIFHelperEvent {
        lock.lock(); defer { lock.unlock() }
        return cancellation ?? GIFHelperEvent(kind: .error, errorCode: "cancelled", errorMessage: "GIF export was cancelled.")
    }
    func install(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        let cancelNow = cancellation != nil
        lock.unlock()
        if cancelNow { task.cancel() }
    }
    func cancel(code: String, message: String) {
        lock.lock()
        if cancellation == nil, !finished {
            cancellation = GIFHelperEvent(kind: .error, errorCode: code, errorMessage: message)
            cancellationTime = ProcessInfo.processInfo.systemUptime
        }
        let active = task
        lock.unlock()
        active?.cancel()
    }
    func complete(succeeded: Bool) {
        lock.lock(); defer { lock.unlock() }
        success = succeeded && cancellation == nil
        finished = true
    }
}

/// Serializes small, newline-delimited messages without an unbounded buffer or
/// blocking pipe writes. Terminal events reserve space within the total cap.
private final class GIFHelperEventWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytesWritten = 0
    private var terminal = false
    private var progressCount = 0
    private var lastFraction: Double = -1
    private var residentCount = 0
    private var footprintCount = 0
    private var residentPeak: UInt64?
    private var footprintPeak: UInt64?

    func progress(_ fraction: Double) throws {
        lock.lock(); defer { lock.unlock() }
        guard !terminal else { return }
        guard progressCount < GIFHelperLimits.progressEvents, fraction >= lastFraction else { throw GIFHelperProtocolError.invalidMessage }
        try writeLocked(GIFHelperEvent(kind: .progress, fraction: fraction))
        progressCount += 1
        lastFraction = fraction
    }
    func memory(_ reading: GIFResourceMemoryReading) throws {
        lock.lock(); defer { lock.unlock() }
        guard !terminal else { return }
        recordLocked(reading)
        try writeLocked(GIFHelperEvent(kind: .memory, residentBytes: reading.residentBytes, physicalFootprintBytes: reading.physicalFootprintBytes))
    }
    func finish(_ event: GIFHelperEvent) throws {
        lock.lock(); defer { lock.unlock() }
        guard !terminal else { return }
        terminal = true
        let reading = GIFResourceMemoryReading.current()
        recordLocked(reading)
        var final = event
        final.residentBytes = reading.residentBytes
        final.physicalFootprintBytes = reading.physicalFootprintBytes
        final.sampledPeakResidentBytes = residentPeak
        final.sampledPeakPhysicalFootprintBytes = footprintPeak
        final.residentSampleCount = residentCount
        final.physicalFootprintSampleCount = footprintCount
        try writeLocked(final)
    }
    private func recordLocked(_ reading: GIFResourceMemoryReading) {
        if let bytes = reading.residentBytes { residentCount += 1; residentPeak = max(residentPeak ?? bytes, bytes) }
        if let bytes = reading.physicalFootprintBytes { footprintCount += 1; footprintPeak = max(footprintPeak ?? bytes, bytes) }
    }
    private func writeLocked(_ event: GIFHelperEvent) throws {
        let data = try GIFHelperProtocol.encodeEventLine(event)
        let limit = GIFHelperLimits.stdoutBytes - (terminal ? 0 : GIFHelperLimits.eventBytes)
        guard data.count <= limit - bytesWritten else { throw GIFHelperProtocolError.messageTooLarge }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw GIFHelperProtocolError.invalidMessage }
            var offset = 0
            while offset < data.count {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw GIFHelperProtocolError.invalidMessage }
                let written = Darwin.write(STDOUT_FILENO, base.advanced(by: offset), data.count - offset)
                if written > 0 { offset += written; bytesWritten += written; continue }
                if written < 0, errno == EINTR { continue }
                guard written < 0, errno == EAGAIN || errno == EWOULDBLOCK else { throw GIFHelperProtocolError.invalidMessage }
                var descriptor = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                _ = poll(&descriptor, 1, 10)
            }
        }
    }
}
