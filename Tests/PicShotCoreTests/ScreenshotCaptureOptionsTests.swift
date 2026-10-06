import XCTest
@testable import PicShotCore

final class ScreenshotCaptureOptionsTests: XCTestCase {
    func testOnlySupportedDelaysAndSafeDefaults() {
        XCTAssertEqual(ScreenshotDelay.allCases.map(\.rawValue), [0, 3, 5, 10])
        XCTAssertNil(ScreenshotDelay(rawValue: -1))
        XCTAssertNil(ScreenshotDelay(rawValue: 9))
        XCTAssertEqual(ScreenshotCaptureOptions(), ScreenshotCaptureOptions(delay: .none, showsCursor: false))
    }

    func testDelaySleepsExactlyOnceOrNotAtAll() async throws {
        for delay in ScreenshotDelay.allCases {
            var calls: [UInt64] = []
            try await delay.wait { calls.append($0) }
            XCTAssertEqual(calls, delay == .none ? [] : [UInt64(delay.rawValue) * 1_000_000_000])
        }
    }

    func testRealSleepCancellationStopsImmediatelyAndCanBeRepeated() async throws {
        for _ in 0..<20 {
            let task = Task { try await ScreenshotDelay.tenSeconds.wait() }
            task.cancel()
            do { try await task.value; XCTFail("Cancelled delay returned successfully") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        try await ScreenshotDelay.none.wait()
    }

    func testCancellationAfterSleeperReturnsIsStillDetected() async throws {
        let task = Task {
            try await ScreenshotDelay.threeSeconds.wait { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { try await task.value; XCTFail("Cancellation was swallowed by the sleeper") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testAlreadyCancelledZeroDelayDoesNotPass() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await ScreenshotDelay.none.wait()
        }
        do { try await task.value; XCTFail("Zero delay must still check cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testPreferencesRoundTripAndInvalidStoredDelayFallsBackSafely() throws {
        let name = "PicShot-ScreenshotTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(ScreenshotPreferences.read(from: defaults), .init())
        for delay in ScreenshotDelay.allCases {
            let options = ScreenshotCaptureOptions(delay: delay, showsCursor: true)
            ScreenshotPreferences.save(options, to: defaults)
            XCTAssertEqual(ScreenshotPreferences.read(from: defaults), options)
        }
        defaults.set(Int.max, forKey: ScreenshotPreferences.delayKey)
        XCTAssertEqual(ScreenshotPreferences.read(from: defaults).delay, .none)
        XCTAssertTrue(ScreenshotPreferences.read(from: defaults).showsCursor)
    }
}
