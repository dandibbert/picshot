import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import PicShot

final class ImageOutputDecorationTests: XCTestCase {
    func testDisabledAndEffectivelyEmptyReturnExactIdentityWithoutAllocation() throws {
        let source = try patterned(53, 41), probe = ImageOutputDecorationResourceProbe()
        for value in [ImageOutputDecoration.none, ImageOutputDecoration(enabled: true),
                      ImageOutputDecoration(enabled: true, borderEnabled: true, borderWidth: 0, shadowEnabled: true, shadowOpacity: 0)] {
            let output = try ImageOutputDecorationRenderer.project(flattened: source, decoration: value, resourceProbe: probe)
            XCTAssertTrue(output === source)
        }
        XCTAssertEqual(probe.allocationCount, 0); XCTAssertEqual(probe.peakBytes, 0)
    }

    func testSharpBorderIsInsideAndEveryUnborderedInteriorPixelMatchesIndependentNormalization() throws {
        let source = try patterned(51, 39), original = try rgba(source)
        let value = ImageOutputDecoration(enabled: true, borderEnabled: true, borderWidth: 3,
                                           borderColor: .init(red: 1, green: 0, blue: 0, alpha: 1))
        let output = try ImageOutputDecorationRenderer.project(flattened: source, decoration: value)
        XCTAssertEqual(output.width, source.width); XCTAssertEqual(output.height, source.height)
        let actual = try rgba(output)
        for y in 0..<39 { for x in 0..<51 {
            XCTAssertEqual(pixel(actual, width: 51, x: x, y: y),
                x < 3 || x >= 48 || y < 3 || y >= 36 ? [255, 0, 0, 255] : pixel(original, width: 51, x: x, y: y),
                "x=\(x), y=\(y)")
        } }
        XCTAssertEqual(try rgba(source), original, "Source provider and coordinates must not change")
    }

    func testRoundedCornersHaveTransparentCornersAntialiasedEdgesAndExactInterior() throws {
        let source = try solid(64, 48, [30, 100, 210, 255]), original = try rgba(source)
        let output = try ImageOutputDecorationRenderer.project(flattened: source,
            decoration: ImageOutputDecoration(enabled: true, cornerRadius: 16))
        let bytes = try rgba(output)
        for (x, y) in [(0, 0), (63, 0), (0, 47), (63, 47)] { XCTAssertEqual(pixel(bytes, width: 64, x: x, y: y), [0, 0, 0, 0]) }
        let edge = pixel(bytes, width: 64, x: 4, y: 4)
        XCTAssertGreaterThan(edge[3], 0); XCTAssertLessThan(edge[3], 255)
        XCTAssertLessThanOrEqual(edge[0], edge[3]); XCTAssertLessThanOrEqual(edge[1], edge[3]); XCTAssertLessThanOrEqual(edge[2], edge[3])
        for y in 16..<32 { for x in 0..<64 {
            XCTAssertEqual(pixel(bytes, width: 64, x: x, y: y), pixel(original, width: 64, x: x, y: y))
        } }
        XCTAssertEqual(pixel(bytes, width: 64, x: 32, y: 0), [30, 100, 210, 255])
        XCTAssertEqual(try rgba(source), original)
    }

    func testBorderOpacityCompositesInsideRoundedCoverageWithoutFlatteningAlpha() throws {
        let source = try solid(32, 32, [0, 0, 255, 255])
        let output = try ImageOutputDecorationRenderer.project(flattened: source,
            decoration: ImageOutputDecoration(enabled: true, cornerRadius: 8, borderEnabled: true, borderWidth: 2,
                borderColor: .init(red: 1, green: 0, blue: 0, alpha: 0.5)))
        let bytes = try rgba(output)
        XCTAssertEqual(pixel(bytes, width: 32, x: 0, y: 0), [0, 0, 0, 0])
        XCTAssertEqual(pixel(bytes, width: 32, x: 0, y: 16), [128, 0, 128, 255])
        XCTAssertEqual(pixel(bytes, width: 32, x: 2, y: 16), [0, 0, 255, 255])
    }

    func testShadowOffsetsInAllDirectionsAndExactPaddingHaveNoCutoff() throws {
        let source = try solid(16, 16, [255, 255, 255, 255])
        for (dx, dy) in [(4.0, 3.0), (-4, 3), (4, -3), (-4, -3)] {
            let value = ImageOutputDecoration(enabled: true, shadowEnabled: true, shadowBlur: 0,
                shadowOffsetX: dx, shadowOffsetY: dy, shadowOpacity: 0.5)
            let layout = try ImageOutputDecorationLayout.make(width: 16, height: 16, decoration: value)
            XCTAssertEqual(layout.left, dx < 0 ? 5 : 0); XCTAssertEqual(layout.right, dx > 0 ? 5 : 0)
            XCTAssertEqual(layout.top, dy < 0 ? 4 : 0); XCTAssertEqual(layout.bottom, dy > 0 ? 4 : 0)
            XCTAssertEqual(layout.imageRect, CGRect(x: layout.left, y: layout.bottom, width: 16, height: 16))
            let output = try ImageOutputDecorationRenderer.project(flattened: source, decoration: value), bytes = try rgba(output)
            XCTAssertEqual(output.width, 21); XCTAssertEqual(output.height, 20)
            let shadowX = dx > 0 ? layout.left + 17 : layout.left - 2
            XCTAssertEqual(pixel(bytes, width: output.width, x: shadowX, y: layout.top + 8), [0, 0, 0, 128])
            let shadowY = dy > 0 ? layout.top + 17 : layout.top - 2
            XCTAssertEqual(pixel(bytes, width: output.width, x: layout.left + 8, y: shadowY), [0, 0, 0, 128])
            XCTAssertEqual(pixel(bytes, width: output.width, x: layout.left + 8, y: layout.top + 8), [255, 255, 255, 255])
            // The side beyond each shadow has a full transparent guard pixel.
            let outerX = dx > 0 ? output.width - 1 : 0, outerY = dy > 0 ? output.height - 1 : 0
            XCTAssertEqual(pixel(bytes, width: output.width, x: outerX, y: layout.top + 8)[3], 0)
            XCTAssertEqual(pixel(bytes, width: output.width, x: layout.left + 8, y: outerY)[3], 0)
        }
    }

    func testFractionalShadowOffsetUsesActualAlphaAndKeepsDisjointGapTransparent() throws {
        let source = try makeImage(80, 48) { x, y in
            (x < 16 || x >= 64) && y >= 8 && y < 40 ? [90, 150, 220, 255] : [0, 0, 0, 0]
        }
        let original = try rgba(source)
        let value = ImageOutputDecoration(enabled: true, shadowEnabled: true, shadowBlur: 2,
            shadowOffsetX: 3.5, shadowOffsetY: -2.5, shadowOpacity: 0.7)
        let layout = try ImageOutputDecorationLayout.make(width: 80, height: 48, decoration: value)
        let output = try ImageOutputDecorationRenderer.project(flattened: source, decoration: value), bytes = try rgba(output)
        XCTAssertEqual(pixel(bytes, width: output.width, x: layout.left + 40, y: layout.top + 24), [0, 0, 0, 0], "Deep gap must not acquire a rectangular background")
        let shadow = pixel(bytes, width: output.width, x: layout.left + 18, y: layout.top + 20)
        XCTAssertEqual(Array(shadow.prefix(3)), [0, 0, 0]); XCTAssertGreaterThan(shadow[3], 0); XCTAssertLessThan(shadow[3], 255)
        XCTAssertEqual(pixel(bytes, width: output.width, x: layout.left + 4, y: layout.top + 20), [90, 150, 220, 255])
        XCTAssertEqual(try rgba(source), original)
        for x in 0..<output.width {
            XCTAssertEqual(pixel(bytes, width: output.width, x: x, y: 0)[3], 0)
            XCTAssertEqual(pixel(bytes, width: output.width, x: x, y: output.height - 1)[3], 0)
        }
        for y in 0..<output.height {
            XCTAssertEqual(pixel(bytes, width: output.width, x: 0, y: y)[3], 0)
            XCTAssertEqual(pixel(bytes, width: output.width, x: output.width - 1, y: y)[3], 0)
        }
    }

    func testSubpixelHardShadowAndSourceTransparency() throws {
        let source = try solid(8, 8, [255, 0, 0, 255])
        let value = ImageOutputDecoration(enabled: true, shadowEnabled: true, shadowBlur: 0,
            shadowOffsetX: 0.5, shadowOffsetY: 0, shadowOpacity: 1)
        let layout = try ImageOutputDecorationLayout.make(width: 8, height: 8, decoration: value)
        let output = try ImageOutputDecorationRenderer.project(flattened: source, decoration: value), bytes = try rgba(output)
        XCTAssertEqual(pixel(bytes, width: output.width, x: layout.left + 8, y: layout.top + 3), [0, 0, 0, 128])
        let empty = try solid(8, 8, [0, 0, 0, 0])
        let emptyResult = try ImageOutputDecorationRenderer.project(flattened: empty, decoration: value)
        XCTAssertTrue(try rgba(emptyResult).allSatisfy { $0 == 0 })
    }

    func testSixtyMegapixelSourceAndAllBoundsAreValidatedWithoutAllocating() throws {
        let value = ImageOutputDecoration(enabled: true, cornerRadius: 48, shadowEnabled: true)
        let layout = try ImageOutputDecorationLayout.make(width: 2_000, height: 30_000, decoration: value)
        XCTAssertGreaterThan(layout.width * layout.height, 60_000_000)
        XCTAssertLessThan(layout.workingBytes, ImageOutputDecorationLimits.standard.maximumWorkingBytes)
        for (w, h) in [(Int.max, 1), (1, Int.max), (0, 10), (-1, 3), (32_769, 1), (20_000, 20_000)] {
            XCTAssertThrowsError(try ImageOutputDecorationLayout.make(width: w, height: h, decoration: value))
        }
        let clamped = try ImageOutputDecorationLayout.make(width: 8, height: 3,
            decoration: ImageOutputDecoration(enabled: true, cornerRadius: 4_096, borderEnabled: true, borderWidth: 128))
        XCTAssertEqual(clamped.radius, 1.5); XCTAssertEqual(clamped.borderWidth, 1.5)
        var limits = ImageOutputDecorationLimits.standard; limits.maximumPadding = 1
        XCTAssertThrowsError(try ImageOutputDecorationLayout.make(width: 10, height: 10, decoration: value, limits: limits))
        limits = .standard; limits.maximumWorkingBytes = 8
        XCTAssertThrowsError(try ImageOutputDecorationLayout.make(width: 10, height: 10, decoration: value, limits: limits))
        for key in [0, 1, 2, 3, 4, 5, 6] {
            var invalid = value
            switch key {
            case 0: invalid.cornerRadius = .nan
            case 1: invalid.borderWidth = -.infinity
            case 2: invalid.shadowBlur = 65
            case 3: invalid.shadowOffsetX = .infinity
            case 4: invalid.shadowOffsetY = -129
            case 5: invalid.shadowOpacity = .nan
            default: invalid.borderColor.red = 1.1
            }
            XCTAssertThrowsError(try ImageOutputDecorationLayout.make(width: 10, height: 10, decoration: invalid))
        }
    }

    func testCancellationAndRepeatedOutputReleaseAllOwnedBuffers() throws {
        let source = try patterned(160, 100), probe = ImageOutputDecorationResourceProbe()
        let value = ImageOutputDecoration(enabled: true, cornerRadius: 16, borderEnabled: true, shadowEnabled: true)
        let token = ImageExportCancellation(); token.cancel()
        XCTAssertThrowsError(try ImageOutputDecorationRenderer.project(flattened: source, decoration: value, cancellation: token, resourceProbe: probe)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(probe.allocationCount, 0)
        for _ in 0..<25 {
            try autoreleasepool {
                let output = try ImageOutputDecorationRenderer.project(flattened: source, decoration: value, resourceProbe: probe)
                XCTAssertEqual(probe.currentBytes, output.width * output.height * 4, "Only the final provider may own renderer bytes after return")
                XCTAssertGreaterThan(output.width, source.width)
            }
            XCTAssertEqual(probe.currentBytes, 0, "No accumulating normalization/preview cache may retain a prior output")
        }
        XCTAssertLessThan(probe.peakBytes, ImageOutputDecorationLimits.standard.maximumWorkingBytes)
    }

    func testThumbnailOwnsOnlyBoundedPixelsAndReleasesFullConversionBeforeReturn() throws {
        let source = try patterned(901, 600), probe = ImageOutputDecorationResourceProbe()
        try autoreleasepool {
            let preview = try ImageOutputDecorationRenderer.previewSource(image: source, maximumDimension: 128,
                cancellation: ImageExportCancellation(), resourceProbe: probe)
            XCTAssertEqual(preview.image.width, 128); XCTAssertLessThanOrEqual(preview.image.height, 128)
            XCTAssertEqual(preview.scale, 128.0 / 901.0)
            XCTAssertEqual(probe.currentBytes, preview.image.width * preview.image.height * 4)
            XCTAssertGreaterThan(probe.peakBytes, source.width * source.height * 4)
        }
        XCTAssertEqual(probe.currentBytes, 0)
    }

    func testDraftApplyCancelResetAndUndoValuesNeverHoldPixels() throws {
        let initial = ImageOutputDecoration.none
        var draft = ImageOutputDecorationDraft(initial)
        draft.value = .init(enabled: true, cornerRadius: 20, borderEnabled: true)
        let committed = try XCTUnwrap(draft.apply())
        XCTAssertEqual(committed.cornerRadius, 20); XCTAssertNil(try draft.apply(), "Commit callback may run only once")
        // This is the owner's metadata-only undo record: old and new retain no raster.
        let undo = initial, redo = committed
        XCTAssertEqual(undo, .none); XCTAssertEqual(redo, committed)
        var cancelled = ImageOutputDecorationDraft(committed)
        cancelled.value.cornerRadius = 2; cancelled.cancel()
        XCTAssertEqual(cancelled.value, committed); XCTAssertNil(try cancelled.apply())
        var reset = ImageOutputDecorationDraft(committed); reset.reset()
        XCTAssertEqual(try reset.apply(), ImageOutputDecoration.none)
        var unchanged = ImageOutputDecorationDraft(initial); XCTAssertNil(try unchanged.apply())
        var invalid = ImageOutputDecorationDraft(committed); invalid.value.cornerRadius = .nan
        XCTAssertThrowsError(try invalid.apply()); XCTAssertFalse(invalid.isFinished)
    }

    func testNativeExportsReopenDecoratedTransparentOrWhitePixelsAndDimensions() throws {
        let source = try solid(96, 80, [20, 70, 180, 255])
        let decoration = ImageOutputDecoration(enabled: true, cornerRadius: 20, shadowEnabled: true,
            shadowBlur: 2, shadowOffsetX: 3, shadowOffsetY: 4, shadowOpacity: 0.4)
        let decorated = try ImageOutputDecorationRenderer.project(flattened: source, decoration: decoration)
        let snapshot = try ImageExportSnapshot(image: decorated)
        for format in [ImageExportFormat.png, .tiff, .jpeg, .bmp, .pdf] {
            let artifact = try ImageExportService.encode(snapshot: snapshot, options: ImageExportOptions(format: format))
            XCTAssertEqual(artifact.width, decorated.width); XCTAssertEqual(artifact.height, decorated.height)
            let decoded: CGImage
            if format == .pdf {
                let document = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: artifact.data as CFData))))
                let page = try XCTUnwrap(document.page(at: 1))
                XCTAssertEqual(page.getBoxRect(.mediaBox).size, CGSize(width: decorated.width, height: decorated.height))
                decoded = try renderPDF(page)
            } else {
                let encodedSource = try XCTUnwrap(CGImageSourceCreateWithData(artifact.data as CFData, nil))
                XCTAssertEqual(CGImageSourceGetType(encodedSource) as String?, format.contentType.identifier)
                decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(encodedSource, 0, nil))
            }
            XCTAssertEqual(decoded.width, decorated.width); XCTAssertEqual(decoded.height, decorated.height)
            let bytes = try rgba(decoded), corner = pixel(bytes, width: decoded.width, x: 0, y: 0)
            if format.preservesAlpha {
                XCTAssertEqual(corner, [0, 0, 0, 0]); XCTAssertEqual(bytes, try rgba(decorated))
            } else {
                XCTAssertEqual(corner[3], 255)
                XCTAssertTrue(corner.prefix(3).allSatisfy { $0 >= 245 }, "\(format) must use the existing white export composition")
                XCTAssertTrue(stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 })
            }
        }
    }

    func testVImageProjectionMatchesIndependentCGContextForPaddedColorSpacesGrayAndCroppedInputs() throws {
        var images: [CGImage] = []
        let width = 37, height = 29
        for space in [CGColorSpace(name: CGColorSpace.sRGB)!, CGColorSpaceCreateDeviceRGB(), CGColorSpace(name: CGColorSpace.displayP3)!] {
            for bgra in [false, true] {
                let row = width * 4 + 12
                var bytes = [UInt8](repeating: 211, count: row * height)
                for y in 0..<height { for x in 0..<width {
                    let alpha = (x * 43 + y * 71) % 256
                    let r = UInt8((x * 97 + y * 23) % (alpha + 1)), g = UInt8((x * 17 + y * 109) % (alpha + 1))
                    let b = UInt8((x * 67 + y * 13) % (alpha + 1))
                    let pixel: [UInt8] = bgra ? [b, g, r, UInt8(alpha)] : [r, g, b, UInt8(alpha)]
                    for c in 0..<4 { bytes[y * row + x * 4 + c] = pixel[c] }
                } }
                let bitmap = bgra ? CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue :
                    CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
                let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: row, space: space, bitmapInfo: CGBitmapInfo(rawValue: bitmap), provider: provider,
                    decode: nil, shouldInterpolate: false, intent: .defaultIntent))
                images.append(image)
                images.append(try XCTUnwrap(image.cropping(to: CGRect(x: 5, y: 7, width: 19, height: 13))))
            }
        }
        let grayBytes = (0..<((width + 7) * height)).map { UInt8(($0 * 37) % 256) }
        images.append(try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width + 7, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: try XCTUnwrap(CGDataProvider(data: Data(grayBytes) as CFData)), decode: nil, shouldInterpolate: false, intent: .defaultIntent)))
        for image in images + Array(images.reversed()) {
            // Radius 0.01 exercises the real normalization path; all 4×4 sample
            // centers remain inside, so every normalized source byte is known.
            let output = try ImageOutputDecorationRenderer.project(flattened: image,
                decoration: ImageOutputDecoration(enabled: true, cornerRadius: 0.01))
            XCTAssertFalse(output === image); XCTAssertEqual(try rgba(output), try rgba(image))
        }
    }

    func testSixteenBitAndIndexedProvidersAreNormalizedWithoutReadingRawProviderOffsets() throws {
        let width = 37, height = 19, row = width * 8 + 16
        var wide = [UInt8](repeating: 193, count: row * height)
        for y in 0..<height { for x in 0..<width {
            let values = [(x * 1_733 + y * 307) % 65_536, (x * 97 + y * 2_011) % 65_536, (x * 911 + y * 37) % 65_536, 65_535]
            for c in 0..<4 {
                wide[y * row + x * 8 + c * 2] = UInt8(values[c] >> 8)
                wide[y * row + x * 8 + c * 2 + 1] = UInt8(values[c] & 255)
            }
        } }
        let wideImage = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: row, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: try XCTUnwrap(CGDataProvider(data: Data(wide) as CFData)), decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let palette: [UInt8] = [11, 79, 223, 97, 241, 3, 211, 31, 173, 251, 181, 59]
        let space = try palette.withUnsafeBufferPointer {
            try XCTUnwrap(CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(), last: 3, colorTable: $0.baseAddress!))
        }
        let bytes = (0..<(width + 7) * height).map { UInt8(($0 + $0 / (width + 7)) % 4) }
        let indexed = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width + 7, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData)), decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        for image in [wideImage, indexed] {
            let source = try XCTUnwrap(image.cropping(to: CGRect(x: 3, y: 5, width: 20, height: 11)))
            let projected = try ImageOutputDecorationRenderer.project(flattened: source,
                decoration: ImageOutputDecoration(enabled: true, cornerRadius: 0.01))
            XCTAssertEqual(try rgba(projected), try rgba(source))
        }
    }

    /// Real signed helper and independent platform decode, including explicit
    /// alpha-off composition. Missing builds/readers fail; no mock/skip fallback.
    func testBundledWebPAndAVIFRespectExplicitAlphaChoiceAfterDecoration() async throws {
        let app = try CodecProcessTestApplication.make(); defer { app.cleanup() }
        let service = app.service()
        let decorated = try ImageOutputDecorationRenderer.project(flattened: solid(80, 64, [40, 110, 210, 255]),
            decoration: ImageOutputDecoration(enabled: true, cornerRadius: 16, shadowEnabled: true, shadowBlur: 2))
        let snapshot = try ImageExportSnapshot(image: decorated), transparentReference = try rgba(decorated)
        for format in [ImageExportFormat.webp, .avif] { for preservesAlpha in [true, false] {
            let artifact = try await ImageExportService.encodeBundled(snapshot: snapshot,
                options: ImageExportOptions(format: format, lossless: true, preserveAlpha: preservesAlpha), service: service)
            let decoded = try CodecExportResourceFixture.independentDecode(artifact.data, format: format,
                width: decorated.width, height: decorated.height)
            let bytes = try rgba(decoded)
            XCTAssertEqual(bytes.count, transparentReference.count)
            for index in stride(from: 0, to: bytes.count, by: 4) {
                let sourceAlpha = Int(transparentReference[index + 3])
                XCTAssertLessThanOrEqual(abs(Int(bytes[index + 3]) - (preservesAlpha ? sourceAlpha : 255)), 2)
                for channel in 0..<3 {
                    let expected = Int(transparentReference[index + channel]) + (preservesAlpha ? 0 : 255 - sourceAlpha)
                    XCTAssertLessThanOrEqual(abs(Int(bytes[index + channel]) - expected), 2)
                }
            }
            let state = await service.snapshot()
            XCTAssertFalse(state.active); XCTAssertEqual(state.lastJob?.childExitConfirmed, true)
            XCTAssertEqual(state.lastJob?.temporaryDirectoryRemoved, true)
        } }
    }

    /// Native measurements are attached as observations, with no automatic
    /// plateau/no-leak claim. Full-size 60 MP/UI acceptance is a separate gate.
    func testRepeatedNativeResourceObservationsKeepNoOwnedRendererBuffers() throws {
        let source = try patterned(1_024, 768), probe = ImageOutputDecorationResourceProbe()
        let value = ImageOutputDecoration(enabled: true, cornerRadius: 24, borderEnabled: true, shadowEnabled: true)
        for _ in 0..<2 { try autoreleasepool { _ = try ImageOutputDecorationRenderer.project(flattened: source, decoration: value) } }
        let baseline = GIFResourceMemoryReading.current(), sampler = GIFResourceMemorySampler()
        defer { sampler.stop() }
        var readings: [GIFResourceMemoryReading] = []
        for _ in 0..<12 {
            try autoreleasepool {
                let image = try ImageOutputDecorationRenderer.project(flattened: source, decoration: value, resourceProbe: probe)
                XCTAssertGreaterThan(image.width, source.width); sampler.sample()
            }
            XCTAssertEqual(probe.currentBytes, 0)
            readings.append(GIFResourceMemoryReading.current())
        }
        sampler.stop()
        struct Observation: Encodable {
            let profile = "unit-1024x768-12-cycles"
            let scope = "Current process sampled RSS/footprint; framework internals included, source retained; no leak/stability verdict"
            let baseline: GIFResourceMemoryReading
            let settled: [GIFResourceMemoryReading]
            let statistics: GIFResourceMemoryStatistics
            let ownedPeakBytes: Int
        }
        let observation = Observation(baseline: baseline, settled: readings, statistics: sampler.snapshot(), ownedPeakBytes: probe.peakBytes)
        XCTAssertNotNil(baseline.residentBytes); XCTAssertNotNil(baseline.physicalFootprintBytes)
        XCTAssertTrue(readings.allSatisfy { $0.residentBytes != nil && $0.physicalFootprintBytes != nil })
        let attachment = XCTAttachment(data: try JSONEncoder().encode(observation), uniformTypeIdentifier: UTType.json.identifier)
        attachment.name = "output-decoration-native-resources.json"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func patterned(_ width: Int, _ height: Int) throws -> CGImage {
        try makeImage(width, height) { x, y in [UInt8((x * 13 + y * 7) % 256), UInt8((x * 3 + y * 29) % 256), UInt8((x * 17 + y * 11) % 256), 255] }
    }
    private func solid(_ width: Int, _ height: Int, _ pixel: [UInt8]) throws -> CGImage { try makeImage(width, height) { _, _ in pixel } }
    private func makeImage(_ width: Int, _ height: Int, body: (Int, Int) -> [UInt8]) throws -> CGImage {
        var bytes = [UInt8](); bytes.reserveCapacity(width * height * 4)
        for y in 0..<height { for x in 0..<width { bytes.append(contentsOf: body(x, y)) } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    /// Independent unchanged CGContext reference, not the renderer's vImage path.
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    private func pixel(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> [UInt8] {
        Array(bytes[((y * width + x) * 4)..<((y * width + x) * 4 + 4)])
    }
    private func renderPDF(_ page: CGPDFPage) throws -> CGImage {
        let bounds = page.getBoxRect(.mediaBox)
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(bounds.width), height: Int(bounds.height), bitsPerComponent: 8,
            bytesPerRow: Int(bounds.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.drawPDFPage(page); return try XCTUnwrap(context.makeImage())
    }
}
