import XCTest
import Foundation
@testable import PicShotFormulaRenderHelper
import PicShotFormulaRenderCore

final class FormulaRenderResourceLookupTests: XCTestCase {
    func testPackagedLookupWorksWhenDevelopmentFallbackIsUnavailable() throws {
        let fixture = try makeAppFixture(copyRuntime: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var fallbackCalled = false
        let directory = try FormulaRenderResources.directory(executableURL: fixture.helper, developmentDirectory: {
            fallbackCalled = true; throw FormulaRenderError.missingRuntime
        })
        XCTAssertFalse(fallbackCalled)
        XCTAssertEqual(directory.path, fixture.runtime.path)
        let request = FormulaRenderRequest(latex: #"\frac{1}{x^2-1}"#)
        let rendered = try FormulaRenderEngine.render(request, runtimeDirectory: directory)
        try rendered.validate(for: request)
        XCTAssertTrue(rendered.mathML.contains("<mfrac>"))
    }

    func testMissingPackagedBundleCannotUseExistingBuildFallback() throws {
        let fixture = try makeAppFixture(copyRuntime: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var fallbackCalled = false
        XCTAssertThrowsError(try FormulaRenderResources.directory(executableURL: fixture.helper, developmentDirectory: {
            fallbackCalled = true; return fixture.root
        }))
        XCTAssertFalse(fallbackCalled)
    }

    func testSymlinkedBundleIsRejectedWithoutDevelopmentFallback() throws {
        let fixture = try makeAppFixture(copyRuntime: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let external = fixture.root.appendingPathComponent("external.bundle")
        try FileManager.default.moveItem(at: fixture.bundle, to: external)
        try FileManager.default.createSymbolicLink(at: fixture.bundle, withDestinationURL: external)
        XCTAssertThrowsError(try FormulaRenderResources.directory(executableURL: fixture.helper, developmentDirectory: {
            XCTFail("Packaged lookup must not use the build fallback"); return external
        }))
    }

    func testHelperInWrongAppDirectoryFailsInsteadOfUsingBuildResources() throws {
        let fixture = try makeAppFixture(copyRuntime: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let wrong = fixture.helper.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacOS/PicShotFormulaRenderHelper")
        XCTAssertThrowsError(try FormulaRenderResources.directory(executableURL: wrong, developmentDirectory: {
            XCTFail("Malformed app layout must not use the build fallback"); return fixture.root
        }))
    }

    private struct Fixture { let root: URL, helper: URL, bundle: URL, runtime: URL }
    private func makeAppFixture(copyRuntime: Bool) throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FormulaRenderLookup-\(UUID().uuidString)")
        let contents = root.appendingPathComponent("Relocated.app/Contents")
        let helpers = contents.appendingPathComponent("Helpers")
        try fm.createDirectory(at: helpers, withIntermediateDirectories: true)
        let helper = helpers.appendingPathComponent("PicShotFormulaRenderHelper")
        XCTAssertTrue(fm.createFile(atPath: helper.path, contents: Data("fixture".utf8), attributes: [.posixPermissions: 0o700]))
        let bundle = contents.appendingPathComponent("Resources/\(FormulaRenderResources.bundleName)")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        let runtime = resources.appendingPathComponent("FormulaRenderResources")
        if copyRuntime {
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": "local.picshot.formula.fixture.\(UUID().uuidString)",
                                       "CFBundleName": "FormulaRenderFixture", "CFBundlePackageType": "BNDL"]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            try fm.copyItem(at: FormulaRenderResources.directory(), to: runtime)
        }
        return Fixture(root: root, helper: helper, bundle: bundle, runtime: runtime)
    }
}
