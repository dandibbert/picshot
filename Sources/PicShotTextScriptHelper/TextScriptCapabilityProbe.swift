import Foundation
import Darwin
import PicShotTextScriptCore

/// Native-only experiment plumbing. It never creates a JavaScript context, accepts a path,
/// reads file contents, writes file contents, or exposes an operation to JavaScript.
enum TextScriptCapabilityProbe {
    static func run(requestID: UUID, request: TextScriptProbeRequest) -> TextScriptProbeResult {
        let directory = TextScriptProbeRequest.sentinelDirectory(for: requestID)
        let readError = attemptOpen(directory + "/" + TextScriptProbeRequest.readSentinelName, flags: O_RDONLY)
        let writeError = attemptOpen(directory + "/" + TextScriptProbeRequest.writeSentinelName, flags: O_WRONLY)
        let networkError = attemptLoopback(port: request.loopbackPort)
        return .init(readDenied: denied(readError), writeDenied: denied(writeError), networkDenied: denied(networkError),
                     readErrno: readError, writeErrno: writeError, networkErrno: networkError)
    }

    private static func denied(_ code: Int32) -> Bool { code == EPERM || code == EACCES }

    private static func attemptOpen(_ path: String, flags: Int32) -> Int32 {
        let descriptor = open(path, flags | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return errno }
        close(descriptor)
        return 0
    }

    private static func attemptLoopback(port: UInt16) -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return errno }
        defer { close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else { return errno }
        guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return errno }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return 0 }
        let connectError = errno
        guard connectError == EINPROGRESS else { return connectError }
        var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&poller, 1, 200)
        guard ready > 0 else { return ready == 0 ? ETIMEDOUT : errno }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return errno }
        return socketError
    }
}
