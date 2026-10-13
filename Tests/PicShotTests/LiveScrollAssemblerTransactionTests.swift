import XCTest
import AppKit
import PicShotCore
@testable import PicShot

@MainActor
final class LiveScrollAssemblerTransactionTests: XCTestCase {
    private func root() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-LiveTransaction-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
        return result
    }

    /// Nonrepeating texture in absolute document coordinates. This independently
    /// constructs either a viewport or the expected whole union, with no strip code.
    private func image(_ axis: ScrollAxis, origin: Int, length: Int = 200, cross: Int = 64,
                       salt: UInt64 = 7, luminanceDelta: Int = 0) throws -> CGImage {
        let width = axis == .vertical ? cross : length, height = axis == .vertical ? length : cross
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let along = (axis == .vertical ? y : x) + origin + 10_000
            let across = axis == .vertical ? x : y
            var value = UInt64(along) &* 0x9e3779b185ebca87
            value ^= UInt64(across) &* 0xc2b2ae3d27d4eb4f
            value ^= salt
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            value ^= value >> 31
            let pixel = UInt8(Int(value % 216 + 20) + luminanceDelta), index = (y * width + x) * 4
            data[index] = pixel; data[index + 1] = pixel; data[index + 2] = pixel
        } }
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy); context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }

    private func assertOutput(_ output: CGImage, axis: ScrollAxis, origin: Int, length: Int,
                              cross: Int = 64, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try image(axis, origin: origin, length: length, cross: cross)
        XCTAssertEqual(output.width, expected.width, file: file, line: line)
        XCTAssertEqual(output.height, expected.height, file: file, line: line)
        XCTAssertEqual(try pixels(output), try pixels(expected), file: file, line: line)
    }

    private func failPreview(_ assembler: LiveScrollAssembler, axis: ScrollAxis, offset: Int) async throws -> LiveScrollAssembler.Update {
        let sign = offset < 0 ? -1 : 1
        var offsets = [0]
        if offset != 0 { offsets.append(sign * 24) }
        if abs(offset) > 24 { offsets.append(offset) }
        for prior in offsets.dropLast() { _ = try await assembler.observe(image(axis, origin: prior)) }
        await assembler.failNextPreviewForTesting()
        return try await assembler.observe(image(axis, origin: offset))
    }

    private func assertAcceptedStateUnchanged(_ actual: LiveScrollAssembler.State, _ expected: LiveScrollAssembler.State,
                                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.width, expected.width, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, file: file, line: line)
        XCTAssertEqual(actual.viewportOffset, expected.viewportOffset, file: file, line: line)
        XCTAssertEqual(actual.acceptedObservations, expected.acceptedObservations, file: file, line: line)
        XCTAssertEqual(actual.committedSources, expected.committedSources, file: file, line: line)
        XCTAssertEqual(actual.diskBytes, expected.diskBytes, file: file, line: line)
        XCTAssertEqual(actual.fixedLeading, expected.fixedLeading, file: file, line: line)
        XCTAssertEqual(actual.fixedTrailing, expected.fixedTrailing, file: file, line: line)
        XCTAssertEqual(actual.previewIsTransient, expected.previewIsTransient, file: file, line: line)
    }

    private func spoolFiles(_ parent: URL) throws -> [String: Data] {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: parent, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in files {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(url.path.dropFirst(parent.path.count))] = try Data(contentsOf: url)
            }
        }
        return result
    }

    func testStationaryPreviewRecoveryPreservesAcceptedStateAndSpoolBothDirectionsAndAxes() async throws {
        // 0: initial image; 24: bootstrap commit; 43: pending frontier; 120: committed extension.
        for axis in ScrollAxis.allCases { for sign in [-1, 1] { for extent in [0, 24, 43, 120] {
            let parent = try root()
            defer { try? FileManager.default.removeItem(at: parent) }
            let assembler = LiveScrollAssembler(axis: axis, generation: 49, storageParent: parent)
            let offset = sign * extent
            let failed = try await failPreview(assembler, axis: axis, offset: offset)
            XCTAssertNil(failed.preview); XCTAssertTrue(failed.state.previewUnavailable)
            XCTAssertEqual(failed.state.previewIsTransient, extent == 43)
            let before = await assembler.documentSnapshotForResourceVerification()
            let filesBefore = try spoolFiles(parent)
            XCTAssertEqual(before?.sourceReadCount ?? 0, 0)

            // Negative cases differ by one luminance level, so zero displacement is
            // verified through matching instead of the exact-pixel fast path.
            let candidate = try image(axis, origin: offset, luminanceDelta: sign < 0 ? 1 : 0)
            let anchorGray = try ScrollImageIO.luminance(image(axis, origin: offset))
            let candidateGray = try ScrollImageIO.luminance(candidate)
            XCTAssertEqual(anchorGray.pixels == candidateGray.pixels, sign > 0)
            XCTAssertEqual(try LiveScrollMatcher.match(previous: anchorGray, next: candidateGray, axis: axis).displacement, 0)
            let recovered = try await assembler.observe(candidate)
            XCTAssertTrue(recovered.state.matched); XCTAssertFalse(recovered.state.previewUnavailable)
            assertAcceptedStateUnchanged(recovered.state, failed.state)
            let preview = try XCTUnwrap(recovered.preview)
            try assertOutput(preview, axis: axis, origin: min(0, offset), length: 200 + extent)
            let start = CGFloat(offset - min(0, offset)) / CGFloat(200 + extent)
            let length = CGFloat(200) / CGFloat(200 + extent)
            XCTAssertEqual(recovered.viewport, axis == .vertical
                ? CGRect(x: 0, y: start, width: 1, height: length)
                : CGRect(x: start, y: 0, width: length, height: 1))
            let after = await assembler.documentSnapshotForResourceVerification()
            XCTAssertEqual(after, before, "Recovery must not flush, decode strips or mutate durable metadata")
            XCTAssertEqual(try spoolFiles(parent), filesBefore, "Recovery must leave every spool byte unchanged")
            for _ in 0..<3 {
                let repeated = try await assembler.observe(candidate)
                XCTAssertNil(repeated.preview, "Healthy stationary frames must not rebuild the preview")
                XCTAssertFalse(repeated.state.previewUnavailable)
                assertAcceptedStateUnchanged(repeated.state, failed.state)
            }
            let output = try await assembler.finish()
            try assertOutput(output, axis: axis, origin: min(0, offset), length: 200 + extent)
            let finished = await assembler.currentState()
            XCTAssertEqual(finished.committedSources, failed.state.committedSources + (extent == 43 ? 1 : 0))
            await assembler.close()
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
        } } }
    }

    func testMismatchCannotSpendRecoveryAndFailedStationaryRetryIsBoundedBothAxes() async throws {
        for axis in ScrollAxis.allCases { for offset in [0, 43, 120] {
            let parent = try root()
            defer { try? FileManager.default.removeItem(at: parent) }
            let assembler = LiveScrollAssembler(axis: axis, generation: 50, storageParent: parent)
            let failed = try await failPreview(assembler, axis: axis, offset: offset)
            let before = await assembler.documentSnapshotForResourceVerification()
            let filesBefore = try spoolFiles(parent)
            await assembler.failNextPreviewForTesting()
            let rejected = try await assembler.observe(image(axis, origin: offset, salt: 101))
            XCTAssertFalse(rejected.state.matched); XCTAssertTrue(rejected.state.previewUnavailable)
            XCTAssertNil(rejected.preview)
            assertAcceptedStateUnchanged(rejected.state, failed.state)
            let retry = try await assembler.observe(image(axis, origin: offset))
            XCTAssertTrue(retry.state.matched); XCTAssertTrue(retry.state.previewUnavailable)
            XCTAssertNil(retry.preview, "Mismatch must leave the one-shot failure hook for the verified retry")
            XCTAssertEqual(retry.state.message, failed.state.message)
            for _ in 0..<5 {
                let stationary = try await assembler.observe(image(axis, origin: offset))
                XCTAssertNil(stationary.preview, "A failed retry must not start an unbounded stationary loop")
                XCTAssertTrue(stationary.state.previewUnavailable)
                XCTAssertEqual(stationary.state.message, failed.state.message)
                assertAcceptedStateUnchanged(stationary.state, failed.state)
            }
            let after = await assembler.documentSnapshotForResourceVerification()
            XCTAssertEqual(after, before); XCTAssertEqual(try spoolFiles(parent), filesBefore)
            // The matcher and pending frontier remain usable after exhausting the
            // display-only retry. New accepted motion gets its ordinary preview.
            let moved = try await assembler.observe(image(axis, origin: offset + 12))
            XCTAssertTrue(moved.state.matched); XCTAssertFalse(moved.state.previewUnavailable)
            XCTAssertNotNil(moved.preview)
            XCTAssertEqual(moved.state.acceptedObservations, failed.state.acceptedObservations + 1)
            let output = try await assembler.finish()
            try assertOutput(output, axis: axis, origin: 0, length: 212 + offset)
            await assembler.close()
        } }
    }

    func testStationaryPreviewRecoveryPropagatesCancellationAndCloseCannotResurrectBothAxes() async throws {
        for axis in ScrollAxis.allCases { for offset in [0, 43, 120] {
            let parent = try root()
            defer { try? FileManager.default.removeItem(at: parent) }
            let assembler = LiveScrollAssembler(axis: axis, generation: 51, storageParent: parent)
            let failed = try await failPreview(assembler, axis: axis, offset: offset)
            let before = await assembler.documentSnapshotForResourceVerification()
            let filesBefore = try spoolFiles(parent)
            await assembler.failNextPreviewForTesting(.cancelled)
            do { _ = try await assembler.observe(image(axis, origin: offset)); XCTFail("Expected stationary preview cancellation") }
            catch is CancellationError { }
            catch { XCTFail("Unexpected \(error)") }
            let cancelled = await assembler.currentState()
            assertAcceptedStateUnchanged(cancelled, failed.state)
            XCTAssertTrue(cancelled.previewUnavailable)
            let after = await assembler.documentSnapshotForResourceVerification()
            XCTAssertEqual(after, before); XCTAssertEqual(try spoolFiles(parent), filesBefore)
            let stationary = try await assembler.observe(image(axis, origin: offset))
            XCTAssertNil(stationary.preview); XCTAssertTrue(stationary.state.previewUnavailable)
            let output = try await assembler.finish()
            try assertOutput(output, axis: axis, origin: 0, length: 200 + offset)
            await assembler.close(); await assembler.close()
            do { _ = try await assembler.observe(image(axis, origin: offset)); XCTFail("Closed recovery must not resurrect output") }
            catch is CancellationError { }
            catch { XCTFail("Unexpected \(error)") }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
        } }
    }

    func testReversalBefore96PixelCommitPreservesEveryVisitedPixelInBothDirectionsAndAxes() async throws {
        for axis in ScrollAxis.allCases { for sign in [-1, 1] {
            let parent = try root()
            defer { try? FileManager.default.removeItem(at: parent) }
            let assembler = LiveScrollAssembler(axis: axis, generation: 41, storageParent: parent)
            _ = try await assembler.observe(image(axis, origin: 0))
            let established = try await assembler.observe(image(axis, origin: sign * 24))
            XCTAssertTrue(established.state.matched); XCTAssertEqual(established.state.committedSources, 2)
            let pending = try await assembler.observe(image(axis, origin: sign * 43))
            XCTAssertTrue(pending.state.matched); XCTAssertEqual(pending.state.committedSources, 2)
            let reversed = try await assembler.observe(image(axis, origin: sign * 31))
            XCTAssertTrue(reversed.state.matched)
            XCTAssertEqual(reversed.state.viewportOffset, sign * 31)
            XCTAssertEqual(reversed.state.committedSources, 3, "Flush the pending 19-pixel extreme exactly once before retreat")
            let output = try await assembler.finish()
            try assertOutput(output, axis: axis, origin: min(0, sign * 43), length: 243)
            let finished = await assembler.currentState()
            XCTAssertEqual(finished.committedSources, 3, "Finish of an interior viewport must not create another source")
            await assembler.close()
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
        } }
    }

    func testPendingPreviewFailureStillFlushesTheNewestVerifiedPixelsOnFinishBothAxes() async throws {
        for axis in ScrollAxis.allCases {
            let parent = try root()
            defer { try? FileManager.default.removeItem(at: parent) }
            let assembler = LiveScrollAssembler(axis: axis, generation: 42, storageParent: parent)
            _ = try await assembler.observe(image(axis, origin: 0))
            _ = try await assembler.observe(image(axis, origin: 24))
            await assembler.failNextPreviewForTesting()
            let failedPreview = try await assembler.observe(image(axis, origin: 43))
            XCTAssertNil(failedPreview.preview)
            XCTAssertTrue(failedPreview.state.previewUnavailable)
            XCTAssertTrue(failedPreview.state.matched)
            XCTAssertEqual(failedPreview.state.viewportOffset, 43)
            XCTAssertEqual(failedPreview.state.acceptedObservations, 3)
            XCTAssertEqual(failedPreview.state.committedSources, 2)
            XCTAssertEqual(failedPreview.state.width, axis == .vertical ? 64 : 243)
            XCTAssertEqual(failedPreview.state.height, axis == .vertical ? 243 : 64)
            XCTAssertTrue(failedPreview.state.previewIsTransient, "Logical pending extent survives a display-only failure")
            let output = try await assembler.finish()
            try assertOutput(output, axis: axis, origin: 0, length: 243)
            let finished = await assembler.currentState()
            XCTAssertEqual(finished.committedSources, 3)
            XCTAssertFalse(finished.previewIsTransient)
            await assembler.close()
        }
    }

    func testCommittedPreviewFailureKeepsMatchingAnchorAndFinishRetryDoesNotDuplicatePixels() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let assembler = LiveScrollAssembler(axis: .vertical, generation: 43, storageParent: parent)
        _ = try await assembler.observe(image(.vertical, origin: 0))
        _ = try await assembler.observe(image(.vertical, origin: 24))
        await assembler.failNextPreviewForTesting()
        let failedPreview = try await assembler.observe(image(.vertical, origin: 120))
        XCTAssertNil(failedPreview.preview); XCTAssertTrue(failedPreview.state.previewUnavailable)
        XCTAssertEqual(failedPreview.state.viewportOffset, 120)
        XCTAssertEqual(failedPreview.state.committedSources, 3)
        XCTAssertEqual(failedPreview.state.height, 320)
        XCTAssertFalse(failedPreview.state.previewIsTransient)
        let firstFinish = try await assembler.finish()
        let repeatedFinish = try await assembler.finish()
        try assertOutput(firstFinish, axis: .vertical, origin: 0, length: 320)
        XCTAssertEqual(try pixels(firstFinish), try pixels(repeatedFinish))
        let recovered = try await assembler.observe(image(.vertical, origin: 150))
        XCTAssertTrue(recovered.state.matched); XCTAssertFalse(recovered.state.previewUnavailable)
        XCTAssertNotNil(recovered.preview); XCTAssertEqual(recovered.state.viewportOffset, 150)
        let final = try await assembler.finish()
        try assertOutput(final, axis: .vertical, origin: 0, length: 350)
        let finished = await assembler.currentState()
        XCTAssertEqual(finished.committedSources, 4)
        await assembler.close()
    }

    func testReversalAfterPendingPreviewFailurePreservesTheFailedDisplayFrontier() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let assembler = LiveScrollAssembler(axis: .vertical, generation: 44, storageParent: parent)
        _ = try await assembler.observe(image(.vertical, origin: 0))
        _ = try await assembler.observe(image(.vertical, origin: 24))
        await assembler.failNextPreviewForTesting()
        _ = try await assembler.observe(image(.vertical, origin: 43))
        let reversed = try await assembler.observe(image(.vertical, origin: 31))
        XCTAssertTrue(reversed.state.matched); XCTAssertEqual(reversed.state.viewportOffset, 31)
        XCTAssertEqual(reversed.state.committedSources, 3)
        let output = try await assembler.finish()
        try assertOutput(output, axis: .vertical, origin: 0, length: 243)
        await assembler.close()
    }

    func testFirstImageAndBootstrapPreviewFailuresRemainFinishable() async throws {
        for failInitial in [true, false] {
            let parent = try root()
            defer { try? FileManager.default.removeItem(at: parent) }
            let assembler = LiveScrollAssembler(axis: .vertical, generation: 45, storageParent: parent)
            if failInitial { await assembler.failNextPreviewForTesting() }
            let initial = try await assembler.observe(image(.vertical, origin: 0))
            if failInitial {
                XCTAssertNil(initial.preview); XCTAssertTrue(initial.state.previewUnavailable)
                let firstOnly = try await assembler.finish()
                try assertOutput(firstOnly, axis: .vertical, origin: 0, length: 200)
            } else { await assembler.failNextPreviewForTesting() }
            let established = try await assembler.observe(image(.vertical, origin: 24))
            XCTAssertEqual(established.state.viewportOffset, 24)
            XCTAssertEqual(established.state.committedSources, 2)
            XCTAssertEqual(established.state.previewUnavailable, !failInitial)
            let output = try await assembler.finish()
            try assertOutput(output, axis: .vertical, origin: 0, length: 224)
            await assembler.close()
        }
    }

    func testCancellationAtPreviewBoundaryKeepsAcceptedAnchorAndCloseCannotResurrectOutput() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let assembler = LiveScrollAssembler(axis: .vertical, generation: 46, storageParent: parent)
        _ = try await assembler.observe(image(.vertical, origin: 0))
        _ = try await assembler.observe(image(.vertical, origin: 24))
        await assembler.failNextPreviewForTesting(.cancelled)
        do { _ = try await assembler.observe(image(.vertical, origin: 43)); XCTFail("Expected cancellation at display boundary") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected \(error)") }
        let accepted = await assembler.currentState()
        XCTAssertEqual(accepted.viewportOffset, 43)
        let output = try await assembler.finish()
        try assertOutput(output, axis: .vertical, origin: 0, length: 243)
        await assembler.close(); await assembler.close()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
        do { _ = try await assembler.finish(); XCTFail("Closed assembler must not export") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected \(error)") }
        do { _ = try await assembler.observe(image(.vertical, origin: 44)); XCTFail("Closed assembler must not accept frames") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected \(error)") }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    func testSourceLimitRejectsUnflushablePendingMotionAndLeavesFinishUsable() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let assembler = LiveScrollAssembler(axis: .vertical, generation: 48, storageParent: parent)
        _ = try await assembler.observe(image(.vertical, origin: 0, cross: 24))
        _ = try await assembler.observe(image(.vertical, origin: 24, cross: 24))
        for source in 3...100 {
            let offset = 24 + (source - 2) * 96
            let update = try await assembler.observe(image(.vertical, origin: offset, cross: 24))
            XCTAssertTrue(update.state.matched)
            XCTAssertEqual(update.state.committedSources, source)
        }
        let before = await assembler.currentState()
        do {
            _ = try await assembler.observe(image(.vertical, origin: before.viewportOffset + 1, cross: 24))
            XCTFail("A new pending frontier must not be accepted when Finish cannot persist it")
        } catch let failure as LiveScrollDocument.Failure { XCTAssertEqual(failure, .sourceLimit) }
        catch { XCTFail("Unexpected \(error)") }
        let after = await assembler.currentState()
        XCTAssertEqual(after.viewportOffset, before.viewportOffset)
        XCTAssertEqual(after.acceptedObservations, before.acceptedObservations)
        XCTAssertEqual(after.committedSources, 100)
        let output = try await assembler.finish()
        try assertOutput(output, axis: .vertical, origin: 0, length: before.viewportOffset + 200, cross: 24)
        await assembler.close()
    }

    func testSmallViewportFlushesPendingAnchorBeforeBatchThresholdWouldCreateGap() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let assembler = LiveScrollAssembler(axis: .vertical, generation: 47, storageParent: parent)
        for offset in [0, 4, 25, 48, 54] {
            let update = try await assembler.observe(image(.vertical, origin: offset, length: 48, cross: 32))
            XCTAssertTrue(update.state.matched)
            XCTAssertEqual(update.state.viewportOffset, offset)
        }
        let output = try await assembler.finish()
        try assertOutput(output, axis: .vertical, origin: 0, length: 102, cross: 32)
        let finalState = await assembler.currentState()
        XCTAssertEqual(finalState.committedSources, 4)
        await assembler.close()
    }
}
