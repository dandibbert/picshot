import XCTest
import AppKit
import PicShotCore
@testable import PicShot

final class EditableAnnotationDocumentTests: XCTestCase {
    func testEveryStoredFieldAndAllDrawableToolsRoundTripWithoutPixelOrStyleChanges() throws {
        let base = try patternedImage()
        for tool in ImageEditorTool.allCases where tool != .select && tool != .crop {
            let mark = styledMark(tool)
            let document = makeDocument([mark])
            let bytes = try EditableAnnotationDocumentCodec.encode(document)
            let reopened = try EditableAnnotationDocumentCodec.decode(bytes)
            XCTAssertEqual(reopened.annotations.count, 1)
            assertEqual(mark, reopened.annotations[0])
            XCTAssertEqual(document.documentID, reopened.documentID)
            XCTAssertEqual(try EditableAnnotationDocumentCodec.encode(reopened), bytes)
            let before = try XCTUnwrap(ImageEditorRenderer.render(image: base, annotations: [mark]))
            let after = try XCTUnwrap(ImageEditorRenderer.render(image: base, annotations: reopened.annotations))
            XCTAssertEqual(try rgba(before), try rgba(after), "Pixel identity for \(tool.rawValue)")
        }
    }

    func testJSONFieldCoverageMatchesEveryCurrentAnnotationStoredProperty() throws {
        let mark = styledMark(.pixelate, linked: true)
        let json = try object(makeDocument([mark]))
        let stored = try XCTUnwrap((json["annotations"] as? [[String: Any]])?.first)
        let properties = Set(Mirror(reflecting: mark).children.compactMap(\.label))
        XCTAssertEqual(properties, Set(stored.keys), "A newly added annotation field needs an explicit persistence decision")
        XCTAssertFalse(String(describing: json).contains("NSImage"))
        XCTAssertNil(json["imageBytes"]); XCTAssertNil(json["filename"])
    }

    func testOptionalStylesRemainNilInsteadOfBecomingDefaultsAndUnicodeIsExact() throws {
        var mark = ImageAnnotation(tool: .text, points: [CGPoint(x: 9.5, y: 13.125)])
        mark.text = "中文 👩🏽‍💻 e\u{301} \"quoted\"\\path\nline\tend\0"
        mark.numberComment = "注释 🧪"; mark.watermarkTemplate = "备份 $yyyy-MM-dd$"
        let reopened = try EditableAnnotationDocumentCodec.decode(EditableAnnotationDocumentCodec.encode(makeDocument([mark])))
        assertEqual(mark, reopened.annotations[0])
        XCTAssertNil(reopened.annotations[0].endArrowEnabled)
        XCTAssertNil(reopened.annotations[0].fontSize)
        XCTAssertNil(reopened.annotations[0].textBoxSize)
        XCTAssertNil(reopened.annotations[0].magnifierSource)
        XCTAssertNil(reopened.annotations[0].mosaicLink)
    }

    func testNamedDeviceAndExtendedColorsRoundTripExactlyAndCMYKIsRejected() throws {
        let spaces = [CGColorSpace.sRGB, CGColorSpace.displayP3, CGColorSpace.extendedSRGB,
                      CGColorSpace.extendedLinearSRGB, CGColorSpace.genericGrayGamma2_2]
        var colors = [CGColor(gray: 0.33, alpha: 0.75), CGColor(srgbRed: 0.23, green: 0.41, blue: 0.77, alpha: 0.8),
                      CGColor(red: 0.23, green: 0.41, blue: 0.77, alpha: 0.8),
                      NSColor.systemRed.cgColor, NSColor.systemBlue.cgColor, NSColor.white.cgColor]
        for name in spaces {
            let space = try XCTUnwrap(CGColorSpace(name: name))
            let values: [CGFloat] = space.numberOfComponents == 1 ? [0.72, 0.33] : [0.18, 0.67, 0.9, 0.42]
            colors.append(try XCTUnwrap(CGColor(colorSpace: space, components: values)))
        }
        let extended = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedSRGB))
        colors.append(try XCTUnwrap(CGColor(colorSpace: extended, components: [-0.125, 1.25, 0.375, 0.5])))
        let base = try patternedImage()
        for color in colors {
            var mark = styledMark(.rectangle); mark.color = color; mark.fillColor = color; mark.textOutlineColor = color
            let restored = try EditableAnnotationDocumentCodec.decode(EditableAnnotationDocumentCodec.encode(makeDocument([mark])))
            assertEqual(mark, restored.annotations[0])
            XCTAssertEqual(try rgba(XCTUnwrap(ImageEditorRenderer.render(image: base, annotations: [mark]))),
                           try rgba(XCTUnwrap(ImageEditorRenderer.render(image: base, annotations: restored.annotations))))
        }
        var mark = styledMark(.rectangle)
        mark.color = try XCTUnwrap(CGColor(colorSpace: CGColorSpaceCreateDeviceCMYK(), components: [0, 1, 1, 0, 1]))
        XCTAssertThrowsError(try EditableAnnotationDocumentCodec.encode(makeDocument([mark]))) {
            XCTAssertEqual($0 as? EditableAnnotationDocumentError, .unsupportedColor)
        }
    }

    func testGenericConstructorColorsKeepExactNamedProfilesAndComponents() throws {
        for color in [CGColor(red: 0.23, green: 0.41, blue: 0.77, alpha: 0.8), CGColor(gray: 0.33, alpha: 0.75)] {
            let space = try XCTUnwrap(color.colorSpace), name = try XCTUnwrap(space.name)
            XCTAssertTrue(CFEqual(space, try XCTUnwrap(CGColorSpace(name: name))))
            var mark = styledMark(.rectangle); mark.color = color; mark.fillColor = color; mark.textOutlineColor = color
            let document = makeDocument([mark])
            let json = try object(document)
            let annotation = try XCTUnwrap((json["annotations"] as? [[String: Any]])?.first)
            for key in ["color", "fillColor", "textOutlineColor"] {
                let stored = try XCTUnwrap(annotation[key] as? [String: Any])
                XCTAssertEqual(stored["space"] as? String, name as String)
            }
            let decoded = try EditableAnnotationDocumentCodec.decode(EditableAnnotationDocumentCodec.encode(document))
            assertEqual(mark, try XCTUnwrap(decoded.annotations.first))
            XCTAssertEqual(decoded.annotations[0].color.components, color.components)
        }
    }

    func testLinkedMosaicIdentityExclusionsAndDeletedRootsRoundTrip() throws {
        var root = styledMark(.pixelate, linked: true)
        var peer = root; peer.id = UUID(); peer.points = [CGPoint(x: 85, y: 25), CGPoint(x: 115, y: 45)]
        peer.mosaicLink?.target = CGRect(x: 85, y: 25, width: 30, height: 20)
        root.mosaicLink?.includedTargets.append(peer.mosaicLink!.target)
        peer.mosaicLink?.includedTargets = root.mosaicLink!.includedTargets
        var correction = root; correction.id = UUID(); correction.mosaicLink?.additionID = UUID()
        correction.points = [CGPoint(x: 30, y: 30), CGPoint(x: 38, y: 38)]
        let marks = [root, peer, correction]
        let result = try EditableAnnotationDocumentCodec.decode(EditableAnnotationDocumentCodec.encode(makeDocument(marks)))
        for (a, b) in zip(marks, result.annotations) { assertEqual(a, b) }
        // Deletion can leave only additions, retaining a historical root UUID.
        let orphan = try EditableAnnotationDocumentCodec.decode(EditableAnnotationDocumentCodec.encode(makeDocument([correction])))
        assertEqual(correction, orphan.annotations[0])
        var bad = peer; bad.mosaicLink?.rootAdditionID = UUID()
        XCTAssertThrowsError(try EditableAnnotationDocumentCodec.encode(makeDocument([root, bad])))
        var otherGroup = correction; otherGroup.mosaicLink?.groupID = UUID()
        XCTAssertThrowsError(try EditableAnnotationDocumentCodec.encode(makeDocument([root, otherGroup])))
    }

    func testNumberSequenceIncludingExhaustionAndGapClosingRoundTrips() throws {
        for exhausted in [false, true] {
            var doc = makeDocument([styledMark(.number)])
            doc.numberSequence.setNext(exhausted ? NumberedCalloutSequence.maximumValue : 73)
            if exhausted { doc.numberSequence.didInsert(NumberedCalloutSequence.maximumValue) }
            doc.numberSequence.closesGapsOnDelete = true
            let restored = try EditableAnnotationDocumentCodec.decode(EditableAnnotationDocumentCodec.encode(doc))
            XCTAssertEqual(restored.numberSequence, doc.numberSequence)
        }
        var bad = try object(makeDocument([]))
        bad["numberSequence"] = ["nextValue": 2, "isExhausted": true, "closesGapsOnDelete": false]
        XCTAssertThrowsError(try decodeObject(bad))
    }

    func testViewportCropDecorationAndCaptureMetadataPreserveFullBaseCoordinatesAndPixels() throws {
        let base = try patternedImage()
        var doc = makeDocument([styledMark(.rectangle), styledMark(.text), styledMark(.magnifier)])
        doc.baseProvenance = .originalCapture
        doc.cropViewportInBase = CGRect(x: 17, y: 11, width: 91, height: 73)
        doc.capturedAt = Date(timeIntervalSinceReferenceDate: 812_345_678.123456)
        doc.captureTimeZoneIdentifier = "Asia/Shanghai"; doc.captureTimestampKnown = true
        doc.outputDecoration = ImageOutputDecoration(enabled: true, cornerRadius: 7.125,
            borderEnabled: true, borderWidth: 1.5, borderColor: .init(red: 0.2, green: 0.7, blue: 0.4, alpha: 0.8),
            shadowEnabled: true, shadowBlur: 2.5, shadowOffsetX: -3.25, shadowOffsetY: 4.75, shadowOpacity: 0.45)
        let restored = try EditableAnnotationDocumentCodec.decode(EditableAnnotationDocumentCodec.encode(doc))
        XCTAssertEqual(restored.cropViewportInBase, doc.cropViewportInBase)
        XCTAssertEqual(restored.capturedAt, doc.capturedAt)
        XCTAssertEqual(restored.captureTimeZoneIdentifier, doc.captureTimeZoneIdentifier)
        XCTAssertEqual(restored.captureTimestampKnown, doc.captureTimestampKnown)
        XCTAssertEqual(restored.baseProvenance, .originalCapture)
        XCTAssertEqual(restored.outputDecoration, doc.outputDecoration)
        for (a, b) in zip(doc.annotations, restored.annotations) { assertEqual(a, b) }
        let before = try projected(doc, base: base), after = try projected(restored, base: base)
        XCTAssertEqual(try rgba(before), try rgba(after))
        XCTAssertEqual(try restored.expectedOutputPixelSize(), CGSize(width: before.width, height: before.height))
        let payload = EditableCapturePayload(document: restored, originalImage: base, baseImage: base)
        XCTAssertNoThrow(try payload.validate(currentImage: before))
        XCTAssertThrowsError(try payload.validate(currentImage: base))
    }

    func testReferencesDimensionsCropProvenanceAndImageIdentityAreValidated() throws {
        let base = try patternedImage(), separate = try patternedImage()
        var doc = makeDocument([])
        XCTAssertNoThrow(try EditableCapturePayload(document: doc, originalImage: base, baseImage: base).validate())
        XCTAssertThrowsError(try EditableCapturePayload(document: doc, originalImage: base, baseImage: separate).validate())
        XCTAssertThrowsError(try doc.validateAssetReferences(originalID: UUID(), baseID: doc.baseAssetID,
            originalWidth: 160, originalHeight: 120, baseWidth: 160, baseHeight: 120))
        doc.baseAssetID = UUID(); doc.basePixelWidth = 90; doc.basePixelHeight = 70
        doc.baseCropInOriginal = CGRect(x: 10, y: 20, width: 90, height: 70); doc.baseProvenance = .derivedRaster
        let restored = try EditableAnnotationDocumentCodec.decode(EditableAnnotationDocumentCodec.encode(doc))
        XCTAssertEqual(restored.baseCropInOriginal, doc.baseCropInOriginal)
        XCTAssertEqual(restored.baseProvenance, .derivedRaster)
        doc.baseCropInOriginal = CGRect(x: 100, y: 20, width: 90, height: 70)
        XCTAssertThrowsError(try doc.validate())
        doc.baseCropInOriginal = nil; doc.baseAssetID = doc.originalAssetID
        XCTAssertThrowsError(try doc.validate())
        for rect in [CGRect(x: -1, y: 0, width: 3, height: 3), CGRect(x: 1.5, y: 0, width: 3, height: 3),
                     CGRect(x: 0, y: 0, width: 0, height: 3), CGRect(x: 0, y: 0, width: 161, height: 120)] {
            var value = makeDocument([]); value.cropViewportInBase = rect
            XCTAssertThrowsError(try value.validate())
        }
    }

    func testUnsupportedVersionsUnknownFieldsMissingFieldsDuplicateKeysAndTruncationAreRejected() throws {
        let doc = makeDocument([styledMark(.text)])
        let good = try EditableAnnotationDocumentCodec.encode(doc)
        for value in [0, 2, "1", 1.5] as [Any] {
            var bad = try object(doc); bad["version"] = value
            XCTAssertThrowsError(try decodeObject(bad))
        }
        for key in ["format", "coordinates", "baseProvenance"] {
            var bad = try object(doc); bad[key] = "future-or-invalid"
            XCTAssertThrowsError(try decodeObject(bad))
        }
        var unknown = try object(doc); unknown["futureLayers"] = []
        XCTAssertThrowsError(try decodeObject(unknown))
        var missing = try object(doc); missing.removeValue(forKey: "numberSequence")
        XCTAssertThrowsError(try decodeObject(missing))
        let text = String(decoding: good, as: UTF8.self)
        XCTAssertThrowsError(try EditableAnnotationDocumentCodec.decode(Data(("{\"version\":1," + text.dropFirst()).utf8)))
        XCTAssertThrowsError(try EditableAnnotationDocumentCodec.decode(Data(text.replacingOccurrences(of: "\"version\"", with: "\"vers\\u0069on\"").utf8)))
        XCTAssertThrowsError(try EditableAnnotationDocumentCodec.decode(good + Data("{}".utf8)))
        for length in [0, 1, good.count / 2, good.count - 1] {
            XCTAssertThrowsError(try EditableAnnotationDocumentCodec.decode(Data(good.prefix(length))))
        }
    }

    func testInvalidUTF8AndLoneSurrogatesAreRejectedWithoutReplacementText() throws {
        let bytes = try EditableAnnotationDocumentCodec.encode(makeDocument([styledMark(.text)]))
        let text = String(decoding: bytes, as: UTF8.self)
        for escaped in ["\\uD800", "\\uDC00", "\\uD800\\u0041"] {
            let bad = text.replacingOccurrences(of: "Hello 中文", with: escaped)
            XCTAssertThrowsError(try EditableAnnotationDocumentCodec.decode(Data(bad.utf8)))
        }
        let needle = Data("Hello 中文".utf8)
        let range = try XCTUnwrap(bytes.range(of: needle))
        for invalid in [[0xC0, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0x80]] as [[UInt8]] {
            var bad = bytes; bad.replaceSubrange(range, with: invalid)
            XCTAssertThrowsError(try EditableAnnotationJSONPreflight.validate(bad))
        }
        let surrogatePair = text.replacingOccurrences(of: "Hello 中文", with: "\\uD83D\\uDE00")
        XCTAssertEqual(try EditableAnnotationDocumentCodec.decode(Data(surrogatePair.utf8)).annotations[0].text, "😀")
    }

    func testMalformedNumbersGeometryEnumValuesAndColorsAreRejected() throws {
        let doc = makeDocument([styledMark(.text)])
        for (key, value) in [("tool", "futureTool"), ("lineCap", "hexagonal"), ("opacity", 1.1),
            ("points", [[1, 2, 3]]), ("points", [[1_000_001, 2]]), ("freehandCorners", [9]),
            ("magnifierScale", 9), ("fontName", String(repeating: "x", count: 257)),
            ("frozenTimeZoneIdentifier", "invalid/timezone"), ("frozenTimestamp", 1e100)] as [(String, Any)] {
            var json = try object(doc); var marks = try XCTUnwrap(json["annotations"] as? [[String: Any]])
            marks[0][key] = value; json["annotations"] = marks
            XCTAssertThrowsError(try decodeObject(json), "\(key)")
        }
        for color in [["space": "untrusted-profile", "components": [0, 0, 0, 1]],
            ["space": "device-rgb", "components": [0, 0, 0, 2]], ["space": "device-gray", "components": [0, 0, 1]]] as [[String: Any]] {
            var json = try object(doc); var marks = try XCTUnwrap(json["annotations"] as? [[String: Any]])
            marks[0]["color"] = color; json["annotations"] = marks
            XCTAssertThrowsError(try decodeObject(json))
        }
        var mark = styledMark(.text); mark.rotation = .nan
        XCTAssertThrowsError(try EditableAnnotationDocumentCodec.encode(makeDocument([mark])))
        let text = String(decoding: try EditableAnnotationDocumentCodec.encode(doc), as: UTF8.self)
        for value in ["1e999", "NaN", "Infinity", "01", "1.", "1e+", String(repeating: "9", count: 65)] {
            let bad = text.replacingOccurrences(of: "\"basePixelWidth\":160", with: "\"basePixelWidth\":\(value)")
            XCTAssertNotEqual(bad, text)
            XCTAssertThrowsError(try EditableAnnotationDocumentCodec.decode(Data(bad.utf8)))
        }
    }

    func testDecodedMagnifierRejectsSubnormalSourceAxesAndTranslationOverflowAfterPreflight() throws {
        var mark = styledMark(.magnifier)
        mark.points = [CGPoint(x: 12.25, y: 10.5), CGPoint(x: 112.25, y: 110.5)]
        let good = try object(makeDocument([mark]))
        // All tokens, coordinates, bytes and schema are admissible to preflight.
        // The first two cases overflow an axis ratio; the final two have finite
        // ratios whose source-origin multiplication overflows the translation.
        let cases: [(Double, Double, Double, Double)] = [
            (0, 0, 1e-320, 10), (0, 0, 10, 1e-320),
            (1_000_000, 0, 1e-302, 10), (0, 1_000_000, 10, 1e-302)
        ]
        for (index, item) in cases.enumerated() {
            let (x, y, width, height) = item
            let sx = 100 / width, sy = 100 / height
            if index < 2 { XCTAssertFalse(sx.isFinite && sy.isFinite) }
            else {
                XCTAssertTrue(sx.isFinite && sy.isFinite)
                XCTAssertFalse((12.25 - x * sx).isFinite && (10.5 - y * sy).isFinite)
            }
            var bad = good; var marks = try XCTUnwrap(good["annotations"] as? [[String: Any]])
            marks[0]["magnifierSource"] = [[x, y], [width, height]]; bad["annotations"] = marks
            let bytes = try JSONSerialization.data(withJSONObject: bad, options: [.sortedKeys])
            XCTAssertNoThrow(try EditableAnnotationJSONPreflight.validate(bytes))
            XCTAssertThrowsError(try EditableAnnotationDocumentCodec.decode(bytes)) {
                XCTAssertEqual($0 as? EditableAnnotationDocumentError, .invalidDocument)
            }
        }
    }

    func testDecodedMagnifierRejectsUnusableSourceAndFallbackLensSizesAfterPreflight() throws {
        let good = try object(makeDocument([styledMark(.magnifier)]))
        let cases: [([[Double]], Any)] = [
            ([[10, 10], [110, 110]], [[0, 0], [0, 10]]),
            ([[10, 10], [110, 110]], [[0, 0], [10, 1]]),
            ([[10, 10], [10.5, 110]], [[0, 0], [10, 10]]),
            ([[10, 10], [110, 11.5]], [[0, 0], [10, 10]]),
            ([[10, 10], [10, 110]], NSNull()),
            ([[10, 10], [110, 10]], NSNull())
        ]
        for (points, source) in cases {
            var bad = good; var marks = try XCTUnwrap(good["annotations"] as? [[String: Any]])
            marks[0]["points"] = points; marks[0]["magnifierSource"] = source; bad["annotations"] = marks
            let bytes = try JSONSerialization.data(withJSONObject: bad, options: [.sortedKeys])
            XCTAssertNoThrow(try EditableAnnotationJSONPreflight.validate(bytes))
            XCTAssertThrowsError(try EditableAnnotationDocumentCodec.decode(bytes)) {
                XCTAssertEqual($0 as? EditableAnnotationDocumentError, .invalidDocument)
            }
        }
    }

    func testMagnifierFractionalGeometryAndFallbackSourceRetainUsableExactSamplingAndPixels() throws {
        let base = try patternedImage()
        var fractional = styledMark(.magnifier)
        fractional.points = [CGPoint(x: 20.125, y: 30.375), CGPoint(x: 22.625, y: 33.875)]
        fractional.magnifierSource = CGRect(x: 5.375, y: 7.125, width: 1.25, height: 1.75)
        var fallback = fractional; fallback.magnifierSource = nil
        let maximumUILens = fractional.resizedMagnifierLens(scale: 8)
        var translatedMinimum = fractional
        translatedMinimum.points = [CGPoint(x: 1.0000000000000002 - 1, y: 0),
                                    CGPoint(x: 1.0000000000000002 + 1, y: 2)]
        for mark in [fractional, fallback, maximumUILens, translatedMinimum] {
            let decoded = try EditableAnnotationDocumentCodec.decode(EditableAnnotationDocumentCodec.encode(makeDocument([mark])))
            let restored = try XCTUnwrap(decoded.annotations.first)
            assertEqual(mark, restored)
            let lens = restored.localBounds, source = restored.magnifierSourceRect
            let sx = lens.width / source.width, sy = lens.height / source.height
            let sampling = CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                tx: lens.minX - source.minX * sx, ty: lens.minY - source.minY * sy)
            let inverse = sampling.inverted()
            XCTAssertTrue([sx, sy, sampling.tx, sampling.ty, inverse.a, inverse.d, inverse.tx, inverse.ty].allSatisfy(\.isFinite))
            XCTAssertGreaterThan(sx, 0); XCTAssertGreaterThan(sy, 0)
            let extent = CGRect(x: 0, y: 0, width: base.width, height: base.height).applying(sampling)
            XCTAssertTrue([extent.minX, extent.minY, extent.maxX, extent.maxY, extent.width, extent.height].allSatisfy(\.isFinite))
            XCTAssertGreaterThan(extent.width, 0); XCTAssertGreaterThan(extent.height, 0)
            XCTAssertEqual(try rgba(XCTUnwrap(ImageEditorRenderer.render(image: base, annotations: [mark]))),
                           try rgba(XCTUnwrap(ImageEditorRenderer.render(image: base, annotations: [restored]))))
        }
    }

    func testBoundsRejectOversizeBeforeDecodingAndDoNotTruncateValidMaximumStroke() throws {
        XCTAssertThrowsError(try EditableAnnotationDocumentCodec.decode(Data(repeating: 32,
            count: EditableAnnotationDocumentCodec.maximumFileBytes + 1))) {
            XCTAssertEqual($0 as? EditableAnnotationDocumentError, .tooLarge)
        }
        var mark = styledMark(.freehand)
        mark.points = (0..<ImageAnnotation.maximumGesturePoints).map { CGPoint(x: $0 % 150, y: $0 % 110) }
        mark.freehandCorners = Array(mark.points.indices)
        let doc = makeDocument([mark])
        let restored = try EditableAnnotationDocumentCodec.decode(EditableAnnotationDocumentCodec.encode(doc))
        assertEqual(mark, restored.annotations[0])
        mark.points.append(.zero)
        XCTAssertThrowsError(try EditableAnnotationDocumentCodec.encode(makeDocument([mark])))
        var many = (0...EditableAnnotationDocumentCodec.maximumAnnotations).map { _ in styledMark(.rectangle) }
        XCTAssertThrowsError(try EditableAnnotationDocumentCodec.encode(makeDocument(many)))
        many = (0..<65).map { _ in var value = restored.annotations[0]; value.id = UUID(); return value }
        XCTAssertThrowsError(try EditableAnnotationDocumentCodec.encode(makeDocument(many)))
        var long = styledMark(.text); long.text = String(repeating: "😀", count: 8_193)
        XCTAssertThrowsError(try EditableAnnotationDocumentCodec.encode(makeDocument([long])))
        long.text = String(repeating: "e\u{301}", count: 8_192)
        XCTAssertNoThrow(try EditableAnnotationDocumentCodec.encode(makeDocument([long])))
        var json = try object(doc); var marks = try XCTUnwrap(json["annotations"] as? [[String: Any]])
        marks[0]["points"] = Array(repeating: [0, 0], count: 2_049); json["annotations"] = marks
        XCTAssertThrowsError(try decodeObject(json))
        let nested = "{\"annotations\":" + String(repeating: "[", count: 1000) + "0" + String(repeating: "]", count: 1000) + "}"
        XCTAssertThrowsError(try EditableAnnotationDocumentCodec.decode(Data(nested.utf8)))
    }

    func testPreflightRejectsAggregatePointsAndUnknownNestedFieldsBeforeModelDecoding() throws {
        var mark = styledMark(.freehand)
        mark.points = Array(repeating: CGPoint(x: 10, y: 20), count: 2_048)
        let json = try object(makeDocument([mark]))
        let wireMark = try XCTUnwrap((json["annotations"] as? [[String: Any]])?.first)
        var excessive = json
        excessive["annotations"] = Array(repeating: wireMark, count: 65)
        let bytes = try JSONSerialization.data(withJSONObject: excessive)
        XCTAssertLessThan(bytes.count, EditableAnnotationDocumentCodec.maximumFileBytes)
        XCTAssertThrowsError(try EditableAnnotationJSONPreflight.validate(bytes)) {
            XCTAssertEqual($0 as? EditableAnnotationDocumentError, .tooLarge)
        }
        var unknown = wireMark; unknown["numberSequence"] = ["nextValue": 1]
        var bad = json; bad["annotations"] = [unknown]
        XCTAssertThrowsError(try EditableAnnotationJSONPreflight.validate(JSONSerialization.data(withJSONObject: bad)))
        var tooManyTargets = styledMark(.pixelate, linked: true)
        tooManyTargets.mosaicLink?.excludedTargets = (0..<25).map { CGRect(x: $0 * 2, y: 80, width: 1, height: 1) }
        XCTAssertThrowsError(try makeDocument([tooManyTargets]).validate())
    }

    func testDuplicateIDsInvalidMosaicReferencesAndUnsafeSizesAreRejected() throws {
        let mark = styledMark(.rectangle)
        XCTAssertThrowsError(try EditableAnnotationDocumentCodec.encode(makeDocument([mark, mark])))
        for size in [(-1, 120), (0, 120), (Int.max, 120), (32_768, 32_768)] {
            var doc = makeDocument([]); doc.basePixelWidth = size.0; doc.basePixelHeight = size.1
            XCTAssertThrowsError(try doc.validate())
        }
        var linked = styledMark(.pixelate, linked: true)
        let duplicate = linked.mosaicLink!.target
        linked.mosaicLink?.excludedTargets.append(duplicate)
        XCTAssertThrowsError(try makeDocument([linked]).validate())
        linked = styledMark(.pixelate, linked: true); linked.mosaicLink?.includedTargets = Array(repeating: .zero, count: 26)
        XCTAssertThrowsError(try makeDocument([linked]).validate())
        linked = styledMark(.text, linked: true)
        XCTAssertThrowsError(try makeDocument([linked]).validate())
    }

    func testBoundedFileReaderRejectsOversizedOrCorruptFilesWithoutChangingSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("annotations.json")
        let data = try EditableAnnotationDocumentCodec.encode(makeDocument([styledMark(.rectangle)]))
        try data.write(to: url)
        let decoded = try EditableAnnotationDocumentCodec.read(from: url)
        XCTAssertEqual(try EditableAnnotationDocumentCodec.encode(decoded), data)
        XCTAssertEqual(try Data(contentsOf: url), data)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(EditableAnnotationDocumentCodec.maximumFileBytes + 1)); try handle.close()
        XCTAssertThrowsError(try EditableAnnotationDocumentCodec.read(from: url)) {
            XCTAssertEqual($0 as? EditableAnnotationDocumentError, .tooLarge)
        }
    }

    private func makeDocument(_ marks: [ImageAnnotation]) -> EditableAnnotationDocument {
        let id = UUID()
        return EditableAnnotationDocument(originalAssetID: id, originalPixelWidth: 160, originalPixelHeight: 120,
            baseAssetID: id, basePixelWidth: 160, basePixelHeight: 120, annotations: marks)
    }
    private func object(_ document: EditableAnnotationDocument) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: EditableAnnotationDocumentCodec.encode(document)) as? [String: Any])
    }
    private func decodeObject(_ object: [String: Any]) throws -> EditableAnnotationDocument {
        try EditableAnnotationDocumentCodec.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
    private func styledMark(_ tool: ImageEditorTool, linked: Bool = false) -> ImageAnnotation {
        var value = ImageAnnotation(tool: tool, points: [CGPoint(x: 25.125, y: 22.75), CGPoint(x: 95.5, y: 78.25)])
        value.color = CGColor(srgbRed: 0.125, green: 0.625, blue: 0.875, alpha: 0.8125)
        value.lineWidth = 5.25; value.text = "Hello 中文"; value.number = 37; value.numberStyle = .roman
        value.numberComment = "备注 🧪"; value.numberCommentSize = CGSize(width: 61.5, height: 32.25)
        value.rotation = .pi / 7; value.opacity = 0.625; value.strokeStyle = .dashed
        value.lineCap = .square; value.lineJoin = .bevel; value.startArrowEnabled = true; value.endArrowEnabled = false
        value.startArrowhead = .diamond; value.endArrowhead = .filledTriangle; value.fillEnabled = true
        value.fillColor = CGColor(gray: 0.75, alpha: 0.375); value.cornerRadius = 9.75
        value.fontName = "Helvetica"; value.fontSize = 17.25; value.bold = true; value.italic = true; value.underline = true
        value.textOutlineEnabled = true; value.textOutlineColor = CGColor(gray: 0.25, alpha: 0.75)
        value.textOutlineWidth = 1.25; value.textBoxSize = CGSize(width: 81.5, height: 37.5)
        value.eraserMode = .rectangle; value.spotlightShape = .rectangle; value.spotlightDim = 0.3125
        value.spotlightBorder = false; value.watermarkPlacement = .topCenter; value.watermarkSpacing = 29.5
        value.watermarkTemplate = "PicShot $yyyy-MM-dd HH:mm$"; value.frozenTimestamp = Date(timeIntervalSinceReferenceDate: 812_345_678.123456)
        value.frozenTimeZoneIdentifier = "Asia/Shanghai"; value.timestampIsCaptureDate = true
        value.magnifierSource = CGRect(x: 3.5, y: 5.25, width: 42.5, height: 31.125)
        value.magnifierScale = 3.25; value.magnifierShape = .rectangle; value.magnifierConnector = .edges
        value.magnifierSmooth = true; value.magnifierShowsAnnotations = false; value.magnifierShadow = false
        value.arcStartAngle = -.pi / 3; value.arcSweepAngle = -.pi * 1.25
        value.freehandSmoothing = true; value.freehandConstraint = .degrees15; value.freehandCorners = [0, 1]
        value.freehandWasSimplified = true; value.highlighterMode = .freehand; value.highlighterBlend = .multiply
        if linked {
            let root = UUID(), rect = CGRect(x: 25, y: 22, width: 30, height: 20)
            value.mosaicLink = AutomaticMosaicLink(groupID: UUID(), additionID: root, rootAdditionID: root,
                target: rect, includedTargets: [rect], excludedTargets: [CGRect(x: 25, y: 65, width: 30, height: 20)], synchronizes: true)
        }
        return value
    }
    private func patternedImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 160 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in 0..<120 { for x in 0..<160 {
            context.setFillColor(CGColor(srgbRed: CGFloat(x % 31) / 31, green: CGFloat(y % 29) / 29,
                blue: CGFloat((x + y) % 23) / 23, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        return try XCTUnwrap(context.makeImage())
    }
    private func rgba(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }
    private func projected(_ doc: EditableAnnotationDocument, base: CGImage) throws -> CGImage {
        let full = try XCTUnwrap(ImageEditorRenderer.render(image: base, annotations: doc.annotations))
        let cropped = try doc.cropViewportInBase.map { try XCTUnwrap(ImageEditorRenderer.crop(image: full, to: $0)) } ?? full
        return try ImageOutputDecorationRenderer.project(flattened: cropped, decoration: doc.outputDecoration)
    }
    private func assertEqual(_ lhs: ImageAnnotation, _ rhs: ImageAnnotation,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.id, rhs.id, "id", file: file, line: line)
        XCTAssertEqual(lhs.tool, rhs.tool, "tool", file: file, line: line)
        XCTAssertEqual(lhs.points, rhs.points, "points", file: file, line: line)
        XCTAssertTrue(CFEqual(lhs.color, rhs.color), "color", file: file, line: line)
        XCTAssertEqual(lhs.lineWidth, rhs.lineWidth, "lineWidth", file: file, line: line)
        XCTAssertEqual(lhs.text, rhs.text, "text", file: file, line: line)
        XCTAssertEqual(lhs.number, rhs.number, "number", file: file, line: line)
        XCTAssertEqual(lhs.numberStyle, rhs.numberStyle, "numberStyle", file: file, line: line)
        XCTAssertEqual(lhs.numberComment, rhs.numberComment, "numberComment", file: file, line: line)
        XCTAssertEqual(lhs.numberCommentSize, rhs.numberCommentSize, "numberCommentSize", file: file, line: line)
        XCTAssertEqual(lhs.rotation, rhs.rotation, "rotation", file: file, line: line)
        XCTAssertEqual(lhs.opacity, rhs.opacity, "opacity", file: file, line: line)
        XCTAssertEqual(lhs.strokeStyle, rhs.strokeStyle, "strokeStyle", file: file, line: line)
        XCTAssertEqual(lhs.lineCap, rhs.lineCap, "lineCap", file: file, line: line)
        XCTAssertEqual(lhs.lineJoin, rhs.lineJoin, "lineJoin", file: file, line: line)
        XCTAssertEqual(lhs.startArrowEnabled, rhs.startArrowEnabled, "startArrowEnabled", file: file, line: line)
        XCTAssertEqual(lhs.endArrowEnabled, rhs.endArrowEnabled, "endArrowEnabled", file: file, line: line)
        XCTAssertEqual(lhs.startArrowhead, rhs.startArrowhead, "startArrowhead", file: file, line: line)
        XCTAssertEqual(lhs.endArrowhead, rhs.endArrowhead, "endArrowhead", file: file, line: line)
        XCTAssertEqual(lhs.fillEnabled, rhs.fillEnabled, "fillEnabled", file: file, line: line)
        XCTAssertTrue(CFEqual(lhs.fillColor, rhs.fillColor), "fillColor", file: file, line: line)
        XCTAssertEqual(lhs.cornerRadius, rhs.cornerRadius, "cornerRadius", file: file, line: line)
        XCTAssertEqual(lhs.fontName, rhs.fontName, "fontName", file: file, line: line)
        XCTAssertEqual(lhs.fontSize, rhs.fontSize, "fontSize", file: file, line: line)
        XCTAssertEqual(lhs.bold, rhs.bold, "bold", file: file, line: line)
        XCTAssertEqual(lhs.italic, rhs.italic, "italic", file: file, line: line)
        XCTAssertEqual(lhs.underline, rhs.underline, "underline", file: file, line: line)
        XCTAssertEqual(lhs.textOutlineEnabled, rhs.textOutlineEnabled, "textOutlineEnabled", file: file, line: line)
        XCTAssertTrue(CFEqual(lhs.textOutlineColor, rhs.textOutlineColor), "textOutlineColor", file: file, line: line)
        XCTAssertEqual(lhs.textOutlineWidth, rhs.textOutlineWidth, "textOutlineWidth", file: file, line: line)
        XCTAssertEqual(lhs.textBoxSize, rhs.textBoxSize, "textBoxSize", file: file, line: line)
        XCTAssertEqual(lhs.eraserMode, rhs.eraserMode, "eraserMode", file: file, line: line)
        XCTAssertEqual(lhs.spotlightShape, rhs.spotlightShape, "spotlightShape", file: file, line: line)
        XCTAssertEqual(lhs.spotlightDim, rhs.spotlightDim, "spotlightDim", file: file, line: line)
        XCTAssertEqual(lhs.spotlightBorder, rhs.spotlightBorder, "spotlightBorder", file: file, line: line)
        XCTAssertEqual(lhs.watermarkPlacement, rhs.watermarkPlacement, "watermarkPlacement", file: file, line: line)
        XCTAssertEqual(lhs.watermarkSpacing, rhs.watermarkSpacing, "watermarkSpacing", file: file, line: line)
        XCTAssertEqual(lhs.watermarkTemplate, rhs.watermarkTemplate, "watermarkTemplate", file: file, line: line)
        XCTAssertEqual(lhs.frozenTimestamp, rhs.frozenTimestamp, "frozenTimestamp", file: file, line: line)
        XCTAssertEqual(lhs.frozenTimeZoneIdentifier, rhs.frozenTimeZoneIdentifier, "frozenTimeZoneIdentifier", file: file, line: line)
        XCTAssertEqual(lhs.timestampIsCaptureDate, rhs.timestampIsCaptureDate, "timestampIsCaptureDate", file: file, line: line)
        XCTAssertEqual(lhs.magnifierSource, rhs.magnifierSource, "magnifierSource", file: file, line: line)
        XCTAssertEqual(lhs.magnifierScale, rhs.magnifierScale, "magnifierScale", file: file, line: line)
        XCTAssertEqual(lhs.magnifierShape, rhs.magnifierShape, "magnifierShape", file: file, line: line)
        XCTAssertEqual(lhs.magnifierConnector, rhs.magnifierConnector, "magnifierConnector", file: file, line: line)
        XCTAssertEqual(lhs.magnifierSmooth, rhs.magnifierSmooth, "magnifierSmooth", file: file, line: line)
        XCTAssertEqual(lhs.magnifierShowsAnnotations, rhs.magnifierShowsAnnotations, "magnifierShowsAnnotations", file: file, line: line)
        XCTAssertEqual(lhs.magnifierShadow, rhs.magnifierShadow, "magnifierShadow", file: file, line: line)
        XCTAssertEqual(lhs.arcStartAngle, rhs.arcStartAngle, "arcStartAngle", file: file, line: line)
        XCTAssertEqual(lhs.arcSweepAngle, rhs.arcSweepAngle, "arcSweepAngle", file: file, line: line)
        XCTAssertEqual(lhs.freehandSmoothing, rhs.freehandSmoothing, "freehandSmoothing", file: file, line: line)
        XCTAssertEqual(lhs.freehandConstraint, rhs.freehandConstraint, "freehandConstraint", file: file, line: line)
        XCTAssertEqual(lhs.freehandCorners, rhs.freehandCorners, "freehandCorners", file: file, line: line)
        XCTAssertEqual(lhs.freehandWasSimplified, rhs.freehandWasSimplified, "freehandWasSimplified", file: file, line: line)
        XCTAssertEqual(lhs.highlighterMode, rhs.highlighterMode, "highlighterMode", file: file, line: line)
        XCTAssertEqual(lhs.highlighterBlend, rhs.highlighterBlend, "highlighterBlend", file: file, line: line)
        XCTAssertEqual(lhs.mosaicLink?.groupID, rhs.mosaicLink?.groupID, "mosaicLink.groupID", file: file, line: line)
        XCTAssertEqual(lhs.mosaicLink?.additionID, rhs.mosaicLink?.additionID, "mosaicLink.additionID", file: file, line: line)
        XCTAssertEqual(lhs.mosaicLink?.rootAdditionID, rhs.mosaicLink?.rootAdditionID, "mosaicLink.rootAdditionID", file: file, line: line)
        XCTAssertEqual(lhs.mosaicLink?.target, rhs.mosaicLink?.target, "mosaicLink.target", file: file, line: line)
        XCTAssertEqual(lhs.mosaicLink?.includedTargets, rhs.mosaicLink?.includedTargets, "mosaicLink.includedTargets", file: file, line: line)
        XCTAssertEqual(lhs.mosaicLink?.excludedTargets, rhs.mosaicLink?.excludedTargets, "mosaicLink.excludedTargets", file: file, line: line)
        XCTAssertEqual(lhs.mosaicLink?.synchronizes, rhs.mosaicLink?.synchronizes, "mosaicLink.synchronizes", file: file, line: line)
    }
}
