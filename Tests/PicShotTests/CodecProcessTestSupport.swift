import Foundation
import Darwin
@testable import PicShot

/// Real ad-hoc signed app with the actual app and native codec helper binaries.
/// A missing executable is a test failure, never a skipped integration test.
struct CodecProcessTestApplication: Sendable {
    let bundleURL: URL
    let root: URL

    static func make() throws -> CodecProcessTestApplication {
        let files = FileManager.default
        let executable = try builtExecutable(named: "PicShot")
        let helper = try builtExecutable(named: "PicShotCodecHelper")
        // macOS's /var and /tmp aliases must not make an otherwise genuine
        // fixture fail the production verifier's no-symlink path requirement.
        let root = files.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PicShot-Codec-Process-Test-" + UUID().uuidString, isDirectory: true)
        let bundle = root.appendingPathComponent("PicShot.app", isDirectory: true)
        let binaries = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try files.createDirectory(at: binaries, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        do {
            try files.copyItem(at: executable, to: binaries.appendingPathComponent("PicShot"))
            let helpers = bundle.appendingPathComponent("Contents/Helpers", isDirectory: true)
            try files.createDirectory(at: helpers, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let helperTarget = helpers.appendingPathComponent("PicShotCodecHelper")
            try files.copyItem(at: helper, to: helperTarget)
            try codesign(["--force", "--sign", "-", "--identifier", "local.picshot.codec", helperTarget.path])
            let info: [String: Any] = [
                "CFBundleExecutable": "PicShot", "CFBundleIdentifier": "local.picshot.app",
                "CFBundleName": "PicShot", "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "14.0"
            ]
            let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"), options: .atomic)
            try codesign(["--force", "--sign", "-", "--identifier", "local.picshot.app", bundle.path])
            try codesign(["--verify", "--strict", bundle.path])
            _ = try CodecHelperExecutable.verified(bundleURL: bundle)
            return CodecProcessTestApplication(bundleURL: bundle, root: root)
        } catch {
            try? files.removeItem(at: root)
            throw error
        }
    }

    func service() -> CodecExportProcessService {
        let bundle = bundleURL
        return CodecExportProcessService(configuration: .init(
            executable: { try CodecHelperExecutable.verified(bundleURL: bundle) }, wallSeconds: 30))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    private static func builtExecutable(named name: String) throws -> URL {
        let files = FileManager.default
        var directory = Bundle(for: CodecProcessTestBundleAnchor.self).bundleURL.resolvingSymlinksInPath()
        // SwiftPM's XCTest bundle lives beside the built executable, possibly
        // beneath Contents/MacOS depending on the test runner's bundle layout.
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent(name)
            if directory.pathComponents.contains(".build"), files.isExecutableFile(atPath: candidate.path) {
                let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isRegularFile == true, values.isSymbolicLink != true { return candidate }
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        throw CodecProcessTestSupportError.failed(
            "Built \(name) executable was not found beside the SwiftPM test bundle; build PicShot and PicShotCodecHelper before these tests")
    }

    /// Arguments go straight to Apple's codesign executable, never to a shell.
    /// Neither a wedged signing process nor a full stderr pipe can hang XCTest.
    private static func codesign(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = ProcessInfo.processInfo.systemUptime + 3
            while process.isRunning, ProcessInfo.processInfo.systemUptime < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
            if !process.isRunning { process.waitUntilExit() }
            throw CodecProcessTestSupportError.failed("Fixture codesign exceeded its 20-second deadline")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CodecProcessTestSupportError.failed("Fixture codesign failed with status \(process.terminationStatus)")
        }
    }
}

private final class CodecProcessTestBundleAnchor: NSObject { }

enum CodecProcessTestSupportError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): return message } }
}

