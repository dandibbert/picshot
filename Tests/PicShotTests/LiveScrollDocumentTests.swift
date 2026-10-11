import XCTest
import AppKit
import PicShotCore
@testable import PicShot

@MainActor
final class LiveScrollDocumentTests: XCTestCase {
    private typealias Document = LiveScrollDocument

    private func root() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("PicShot-LiveDocument-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
        return result
    }

    /// Independent pixel oracle. The body encodes signed document coordinates and the
    /// cross-axis coordinate; fixed edges encode their frame-specific marker instead.
    private func image(axis: ScrollAxis, lower: Int, upper: Int, cross: Int = 19,
                       leading: Int = 3, trailing: Int = 2, header: UInt8 = 17, footer: UInt8 = 29) throws -> CGImage {
        let length = leading + upper - lower + trailing
        let width = axis == .vertical ? cross : length, height = axis == .vertical ? length : cross
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let along = axis == .vertical ? y : x, across = axis == .vertical ? x : y
            let index = (y * width + x) * 4
            if along < leading {
                data[index] = header; data[index + 1] = UInt8(truncatingIfNeeded: across); data[index + 2] = UInt8(along)
            } else if along >= length - trailing {
                data[index] = footer; data[index + 1] = UInt8(truncatingIfNeeded: across); data[index + 2] = UInt8(along - length + trailing)
            } else {
                let coordinate = lower + along - leading + 10_000
                data[index] = UInt8(truncatingIfNeeded: coordinate * 31 + across * 7)
                data[index + 1] = UInt8(truncatingIfNeeded: coordinate / 5 + across * 13)
                data[index + 2] = UInt8(truncatingIfNeeded: coordinate / 251 + across * 19)
            }
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

    private func content(axis: ScrollAxis, cross: Int = 19, length: Int = 8, leading: Int = 3) -> CGRect {
        axis == .vertical ? CGRect(x: 0, y: leading, width: cross, height: length)
                          : CGRect(x: leading, y: 0, width: length, height: cross)
    }

    private func files(_ document: Document) throws -> [URL: Data] {
        let urls = try FileManager.default.contentsOfDirectory(at: document.storageDirectory, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: urls.map { ($0, try Data(contentsOf: $0)) })
    }

    private func expect(_ failure: Document.Failure, _ operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(failure)", file: file, line: line) }
        catch let actual as Document.Failure { XCTAssertEqual(actual, failure, file: file, line: line) }
        catch { XCTFail("Unexpected \(error)", file: file, line: line) }
    }

    private func verifyReverseUnion(_ axis: ScrollAxis) async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = try image(axis: axis, lower: 0, upper: 8)
        let document = try await Document.create(firstImage: first, scrollingContentRect: content(axis: axis), axis: axis,
                                                 generation: 51, storageParent: parent)
        let firstUpdate = try await document.append(image: image(axis: axis, lower: 5, upper: 13, header: 99, footer: 37),
                                                    viewportOffset: 5, generation: 51)
        XCTAssertEqual(firstUpdate.addedPixels, 5)
        let secondUpdate = try await document.append(image: image(axis: axis, lower: -4, upper: 4, header: 98, footer: 41),
                                                     viewportOffset: -4, generation: 51)
        XCTAssertEqual(secondUpdate.addedPixels, 4)
        let revisit = try await document.append(image: image(axis: axis, lower: 3, upper: 11, header: 97, footer: 60),
                                                viewportOffset: 3, generation: 51)
        XCTAssertEqual(revisit.addedPixels, 0)
        XCTAssertEqual(revisit.snapshot.sourceCount, 3)
        let last = try await document.append(image: image(axis: axis, lower: 10, upper: 18, header: 96, footer: 43),
                                             viewportOffset: 10, generation: 51)
        XCTAssertEqual(last.addedPixels, 5)
        XCTAssertEqual(last.snapshot.lowerBound, -4)
        XCTAssertEqual(last.snapshot.upperBound, 18)
        XCTAssertEqual(last.snapshot.viewportOffset, 10)
        XCTAssertEqual(last.snapshot.viewportLength, 8)
        XCTAssertEqual(last.snapshot.sourceCount, 4)
        XCTAssertEqual(last.snapshot.stripCount, 4)
        XCTAssertEqual(last.snapshot.diskBytes, Int64(19 * (3 + 22 + 2) * 4))
        XCTAssertEqual(last.snapshot.sourceReadCount, 0)
        let result = try await document.render()
        let expected = try image(axis: axis, lower: -4, upper: 18, header: 17, footer: 43)
        XCTAssertEqual(result.width, expected.width); XCTAssertEqual(result.height, expected.height)
        XCTAssertEqual(try pixels(result), try pixels(expected))
        let preview = try await document.preview()
        XCTAssertEqual(try pixels(preview.image), try pixels(expected))
        let fraction = preview.viewportFraction
        XCTAssertEqual(axis == .vertical ? fraction.minY : fraction.minX, 17.0 / 27.0, accuracy: 0.000001)
        XCTAssertEqual(axis == .vertical ? fraction.height : fraction.width, 8.0 / 27.0, accuracy: 0.000001)
        await document.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.storageDirectory.path))
    }

    func testVerticalReverseUnionPreservesFirstHeaderAndLatestCommittedFooterExactlyOnce() async throws {
        try await verifyReverseUnion(.vertical)
    }

    func testHorizontalReverseUnionPreservesFirstLeftEdgeAndLatestCommittedRightEdgeExactlyOnce() async throws {
        try await verifyReverseUnion(.horizontal)
    }

    func testRevisitsAndHundredsOfObservedFramesDoNotWriteOrConsumeSourceSlots() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = try image(axis: .vertical, lower: 0, upper: 256, cross: 13, leading: 0, trailing: 0)
        let document = try await Document.create(firstImage: first, scrollingContentRect: content(axis: .vertical, cross: 13, length: 256, leading: 0), storageParent: parent)
        let initialFiles = try files(document)
        for index in 1...300 {
            let state = try await document.updateViewport(offset: index % 128)
            XCTAssertEqual(state.sourceCount, 1)
            XCTAssertEqual(state.diskBytes, Int64(13 * 256 * 4))
        }
        XCTAssertEqual(try files(document), initialFiles)
        let advance = try await document.append(image: image(axis: .vertical, lower: 128, upper: 384, cross: 13, leading: 0, trailing: 0), viewportOffset: 128)
        XCTAssertEqual(advance.addedPixels, 128)
        XCTAssertEqual(advance.snapshot.sourceCount, 2)
        XCTAssertEqual(advance.snapshot.diskBytes, Int64(13 * 384 * 4))
        let afterAdvance = try files(document)
        XCTAssertEqual(afterAdvance.count, 2)
        for (url, data) in initialFiles { XCTAssertEqual(afterAdvance[url], data, "Committed source bytes must remain immutable") }
        for offset in stride(from: 127, through: 0, by: -1) {
            let revisit = try await document.append(image: first, viewportOffset: offset)
            XCTAssertEqual(revisit.addedPixels, 0)
        }
        XCTAssertEqual(try files(document), afterAdvance)
        let last = await document.snapshot()
        XCTAssertEqual(last.sourceCount, 2); XCTAssertEqual(last.sourceReadCount, 0)
        await document.close()
    }

    func testTransientPreviewsCoverPendingNewEdgesWithoutWritesOrDurableChangesBothAxes() async throws {
        for axis in ScrollAxis.allCases {
            let parent = try root()
            defer { try? FileManager.default.removeItem(at: parent) }
            let first = try image(axis: axis, lower: 0, upper: 8)
            let document = try await Document.create(firstImage: first, scrollingContentRect: content(axis: axis), axis: axis,
                                                     generation: 3, storageParent: parent)
            let saved = try files(document), initial = await document.snapshot()
            for offset in [-3, 4] {
                let candidate = try image(axis: axis, lower: offset, upper: offset + 8, header: 99, footer: 61)
                let preview = try await document.preview(image: candidate, viewportOffset: offset, generation: 3)
                let expected = try image(axis: axis, lower: min(0, offset), upper: max(8, offset + 8), header: 17, footer: 61)
                XCTAssertTrue(preview.isTransient)
                XCTAssertEqual(preview.outputWidth, expected.width); XCTAssertEqual(preview.outputHeight, expected.height)
                XCTAssertEqual(preview.snapshot, initial)
                XCTAssertEqual(try pixels(preview.image), try pixels(expected))
                XCTAssertEqual(try files(document), saved)
            }
            let durable = try await document.preview()
            XCTAssertFalse(durable.isTransient)
            XCTAssertEqual(try pixels(durable.image), try pixels(first))
            let finalState = await document.snapshot()
            XCTAssertEqual(finalState, initial)
            await document.close()
        }
    }

    func testPreviewUsesOwnedBoundedSamplesAndDoesNotReadHistoricalSourceFiles() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = try image(axis: .vertical, lower: 0, upper: 256, cross: 768, leading: 0, trailing: 0)
        let document = try await Document.create(firstImage: first, scrollingContentRect: content(axis: .vertical, cross: 768, length: 256, leading: 0), storageParent: parent)
        for index in 1...30 {
            _ = try await document.append(image: image(axis: .vertical, lower: index * 128, upper: index * 128 + 256,
                                                       cross: 768, leading: 0, trailing: 0), viewportOffset: index * 128)
            let current = await document.snapshot()
            XCTAssertLessThanOrEqual(current.cachedPreviewBytes, Document.maximumCachedPreviewBytes)
            XCTAssertEqual(current.sourceReadCount, 0)
        }
        let committed = try await document.preview()
        XCTAssertLessThanOrEqual(committed.image.width * committed.image.height, Document.maximumPreviewPixels)
        XCTAssertLessThanOrEqual(max(committed.image.width, committed.image.height), Document.maximumPreviewEdge)
        // Remove every source to prove preview cannot secretly reopen/redecode one.
        for url in try files(document).keys { try FileManager.default.removeItem(at: url) }
        let cached = try await document.preview()
        XCTAssertEqual(try pixels(cached.image), try pixels(committed.image))
        let transient = try await document.preview(image: image(axis: .vertical, lower: 3_880, upper: 4_136,
                                                                 cross: 768, leading: 0, trailing: 0), viewportOffset: 3_880)
        XCTAssertLessThanOrEqual(transient.image.width * transient.image.height, Document.maximumPreviewPixels)
        await expect(.missingStrip) { _ = try await document.render() }
        await document.close()
    }

    func testSourceCapCountsOnlyNewCoverageAndAllowsRevisitsAtCap() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = try image(axis: .vertical, lower: 0, upper: 8, cross: 3, leading: 0, trailing: 0)
        let document = try await Document.create(firstImage: first, scrollingContentRect: content(axis: .vertical, cross: 3, length: 8, leading: 0), storageParent: parent)
        for offset in 1..<100 {
            _ = try await document.append(image: image(axis: .vertical, lower: offset, upper: offset + 8,
                                                       cross: 3, leading: 0, trailing: 0), viewportOffset: offset)
        }
        let before = await document.snapshot(), beforeFiles = try files(document)
        XCTAssertEqual(before.sourceCount, 100); XCTAssertEqual(before.stripCount, 100)
        await expect(.sourceLimit) {
            _ = try await document.append(image: image(axis: .vertical, lower: 100, upper: 108, cross: 3, leading: 0, trailing: 0), viewportOffset: 100)
        }
        let after = await document.snapshot()
        XCTAssertEqual(before, after); XCTAssertEqual(try files(document), beforeFiles)
        let revisit = try await document.append(image: first, viewportOffset: 0)
        XCTAssertEqual(revisit.addedPixels, 0); XCTAssertEqual(revisit.snapshot.sourceCount, 100)
        let transient = try await document.preview(image: image(axis: .vertical, lower: 100, upper: 108,
                                                                 cross: 3, leading: 0, trailing: 0), viewportOffset: 100)
        XCTAssertTrue(transient.isTransient)
        await document.close()
    }

    func testGeometryGenerationGapAndOverflowFailuresPreserveStateAndFiles() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = try image(axis: .vertical, lower: 0, upper: 8)
        let document = try await Document.create(firstImage: first, scrollingContentRect: content(axis: .vertical), generation: 7, storageParent: parent)
        let before = await document.snapshot(), beforeFiles = try files(document)
        await expect(.staleGeneration) { _ = try await document.append(image: first, viewportOffset: 1, generation: 6) }
        await expect(.staleGeneration) { _ = try await document.updateViewport(offset: 1, generation: 6) }
        await expect(.invalidGeometry) {
            _ = try await document.append(image: image(axis: .vertical, lower: 1, upper: 10), viewportOffset: 1, generation: 7)
        }
        await expect(.disconnectedViewport) { _ = try await document.append(image: first, viewportOffset: 9, generation: 7) }
        await expect(.disconnectedViewport) { _ = try await document.append(image: first, viewportOffset: -9, generation: 7) }
        await expect(.invalidGeometry) { _ = try await document.append(image: first, viewportOffset: Int.max, generation: 7) }
        await expect(.disconnectedViewport) { _ = try await document.updateViewport(offset: Int.min, generation: 7) }
        let after = await document.snapshot()
        XCTAssertEqual(after, before); XCTAssertEqual(try files(document), beforeFiles)
        await document.close()
    }

    func testPixelEdgeAndPeakDiskLimitsRejectBeforeWritingAndKeepExportUsable() async throws {
        for kind in 0..<3 {
            let parent = try root()
            defer { try? FileManager.default.removeItem(at: parent) }
            let first = try image(axis: .vertical, lower: 0, upper: 8, cross: 11)
            var limits = Document.Limits.default
            if kind == 0 { limits.maximumOutputPixels = 11 * 14 }
            if kind == 1 { limits.maximumOutputDimension = 14 }
            // Active initial output = 572 bytes. New two-row strip + new footer = 176.
            // This fails the actual temporary peak, even though final output is 660.
            if kind == 2 { limits.maximumDiskBytes = 700 }
            let document = try await Document.create(firstImage: first, scrollingContentRect: content(axis: .vertical, cross: 11),
                                                     limits: limits, storageParent: parent)
            let before = await document.snapshot(), beforeFiles = try files(document)
            await expect(kind == 2 ? .storageLimit : .pixelLimit) {
                _ = try await document.append(image: image(axis: .vertical, lower: 2, upper: 10, cross: 11), viewportOffset: 2)
            }
            let after = await document.snapshot()
            XCTAssertEqual(after, before); XCTAssertEqual(try files(document), beforeFiles)
            let exported = try await document.render()
            XCTAssertEqual(try pixels(exported), try pixels(first))
            await document.close()
        }
    }

    func testCancellationImmediatelyBeforeCommitRollsBackStagedFilesAndPreservesPriorMetadata() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = try image(axis: .vertical, lower: 0, upper: 8)
        let document = try await Document.create(firstImage: first, scrollingContentRect: content(axis: .vertical), storageParent: parent)
        let before = await document.snapshot(), beforeFiles = try files(document)
        await document.setBeforeCommitHookForTesting { document.cancel() }
        do {
            _ = try await document.append(image: image(axis: .vertical, lower: 4, upper: 12, footer: 99), viewportOffset: 4)
            XCTFail("Cancelled staged commit must not become visible")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected \(error)") }
        let after = await document.snapshot()
        XCTAssertEqual(after, before); XCTAssertEqual(try files(document), beforeFiles)
        XCTAssertTrue(try files(document).keys.allSatisfy { $0.pathExtension == "rgba" })
        await document.setBeforeCommitHookForTesting(nil)
        await document.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.storageDirectory.path))
    }

    func testTaskCancellationBeforeAppendDoesNotChangeDocumentAndDoesNotInvalidateLaterWork() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = try image(axis: .vertical, lower: 0, upper: 8)
        let document = try await Document.create(firstImage: first, scrollingContentRect: content(axis: .vertical), storageParent: parent)
        let before = await document.snapshot(), beforeFiles = try files(document)
        // Task inherits MainActor and cannot run before this turn cancels it.
        let task = Task { try await document.append(image: first, viewportOffset: 1) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled task must not append") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected \(error)") }
        let after = await document.snapshot()
        XCTAssertEqual(after, before); XCTAssertEqual(try files(document), beforeFiles)
        let update = try await document.append(image: image(axis: .vertical, lower: 1, upper: 9), viewportOffset: 1)
        XCTAssertEqual(update.addedPixels, 1)
        await document.close()
    }

    func testExplicitViewportCropRequiredForSidebarsAndInitialOutputMatchesCrop() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = try image(axis: .vertical, lower: 0, upper: 15, cross: 21)
        let contentRect = CGRect(x: 2, y: 3, width: 17, height: 14)
        await expect(.invalidGeometry) {
            _ = try await Document.create(firstImage: source, scrollingContentRect: contentRect, storageParent: parent)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
        let crop = CGRect(x: 2, y: 1, width: 17, height: 18)
        let document = try await Document.create(firstImage: source, scrollingContentRect: contentRect, viewportCrop: crop, storageParent: parent)
        XCTAssertEqual(document.viewportCrop, crop)
        let result = try await document.render()
        XCTAssertEqual(try pixels(result), try pixels(XCTUnwrap(source.cropping(to: crop))))
        await document.close()
    }

    func testInvalidInitialGeometryAndTighterLimitsLeaveNoOwnedTemporaryFiles() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = try image(axis: .vertical, lower: 0, upper: 8)
        for rectangle in [CGRect(x: 0, y: 3.5, width: 19, height: 8), .zero,
                          CGRect(x: 0, y: 3, width: 20, height: 8), CGRect(x: 0, y: -1, width: 19, height: 8)] {
            await expect(.invalidGeometry) {
                _ = try await Document.create(firstImage: source, scrollingContentRect: rectangle, storageParent: parent)
            }
        }
        var limits = Document.Limits.default; limits.maximumDiskBytes = 1
        await expect(.storageLimit) {
            _ = try await Document.create(firstImage: source, scrollingContentRect: content(axis: .vertical), limits: limits, storageParent: parent)
        }
        limits = .default; limits.maximumSources = 101
        await expect(.invalidGeometry) {
            _ = try await Document.create(firstImage: source, scrollingContentRect: content(axis: .vertical), limits: limits, storageParent: parent)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    func testCloseOnlyRemovesOwnedFilesAndIsIdempotent() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let unrelated = parent.appendingPathComponent("unrelated.txt")
        try Data("keep parent neighbor".utf8).write(to: unrelated)
        let source = try image(axis: .vertical, lower: 0, upper: 8)
        let document = try await Document.create(firstImage: source, scrollingContentRect: content(axis: .vertical), storageParent: parent)
        let unexpected = document.storageDirectory.appendingPathComponent("not-owned.txt")
        try Data("keep unowned child".utf8).write(to: unexpected)
        let own = Set(try files(document).keys).subtracting([unexpected])
        await document.close(); await document.close()
        XCTAssertEqual(try String(contentsOf: unrelated), "keep parent neighbor")
        XCTAssertEqual(try String(contentsOf: unexpected), "keep unowned child")
        for url in own { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
        await expect(.closed) { _ = try await document.append(image: source, viewportOffset: 1) }
        await expect(.closed) { _ = try await document.render() }
    }

    func testExportAndPreviewImagesOwnTheirPixelsAfterDocumentCloses() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = try image(axis: .vertical, lower: 0, upper: 8)
        let document = try await Document.create(firstImage: source, scrollingContentRect: content(axis: .vertical), storageParent: parent)
        let exported = try await document.render(), preview = try await document.preview()
        await document.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.storageDirectory.path))
        XCTAssertEqual(try pixels(exported), try pixels(source))
        XCTAssertEqual(try pixels(preview.image), try pixels(source))
    }

    func testDamagedStoredStripFailsExportWithoutChangingCoverage() async throws {
        let parent = try root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = try image(axis: .horizontal, lower: 0, upper: 8, leading: 0, trailing: 0)
        let document = try await Document.create(firstImage: source, scrollingContentRect: content(axis: .horizontal, leading: 0),
                                                 axis: .horizontal, storageParent: parent)
        let before = await document.snapshot()
        let url = try XCTUnwrap(files(document).keys.first)
        try Data([1, 2, 3]).write(to: url)
        await expect(.missingStrip) { _ = try await document.render() }
        let after = await document.snapshot()
        XCTAssertEqual(after, before)
        await document.close()
    }
}
