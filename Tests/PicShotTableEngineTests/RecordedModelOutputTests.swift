import XCTest
import Foundation
import PicShotCore
@testable import PicShotTableEngine

/// These fixtures contain genuine output tensors from the pinned model, not handcrafted token IDs.
/// The test runs Swift postprocessing over them without downloading weights or needing Python.
final class RecordedModelOutputTests: XCTestCase {
    private struct Fixture: Decodable {
        var modelSHA256: String
        var runtime: String
        var imageWidth: Int
        var imageHeight: Int
        var boxShape: [Int64]
        var probabilityShape: [Int64]
        var boundingBoxes: [Float]
        var structureProbabilities: [Float]
    }
    private func decode(_ name: String) throws -> TableRecognitionResult {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.modelSHA256, SLANetPlus.modelSHA256)
        return try SLANetPlus.decode(boundingBoxes: fixture.boundingBoxes, boxShape: fixture.boxShape,
                                    structureProbabilities: fixture.structureProbabilities, probabilityShape: fixture.probabilityShape,
                                    imageWidth: fixture.imageWidth, imageHeight: fixture.imageHeight, ocr: [])
    }
    func testActualModelThreeByThreeTable() throws {
        let result = try decode("table-output")
        XCTAssertEqual(result.table.rowCount, 3); XCTAssertEqual(result.table.columnCount, 3)
        XCTAssertEqual(result.table.cells.count, 9)
        XCTAssertGreaterThan(result.structureConfidence, 0.99)
    }
    func testActualModelMergedHeader() throws {
        let result = try decode("merged-table-output")
        XCTAssertEqual(result.table.rowCount, 4); XCTAssertEqual(result.table.columnCount, 3)
        XCTAssertEqual(result.table.cells.count, 10)
        XCTAssertEqual(result.table.cells[0].columnSpan, 3)
        XCTAssertGreaterThan(result.structureConfidence, 0.99)
    }

    func testKnownWrongRowspanPredictionFailsGeometryValidation() throws {
        // Ground truth is three rows with rowspan=2. This model predicts four rows and
        // rowspan=3 at high confidence, and a final cell extends beyond the source crop.
        // It is a known model accuracy failure; geometry validation must reject it.
        XCTAssertThrowsError(try decode("known-failure-rowspan-output")) { error in
            XCTAssertEqual(error as? TableRecognitionError, .invalidCellGeometry)
        }
    }

    /// Opt-in end-to-end macOS check: native preprocessing + native ORT + Apple Vision + Swift decoder.
    /// Set both paths in the model-validation CI job; ordinary unit tests remain entirely offline.
    func testNativeHelperWithRealWeightsWhenConfigured() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let executable = environment["PICSHOT_TEST_ML_HELPER"], let modelDirectory = environment["PICSHOT_TEST_TABLE_MODEL_DIR"] else {
            throw XCTSkip("Native real-weight validation requires PICSHOT_TEST_ML_HELPER and PICSHOT_TEST_TABLE_MODEL_DIR")
        }
        let source = try XCTUnwrap(Bundle.module.url(forResource: "merged-table", withExtension: "png"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicShotTableTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("result.json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--mode", "table", "--model-dir", modelDirectory, "--input", source.path, "--output", output.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(90)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        guard !process.isRunning else { process.terminate(); throw TableRecognitionError.invalidTensor("native helper timed out") }
        XCTAssertEqual(process.terminationStatus, 0)
        let result = try JSONDecoder().decode(TableRecognitionResult.self, from: Data(contentsOf: output))
        XCTAssertEqual(result.table.rowCount, 4); XCTAssertEqual(result.table.columnCount, 3)
        XCTAssertEqual(result.table.cells.first?.columnSpan, 3)
        let text = result.table.cells.map { $0.value.displayText }.joined(separator: " ")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Fruit"))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Apples"))
        XCTAssertTrue(text.contains("12"))
        XCTAssertGreaterThan(result.structureConfidence, 0.9)
    }
}
