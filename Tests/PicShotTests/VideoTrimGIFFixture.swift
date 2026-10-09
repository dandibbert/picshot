import Foundation
@testable import PicShot

/// Synthetic late-exit child only. Readiness is emitted after the complete
/// expected request and a closed marker, before any sleep or subprocess.
/// Request/path values are positional data, never interpolated shell source.
enum VideoTrimGIFFixture {
    static let executableURL = URL(fileURLWithPath: "/bin/bash")
    static let readyFraction = 0.5
    // VideoTrimExporter maps preparation to 0...0.4 and GIF progress to this
    // disjoint interval. The preparation-complete callback cannot signal ready.
    static let trimReadyFraction = 0.4 + readyFraction * 0.59
    // The real process parser requires an initial zero before later progress.
    // Only the distinct 0.5 event means ready to cancel the late-exit child.
    static let progressBytes = Data(("{\"version\":1,\"kind\":\"progress\",\"fraction\":0}\n" +
        "{\"version\":1,\"kind\":\"progress\",\"fraction\":0.5}\n").utf8)

    static func requestLine() throws -> Data {
        try GIFHelperProtocol.encodeRequestLine(GIFHelperRequest())
    }

    static func arguments(marker: URL, release: URL, readback: URL) throws -> [String] {
        let line = try requestLine()
        return ["--noprofile", "--norc", "-c", script, "picshot-trim-gif-fixture",
                marker.path, release.path, readback.path, String(decoding: line.dropLast(), as: UTF8.self)]
    }

    static let script = #"""
    set -C
    SECONDS=0
    IFS= read -r -t 20 request || exit 2
    [[ "$request" == "$4" ]] || exit 2
    cd -P . || exit 3
    printf '%s\0%s\0' "$$" "$PWD" > "$1" || exit 3
    printf '%s\n' '{"version":1,"kind":"progress","fraction":0}' \
        '{"version":1,"kind":"progress","fraction":0.5}' || exit 3
    while [[ ! -e "$2" && "$SECONDS" -lt 20 ]]; do
        /bin/sleep 0.02 || exit 4
    done
    [[ -e "$2" ]] || exit 4
    exec /bin/cat source.mp4 > "$3"
    """#

    struct ChildMarker {
        let directory: String
        let pid: Int32

        init(data: Data) throws {
            let fields = data.split(separator: 0, omittingEmptySubsequences: false)
            guard data.count <= 8_192, fields.count == 3, fields[2].isEmpty,
                  let rawPID = String(data: Data(fields[0]), encoding: .utf8),
                  rawPID.utf8.allSatisfy({ (48...57).contains($0) }),
                  let pid = Int32(rawPID), pid > 0,
                  let directory = String(data: Data(fields[1]), encoding: .utf8), directory.hasPrefix("/")
            else { throw GIFProcessTestSupportError.failed("Incomplete or invalid trim GIF child readiness marker") }
            self.pid = pid; self.directory = directory
        }
    }
}
