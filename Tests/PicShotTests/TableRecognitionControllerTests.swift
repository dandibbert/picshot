import XCTest
import AppKit
import PicShotCore
import PicShotFormulaCore
import PicShotTableEngine
@testable import PicShot

final class TableRecognitionControllerTests: XCTestCase {
    @MainActor
    func testOpeningVerifiesWithoutDownloadingOrRecognizing() async throws {
        let result = try fixture()
        var verifications = 0, downloads = 0, recognitions = 0, callbacks = 0
        var services = fakeServices(result: result)
        services.verifiedDirectory = { verifications += 1; return URL(fileURLWithPath: "/unused-model") }
        services.install = { _ in downloads += 1; throw TestFailure.unexpectedDownload }
        services.recognize = { _, _ in recognitions += 1; return result }
        let model = TableRecognitionModel(image: try image(), services: services) { _, _ in callbacks += 1 }
        XCTAssertEqual(verifications, 0)
        XCTAssertFalse(model.canRecognize)
        model.checkInstallation()
        try await waitUntil { !model.working }
        model.checkInstallation()
        XCTAssertEqual(verifications, 1)
        XCTAssertEqual(downloads, 0)
        XCTAssertEqual(recognitions, 0)
        XCTAssertEqual(callbacks, 0)
        XCTAssertTrue(model.canRecognize)
    }

    @MainActor
    func testMissingModelDoesNotDownloadOrInventATable() async throws {
        var services = fakeServices(result: try fixture())
        services.verifiedDirectory = { throw ModelValidationError.missing("SLANet-plus") }
        let model = TableRecognitionModel(image: try image(), services: services) { _, _ in
            XCTFail("A missing model must not create a table")
        }
        model.checkInstallation()
        try await waitUntil { !model.working }
        model.recognize()
        XCTAssertFalse(model.installed)
        XCTAssertFalse(model.working)
        XCTAssertTrue(model.status.contains("需先下载"))
        XCTAssertTrue(model.warnings.isEmpty)
    }

    @MainActor
    func testSuccessPreservesStructureWarningsAndEveryUnmatchedString() async throws {
        let result = try fixture()
        var verifications = 0
        var services = fakeServices(result: result)
        services.verifiedDirectory = { verifications += 1; return URL(fileURLWithPath: "/unused-model") }
        var tables: [StructuredTable] = [], review: [String] = []
        let model = TableRecognitionModel(image: try image(), services: services) { table, warnings in
            tables.append(table); review = warnings
        }
        model.checkInstallation()
        try await waitUntil { !model.working }
        model.recognize()
        try await waitUntil { !model.working }
        XCTAssertEqual(verifications, 2, "Recognition must reverify the model")
        XCTAssertEqual(tables, [result.table])
        XCTAssertTrue(model.warnings.contains(result.warnings[0]))
        XCTAssertTrue(model.warnings.contains(TableRecognitionModel.reviewNotice))
        XCTAssertEqual(model.unmatchedOCR, result.unmatchedOCR)
        XCTAssertTrue(review.contains(result.warnings[0]))
        XCTAssertTrue(review.contains(TableRecognitionModel.reviewNotice))
        XCTAssertTrue(review.contains { $0.contains(result.unmatchedOCR[0].text) })
        XCTAssertEqual(tables[0].cell(at: TableCoordinate(row: 0, column: 0))?.columnSpan, 3)
        XCTAssertEqual(tables[0].cell(at: TableCoordinate(row: 1, column: 0))?.value, .text("=SUM(A1:A2)"))
    }

    @MainActor
    func testRepeatedClicksAndCancellationKeepOneJobUntilItUnwinds() async throws {
        let result = try fixture()
        var continuation: CheckedContinuation<TableRecognitionResult, Error>?
        var recognitions = 0, callbacks = 0
        var services = fakeServices(result: result)
        services.recognize = { _, _ in
            recognitions += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        let model = TableRecognitionModel(image: try image(), services: services) { _, _ in callbacks += 1 }
        model.checkInstallation()
        try await waitUntil { !model.working }
        model.recognize()
        try await waitUntil { continuation != nil }
        model.recognize()
        model.cancel()
        model.recognize()
        XCTAssertEqual(recognitions, 1)
        XCTAssertTrue(model.working, "Do not release the job slot before cancellation unwinds")
        XCTAssertTrue(model.cancelling)
        XCTAssertFalse(model.canRecognize)
        // Simulate a late engine that finishes despite cancellation.
        continuation?.resume(returning: result)
        continuation = nil
        try await waitUntil { !model.working }
        XCTAssertEqual(callbacks, 0)
        XCTAssertTrue(model.warnings.isEmpty)
        XCTAssertTrue(model.unmatchedOCR.isEmpty)
        XCTAssertEqual(model.status, "已取消。")
        XCTAssertTrue(model.canRecognize)
    }

    @MainActor
    func testCloseRejectsLateSuccessAndPreventsNewJobs() async throws {
        let result = try fixture()
        var continuation: CheckedContinuation<TableRecognitionResult, Error>?
        var services = fakeServices(result: result)
        services.recognize = { _, _ in try await withCheckedThrowingContinuation { continuation = $0 } }
        let model = TableRecognitionModel(image: try image(), services: services) { _, _ in
            XCTFail("Closing the window must suppress the editor callback")
        }
        model.checkInstallation()
        try await waitUntil { !model.working }
        model.recognize()
        try await waitUntil { continuation != nil }
        model.close()
        continuation?.resume(returning: result)
        try await waitUntil { !model.working }
        model.recognize()
        model.checkInstallationAgain()
        model.installConfirmedModel()
        XCTAssertFalse(model.canRecognize)
        XCTAssertFalse(model.working)
        XCTAssertTrue(model.warnings.isEmpty)
    }

    @MainActor
    func testInferenceFailureIsShownWithoutFallbackGrid() async throws {
        var services = fakeServices(result: try fixture())
        services.recognize = { _, _ in throw TableRecognitionError.incompleteSequence }
        let model = TableRecognitionModel(image: try image(), services: services) { _, _ in
            XCTFail("Inference failure must not produce a fallback grid")
        }
        model.checkInstallation()
        try await waitUntil { !model.working }
        model.recognize()
        try await waitUntil { !model.working }
        XCTAssertEqual(model.status, TableRecognitionError.incompleteSequence.localizedDescription)
        XCTAssertTrue(model.installed)
        XCTAssertTrue(model.canRecognize)
    }

    @MainActor
    func testChangedModelDisablesRecognitionBeforeStartingHelper() async throws {
        var verifications = 0, recognitions = 0
        let result = try fixture()
        var services = fakeServices(result: result)
        services.verifiedDirectory = {
            verifications += 1
            if verifications > 1 { throw ModelValidationError.invalid("slanet-plus.onnx") }
            return URL(fileURLWithPath: "/unused-model")
        }
        services.recognize = { _, _ in recognitions += 1; return result }
        let model = TableRecognitionModel(image: try image(), services: services) { _, _ in
            XCTFail("Invalid model must not return a table")
        }
        model.checkInstallation()
        try await waitUntil { !model.working }
        model.recognize()
        try await waitUntil { !model.working }
        XCTAssertEqual(recognitions, 0)
        XCTAssertFalse(model.installed)
        XCTAssertFalse(model.canRecognize)
        XCTAssertTrue(model.status.contains("模型校验失败"))
    }

    @MainActor
    func testConfirmedDownloadDoesNotAutomaticallyRecognize() async throws {
        var downloads = 0, recognitions = 0
        let result = try fixture()
        var services = fakeServices(result: result)
        services.install = { progress in
            downloads += 1
            progress(5, 10)
            return URL(fileURLWithPath: "/unused-model")
        }
        services.recognize = { _, _ in recognitions += 1; return result }
        let model = TableRecognitionModel(image: try image(), services: services) { _, _ in
            XCTFail("Download completion must not begin recognition")
        }
        model.installConfirmedModel()
        try await waitUntil { !model.working }
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(recognitions, 0)
        XCTAssertTrue(model.installed)
        XCTAssertTrue(model.canRecognize)
        XCTAssertNil(model.progress)
    }

    @MainActor
    func testNoWarningResultStillRequiresManualReview() async throws {
        var result = try fixture()
        result.warnings = []; result.unmatchedOCR = []
        var review: [String] = []
        let model = TableRecognitionModel(image: try image(), services: fakeServices(result: result)) { _, warnings in
            review = warnings
        }
        model.checkInstallation()
        try await waitUntil { !model.working }
        model.recognize()
        try await waitUntil { !model.working }
        XCTAssertEqual(review, [TableRecognitionModel.reviewNotice])
        XCTAssertEqual(model.warnings, review)
    }

    @MainActor
    func testImmediateCloseDoesNotStartAnAlreadyCancelledDownload() async throws {
        let model = TableRecognitionModel(image: try image(), services: fakeServices(result: try fixture())) { _, _ in
            XCTFail("Closing must not invoke the editor callback")
        }
        model.installConfirmedModel()
        model.close()
        try await waitUntil { !model.working }
        XCTAssertFalse(model.installed)
        XCTAssertFalse(model.canRecognize)
        XCTAssertNil(model.progress)
    }

    @MainActor
    private func fakeServices(result: TableRecognitionResult) -> TableRecognitionServices {
        TableRecognitionServices(
            verifiedDirectory: { URL(fileURLWithPath: "/unused-model") },
            install: { _ in XCTFail("Unexpected model download"); throw TestFailure.unexpectedDownload },
            recognize: { _, _ in result })
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out waiting for recognition state"); throw TestFailure.timeout }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8,
            bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    private func fixture() throws -> TableRecognitionResult {
        struct Payload: Encodable {
            let table: StructuredTable
            let structureConfidence: Double
            let cells: [RecognizedTableCell]
            let unmatchedOCR: [TableOCRObservation]
            let warnings: [String]
        }
        let table = try StructuredTable(rowCount: 2, columnCount: 3, cells: [
            TableCell(row: 0, column: 0, columnSpan: 3, value: .text("Merged header")),
            TableCell(row: 1, column: 0, value: .text("=SUM(A1:A2)"))
        ])
        let payload = Payload(table: table, structureConfidence: 0.92, cells: [], unmatchedOCR: [
            TableOCRObservation(text: "Entire unmatched text\n第二行 = 42", confidence: 0.4,
                                box: TableOCRBox(x: 1, y: 2, width: 3, height: 4))
        ], warnings: ["请核对模糊文字。"])
        return try JSONDecoder().decode(TableRecognitionResult.self, from: JSONEncoder().encode(payload))
    }

    private enum TestFailure: Error { case unexpectedDownload, timeout }
}
