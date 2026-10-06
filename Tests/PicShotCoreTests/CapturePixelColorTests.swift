import XCTest
@testable import PicShotCore

final class CapturePixelColorTests: XCTestCase {
    func testPrimaryAndSecondaryColorsHaveExpectedHue() {
        let fixtures: [(Int, Int, Int, Double)] = [(255, 0, 0, 0), (255, 255, 0, 60), (0, 255, 0, 120),
                                                  (0, 255, 255, 180), (0, 0, 255, 240), (255, 0, 255, 300)]
        for (red, green, blue, hue) in fixtures {
            let color = CapturePixelColor(red: red, green: green, blue: blue)
            XCTAssertEqual(color.hsv.hue, hue, accuracy: 0.000001)
            XCTAssertEqual(color.hsl.hue, hue, accuracy: 0.000001)
            XCTAssertEqual(color.hsv.saturation, 1)
            XCTAssertEqual(color.hsv.value, 1)
            XCTAssertEqual(color.hsl.saturation, 1)
            XCTAssertEqual(color.hsl.lightness, 0.5)
        }
    }

    func testEveryGrayHasZeroHueAndSaturationWithoutNaN() {
        for component in 0...255 {
            let color = CapturePixelColor(red: component, green: component, blue: component)
            XCTAssertEqual(color.hsv.hue, 0)
            XCTAssertEqual(color.hsl.hue, 0)
            XCTAssertEqual(color.hsv.saturation, 0)
            XCTAssertEqual(color.hsl.saturation, 0)
            XCTAssertEqual(color.hsv.value, Double(component) / 255)
            XCTAssertEqual(color.hsl.lightness, Double(component) / 255)
        }
    }

    func testKnownMixedColorHasDifferentHSVAndHSLSaturation() {
        let color = CapturePixelColor(red: 102, green: 51, blue: 153)
        XCTAssertEqual(color.hex, "#663399")
        XCTAssertEqual(color.hsv.hue, 270, accuracy: 0.000001)
        XCTAssertEqual(color.hsv.saturation, 2.0 / 3, accuracy: 0.000001)
        XCTAssertEqual(color.hsv.value, 0.6, accuracy: 0.000001)
        XCTAssertEqual(color.hsl.saturation, 0.5, accuracy: 0.000001)
        XCTAssertEqual(color.hsl.lightness, 0.4, accuracy: 0.000001)
    }

    func testRedDominantNegativeHueWrapsIntoPositiveDegrees() {
        let color = CapturePixelColor(red: 255, green: 0, blue: 128)
        XCTAssertEqual(color.hsv.hue, 360 - 128.0 / 255 * 60, accuracy: 0.000001)
        XCTAssertGreaterThanOrEqual(color.hsv.hue, 0)
        XCTAssertLessThan(color.hsv.hue, 360)
    }

    func testIntegerChannelsClampAndHexAlwaysHasSixUppercaseDigits() {
        let color = CapturePixelColor(red: Int.min, green: Int.max, blue: 10, alpha: -4)
        XCTAssertEqual(color.red, 0)
        XCTAssertEqual(color.green, 255)
        XCTAssertEqual(color.blue, 10)
        XCTAssertEqual(color.alpha, 0)
        XCTAssertEqual(color.hex, "#00FF0A")
        XCTAssertEqual(CapturePixelColor(red: 1, green: 2, blue: 3, alpha: Int.max).alpha, 255)
    }
}
