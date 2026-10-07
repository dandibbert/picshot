import XCTest
import Foundation
import AppKit
import PicShotFormulaRenderCore
@testable import PicShot

/// Real create-only filesystem publication, cancellation and ownership checks.
/// Short SVG/MathML/PDF byte fixtures validate transport only, not render correctness.
final class LaTeXPinExportTests: XCTestCase {
    func testAllActualExtensionsPublishExactBytesAndRefuseExistingDestinations() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        for (format, data) in try payloads() {
            let target = directory.appendingPathComponent("formula." + format.fileExtension)
            try LaTeXPinExport.publish(data, format: format, to: target)
            XCTAssertEqual(try Data(contentsOf: target), data)
            XCTAssertThrowsError(try LaTeXPinExport.publish(data, format: format, to: target))
            XCTAssertEqual(try Data(contentsOf: target), data)
        }
        XCTAssertEqual(try contents(directory).count, FormulaRenderFormat.allCases.count)
        XCTAssertFalse(try contents(directory).contains { $0.hasPrefix(".picshot-save-") })
    }
    func testCollisionArrivingAtCommitPreservesSentinelAndCleansPrivateStage() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("formula.svg"), sentinel = Data("existing file".utf8)
        XCTAssertThrowsError(try LaTeXPinExport.publish(Data("<svg />".utf8), format: .svg, to: target, beforeCommit: {
            try sentinel.write(to: target)
        }))
        XCTAssertEqual(try Data(contentsOf: target), sentinel)
        XCTAssertEqual(try contents(directory), ["formula.svg"])
    }
    func testCancellationBeforeAndDuringCommitLeavesNoPublishedFileOrOwnedStage() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("formula.tex"), bytes = Data("x^2".utf8)
        let before = ImageExportCancellation(); before.cancel()
        XCTAssertThrowsError(try LaTeXPinExport.publish(bytes, format: .latex, to: target, cancellation: before))
        XCTAssertTrue(try contents(directory).isEmpty)
        let during = ImageExportCancellation()
        XCTAssertThrowsError(try LaTeXPinExport.publish(bytes, format: .latex, to: target, cancellation: during, beforeCommit: { during.cancel() }))
        XCTAssertTrue(try contents(directory).isEmpty)
    }
    func testDestinationSymlinkAndHardlinkCannotOverwriteTheSource() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.tex"), bytes = Data("unchanged source".utf8)
        try bytes.write(to: source)
        let symbolic = directory.appendingPathComponent("symbolic.tex"), hard = directory.appendingPathComponent("hard.tex")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: source)
        try FileManager.default.linkItem(at: source, to: hard)
        for target in [source, symbolic, hard] {
            XCTAssertThrowsError(try LaTeXPinExport.publish(Data("replacement".utf8), format: .latex, to: target))
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(Set(try contents(directory)), Set(["source.tex", "symbolic.tex", "hard.tex"]))
    }
    func testMovedApprovedDirectoryIsRejectedAndOnlyItsOwnedStageIsCleaned() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let selected = directory.appendingPathComponent("selected", isDirectory: true)
        let moved = directory.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        let target = selected.appendingPathComponent("formula.tex")
        XCTAssertThrowsError(try LaTeXPinExport.publish(Data("x".utf8), format: .latex, to: target, beforeCommit: {
            try FileManager.default.moveItem(at: selected, to: moved)
            try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
            try Data("sentinel".utf8).write(to: selected.appendingPathComponent("sentinel"))
        }))
        XCTAssertTrue(try contents(moved).isEmpty)
        XCTAssertEqual(try contents(selected), ["sentinel"])
        XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent("sentinel")), Data("sentinel".utf8))
    }
    func testApprovalToQueueSymlinkSubstitutionCannotRedirectPublication() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let selected = directory.appendingPathComponent("selected", isDirectory: true)
        let moved = directory.appendingPathComponent("moved", isDirectory: true)
        let unrelated = directory.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        let destination = try RawPinArtifactDestination(selected.appendingPathComponent("formula.tex"))
        try FileManager.default.moveItem(at: selected, to: moved)
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: unrelated)
        XCTAssertThrowsError(try LaTeXPinExport.publish(Data("x".utf8), format: .latex, to: destination))
        XCTAssertTrue(try contents(moved).isEmpty); XCTAssertTrue(try contents(unrelated).isEmpty)
    }
    func testFileURLQueryAndFragmentAreRejectedBeforeDestinationBinding() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("formula.tex")
        for suffix in ["?unexpected=value", "#fragment"] {
            let url = try XCTUnwrap(URL(string: target.absoluteString + suffix))
            XCTAssertThrowsError(try RawPinArtifactDestination(url))
        }
        XCTAssertTrue(try contents(directory).isEmpty)
    }
    func testInvalidExtensionAndOversizedOrMislabeledDataCreateNothing() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try LaTeXPinExport.publish(Data("<svg />".utf8), format: .svg, to: directory.appendingPathComponent("wrong.png")))
        XCTAssertThrowsError(try LaTeXPinExport.publish(Data("not PNG".utf8), format: .png, to: directory.appendingPathComponent("wrong.png")))
        XCTAssertThrowsError(try LaTeXPinExport.publish(Data(repeating: 120, count: FormulaRenderLimits.latexBytes + 1), format: .latex, to: directory.appendingPathComponent("large.tex")))
        XCTAssertThrowsError(try LaTeXPinExport.publish(Data("x\0".utf8), format: .latex, to: directory.appendingPathComponent("nul.tex")))
        XCTAssertTrue(try contents(directory).isEmpty)
    }
    func testFormulaSaveAdmissionRetainsOnlyTwoSlotsUntilActualDrainAndReleaseIsIdempotent() throws {
        XCTAssertEqual(LaTeXPinSaveLease.activeJobs, 0)
        let first = try XCTUnwrap(LaTeXPinSaveLease.acquire()), second = try XCTUnwrap(LaTeXPinSaveLease.acquire())
        defer { first.release(); second.release() }
        XCTAssertNil(LaTeXPinSaveLease.acquire()); XCTAssertEqual(LaTeXPinSaveLease.activeJobs, 2)
        first.release(); first.release(); XCTAssertEqual(LaTeXPinSaveLease.activeJobs, 1)
        let replacement = try XCTUnwrap(LaTeXPinSaveLease.acquire())
        replacement.release(); second.release(); XCTAssertEqual(LaTeXPinSaveLease.activeJobs, 0)
    }
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-FormulaExport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func contents(_ directory: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() }
    private func payloads() throws -> [(FormulaRenderFormat, Data)] {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        return [(.latex, Data("x^2".utf8)), (.mathML, Data("<math ><mi>x</mi></math>".utf8)),
            (.svg, Data("<svg />".utf8)), (.png, try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))),
            (.pdf, Data("%PDF-publication-fixture".utf8))]
    }
}
