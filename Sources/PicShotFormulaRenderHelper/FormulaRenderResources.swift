import Foundation
import Darwin
import PicShotFormulaRenderCore

enum FormulaRenderResources {
    static let bundleName = "PicShot_PicShotFormulaRenderHelper.bundle"

    static func directory() throws -> URL {
        // proc_pidpath comes from the kernel, not argv[0] or Bundle.main's guess about
        // the parent app. SwiftPM's absolute build fallback is development-only.
        try directory(executableURL: currentExecutableURL(), developmentDirectory: {
            guard let resources = Bundle.module.resourceURL else { throw FormulaRenderError.missingRuntime }
            return resources.appendingPathComponent("FormulaRenderResources", isDirectory: true)
        })
    }

    static func directory(executableURL: URL, developmentDirectory: () throws -> URL) throws -> URL {
        let executable = executableURL.standardizedFileURL
        let helpers = executable.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        let isPackaged = app.pathExtension == "app" || helpers.lastPathComponent == "Helpers"
        if isPackaged {
            guard executable.lastPathComponent == "PicShotFormulaRenderHelper",
                  helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents",
                  app.pathExtension == "app", executable.resolvingSymlinksInPath().path == executable.path,
                  FileManager.default.isExecutableFile(atPath: executable.path) else { throw FormulaRenderError.missingRuntime }
            let bundleURL = contents.appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(bundleName, isDirectory: true)
            try validateDirectory(bundleURL)
            guard let bundle = Bundle(url: bundleURL), let root = bundle.resourceURL else { throw FormulaRenderError.missingRuntime }
            let directory = root.appendingPathComponent("FormulaRenderResources", isDirectory: true).standardizedFileURL
            guard directory.path.hasPrefix(bundleURL.path + "/") else { throw FormulaRenderError.missingRuntime }
            try validateDirectory(directory)
            // Missing/damaged installed resources never fall through to Bundle.module.
            return directory
        }
        let directory = try developmentDirectory().standardizedFileURL
        try validateDirectory(directory)
        return directory
    }

    private static func currentExecutableURL() throws -> URL {
        // proc_pidpath accepts at most 4 * MAXPATHLEN (4096 bytes). The C macro
        // PROC_PIDPATHINFO_MAXSIZE is not imported by every supported Swift SDK.
        var bytes = [CChar](repeating: 0, count: 4096)
        let count = bytes.withUnsafeMutableBytes { buffer in
            proc_pidpath(getpid(), buffer.baseAddress, UInt32(buffer.count))
        }
        guard count > 0 else { throw FormulaRenderError.missingRuntime }
        return URL(fileURLWithPath: String(cString: bytes)).standardizedFileURL
    }

    private static func validateDirectory(_ url: URL) throws {
        guard url.isFileURL, url.resolvingSymlinksInPath().path == url.path else { throw FormulaRenderError.missingRuntime }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw FormulaRenderError.missingRuntime }
    }
}
