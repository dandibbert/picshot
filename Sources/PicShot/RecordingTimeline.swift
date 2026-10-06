import CoreMedia

/// One shared cut list, represented in constant space. All inputs use the same
/// source clock; dropping an audio packet never changes the video/audio offset.
/// Access is confined to RecordingWriter.queue.
struct RecordingTimeline {
    private(set) var sourceStart: CMTime?
    private(set) var removedDuration = CMTime.zero
    private(set) var pausedAt: CMTime?
    private(set) var minimumSourceTime: CMTime?
    private(set) var committedSourceEnd: CMTime?
    private(set) var stoppedAt: CMTime?

    var isPaused: Bool { pausedAt != nil }

    mutating func start(at timestamp: CMTime) {
        guard sourceStart == nil else { return }
        sourceStart = timestamp
        // Pauses before the first frame have no place in the output timeline.
        removedDuration = .zero
    }

    mutating func committed(through end: CMTime) {
        guard end.isNumeric else { return }
        committedSourceEnd = committedSourceEnd.map { CMTimeMaximum($0, end) } ?? end
    }

    mutating func pause(at timestamp: CMTime) {
        guard pausedAt == nil, stoppedAt == nil, timestamp.isNumeric else { return }
        // An already-encoded audio packet cannot be retracted. Cut after its end
        // so a very quick pause/resume cannot create overlapping AAC input.
        pausedAt = committedSourceEnd.map { CMTimeMaximum(timestamp, $0) } ?? timestamp
    }

    mutating func resume(at timestamp: CMTime) {
        guard let start = pausedAt, stoppedAt == nil, timestamp.isNumeric else { return }
        let end = CMTimeMaximum(start, timestamp)
        if sourceStart != nil { removedDuration = CMTimeAdd(removedDuration, CMTimeSubtract(end, start)) }
        minimumSourceTime = end
        pausedAt = nil
    }

    func accepts(_ timestamp: CMTime) -> Bool {
        guard !isPaused, stoppedAt == nil, timestamp.isNumeric else { return false }
        if let minimumSourceTime, CMTimeCompare(timestamp, minimumSourceTime) < 0 { return false }
        if let sourceStart, CMTimeCompare(timestamp, sourceStart) < 0 { return false }
        return true
    }

    func presentationTime(for timestamp: CMTime) -> CMTime? {
        guard accepts(timestamp), let sourceStart else { return nil }
        let result = CMTimeSubtract(CMTimeSubtract(timestamp, sourceStart), removedDuration)
        return result.isNumeric && CMTimeCompare(result, .zero) >= 0 ? result : nil
    }

    func activeDuration(at timestamp: CMTime) -> CMTime {
        guard let sourceStart else { return .zero }
        let end = stoppedAt ?? pausedAt ?? timestamp
        return CMTimeMaximum(.zero, CMTimeSubtract(CMTimeSubtract(end, sourceStart), removedDuration))
    }

    mutating func stop(at timestamp: CMTime) {
        guard stoppedAt == nil else { return }
        let boundary = pausedAt ?? timestamp
        stoppedAt = committedSourceEnd.map { CMTimeMaximum(boundary, $0) } ?? boundary
    }
}

/// Retimes every entry, including valid decode timestamps, without copying pixel
/// or PCM payloads. No history of samples or pause intervals is retained.
enum RecordingSampleTiming {
    static let maximumTimingEntries = 65_536

    static func copy(_ sample: CMSampleBuffer, subtracting offset: CMTime) throws -> CMSampleBuffer {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil,
                                                     entriesNeededOut: &count) == noErr,
              count > 0, count <= maximumTimingEntries else {
            throw RecordingError.failed("The recording sample has invalid timing information.")
        }
        var entries = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: count)
        let status = entries.withUnsafeMutableBufferPointer {
            CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: $0.baseAddress,
                                                  entriesNeededOut: nil)
        }
        guard status == noErr else { throw RecordingError.failed("The recording sample timing could not be read.") }
        for index in entries.indices {
            guard entries[index].presentationTimeStamp.isNumeric else {
                throw RecordingError.failed("The recording sample timestamp is invalid.")
            }
            entries[index].presentationTimeStamp = CMTimeSubtract(entries[index].presentationTimeStamp, offset)
            if entries[index].decodeTimeStamp.isNumeric {
                entries[index].decodeTimeStamp = CMTimeSubtract(entries[index].decodeTimeStamp, offset)
            }
        }
        var result: CMSampleBuffer?
        let copied = entries.withUnsafeBufferPointer {
            CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                sampleTimingEntryCount: count, sampleTimingArray: $0.baseAddress, sampleBufferOut: &result)
        }
        guard copied == noErr, let result else { throw RecordingError.failed("The recording sample could not be retimed.") }
        return result
    }
}
