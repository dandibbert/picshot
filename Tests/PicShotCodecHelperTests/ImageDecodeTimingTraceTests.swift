import XCTest
import Foundation
import Darwin
import PicShotCodecCore
@testable import PicShotCodecHelper

final class ImageDecodeTimingTraceTests: XCTestCase {
    func testFrameIsPreparedAfterRunReturnsIncludingDeferredCleanup() throws {
        var clock = 0.0, order: [String] = [], frame: Data?
        let status = ImageDecodeDiagnostic.observeTimingReturn(childPID: 123, uptime: {
            clock += 1; order.append("clock\(Int(clock))"); return clock
        }, emitFrame: {
            order.append("frame"); frame = $0
        }, runDiagnostic: { recorder in
            order.append("run")
            defer { order.append("cleanup") }
            recorder.terminalWriteStarted(); order.append("terminalWrite")
            recorder.terminalWriteCompleted()
            return 23
        })
        XCTAssertEqual(status, 23)
        XCTAssertEqual(order, ["run", "clock1", "terminalWrite", "clock2", "cleanup", "clock3", "clock4", "frame"])
        let trace = try ImageDecodeTimingTrace.decodeFrame(XCTUnwrap(frame))
        XCTAssertEqual(trace.terminalWriteStartedUptimeSeconds, 1)
        XCTAssertEqual(trace.terminalWriteCompletedUptimeSeconds, 2)
        XCTAssertEqual(trace.terminalWriteAttemptCount, 1)
        XCTAssertTrue(trace.terminalWriteSucceeded)
        XCTAssertEqual(trace.runReturnedUptimeSeconds, 3)
        XCTAssertEqual(trace.framePreparedUptimeSeconds, 4)
    }

    func testFrameDescribesAbsentFailedAndFallbackWritesWithoutInventedCompletion() throws {
        for attempts in 0...2 {
            for succeeds in [false, true] where attempts > 0 || !succeeds {
                var clock = 0.0, frame: Data?
                let status = ImageDecodeDiagnostic.observeTimingReturn(childPID: 123, uptime: {
                    clock += 1; return clock
                }, emitFrame: { frame = $0 }, runDiagnostic: { recorder in
                    for _ in 0..<attempts { recorder.terminalWriteStarted() }
                    if succeeds { recorder.terminalWriteCompleted() }
                    return 1
                })
                let trace = try ImageDecodeTimingTrace.decodeFrame(XCTUnwrap(frame))
                XCTAssertEqual(status, 1)
                XCTAssertEqual(trace.terminalWriteAttemptCount, attempts)
                XCTAssertEqual(trace.terminalWriteSucceeded, succeeds)
                XCTAssertEqual(trace.terminalWriteStartedUptimeSeconds, attempts == 0 ? nil : Double(attempts))
                XCTAssertEqual(trace.terminalWriteCompletedUptimeSeconds, succeeds ? Double(attempts + 1) : nil)
            }
        }
    }

    func testObservationFailuresPreserveRunReturnCode() throws {
        var writes = 0
        let status = ImageDecodeDiagnostic.observeTimingReturn(childPID: 123, uptime: { 1 }, emitFrame: { _ in
            writes += 1; throw ImageDecodeDiagnosticError.deadline
        }, runDiagnostic: { _ in 29 })
        XCTAssertEqual(status, 29); XCTAssertEqual(writes, 1)
        let invalidClockStatus = ImageDecodeDiagnostic.observeTimingReturn(childPID: 123, uptime: { .nan }, emitFrame: { _ in
            XCTFail("Invalid observations must not reach stderr")
        }, runDiagnostic: { _ in 31 })
        XCTAssertEqual(invalidClockStatus, 31)
    }

    func testTimingWriterSendsOneFrameAndRestoresDescriptorFlags() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        let original = fcntl(descriptor, F_GETFL)
        let frame = try trace().encodeFrame()
        try ImageDecodeDiagnosticTimingWriter.send(frame, descriptor: descriptor)
        XCTAssertEqual(fcntl(descriptor, F_GETFL), original)
        var bytes = [UInt8](repeating: 0, count: 1_024)
        let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
        XCTAssertEqual(count, frame.count)
        XCTAssertEqual(Data(bytes.prefix(max(0, count))), frame)
    }

    func testFullTimingPipeHitsShortDeadlineAndRestoresFlags() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        let original = fcntl(descriptor, F_GETFL)
        XCTAssertGreaterThanOrEqual(original, 0)
        XCTAssertEqual(fcntl(descriptor, F_SETFL, original | O_NONBLOCK), 0)
        let fill = [UInt8](repeating: 32, count: 4_096)
        var full = false
        // Bound setup too; the native pipe must fill well inside 8 MiB.
        for _ in 0..<2_048 {
            let count = fill.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, $0.count) }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { full = true; break }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { XCTFail("Could not fill timing pipe"); return }
        }
        guard full else { XCTFail("Timing pipe did not reach its bounded capacity"); return }
        // An atomic 4096-byte write can report EAGAIN with a smaller gap left.
        // Fill that gap too so even a small timing frame must wait.
        full = false
        var byte: UInt8 = 32
        for _ in 0..<4_097 {
            let count = Darwin.write(descriptor, &byte, 1)
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { full = true; break }
            if count < 0 && errno == EINTR { continue }
            guard count == 1 else { XCTFail("Could not fill final timing pipe gap"); return }
        }
        guard full else { XCTFail("Timing pipe retained space for a small write"); return }
        // Restore blocking mode to prove send itself sets O_NONBLOCK and restores it.
        XCTAssertEqual(fcntl(descriptor, F_SETFL, original), 0)
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try ImageDecodeDiagnosticTimingWriter.send(trace().encodeFrame(), descriptor: descriptor)) {
            XCTAssertEqual($0 as? ImageDecodeDiagnosticError, .deadline)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        XCTAssertEqual(fcntl(descriptor, F_GETFL), original)
    }

    func testInvalidTimingOutputDoesNotWrite() throws {
        XCTAssertThrowsError(try ImageDecodeDiagnosticTimingWriter.send(trace().encodeFrame(), descriptor: -1))
        for frame in [Data(), Data("{}".utf8), Data(repeating: 32, count: 1_024) + Data([10])] {
            XCTAssertThrowsError(try ImageDecodeDiagnosticTimingWriter.send(frame, descriptor: -1))
        }
    }

    private func trace() -> ImageDecodeTimingTrace {
        .init(childPID: 123, terminalWriteStartedUptimeSeconds: 1, terminalWriteCompletedUptimeSeconds: 2,
              terminalWriteAttemptCount: 1, runReturnedUptimeSeconds: 3, framePreparedUptimeSeconds: 4,
              terminalWriteSucceeded: true)
    }
}
