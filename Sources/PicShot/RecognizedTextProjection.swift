import Foundation

/// An exact, deliberately conservative projection from editable output back to OCR text.
/// Only copied spans acquire provenance. Replacements, separators, barcode/status appendices,
/// and text restored by undo remain unmapped; matching words are never guessed by searching.
struct RecognizedTextProjection: Sendable, Equatable {
    static let maximumMappedUTF16Count = 131_072
    static let maximumSpans = 4_096
    private(set) var mappingLimitReached = false
    struct Span: Sendable, Equatable {
        let output: NSRange
        let source: NSRange
    }
    private(set) var text: String
    private(set) var document: RecognizedTextDocument?
    private(set) var spans: [Span]

    init(text: String, document: RecognizedTextDocument? = nil) {
        self.text = text; self.document = document
        if let document, !document.text.isEmpty, text.utf16.prefix(document.text.utf16.count).elementsEqual(document.text.utf16) {
            let range = NSRange(location: 0, length: document.text.utf16.count)
            spans = [Span(output: range, source: range)]
        } else { spans = [] }
        normalize()
    }

    func sourceRanges(for outputRanges: [NSRange]) -> [NSRange] {
        project(outputRanges, reverse: false)
    }
    func outputRanges(for sourceRanges: [NSRange]) -> [NSRange] {
        project(sourceRanges, reverse: true)
    }

    /// Retains exact unchanged sides of an edit. TextKit can coalesce several edits; treating
    /// that whole replacement as new is safer than assigning a repeated word to the wrong box.
    @discardableResult mutating func replace(_ range: NSRange, with replacement: String) -> Bool {
        guard valid(range, length: text.utf16.count), let indices = Range(range, in: text) else { return false }
        let oldLength = text.utf16.count
        let newSpans = retained(in: NSRange(location: 0, length: range.location), at: 0) +
            retained(in: NSRange(location: NSMaxRange(range), length: oldLength - NSMaxRange(range)),
                     at: range.location + replacement.utf16.count)
        text.replaceSubrange(indices, with: replacement)
        spans = newSpans; normalize(); return true
    }

    /// A missing edit description (for example undo or external programmatic replacement)
    /// must not relink equal-looking text. Keep the geometry available for subsequent reruns.
    mutating func invalidate(to text: String) {
        self.text = text; spans = []
        if document != nil && text.utf16.count > Self.maximumMappedUTF16Count { mappingLimitReached = true }
    }

    mutating func joinLines() { transformLines(trim: true, separator: " ") }
    mutating func removeEmptyLines() { transformLines(trim: false, separator: "\n") }

    private mutating func transformLines(trim: Bool, separator: String) {
        let source = text as NSString
        var cursor = 0, lineStart = 0, ranges: [NSRange] = []
        // Character iteration treats CRLF as one newline and never splits a grapheme.
        for character in text {
            let part = String(character), length = part.utf16.count
            if part.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) {
                ranges.append(NSRange(location: lineStart, length: cursor - lineStart)); lineStart = cursor + length
            }
            cursor += length
        }
        ranges.append(NSRange(location: lineStart, length: cursor - lineStart))
        var output = "", mapped: [Span] = []
        var outputLength = 0, spanIndex = 0
        let separatorLength = separator.utf16.count
        for var range in ranges {
            let raw = source.substring(with: range)
            var start = raw.startIndex, end = raw.endIndex
            func isSpace(_ character: Character) -> Bool { character.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) } }
            while start < end, isSpace(raw[start]) { start = raw.index(after: start) }
            while end > start, isSpace(raw[raw.index(before: end)]) { end = raw.index(before: end) }
            guard start < end else { continue }
            if trim {
                // Trim whole composed characters. A space combined with a mark cannot be
                // partially removed while claiming the old glyph still has an exact range.
                let local = NSRange(start..<end, in: raw)
                range = NSRange(location: range.location + local.location, length: local.length)
            }
            if outputLength > 0 { output += separator; outputLength += separatorLength }
            // Source-order slices and provenance are both monotonic. Each span is passed
            // once, except a span crossing several retained lines (one visit per overlap).
            // Inserted lines before/after source text never rescan the entire span array.
            if !mappingLimitReached {
                while spanIndex < spans.count, NSMaxRange(spans[spanIndex].output) <= range.location { spanIndex += 1 }
                while spanIndex < spans.count {
                    let span = spans[spanIndex]
                    guard span.output.location < NSMaxRange(range) else { break }
                    let overlap = NSIntersectionRange(range, span.output)
                    if overlap.length > 0 {
                        guard mapped.count < Self.maximumSpans else {
                            mappingLimitReached = true; mapped.removeAll(keepingCapacity: false); break
                        }
                        mapped.append(Span(output: NSRange(location: outputLength + overlap.location - range.location, length: overlap.length),
                                           source: NSRange(location: span.source.location + overlap.location - span.output.location, length: overlap.length)))
                    }
                    if NSMaxRange(span.output) <= NSMaxRange(range) { spanIndex += 1 } else { break }
                }
            }
            output += source.substring(with: range); outputLength += range.length
        }
        text = output; spans = mapped; normalize()
    }

    private func retained(in range: NSRange, at destination: Int) -> [Span] {
        spans.compactMap { span in
            let overlap = NSIntersectionRange(range, span.output)
            guard overlap.length > 0 else { return nil }
            return Span(output: NSRange(location: destination + overlap.location - range.location, length: overlap.length),
                        source: NSRange(location: span.source.location + overlap.location - span.output.location, length: overlap.length))
        }
    }
    private func project(_ ranges: [NSRange], reverse: Bool) -> [NSRange] {
        guard let document, !mappingLimitReached, !spans.isEmpty else { return [] }
        let inputLength = reverse ? document.text.utf16.count : text.utf16.count
        let inputBoundaries = Set(reverse ? document.boundaries : Self.boundaries(text))
        let outputBoundaries = Set(reverse ? Self.boundaries(text) : document.boundaries)
        guard ranges.count <= Self.maximumSpans else { return [] }
        let inputs = Self.merge(ranges.filter {
            valid($0, length: inputLength) && $0.length > 0 &&
                inputBoundaries.contains($0.location) && inputBoundaries.contains(NSMaxRange($0))
        })
        var result: [NSRange] = [], firstSpan = 0
        // Both axes preserve original order. Sweep sorted intervals instead of an unbounded
        // edit diff or a ranges × spans cross product on every mouse-selection notification.
        for range in inputs {
            while firstSpan < spans.count {
                let from = reverse ? spans[firstSpan].source : spans[firstSpan].output
                guard NSMaxRange(from) <= range.location else { break }
                firstSpan += 1
            }
            var index = firstSpan
            while index < spans.count {
                let span = spans[index], from = reverse ? spans[index].source : spans[index].output
                guard from.location < NSMaxRange(range) else { break }
                let to = reverse ? span.output : span.source
                let overlap = NSIntersectionRange(range, from)
                if overlap.length > 0, inputBoundaries.contains(overlap.location), inputBoundaries.contains(NSMaxRange(overlap)) {
                    let projected = NSRange(location: to.location + overlap.location - from.location, length: overlap.length)
                    if outputBoundaries.contains(projected.location), outputBoundaries.contains(NSMaxRange(projected)) { result.append(projected) }
                }
                index += 1
            }
        }
        return Self.merge(result)
    }
    private mutating func normalize() {
        guard let document else { spans = []; return }
        guard !mappingLimitReached, text.utf16.count <= Self.maximumMappedUTF16Count, spans.count <= Self.maximumSpans else {
            mappingLimitReached = true; spans = []; return
        }
        let outputBoundaries = Self.boundaries(text), sourceBoundaries = Set(document.boundaries)
        let output = text as NSString, source = document.text as NSString
        var normalized: [Span] = []
        for span in spans where valid(span.output, length: output.length) && valid(span.source, length: source.length) && span.output.length == span.source.length {
            // Inserting a combining mark or ZWJ can absorb an untouched neighbor into a new
            // grapheme. Drop that neighbor's provenance instead of splitting the new cluster.
            var start = Self.lowerBound(span.output.location, in: outputBoundaries)
            var end = Self.lowerBound(NSMaxRange(span.output), in: outputBoundaries)
            if end == outputBoundaries.count || outputBoundaries[end] > NSMaxRange(span.output) { end -= 1 }
            while start <= end && !sourceBoundaries.contains(span.source.location + outputBoundaries[start] - span.output.location) { start += 1 }
            while end >= start && !sourceBoundaries.contains(span.source.location + outputBoundaries[end] - span.output.location) { end -= 1 }
            guard start < end else { continue }
            let first = outputBoundaries[start], last = outputBoundaries[end]
            let out = NSRange(location: first, length: last - first)
            let original = NSRange(location: span.source.location + first - span.output.location, length: out.length)
            guard output.substring(with: out).utf16.elementsEqual(source.substring(with: original).utf16) else { continue }
            if let previous = normalized.last, NSMaxRange(previous.output) == out.location, NSMaxRange(previous.source) == original.location {
                normalized[normalized.count - 1] = Span(output: NSRange(location: previous.output.location, length: previous.output.length + out.length),
                    source: NSRange(location: previous.source.location, length: previous.source.length + original.length))
            } else { normalized.append(Span(output: out, source: original)) }
        }
        spans = normalized
    }
    private func valid(_ range: NSRange, length: Int) -> Bool {
        range.location >= 0 && range.length >= 0 && range.location <= length && range.length <= length - range.location
    }
    private static func lowerBound(_ value: Int, in values: [Int]) -> Int {
        var lower = 0, upper = values.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if values[middle] < value { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }
    private static func boundaries(_ text: String) -> [Int] {
        var result = [0], offset = 0
        for character in text { offset += String(character).utf16.count; result.append(offset) }
        return result
    }
    private static func merge(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = result.last, NSMaxRange(last) >= range.location {
                result[result.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(range)) - last.location)
            } else { result.append(range) }
        }
        return result
    }
}
