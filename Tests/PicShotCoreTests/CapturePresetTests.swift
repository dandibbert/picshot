import XCTest
@testable import PicShotCore

final class CapturePresetTests: XCTestCase {
    private let displayID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let presetID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!

    func testNamedRectanglesAndEveryDelayRoundTripWithoutChangingPixels() throws {
        for delay in ScreenshotDelay.allCases {
            let first = try preset(delay: delay)
            let second = try CapturePreset(id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
                name: "第二矩形", delay: .tenSeconds, display: display(),
                topLeftFrame: CGRect(x: 200.5, y: 99.5, width: 91, height: 80),
                pixelFrame: CGRect(x: 401, y: 199, width: 182, height: 160))
            let index = try CapturePresetIndex(presets: [first, second])
            let restored = try JSONDecoder().decode(CapturePresetIndex.self, from: JSONEncoder().encode(index))
            XCTAssertEqual(restored, index)
            XCTAssertEqual(restored.presets.first?.pixelFrame, CGRect(x: 21, y: 41, width: 63, height: 81))
            XCTAssertEqual(restored.presets.first?.topLeftFrame.origin, CGPoint(x: 10.5, y: 20.5))
            XCTAssertEqual(restored.presets.first?.delay, delay)
            XCTAssertEqual(try first.resolveDisplay(in: [display()]), first.display)
        }
    }

    func testArbitraryValidSourceScalesAreCanonicalAndNeverPointRounded() throws {
        let display = try CapturePresetDisplay(uuid: displayID, frame: CGRect(x: 0, y: 0, width: 1100, height: 700),
                                              pixelWidth: 1920, pixelHeight: 1200, rotationDegrees: 0)
        let pixels = CGRect(x: 19, y: 29, width: 99, height: 109)
        let points = CGRect(x: 19 / (1920.0 / 1100), y: 29 / (1200.0 / 700),
                            width: 99 / (1920.0 / 1100), height: 109 / (1200.0 / 700))
        let almost = CGRect(x: points.minX + 1e-10, y: points.minY, width: points.width, height: points.height)
        let saved = try CapturePreset(name: "非整数缩放", delay: .none, display: display, topLeftFrame: almost, pixelFrame: pixels)
        XCTAssertEqual(saved.topLeftFrame, points)
        XCTAssertEqual(try JSONDecoder().decode(CapturePreset.self, from: JSONEncoder().encode(saved)), saved)
    }

    func testMissingAmbiguousRemappedResizedScaledAndRotatedDisplaysFailClosed() throws {
        let saved = try preset()
        XCTAssertThrowsError(try saved.resolveDisplay(in: [])) { XCTAssertEqual($0 as? CapturePresetError, .missingDisplay) }
        XCTAssertThrowsError(try saved.resolveDisplay(in: [display(), display()])) {
            XCTAssertEqual($0 as? CapturePresetError, .ambiguousDisplay)
        }
        let another = try CapturePresetDisplay(uuid: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            frame: saved.display.frame, pixelWidth: 2880, pixelHeight: 1800, rotationDegrees: 0)
        XCTAssertThrowsError(try saved.resolveDisplay(in: [another])) { XCTAssertEqual($0 as? CapturePresetError, .missingDisplay) }
        let changed = [
            try display(frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
            try display(frame: CGRect(x: -1440, y: 0, width: 1280, height: 800)),
            try display(pixelWidth: 1440, pixelHeight: 900),
            try display(rotation: 90)
        ]
        for replacement in changed {
            XCTAssertThrowsError(try saved.resolveDisplay(in: [replacement])) { XCTAssertEqual($0 as? CapturePresetError, .displayChanged) }
        }
    }

    func testMalformedNamesGeometryAndFractionalPixelsAreRejected() throws {
        for name in ["", "  ", "a\nb", String(repeating: "x", count: 65), String(repeating: "👨‍👩‍👧‍👦", count: 64)] {
            XCTAssertThrowsError(try preset(name: name))
        }
        let display = try display()
        for pixels in [CGRect(x: -1, y: 0, width: 20, height: 20), CGRect(x: 0.5, y: 0, width: 20, height: 20),
                       CGRect(x: 2870, y: 0, width: 20, height: 20), CGRect(x: 0, y: 0, width: 0, height: 20),
                       CGRect(x: 0, y: 0, width: 3, height: 20), CGRect(x: CGFloat.infinity, y: 0, width: 20, height: 20)] {
            XCTAssertThrowsError(try CapturePreset(name: "无效", delay: .none, display: display,
                topLeftFrame: CGRect(x: pixels.origin.x / 2, y: pixels.origin.y / 2, width: pixels.width / 2, height: pixels.height / 2),
                pixelFrame: pixels))
        }
        XCTAssertThrowsError(try CapturePreset(name: "错位", delay: .none, display: display,
            topLeftFrame: CGRect(x: 10, y: 20.5, width: 31.5, height: 40.5),
            pixelFrame: CGRect(x: 21, y: 41, width: 63, height: 81)))
        XCTAssertThrowsError(try self.display(pixelWidth: Int.max))
        XCTAssertThrowsError(try self.display(rotation: .nan))
        XCTAssertThrowsError(try self.display(rotation: 45))
    }

    func testMalformedLoadedMetadataRejectsUnknownDelayVersionDuplicateAndCount() throws {
        let saved = try preset()
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["delaySeconds"] = 4 }, { $0["name"] = "bad\nname" }, { $0["name"] = " padded " },
            { $0["id"] = "not-a-uuid" },
            { value in var display = value["display"] as! [String: Any]; display["pixelWidth"] = -1; value["display"] = display }
        ]
        for change in changes {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
            change(&object)
            XCTAssertThrowsError(try JSONDecoder().decode(CapturePreset.self, from: JSONSerialization.data(withJSONObject: object)))
        }
        let record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))
        let malformed: [[String: Any]] = [
            ["version": 2, "presets": [record]], ["version": 1, "presets": [record, record]],
            ["version": 1, "presets": Array(repeating: record, count: 33)]
        ]
        for object in malformed {
            XCTAssertThrowsError(try JSONDecoder().decode(CapturePresetIndex.self, from: JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testCountLimitAndEditsPreserveIdentityAndGeometry() throws {
        let source = try preset()
        let updated = try source.replacing(name: "新名称", delay: .fiveSeconds)
        XCTAssertEqual(updated.id, source.id); XCTAssertEqual(updated.pixelFrame, source.pixelFrame)
        XCTAssertEqual(updated.topLeftFrame, source.topLeftFrame); XCTAssertEqual(updated.display, source.display)
        XCTAssertEqual(updated.name, "新名称"); XCTAssertEqual(updated.delay, .fiveSeconds)
        XCTAssertThrowsError(try CapturePresetIndex(presets: [source, source]))
        var records: [CapturePreset] = []
        for index in 0..<33 {
            records.append(try CapturePreset(id: UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", index))!,
                name: "区域 \(index)", delay: .none, display: source.display, topLeftFrame: source.topLeftFrame, pixelFrame: source.pixelFrame))
        }
        XCTAssertEqual(try CapturePresetIndex(presets: Array(records.prefix(32))).presets.count, 32)
        XCTAssertThrowsError(try CapturePresetIndex(presets: records)) { XCTAssertEqual($0 as? CapturePresetError, .limitReached) }
    }

    private func display(frame: CGRect = CGRect(x: -1440, y: 0, width: 1440, height: 900),
                         pixelWidth: Int = 2880, pixelHeight: Int = 1800, rotation: Double = 0) throws -> CapturePresetDisplay {
        try CapturePresetDisplay(uuid: displayID, frame: frame, pixelWidth: pixelWidth, pixelHeight: pixelHeight, rotationDegrees: rotation)
    }
    private func preset(name: String = "第一区域", delay: ScreenshotDelay = .threeSeconds) throws -> CapturePreset {
        try CapturePreset(id: presetID, name: name, delay: delay, display: display(),
            topLeftFrame: CGRect(x: 10.5, y: 20.5, width: 31.5, height: 40.5),
            pixelFrame: CGRect(x: 21, y: 41, width: 63, height: 81))
    }
}
