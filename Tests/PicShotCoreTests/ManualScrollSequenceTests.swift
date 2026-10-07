import XCTest
@testable import PicShotCore

/// Coordinator + real conservative matching + sequence coverage. Native file commit and
/// RGBA hashing require the separate app tests; fixture signatures here are unique labels.
@MainActor
final class ManualScrollSequenceTests: XCTestCase {
    private struct Viewport {
        let frame: ScrollFrame
        let observation: ManualScrollObservation
    }

    private final class Driver: ManualScrollDriver {
        let axis: ScrollAxis
        var input: [Viewport]
        var pending: Viewport?
        var sequence: ScrollCaptureSequence?
        var anchor: ScrollFrame?
        var sources: [UUID: ScrollFrame] = [:]
        var beforeCommit: (() async -> Void)?
        init(axis: ScrollAxis, input: [Viewport]) { self.axis = axis; self.input = input }
        func checkPermission() throws {}
        func validateTarget() throws {}
        func capture() async throws -> ManualScrollObservation {
            try Task.checkCancellation()
            pending = input.removeFirst()
            return try XCTUnwrap(pending).observation
        }
        func acceptStableCapture() async throws -> ManualScrollSample {
            let frame = try XCTUnwrap(pending).frame
            let sourceID = UUID()
            var next: ScrollCaptureSequence
            let contributes: Bool
            if let current = sequence, let anchor {
                let placement = try ScrollStitcher.matchBidirectional(previous: anchor, next: frame, axis: axis)
                next = current
                contributes = try next.accept(advance: placement.advance, sourceID: sourceID) != nil
                let start = next.viewportOffset
                let length = axis == .vertical ? frame.height : frame.width
                for block in current.blocks {
                    let lower = max(start, block.documentStart)
                    let upper = min(start + length, block.documentStart + block.length)
                    guard lower < upper else { continue }
                    let source = try XCTUnwrap(sources[block.sourceID])
                    _ = try ScrollStitcher.validateAlignedOverlap(previous: source,
                        previousStart: block.sourceStart + lower - block.documentStart,
                        next: frame, nextStart: lower - start, length: upper - lower, axis: axis)
                }
            } else {
                next = try ScrollCaptureSequence(axis: axis, width: frame.width, height: frame.height, sourceID: sourceID)
                contributes = true
            }
            if let beforeCommit { await beforeCommit() }
            try Task.checkCancellation()
            // Transaction boundary: all prospective placement/coverage checks precede it.
            sequence = next; anchor = frame
            if contributes { sources[sourceID] = frame }
            return .accepted(totalFrames: sources.count)
        }
        func discardPendingCapture() { pending = nil }
    }

    private func viewport(_ offset: Int, axis: ScrollAxis, seed: UInt64 = 7, label: UInt8) throws -> Viewport {
        let width = 64, height = 80
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height)
        for row in 0..<height {
            for column in 0..<width {
                let x = column + (axis == .horizontal ? offset : 0)
                let y = row + (axis == .vertical ? offset : 0)
                var value = UInt64(x) &* 0x9e3779b185ebca87
                value ^= UInt64(y) &* 0xc2b2ae3d27d4eb4f
                value ^= seed
                value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
                value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
                value ^= value >> 31
                pixels.append(UInt8(value % 216 + 20))
            }
        }
        return try Viewport(frame: ScrollFrame(width: width, height: height, grayscale: pixels),
            observation: ManualScrollObservation(width: width, height: height, rgbaSHA256: Array(repeating: label, count: 32)))
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        if seconds >= 10 { try await Task.sleep(nanoseconds: 10_000_000_000) }
        else { try Task.checkCancellation(); await Task.yield() }
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func configuration(samples: Int) -> ManualScrollConfiguration {
        var result = ManualScrollConfiguration(); result.countdownSeconds = 0; result.maximumSamples = samples
        return result
    }

    func testContinuousSignedMovementRevisitsAndExtendsImmutableSources() async throws {
        for axis in ScrollAxis.allCases {
            let a = try viewport(50, axis: axis, label: 1)
            let b = try viewport(75, axis: axis, label: 2)
            let reverse = try viewport(60, axis: axis, label: 3)
            let leading = try viewport(30, axis: axis, label: 4)
            let driver = Driver(axis: axis, input: [a, a, b, b, reverse, reverse, leading, leading])
            let coordinator = ManualScrollCoordinator(configuration: configuration(samples: 8), driver: driver, sleep: sleep)
            coordinator.start()
            try await waitUntil { !coordinator.hasPendingOperation }
            let sequence = try XCTUnwrap(driver.sequence)
            XCTAssertEqual(coordinator.state, .finished(.sampleLimit)); XCTAssertEqual(coordinator.acceptedFrames, 3)
            XCTAssertEqual(sequence.viewportOffset, -20); XCTAssertEqual(sequence.lowerBound, -20)
            let length = axis == .vertical ? a.frame.height : a.frame.width
            XCTAssertEqual(sequence.upperBound, length + 25)
            XCTAssertEqual(sequence.blocks.map(\.length), [20, length, 25])
            XCTAssertEqual(driver.sources.count, 3)
            let first = try XCTUnwrap(driver.sources[sequence.blocks[1].sourceID])
            XCTAssertEqual(first.pixels, a.frame.pixels, "Reverse/revisit never changes accepted source pixels")
            let layout = try sequence.layout()
            XCTAssertEqual(axis == .vertical ? layout.height : layout.width, length + 45)
            XCTAssertNil(driver.pending)
        }
    }

    func testRejectedSeamAndPausedRegionRepositionKeepPreviousAnchor() async throws {
        for axis in ScrollAxis.allCases {
            let a = try viewport(50, axis: axis, label: 1)
            let unrelated = try viewport(50, axis: axis, seed: 991, label: 9)
            let recovered = try viewport(70, axis: axis, label: 2)
            let driver = Driver(axis: axis, input: [a, a, unrelated, unrelated])
            let coordinator = ManualScrollCoordinator(configuration: configuration(samples: 6), driver: driver, sleep: sleep)
            coordinator.start()
            try await waitUntil { !coordinator.hasPendingOperation }
            guard case .recoverable = coordinator.state else { return XCTFail("Unknown seam must remain retryable") }
            let first = try XCTUnwrap(driver.sequence).blocks
            XCTAssertEqual(first.count, 1); XCTAssertEqual(driver.anchor?.pixels, a.frame.pixels)
            XCTAssertEqual(driver.sources.count, 1); XCTAssertEqual(coordinator.acceptedFrames, 1)
            // Represents an explicitly moved, same-size capture area after old work drains.
            // The newly observed viewport must match the original anchor, never a reset.
            driver.input = [recovered, recovered]
            coordinator.resume()
            try await waitUntil { !coordinator.hasPendingOperation }
            let sequence = try XCTUnwrap(driver.sequence)
            XCTAssertEqual(sequence.blocks.first, first.first); XCTAssertEqual(sequence.viewportOffset, 20)
            XCTAssertEqual(driver.sources.count, 2); XCTAssertEqual(coordinator.acceptedFrames, 2)
            XCTAssertEqual(coordinator.state, .finished(.sampleLimit))
            XCTAssertEqual(driver.sources[first[0].sourceID]?.pixels, a.frame.pixels)
        }
    }

    func testCancelledTentativePlacementCannotChangeAcceptedSequenceOrSources() async throws {
        let a = try viewport(50, axis: .vertical, label: 1)
        let b = try viewport(75, axis: .vertical, label: 2)
        let driver = Driver(axis: .vertical, input: [a, a, b, b])
        var held: CheckedContinuation<Void, Never>?
        driver.beforeCommit = {
            if driver.sequence != nil { await withCheckedContinuation { held = $0 } }
        }
        let coordinator = ManualScrollCoordinator(configuration: configuration(samples: 4), driver: driver, sleep: sleep)
        coordinator.start()
        try await waitUntil { held != nil }
        let accepted = try XCTUnwrap(driver.sequence).blocks
        coordinator.pause()
        XCTAssertFalse(coordinator.canResume); XCTAssertTrue(coordinator.hasPendingOperation)
        held?.resume(); held = nil
        try await waitUntil { !coordinator.hasPendingOperation }
        XCTAssertEqual(coordinator.state, .paused); XCTAssertTrue(coordinator.canResume)
        XCTAssertEqual(driver.sequence?.blocks, accepted); XCTAssertEqual(driver.sequence?.viewportOffset, 0)
        XCTAssertEqual(driver.sources.count, 1); XCTAssertEqual(driver.anchor?.pixels, a.frame.pixels)
        XCTAssertEqual(coordinator.acceptedFrames, 1); XCTAssertNil(driver.pending)
        driver.beforeCommit = nil
    }
}
