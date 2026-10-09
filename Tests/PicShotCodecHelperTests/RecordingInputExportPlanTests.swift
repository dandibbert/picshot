import XCTest
import PicShotCodecCore
@testable import PicShotCodecHelper

final class RecordingInputExportPlanTests: XCTestCase {
    func testDerivedInputPartialFinalFrameUsesFortyOneRequestsAndExactMilliseconds() throws {
        let options = CodecAnimationOptions(frameRate: 20, maximumDimension: 320,
                                            maximumFrames: 41, maximumDuration: 3)
        let plan = try AnimatedWebPFramePlan(duration: 2.05, options: options)
        XCTAssertEqual(plan.frameCount, 41)
        XCTAssertEqual(plan.durationMS, 2_050)
        for index in 0..<41 {
            XCTAssertEqual(plan.samplingTime(for: index).value, Int64(index * 30))
            XCTAssertEqual(plan.samplingTime(for: index).timescale, 600)
            XCTAssertEqual(plan.delayMS(for: index), 50)
        }
        XCTAssertEqual(plan.samplingTime(for: 40).seconds, 2)
        XCTAssertEqual((0..<41).reduce(0) { $0 + plan.delayMS(for: $1) }, 2_050)
    }
}
