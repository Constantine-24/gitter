import Foundation

/// Splits a rebuilt conflict into segments, and the two measurements the rebuilds need. Pure:
/// bytes in, bytes out, never decoded or re-encoded — a line is split on `\n` only, so `\r\n`
/// stays inside the segment it ends.
///
/// A marker line is exactly `markerSize` of one of `<`, `|`, `=`, `>` at the start of a line,
/// then the end of the line or (for `<`, `|`, `>`) a space and a label. A run of any other
/// length is content: git never widens its own markers for content that looks like one (M 5),
/// which is why the parse rebuild is sized past every run in the stages (`safeMarkerSize`).
enum ConflictParser {
    /// Splits text whose markers are exactly `markerSize` wide, diff3 style. nil on anything
    /// unbalanced. Bytes are never re-encoded; "\r\n" stays inside segments.
    ///
    /// A block with no base section (a non-diff3 text) has a nil `base`; an empty base section
    /// — an add/add's — is empty data.
    static func parse(_ text: Data, markerSize: Int) -> [ConflictSegment]? {
        enum Section { case common, ours, base, theirs }
        var section = Section.common
        var segments: [ConflictSegment] = []
        var common = Data(), ours = Data(), base: Data?, theirs = Data()

        for line in lines(of: text) {
            let marker = self.marker(line, size: markerSize)
            switch (section, marker) {
            case (.common, UInt8(ascii: "<")):
                if !common.isEmpty { segments.append(.common(common)) }
                common = Data()
                ours = Data()
                base = nil
                theirs = Data()
                section = .ours
            case (.common, nil):
                common.append(line)
            case (.ours, UInt8(ascii: "|")):
                base = Data()
                section = .base
            case (.ours, UInt8(ascii: "=")), (.base, UInt8(ascii: "=")):
                section = .theirs
            case (.ours, nil):
                ours.append(line)
            case (.base, nil):
                base?.append(line)
            case (.theirs, UInt8(ascii: ">")):
                segments.append(.block(ConflictBlock(ours: ours, base: base, theirs: theirs)))
                section = .common
            case (.theirs, nil):
                theirs.append(line)
            default:
                return nil
            }
        }
        guard section == .common else { return nil }
        if !common.isEmpty { segments.append(.common(common)) }
        return segments
    }

    /// 1 + the longest run of `<`, `=`, `>` or `|` that starts a line in any of `texts`; min 7.
    static func safeMarkerSize(_ texts: [Data]) -> Int {
        var longest = 0
        for text in texts {
            for line in lines(of: text) {
                guard let first = line.first, markerCharacters.contains(first) else { continue }
                longest = max(longest, line.prefix { $0 == first }.count)
            }
        }
        return max(7, longest + 1)
    }

    /// Replaces "<{N} label", ">{N} label", "|{N} label" lines with the bare marker + EOL (M 26).
    ///
    /// The rule of M 26's measured comparison, `^(<{N}|>{N}|\|{N})(?: [^\r\n]*)?(\r?\n?)$`: the
    /// label is a space and anything but CR or LF, and the line keeps its own ending.
    static func withoutLabels(_ text: Data, markerSize: Int) -> Data {
        var result = Data()
        result.reserveCapacity(text.count)
        for line in lines(of: text) {
            guard let marker = marker(line, size: markerSize), marker != UInt8(ascii: "=") else {
                result.append(line)
                continue
            }
            var body = line[...]
            var ending = Data()
            if body.last == lf {
                ending.insert(lf, at: 0)
                body = body.dropLast()
            }
            if body.last == cr {
                ending.insert(cr, at: 0)
                body = body.dropLast()
            }
            let label = body.dropFirst(markerSize)
            guard label.isEmpty || !label.contains(cr) else {
                result.append(line)
                continue
            }
            result.append(body.prefix(markerSize))
            result.append(ending)
        }
        return result
    }

    // MARK: - Lines

    private static let lf = UInt8(ascii: "\n")
    private static let cr = UInt8(ascii: "\r")
    private static let space = UInt8(ascii: " ")
    private static let markerCharacters: Set<UInt8> = [
        UInt8(ascii: "<"), UInt8(ascii: "|"), UInt8(ascii: "="), UInt8(ascii: ">"),
    ]

    /// Each line with its `\n`; the last one without, when the text does not end in one.
    private static func lines(of text: Data) -> [Data] {
        var result: [Data] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex(of: lf).map { text.index(after: $0) } ?? text.endIndex
            result.append(text[start..<end])
            start = end
        }
        return result
    }

    /// The marker character when `line` is a marker line of exactly `size`, else nil.
    ///
    /// After the run: the end of the line (`\n`, `\r\n`, or the end of the text, with or without
    /// a `\r`), or — for `<`,
    /// `|` and `>`, which git labels — a space. `=` is never labelled, so `======= x` is content.
    private static func marker(_ line: Data, size: Int) -> UInt8? {
        guard let first = line.first, markerCharacters.contains(first) else { return nil }
        let run = line.prefix { $0 == first }.count
        guard run == size else { return nil }
        let rest = line.dropFirst(size)
        let isEnd = rest.isEmpty || rest.elementsEqual([lf]) || rest.elementsEqual([cr, lf])
            || rest.elementsEqual([cr])
        if isEnd { return first }
        if first != UInt8(ascii: "="), rest.first == space { return first }
        return nil
    }
}
