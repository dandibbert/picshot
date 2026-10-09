import AppKit
import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PicShot

/// Exact native pixel/metadata checks, not a memory benchmark. Provider rows are
/// read directly so a redraw cannot hide color/alpha or retained-output changes.
final class EffectContextConfigurationTests: XCTestCase {
    func testProductionDefaultAndFiniteSmokePolicies() throws {
        XCTAssertEqual(EffectContextPolicy.productionDefault, .reference)
        XCTAssertEqual(Set(EffectContextPolicy.allCases.map(\.rawValue)), Set(["reference", "memory32"]))
        XCTAssertEqual(try EffectContextConfiguration.selection(environment: [:]), .reference)
        XCTAssertEqual(try EffectContextConfiguration.selection(environment: ["PICSHOT_SMOKE_TEST": "1"]), .reference)
        for policy in EffectContextPolicy.allCases {
            XCTAssertEqual(try EffectContextConfiguration.selection(environment: smoke(policy.rawValue)), policy)
            XCTAssertEqual(try EffectContextConfiguration(environment: smoke(policy.rawValue)).selectedPolicy(), policy)
            for key in ["PICSHOT_SMOKE_TEST", "PICSHOT_SMOKE_REPORT"] {
                var invalid = smoke(policy.rawValue); invalid.removeValue(forKey: key)
                assertInvalid(invalid)
            }
        }
    }

    func testInvalidSelectorsAndUnknownPrefixedKeysNeverFallBack() {
        for raw in ["", "Reference", "REFERENCE", " memory32", "memory32 ", "32", "memory64", "memory0",
                    "reference,memory32", "memory32\0", "reference\n"] {
            assertInvalid(smoke(raw))
        }
        for key in ["PICSHOT_EFFECT_CONTEXT", "PICSHOT_EFFECT_CONTEXT_UNKNOWN", "PICSHOT_EFFECT_CONTEXT_POLICY_EXTRA",
                    "PICSHOT_EFFECT_CONTEXT_MEMORY_MB", "PICSHOT_EFFECT_CONTEXT_POLICY "] {
            assertInvalid([key: "memory32"])
            var invalid = smoke("reference"); invalid[key] = "memory32"; assertInvalid(invalid)
        }
        for raw in ["", "0", "true", " 1", "1 ", "1\n"] {
            var invalid = smoke("memory32"); invalid["PICSHOT_SMOKE_TEST"] = raw; assertInvalid(invalid)
        }
        for raw in ["", "report.json", "./report.json", "~/report.json", "file:///tmp/report.json", "/tmp/report\0.json"] {
            var invalid = smoke("memory32"); invalid["PICSHOT_SMOKE_REPORT"] = raw; assertInvalid(invalid)
        }
    }

    func testOnlyMemoryTargetOptionDiffersAndUnitsAreExactlyMegabytes() {
        let reference = EffectContextPolicy.reference.contextOptions
        let candidate = EffectContextPolicy.memory32.contextOptions
        XCTAssertEqual(Set(reference.keys), Set([CIContextOption.cacheIntermediates]))
        XCTAssertEqual(Set(candidate.keys), Set([CIContextOption.cacheIntermediates, .memoryTarget]))
        XCTAssertEqual(reference[.cacheIntermediates] as? Bool, false)
        XCTAssertEqual(candidate[.cacheIntermediates] as? Bool, false)
        XCTAssertNil(reference[.memoryTarget])
        XCTAssertEqual(candidate[.memoryTarget] as? Int, 32)
        XCTAssertNil(EffectContextPolicy.reference.configuredMemoryTargetMegabytes)
        XCTAssertEqual(EffectContextPolicy.memory32.configuredMemoryTargetMegabytes, 32)
        for options in [reference, candidate] {
            for key in [CIContextOption.workingColorSpace, .outputColorSpace, .workingFormat,
                        .outputPremultiplied, .useSoftwareRenderer] { XCTAssertNil(options[key]) }
        }
    }

    func testSelectionIsImmutableAndProcessConfigurationIsShared() throws {
        var environment = smoke("reference")
        let configuration = EffectContextConfiguration(environment: environment)
        environment["PICSHOT_EFFECT_CONTEXT_POLICY"] = "memory32"
        XCTAssertEqual(try configuration.selectedPolicy(), .reference)
        XCTAssertEqual(try EffectContextConfiguration(environment: environment).selectedPolicy(), .memory32)
        XCTAssertTrue(EffectContextConfiguration.process === EffectContextConfiguration.process)
        let original = configuration.tracker.snapshot()
        XCTAssertEqual(original.contextCount, 1)
        XCTAssertNil(original.configuredMemoryTargetMegabytes)
        XCTAssertEqual(original.configuredCacheIntermediates, false)
        XCTAssertEqual(original.contextOptionCount, 1)
        XCTAssertEqual(original.attemptCount, 0)
    }

    func testRealBlurAndPixelationMatchIndependentLegacyContextIncludingColorAndAlpha() throws {
        let legacy = CIContext(options: [.cacheIntermediates: false])
        for colorName in [CGColorSpace.sRGB, CGColorSpace.displayP3, CGColorSpace.linearSRGB] {
            let source = try pattern(color: XCTUnwrap(CGColorSpace(name: colorName)))
            let original = try rows(source), profile = source.colorSpace?.copyICCData() as Data?
            for policy in EffectContextPolicy.allCases {
                let configuration = EffectContextConfiguration(environment: smoke(policy.rawValue))
                for tool in [ImageEditorTool.blur, .pixelate] {
                    for region in [CGRect(x: 0, y: 0, width: 129, height: 101),
                                   CGRect(x: 11, y: 7, width: 91, height: 73)] {
                        let input = filtered(source, tool: tool, region: region)
                        let expected = try XCTUnwrap(legacy.createCGImage(input, from: region))
                        let actual = try configuration.render(input, from: region)
                        try assertSame(actual, expected)
                        let unmodified = try XCTUnwrap(legacy.createCGImage(CIImage(cgImage: source), from: region))
                        XCTAssertNotEqual(try rows(actual), try rows(unmodified))
                    }
                }
                assertCounts(configuration, attempts: 4, published: 4, failures: 0)
            }
            XCTAssertEqual(try rows(source), original)
            XCTAssertEqual(source.colorSpace?.copyICCData() as Data?, profile)
        }
    }

    func testLargerRealEffectsKeepExactPixelsAndMetadata() throws {
        // Exercises a larger filter graph without interpreting its scratch usage
        // or duration as an RSS bound. Native timing remains an external gate.
        let source = try pattern(width: 1537, height: 1025)
        let reference = EffectContextConfiguration(policy: .reference)
        let candidate = EffectContextConfiguration(policy: .memory32)
        let region = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        for tool in [ImageEditorTool.blur, .pixelate] {
            let input = filtered(source, tool: tool, region: region)
            try assertSame(candidate.render(input, from: region), reference.render(input, from: region))
        }
        assertCounts(reference, attempts: 2, published: 2, failures: 0)
        assertCounts(candidate, attempts: 2, published: 2, failures: 0)
    }

    func testWholeEditorEffectsPreserveSourcePixelsAndFinalOutput() throws {
        let source = try pattern(), original = try rows(source)
        let legacy = CIContext(options: [.cacheIntermediates: false])
        let marks = [annotation(.blur, CGRect(x: 3, y: 5, width: 77, height: 61)),
                     annotation(.pixelate, CGRect(x: 43, y: 31, width: 79, height: 67))]
        let expected = try XCTUnwrap(ImageEditorRenderer.render(image: source, annotations: marks,
            drawingRaster: .init(strategy: .ownedSRGB8), rendererStorage: .init(strategy: .native),
            effectPatchRenderer: { legacy.createCGImage($0, from: $1) }))
        for policy in EffectContextPolicy.allCases {
            let configuration = EffectContextConfiguration(policy: policy)
            let actual = try XCTUnwrap(ImageEditorRenderer.render(image: source, annotations: marks,
                drawingRaster: .init(strategy: .ownedSRGB8), rendererStorage: .init(strategy: .native),
                effectPatchRenderer: configuration.renderEffectPatch))
            try assertSame(actual, expected)
            assertCounts(configuration, attempts: 2, published: 2, failures: 0)
        }
        XCTAssertEqual(try rows(source), original)
    }

    func testRetainedPatchSurvivesLaterRendersAndConfigurationRelease() throws {
        for policy in EffectContextPolicy.allCases {
            let retained: (CGImage, Data) = try autoreleasepool {
                let configuration = EffectContextConfiguration(policy: policy)
                let source = try pattern()
                let region = CGRect(x: 9, y: 11, width: 97, height: 79)
                let first = try configuration.render(filtered(source, tool: .blur, region: region), from: region)
                let original = try rows(first)
                for index in 0..<16 {
                    try autoreleasepool {
                        let later = try pattern(width: 65 + index, height: 49 + index, seed: index + 1)
                        let extent = CGRect(x: 0, y: 0, width: later.width, height: later.height)
                        _ = try configuration.render(filtered(later, tool: index.isMultiple(of: 2) ? .pixelate : .blur,
                                                              region: extent), from: extent)
                        XCTAssertEqual(try rows(first), original)
                    }
                }
                assertCounts(configuration, attempts: 17, published: 17, failures: 0)
                return (first, original)
            }
            // Only the immutable patch and a copied byte oracle escape the pool;
            // no provider.data observation temporary is kept alive here.
            try autoreleasepool { XCTAssertEqual(try rows(retained.0), retained.1) }
        }
    }

    func testInvalidConfigurationAndInjectedFailureReturnNoPatch() throws {
        let source = try pattern(), input = CIImage(cgImage: source), region = input.extent
        let invalid = EffectContextConfiguration(environment: smoke("memory64"))
        XCTAssertThrowsError(try invalid.render(input, from: region)) {
            XCTAssertEqual($0 as? EffectContextConfiguration.Failure, .invalidConfiguration)
        }
        XCTAssertNil(invalid.renderEffectPatch(input, region))
        assertCounts(invalid, attempts: 2, published: 0, failures: 2, contexts: 0)
        for policy in EffectContextPolicy.allCases {
            let failed = EffectContextConfiguration(policy: policy, failureInjection: .render)
            XCTAssertThrowsError(try failed.render(input, from: region)) {
                XCTAssertEqual($0 as? EffectContextConfiguration.Failure, .injectedRender)
            }
            XCTAssertNil(failed.renderEffectPatch(input, region))
            assertCounts(failed, attempts: 2, published: 0, failures: 2)
        }
    }

    func testActualCoreImageEmptyRegionFailureReturnsNoPatch() throws {
        let input = CIImage(cgImage: try pattern())
        let legacy = CIContext(options: [.cacheIntermediates: false])
        XCTAssertNil(legacy.createCGImage(input, from: .zero))
        for policy in EffectContextPolicy.allCases {
            let configuration = EffectContextConfiguration(policy: policy)
            XCTAssertThrowsError(try configuration.render(input, from: .zero)) {
                XCTAssertEqual($0 as? EffectContextConfiguration.Failure, .renderFailed)
            }
            XCTAssertNil(configuration.renderEffectPatch(input, .zero))
            assertCounts(configuration, attempts: 2, published: 0, failures: 2)
        }
    }

    func testInvalidPolicyReachesExistingFailClosedEditorPath() throws {
        let source = try pattern(), original = try rows(source)
        let invalid = EffectContextConfiguration(environment: ["PICSHOT_EFFECT_CONTEXT_POLICY": "memory32"])
        let storage = RendererStorageConfiguration(strategy: .native)
        let marks = [annotation(.blur, CGRect(x: 7, y: 9, width: 91, height: 73))]
        XCTAssertThrowsError(try RendererStorage.render(image: source, annotations: marks,
            configuration: storage, drawingRaster: .init(strategy: .ownedSRGB8),
            effectPatchRenderer: invalid.renderEffectPatch)) {
            XCTAssertEqual($0 as? RendererStorage.Failure, .annotationFailed)
        }
        XCTAssertNil(ImageEditorRenderer.render(image: source, annotations: marks,
            drawingRaster: .init(strategy: .ownedSRGB8), rendererStorage: storage,
            effectPatchRenderer: invalid.renderEffectPatch))
        assertCounts(invalid, attempts: 2, published: 0, failures: 2, contexts: 0)
        XCTAssertEqual(storage.tracker.snapshot().publishCount, 0)
        XCTAssertEqual(storage.tracker.snapshot().failureCount, 2)
        XCTAssertEqual(try rows(source), original)
    }

    func testFailureAfterSuccessfulEffectDiscardsIncompleteFinalOutput() throws {
        let source = try pattern(), original = try rows(source)
        let marks = [annotation(.blur, CGRect(x: 7, y: 9, width: 79, height: 67)),
                     annotation(.pixelate, CGRect(x: 43, y: 31, width: 71, height: 59))]
        for policy in EffectContextPolicy.allCases {
            let valid = EffectContextConfiguration(policy: policy)
            let failed = EffectContextConfiguration(policy: policy, failureInjection: .render)
            let storage = RendererStorageConfiguration(strategy: .native)
            var calls = 0
            XCTAssertNil(ImageEditorRenderer.render(image: source, annotations: marks,
                drawingRaster: .init(strategy: .ownedSRGB8), rendererStorage: storage,
                effectPatchRenderer: { input, region in
                    calls += 1
                    return (calls == 1 ? valid : failed).renderEffectPatch(input, region)
                }))
            XCTAssertEqual(calls, 2)
            assertCounts(valid, attempts: 1, published: 1, failures: 0)
            assertCounts(failed, attempts: 1, published: 0, failures: 1)
            XCTAssertEqual(storage.tracker.snapshot().publishCount, 0)
            XCTAssertEqual(storage.tracker.snapshot().failureCount, 1)
        }
        XCTAssertEqual(try rows(source), original)
    }

    func testBoundedConcurrentUseSharesOneContextAndExactScalarTotals() throws {
        let source = try pattern(), region = CGRect(x: 3, y: 5, width: 113, height: 89)
        let legacy = CIContext(options: [.cacheIntermediates: false])
        let input = filtered(source, tool: .blur, region: region)
        let expected = try rows(XCTUnwrap(legacy.createCGImage(input, from: region)))
        for policy in EffectContextPolicy.allCases {
            let configuration = EffectContextConfiguration(policy: policy), observed = EffectContextTestCounts()
            DispatchQueue.concurrentPerform(iterations: 12) { _ in
                guard let result = configuration.renderEffectPatch(input, region),
                      let bytes = try? self.rows(result), bytes == expected else { observed.fail(); return }
                observed.succeed()
            }
            XCTAssertEqual(observed.snapshot().successes, 12)
            XCTAssertEqual(observed.snapshot().failures, 0)
            assertCounts(configuration, attempts: 12, published: 12, failures: 0)
            let encoded = try JSONEncoder().encode(configuration.tracker.snapshot())
            XCTAssertLessThan(encoded.count, 512)
            XCTAssertEqual(try JSONDecoder().decode(EffectContextSnapshot.self, from: encoded), configuration.tracker.snapshot())
        }
    }

    private func smoke(_ policy: String) -> [String: String] {
        ["PICSHOT_EFFECT_CONTEXT_POLICY": policy, "PICSHOT_SMOKE_TEST": "1", "PICSHOT_SMOKE_REPORT": "/tmp/effect-context-report.json"]
    }
    private func assertInvalid(_ environment: [String: String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try EffectContextConfiguration.selection(environment: environment), file: file, line: line) {
            XCTAssertEqual($0 as? EffectContextConfiguration.Failure, .invalidConfiguration, file: file, line: line)
        }
        let configuration = EffectContextConfiguration(environment: environment)
        XCTAssertThrowsError(try configuration.selectedPolicy(), file: file, line: line)
        XCTAssertEqual(configuration.tracker.snapshot().contextCount, 0, file: file, line: line)
    }
    private func assertCounts(_ configuration: EffectContextConfiguration, attempts: Int, published: Int, failures: Int,
                              contexts: Int = 1, file: StaticString = #filePath, line: UInt = #line) {
        let counts = configuration.tracker.snapshot()
        XCTAssertEqual(counts.contextCount, contexts, file: file, line: line)
        XCTAssertEqual(counts.attemptCount, attempts, file: file, line: line)
        XCTAssertEqual(counts.publishCount, published, file: file, line: line)
        XCTAssertEqual(counts.failureCount, failures, file: file, line: line)
        XCTAssertEqual(counts.attemptCount, counts.publishCount + counts.failureCount, file: file, line: line)
        XCTAssertEqual(counts.configuredMemoryTargetMegabytes,
                       (try? configuration.selectedPolicy())?.configuredMemoryTargetMegabytes, file: file, line: line)
        XCTAssertEqual(counts.configuredCacheIntermediates, contexts == 0 ? nil : false, file: file, line: line)
        XCTAssertEqual(counts.contextOptionCount, (try? configuration.selectedPolicy())?.contextOptions.count ?? 0,
                       file: file, line: line)
    }
    private func filtered(_ source: CGImage, tool: ImageEditorTool, region: CGRect) -> CIImage {
        let input = CIImage(cgImage: source)
        let result = tool == .blur
            ? input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 9])
            : input.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: 12, kCIInputCenterKey: CIVector(x: 0, y: 0)])
        return result.cropped(to: region)
    }
    private func annotation(_ tool: ImageEditorTool, _ rect: CGRect) -> ImageAnnotation {
        ImageAnnotation(tool: tool, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)], lineWidth: 3)
    }
    func testMeaningfulRowsAcceptExactVisibleExtentWithoutFinalPadding() throws {
        let expected = Data((Array(0..<8) + Array(16..<24) + Array(32..<40)).map { UInt8($0) })
        let minimal = Data((0..<40).map { UInt8($0) })
        XCTAssertEqual(try meaningfulRows(minimal, width: 2, height: 3, bitsPerPixel: 32, bytesPerRow: 16), expected)
        var padded = minimal
        padded.append(Data(repeating: 0xEF, count: 8))
        XCTAssertEqual(try meaningfulRows(padded, width: 2, height: 3, bitsPerPixel: 32, bytesPerRow: 16), expected)
        XCTAssertEqual(try meaningfulRows(Data([1, 2, 3, 4]), width: 1, height: 1, bitsPerPixel: 32, bytesPerRow: 32), Data([1, 2, 3, 4]))
    }

    func testMeaningfulRowsRejectMissingPixelBytesInvalidStrideAndOverflow() {
        XCTAssertThrowsError(try meaningfulRows(Data(repeating: 0, count: 39), width: 2, height: 3, bitsPerPixel: 32, bytesPerRow: 16))
        XCTAssertThrowsError(try meaningfulRows(Data(repeating: 0, count: 48), width: 2, height: 3, bitsPerPixel: 32, bytesPerRow: 7))
        XCTAssertThrowsError(try meaningfulRows(Data(), width: 0, height: 3, bitsPerPixel: 32, bytesPerRow: 16))
        XCTAssertThrowsError(try meaningfulRows(Data(), width: 1, height: 0, bitsPerPixel: 32, bytesPerRow: 16))
        XCTAssertThrowsError(try meaningfulRows(Data(), width: 1, height: 1, bitsPerPixel: 0, bytesPerRow: 16))
        XCTAssertThrowsError(try meaningfulRows(Data(), width: Int.max, height: 1, bitsPerPixel: 32, bytesPerRow: 16))
        XCTAssertThrowsError(try meaningfulRows(Data(), width: 1, height: 3, bitsPerPixel: 32, bytesPerRow: Int.max))
        XCTAssertThrowsError(try meaningfulRows(Data(), width: 1, height: 2, bitsPerPixel: 32, bytesPerRow: Int.max - 2))
    }

    private func rows(_ image: CGImage) throws -> Data {
        let bytes = try XCTUnwrap(XCTUnwrap(image.dataProvider).data) as Data
        return try meaningfulRows(bytes, width: image.width, height: image.height,
                                  bitsPerPixel: image.bitsPerPixel, bytesPerRow: image.bytesPerRow)
    }

    /// A CGImage subimage can end immediately after its final meaningful pixel.
    /// Validate every byte that will be read, without requiring unused tail padding.
    private func meaningfulRows(_ bytes: Data, width: Int, height: Int,
                                bitsPerPixel: Int, bytesPerRow: Int) throws -> Data {
        guard width > 0, height > 0, bitsPerPixel > 0 else { throw EffectContextConfiguration.Failure.renderFailed }
        let (bits, bitsOverflow) = width.multipliedReportingOverflow(by: bitsPerPixel)
        let (roundedBits, roundedOverflow) = bits.addingReportingOverflow(7)
        guard !bitsOverflow, !roundedOverflow else { throw EffectContextConfiguration.Failure.renderFailed }
        let count = roundedBits / 8
        guard bytesPerRow >= count else { throw EffectContextConfiguration.Failure.renderFailed }
        let (lastOffset, offsetOverflow) = (height - 1).multipliedReportingOverflow(by: bytesPerRow)
        let (required, sizeOverflow) = lastOffset.addingReportingOverflow(count)
        guard !offsetOverflow, !sizeOverflow, bytes.count >= required else {
            throw EffectContextConfiguration.Failure.renderFailed
        }
        var meaningful = Data()
        for y in 0..<height {
            let start = bytes.index(bytes.startIndex, offsetBy: y * bytesPerRow)
            meaningful.append(bytes[start..<bytes.index(start, offsetBy: count)])
        }
        return meaningful
    }
    private func assertSame(_ actual: CGImage, _ expected: CGImage, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(actual.width, expected.width, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, file: file, line: line)
        XCTAssertEqual(actual.bitsPerComponent, expected.bitsPerComponent, file: file, line: line)
        XCTAssertEqual(actual.bitsPerPixel, expected.bitsPerPixel, file: file, line: line)
        XCTAssertEqual(actual.bytesPerRow, expected.bytesPerRow, file: file, line: line)
        XCTAssertEqual(actual.bitmapInfo, expected.bitmapInfo, file: file, line: line)
        XCTAssertEqual(actual.alphaInfo, expected.alphaInfo, file: file, line: line)
        XCTAssertEqual(actual.colorSpace?.name, expected.colorSpace?.name, file: file, line: line)
        XCTAssertEqual(actual.colorSpace?.copyICCData() as Data?, expected.colorSpace?.copyICCData() as Data?, file: file, line: line)
        XCTAssertEqual(actual.renderingIntent, expected.renderingIntent, file: file, line: line)
        XCTAssertEqual(actual.shouldInterpolate, expected.shouldInterpolate, file: file, line: line)
        XCTAssertNil(actual.decode, file: file, line: line)
        XCTAssertFalse(actual.isMask, file: file, line: line)
        XCTAssertEqual(try rows(actual), try rows(expected), file: file, line: line)
    }
    private func pattern(width: Int = 129, height: Int = 101, seed: Int = 0, color: CGColorSpace? = nil) throws -> CGImage {
        let color = try color ?? XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let row = width * 4 + 16
        var bytes = Data(repeating: 0xB7, count: row * height)
        let alphas = [0, 1, 2, 63, 127, 254, 255]
        for y in 0..<height { for x in 0..<width {
            let a = alphas[(x + y + seed) % alphas.count], offset = y * row + x * 4
            bytes[offset] = UInt8(((x * 19 + y * 3 + seed * 17) % 256) * a / 255)
            bytes[offset + 1] = UInt8(((x * 5 + y * 23 + seed * 13) % 256) * a / 255)
            bytes[offset + 2] = UInt8(((x * 31 + y * 11 + seed * 7) % 256) * a / 255)
            bytes[offset + 3] = UInt8(a)
        } }
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: row, space: color,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: XCTUnwrap(CGDataProvider(data: bytes as CFData)), decode: nil,
            shouldInterpolate: false, intent: .relativeColorimetric))
    }
}

private final class EffectContextTestCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var successes = 0, failures = 0
    func succeed() { lock.lock(); defer { lock.unlock() }; successes += 1 }
    func fail() { lock.lock(); defer { lock.unlock() }; failures += 1 }
    func snapshot() -> (successes: Int, failures: Int) { lock.lock(); defer { lock.unlock() }; return (successes, failures) }
}
