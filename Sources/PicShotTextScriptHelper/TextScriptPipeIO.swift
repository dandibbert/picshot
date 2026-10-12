import Foundation
import Darwin
import PicShotTextScriptCore

enum TextScriptPipeIO {
    static func prepare() throws {
        // Neither request nor result may be redirected to regular files by this helper.
        for descriptor in [STDIN_FILENO, STDOUT_FILENO] {
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFIFO) else {
                throw TextScriptDiagnostic.transportFailure
            }
        }
        let flags = fcntl(STDOUT_FILENO, F_GETFL)
        guard flags >= 0, fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw TextScriptDiagnostic.transportFailure
        }
    }

    static func readRequest() throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(STDIN_FILENO, $0.baseAddress!, min($0.count, TextScriptLimits.requestBytes - data.count + 1))
            }
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw TextScriptDiagnostic.transportFailure }
            guard count <= TextScriptLimits.requestBytes - data.count else { throw TextScriptDiagnostic.invalidRequest }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard !data.isEmpty else { throw TextScriptDiagnostic.invalidRequest }
        return data
    }

    static func writeResponse(_ data: Data) throws {
        guard !data.isEmpty, data.count <= TextScriptLimits.responseBytes else { throw TextScriptDiagnostic.outputTooLarge }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw TextScriptDiagnostic.transportFailure }
            var offset = 0
            while offset < raw.count {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw TextScriptDiagnostic.transportFailure }
                let count = Darwin.write(STDOUT_FILENO, base.advanced(by: offset), raw.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else { throw TextScriptDiagnostic.transportFailure }
                var descriptor = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&descriptor, 1, 10)
                if ready < 0, errno != EINTR { throw TextScriptDiagnostic.transportFailure }
            }
        }
    }

    static func fixedDiagnostic(_ code: TextScriptDiagnostic) {
        // This enum has no associated payload. Never stringify an arbitrary caught Error.
        let bytes = Array((code.rawValue + "\n").utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
    }
}
