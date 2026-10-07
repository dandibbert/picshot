import XCTest
import Foundation
import Darwin
@testable import PicShotCodecCore

final class ImageDecodeLargeDiagnosticTests: XCTestCase {
    func testClosedProfilesAndLegacyDefaultsDeriveAllDimensions() throws {
        XCTAssertEqual(ImageDecodeDiagnosticLimits.largeSchema, "image-decode-helper-v2")
        XCTAssertEqual(ImageDecodeDiagnosticLimits.largeArgument, "--image-draw-decode-diagnostic-v2")
        XCTAssertEqual(ImageDecodeDiagnosticProfile.allCases, [.fourK, .fiveK])
        XCTAssertEqual(ImageDecodeDiagnosticProfile.fourK.rawValue, "4k")
        XCTAssertEqual(ImageDecodeDiagnosticProfile.fiveK.rawValue, "5k")
        let legacy = request()
        XCTAssertEqual(legacy.schema, ImageDecodeDiagnosticLimits.schema)
        XCTAssertNil(legacy.profile)
        XCTAssertEqual(legacy.sourceWidth, 768); XCTAssertEqual(legacy.sourceHeight, 576)
        XCTAssertEqual(legacy.previewWidth, 768); XCTAssertEqual(legacy.previewHeight, 576)
        XCTAssertEqual(legacy.rasterBytes, 1_769_472)
        for profile in ImageDecodeDiagnosticProfile.allCases {
            let value = request(profile: profile)
            XCTAssertEqual(value.schema, ImageDecodeDiagnosticLimits.largeSchema)
            XCTAssertEqual(value.sourceWidth, profile == .fourK ? 3_840 : 5_120)
            XCTAssertEqual(value.sourceHeight, profile == .fourK ? 2_160 : 2_880)
            XCTAssertEqual(value.previewWidth, 1_024); XCTAssertEqual(value.previewHeight, 576)
            XCTAssertEqual(value.rasterBytes, 2_359_296)
            XCTAssertEqual(try ImageDecodeDiagnosticRequest.decode(JSONEncoder().encode(value)), value)
            XCTAssertThrowsError(try CodecExportProtocol.decodeRequestLine(JSONEncoder().encode(value)))
        }
    }

    func testRequestsRejectCrossVersionProfilesAndArbitraryOverrides() throws {
        let legacy = try object(request()), large = try object(request(profile: .fourK))
        XCTAssertNil(legacy["profile"])
        XCTAssertEqual(Set(large.keys), ["schema", "profile", "token", "parentPID", "pngBytes", "pngSHA256", "mode"])
        for profile in ["4K", "5K", "8k", "", 4, true, NSNull(), ["sourceWidth": 3_840]] as [Any] {
            var invalid = large; invalid["profile"] = profile
            XCTAssertThrowsError(try decode(invalid))
        }
        var invalid = large; invalid.removeValue(forKey: "profile")
        XCTAssertThrowsError(try decode(invalid))
        invalid = large; invalid["schema"] = ImageDecodeDiagnosticLimits.schema
        XCTAssertThrowsError(try decode(invalid))
        invalid = legacy; invalid["profile"] = "4k"
        XCTAssertThrowsError(try decode(invalid))
        invalid = legacy; invalid["profile"] = NSNull()
        XCTAssertThrowsError(try decode(invalid))
        for original in [legacy, large] {
            for key in ["sourceWidth", "sourceHeight", "previewWidth", "previewHeight", "rasterBytes", "maxPixelSize", "path"] {
                invalid = original; invalid[key] = 1_024
                XCTAssertThrowsError(try decode(invalid), key)
            }
        }
        for profile in ImageDecodeDiagnosticProfile.allCases {
            for count in [1, ImageDecodeDiagnosticLimits.pngBytes] { try request(profile: profile, pngBytes: count).validate() }
            for count in [0, -1, ImageDecodeDiagnosticLimits.pngBytes + 1, Int.max] {
                XCTAssertThrowsError(try request(profile: profile, pngBytes: count).validate())
            }
        }
        let good = try JSONEncoder().encode(request(profile: .fiveK))
        for key in ["profile", "profi\\u006ce"] {
            var duplicate = Data("{\"\(key)\":\"5k\",".utf8); duplicate.append(good.dropFirst())
            XCTAssertThrowsError(try ImageDecodeDiagnosticRequest.decode(duplicate))
        }
        XCTAssertThrowsError(try ImageDecodeDiagnosticRequest.decode(good + Data(repeating: 32, count: ImageDecodeDiagnosticLimits.requestBytes)))
    }

    func testEventsKeepLegacyFramingAndEnforceV2ProfileAndRasterBounds() throws {
        for profile in [nil, .fourK, .fiveK] as [ImageDecodeDiagnosticProfile?] {
            let event = result(profile: profile)
            let bytes = try line(event)
            var decoder = ImageDecodeDiagnosticEventDecoder(), events: [ImageDecodeDiagnosticEvent] = []
            for byte in bytes { events += try decoder.consume(Data([byte])) }
            try decoder.finish()
            XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].profile, profile)
            XCTAssertEqual(events[0].rawBytes, profile?.rasterBytes ?? ImageDecodeDiagnosticLimits.rasterBytes)
            XCTAssertThrowsError(try decoder.consume(bytes))
            for count in [0, 1_769_472, 2_359_296, 2_359_297, Int.max] where count != event.rawBytes {
                var invalid = event; invalid.rawBytes = count
                XCTAssertThrowsError(try invalid.validate())
            }
        }
        let large = try object(result(profile: .fourK))
        let invalidFields: [(String, Any)] = [("schema", ImageDecodeDiagnosticLimits.schema), ("profile", "8k"),
                                             ("profile", NSNull()), ("previewWidth", 2_048)]
        for (key, value) in invalidFields {
            var invalid = large; invalid[key] = value
            var decoder = ImageDecodeDiagnosticEventDecoder()
            XCTAssertThrowsError(try decoder.consume(jsonLine(invalid)))
        }
        var missing = large; missing.removeValue(forKey: "profile")
        var decoder = ImageDecodeDiagnosticEventDecoder()
        XCTAssertThrowsError(try decoder.consume(jsonLine(missing)))
        var legacy = try object(result()); legacy["profile"] = "4k"
        decoder = .init(); XCTAssertThrowsError(try decoder.consume(jsonLine(legacy)))
    }

    func testOptionalTimingFieldsAreBoundedAndDescribeHelperEntry() throws {
        var event = result(profile: .fiveK)
        event.uptimeSeconds = 100
        event.helperEntryUptimeSeconds = 98
        event.responsePreparedUptimeSeconds = 100
        event.pngReadAndHashSeconds = 0.125
        try event.validate()
        var decoder = ImageDecodeDiagnosticEventDecoder()
        let decoded = try XCTUnwrap(decoder.consume(line(event)).first)
        XCTAssertEqual(decoded.helperEntryUptimeSeconds, 98)
        XCTAssertEqual(decoded.responsePreparedUptimeSeconds, 100)
        XCTAssertEqual(decoded.pngReadAndHashSeconds, 0.125)
        for invalid in [-1.0, .infinity, .nan, 101] {
            var bad = event; bad.helperEntryUptimeSeconds = invalid; XCTAssertThrowsError(try bad.validate())
            bad = event; bad.responsePreparedUptimeSeconds = invalid; XCTAssertThrowsError(try bad.validate())
        }
        for invalid in [-1.0, .infinity, .nan, ImageDecodeDiagnosticLimits.childHardSeconds + 0.001] {
            var bad = event; bad.pngReadAndHashSeconds = invalid; XCTAssertThrowsError(try bad.validate())
        }
        event.responsePreparedUptimeSeconds = 97; XCTAssertThrowsError(try event.validate())
        // Existing v1 frames omit all three optional measurements.
        let legacy = try object(result())
        for key in ["helperEntryUptimeSeconds", "responsePreparedUptimeSeconds", "pngReadAndHashSeconds", "profile"] {
            XCTAssertNil(legacy[key])
        }
        try result().validate()
    }

    func testJobsUseOnlyTheSelectedProfilesExactRawCap() throws {
        for profile in [nil, .fourK, .fiveK] as [ImageDecodeDiagnosticProfile?] {
            let job = try ImageDecodeDiagnosticJob.create(png: Data([1, 2, 3]), mode: .decode, profile: profile, check: {})
            defer { _ = job.removeAfterExit() }
            XCTAssertEqual(job.request.profile, profile)
            XCTAssertEqual(try job.readPNG(check: {}), Data([1, 2, 3]))
            XCTAssertThrowsError(try ImageDecodeDiagnosticJob.validate(directory: job.directory, expectedParent: getpid() + 1))
            for count in [job.request.rasterBytes - 1, job.request.rasterBytes + 1] {
                XCTAssertThrowsError(try job.writeRaw(Data(count: count), check: {}))
                XCTAssertFalse(job.outputExists())
            }
            let raw = Data(repeating: 128, count: job.request.rasterBytes)
            try job.writeRaw(raw, check: {})
            XCTAssertEqual(try job.readRaw(sha256: ImageDecodeDiagnosticLimits.digest(raw), check: {}), raw)
            XCTAssertThrowsError(try job.writeRaw(raw, check: {}))
            XCTAssertTrue(job.removeAfterExit())
        }
        for profile in ImageDecodeDiagnosticProfile.allCases {
            XCTAssertThrowsError(try ImageDecodeDiagnosticJob.create(png: Data(), mode: .decode, profile: profile, check: {}))
            XCTAssertThrowsError(try ImageDecodeDiagnosticJob.create(png: Data(count: ImageDecodeDiagnosticLimits.pngBytes + 1), mode: .decode, profile: profile, check: {}))
            for count in [1_769_472, profile.rasterBytes + 1] {
                let job = try ImageDecodeDiagnosticJob.create(png: Data([1]), mode: .decode, profile: profile, check: {})
                defer { _ = job.removeAfterExit() }
                let raw = Data(count: count)
                XCTAssertTrue(FileManager.default.createFile(atPath: job.directory.appendingPathComponent("decoded.rgba").path,
                                                            contents: raw, attributes: [.posixPermissions: 0o600]))
                XCTAssertThrowsError(try job.readRaw(sha256: ImageDecodeDiagnosticLimits.digest(raw), check: {}))
                XCTAssertTrue(job.removeAfterExit())
            }
        }
    }

    func testLargeJobsStillRejectOutputSymlinksAndCheckCancellation() throws {
        let job = try ImageDecodeDiagnosticJob.create(png: Data([1]), mode: .decode, profile: .fiveK, check: {})
        let output = job.directory.appendingPathComponent("decoded.rgba")
        let source = job.directory.appendingPathComponent("input.png")
        defer { _ = unlink(output.path); _ = job.removeAfterExit() }
        XCTAssertEqual(symlink(source.path, output.path), 0)
        XCTAssertThrowsError(try job.writeRaw(Data(count: job.request.rasterBytes), check: {}))
        XCTAssertThrowsError(try job.readRaw(sha256: String(repeating: "0", count: 64), check: {}))
        XCTAssertFalse(job.removeAfterExit())
        XCTAssertEqual(try job.readPNG(check: {}), Data([1]))
        XCTAssertEqual(unlink(output.path), 0)
        var checks = 0
        XCTAssertThrowsError(try job.writeRaw(Data(count: job.request.rasterBytes), check: {
            checks += 1; if checks == 2 { throw ImageDecodeDiagnosticError.cancelled }
        })) { XCTAssertEqual($0 as? ImageDecodeDiagnosticError, .cancelled) }
        XCTAssertEqual(try Data(contentsOf: output).count, 65_536)
        XCTAssertTrue(job.removeAfterExit())
    }

    private func request(profile: ImageDecodeDiagnosticProfile? = nil, pngBytes: Int = 3) -> ImageDecodeDiagnosticRequest {
        .init(token: "3C6B0788-E795-4B71-9D75-0DFD7D74DC88", parentPID: 123, pngBytes: pngBytes,
              pngSHA256: String(repeating: "a", count: 64), mode: .decode, profile: profile)
    }
    private func result(profile: ImageDecodeDiagnosticProfile? = nil) -> ImageDecodeDiagnosticEvent {
        var event = ImageDecodeDiagnosticEvent(kind: .result, phase: "complete", childPID: 123, profile: profile)
        event.rawBytes = profile?.rasterBytes ?? ImageDecodeDiagnosticLimits.rasterBytes
        event.rawSHA256 = String(repeating: "a", count: 64)
        event.imageCreationSeconds = 0; event.drawSeconds = 0; event.writeSeconds = 0; event.childWorkSeconds = 0
        var peaks = ImageDecodeMemoryPeaks(); peaks.residentBytes = 1; peaks.footprintBytes = 1
        peaks.residentSamples = 1; peaks.footprintSamples = 1; event.peaks = peaks
        return event
    }
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    private func decode(_ object: [String: Any]) throws -> ImageDecodeDiagnosticRequest {
        try ImageDecodeDiagnosticRequest.decode(JSONSerialization.data(withJSONObject: object))
    }
    private func line(_ event: ImageDecodeDiagnosticEvent) throws -> Data {
        var bytes = try JSONEncoder().encode(event); bytes.append(10); return bytes
    }
    private func jsonLine(_ value: [String: Any]) throws -> Data {
        var bytes = try JSONSerialization.data(withJSONObject: value); bytes.append(10); return bytes
    }
}
