import Foundation

/// A single, explicitly synthetic child for the cross-format admission test.
/// read/printf are shell builtins; exec replaces that same PID with sleep.
/// Request bytes are data only: they are never expanded into shell source.
enum CodecGIFLeaseFixture {
    static let executableURL = URL(fileURLWithPath: "/bin/sh")
    static let arguments = ["-c", script]
    static let progressBytes = Data("{\"version\":1,\"kind\":\"progress\",\"fraction\":0}\n".utf8)
    static let script = #"""
    IFS= read -r request || exit 2
    printf '%s\n' '{"version":1,"kind":"progress","fraction":0}'
    exec /bin/sleep 20
    """#
}
