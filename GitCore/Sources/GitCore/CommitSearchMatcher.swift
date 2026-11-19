import Foundation

/// Message, Author or ID matching, done in the app over what one `log` read returned. git's
/// `--grep` and `--author` combine by AND, and `.mailmap` changes what `--author` sees, so
/// neither can say "the text is in the message or the author or is the id's start" the way the
/// row shows it (design: Git).
public enum CommitSearchMatcher {
    /// Any run of whitespace and line breaks as one space, and nothing at either end: a phrase
    /// hard-wrapped across two lines of a body still matches.
    public static func normalized(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in s.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// Whether `q` can be the start of a commit id: 4 to 40 hexadecimal characters.
    public static func isIDQuery(_ q: String) -> Bool {
        (4...40).contains(q.utf8.count) && q.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
        }
    }

    /// The query is one literal phrase, folded for case (Unicode) and for whitespace. It matches
    /// when the message, the author's name or the author's email holds it, or when it is an id
    /// query and the full `sha` starts with it. A query of only blanks matches nothing.
    public static func matches(
        query: String, sha: String, authorName: String, authorEmail: String, message: String
    ) -> Bool {
        let needle = normalized(query)
        guard !needle.isEmpty else { return false }
        if isIDQuery(needle), sha.lowercased().hasPrefix(needle.lowercased()) { return true }
        return contains(normalized(authorName), needle)
            || contains(normalized(authorEmail), needle)
            || contains(normalized(message), needle)
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: .caseInsensitive) != nil
    }
}

extension CommitSearchMatcher {
    /// One search's matcher, for a read of many commits. The query is normalised once. A field is
    /// matched on its UTF-8 bytes, without a `String`, by turning each scalar into a fold key
    /// (`keys`): whitespace runs become one space, and a letter becomes its case-folded form.
    /// Only scalars whose folding is plain take that path. A scalar that is not (a combining mark,
    /// `ß`, the Kelvin sign, anything outside the BMP,
    /// invalid UTF-8) sends that one field to the full Unicode way of `matches(query:…)`. That the
    /// keyed answer equals the Unicode one for every scalar the table trusts is not proved: it was
    /// checked by an exhaustive probe over all keyed scalars with ASCII neighbours (F1 fix round 3,
    /// 0 divergences) and by a seeded differential test, which a new Unicode version could outdate. 100,000 commits with 40-word bodies went from
    /// about 4.7 s to the figure in docs/DEVELOPMENT.md.
    public final class Session {
        private let needle: String
        private let needleKeys: [UInt16]       // empty when the needle needs the Unicode way
        private let idPrefix: [UInt8]?         // lowercase hex when the query is an id query
        private var buffer: UnsafeMutablePointer<UInt16>
        private var capacity: Int

        public init(query: String) {
            needle = CommitSearchMatcher.normalized(query)
            var keys: [UInt16] = []
            for scalar in needle.unicodeScalars {
                guard scalar.value < 0x10000, let key = Session.keys[Int(scalar.value)] as UInt16?, key != 0 else {
                    keys = []; break
                }
                keys.append(key)
            }
            needleKeys = keys
            idPrefix = CommitSearchMatcher.isIDQuery(needle) ? needle.utf8.map(Session.lower) : nil
            capacity = 4_096
            buffer = .allocate(capacity: capacity)
        }

        deinit { buffer.deallocate() }

        private static func lower(_ byte: UInt8) -> UInt8 {
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte | 0x20 : byte
        }

        /// The fold key of every BMP scalar, 0 for one that must not be trusted: whitespace
        /// (`normalized`'s set) is 0x20; a scalar with a one-scalar BMP case mapping each way is
        /// `lower(upper(c))`; the rest (combining and format characters, Hangul jamo, multi-scalar mappings, mappings into ASCII from outside it, surrogates)
        /// are 0. An ASCII letter is its lower case.
        static let keys: [UInt16] = {
            var table = [UInt16](repeating: 0, count: 0x10000)
            for value in 0..<0x10000 {
                guard let scalar = Unicode.Scalar(UInt32(value)) else { continue }
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { table[value] = 0x20; continue }
                if value < 0x80 {
                    table[value] = UInt16(lower(UInt8(value)))
                    continue
                }
                let properties = scalar.properties
                switch properties.generalCategory {
                case .nonspacingMark, .spacingMark, .enclosingMark, .format, .control, .privateUse, .unassigned,
                     .lineSeparator, .paragraphSeparator, .spaceSeparator:
                    continue
                default: break
                }
                if properties.canonicalCombiningClass.rawValue != 0 { continue }
                // Canonical singletons (U+037E is `;`, U+F900 is U+8C48) and their targets:
                // canonical equivalence makes them equal in the Unicode way, and a key would not.
                if Array(String(scalar).precomposedStringWithCanonicalMapping.unicodeScalars) != [scalar] { continue }
                // Grapheme extenders that are not marks (Thai sara am, halfwidth dakuten): joined to
                // the letter before them, so a search for that letter alone must not find them.
                if ("a" + String(scalar)).count == 1 || (String(scalar) + "a").count == 1 { continue }
                let upper = properties.uppercaseMapping.unicodeScalars
                let title = properties.titlecaseMapping.unicodeScalars
                let low = properties.lowercaseMapping.unicodeScalars
                guard upper.count == 1, low.count == 1, title.count == 1 else { continue }
                if upper.first!.isASCII || low.first!.isASCII || title.first!.isASCII { continue }
                // Full case folding (`ẞ` folds to `ss` though no case mapping says so).
                let fold = String(scalar).folding(options: .caseInsensitive, locale: nil).unicodeScalars
                if fold.count != 1 || fold.first!.isASCII { continue }
                // Hangul jamo combine into syllables under canonical equivalence.
                if (0x1100...0x11FF).contains(value) || (0xA960...0xA97F).contains(value)
                    || (0xD7B0...0xD7FF).contains(value) { continue }
                let folded = upper.first!.properties.lowercaseMapping.unicodeScalars
                guard folded.count == 1, folded.first!.value < 0x10000 else { continue }
                table[value] = UInt16(folded.first!.value)
            }
            return table
        }()

        public func matches(sha: UnsafeBufferPointer<UInt8>, authorName: UnsafeBufferPointer<UInt8>,
                            authorEmail: UnsafeBufferPointer<UInt8>, message: UnsafeBufferPointer<UInt8>) -> Bool {
            guard !needle.isEmpty else { return false }
            if let id = idPrefix, sha.count >= id.count {
                var same = true
                for index in 0..<id.count where Session.lower(sha[index]) != id[index] { same = false; break }
                if same { return true }
            }
            return field(authorName) || field(authorEmail) || field(message)
        }

        private func field(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
            if bytes.isEmpty { return false }
            if !needleKeys.isEmpty, let found = keyedContains(bytes) { return found }
            let text = String(decoding: bytes, as: UTF8.self)
            return CommitSearchMatcher.normalized(text).range(of: needle, options: .caseInsensitive) != nil
        }

        /// The keyed search, or nil when a scalar of `bytes` is not to be trusted.
        private func keyedContains(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool? {
            if bytes.count > capacity {
                buffer.deallocate()
                capacity = bytes.count * 2
                buffer = .allocate(capacity: capacity)
            }
            var length = 0
            var pendingSpace = false
            var index = 0
            let count = bytes.count
            return Session.keys.withUnsafeBufferPointer { table -> Bool? in
                while index < count {
                    let byte = bytes[index]
                    var value = UInt32(byte)
                    if byte < 0x80 {
                        index += 1
                    } else if byte & 0xE0 == 0xC0, index + 1 < count, bytes[index + 1] & 0xC0 == 0x80, byte >= 0xC2 {
                        value = UInt32(byte & 0x1F) << 6 | UInt32(bytes[index + 1] & 0x3F)
                        index += 2
                    } else if byte & 0xF0 == 0xE0, index + 2 < count, bytes[index + 1] & 0xC0 == 0x80,
                              bytes[index + 2] & 0xC0 == 0x80 {
                        value = UInt32(byte & 0x0F) << 12 | UInt32(bytes[index + 1] & 0x3F) << 6
                            | UInt32(bytes[index + 2] & 0x3F)
                        if value < 0x800 { return nil }
                        index += 3
                    } else {
                        return nil
                    }
                    let key = table[Int(value)]
                    if key == 0 { return nil }
                    if key == 0x20 {
                        pendingSpace = length > 0
                    } else {
                        if pendingSpace { buffer[length] = 0x20; length += 1; pendingSpace = false }
                        buffer[length] = key
                        length += 1
                    }
                }
                return needleKeys.withUnsafeBufferPointer { needle -> Bool in
                    let m = needle.count
                    guard length >= m else { return false }
                    let first = needle[0]
                    var start = 0
                    while start <= length - m {
                        if buffer[start] == first {
                            var offset = 1
                            while offset < m, buffer[start + offset] == needle[offset] { offset += 1 }
                            if offset == m { return true }
                        }
                        start += 1
                    }
                    return false
                }
            }
        }
    }
}
