import Foundation
import GitCore
import GitterSyntax

/// The diff view's syntax colours (spec, "The diff view"), worked out from the whole source text
/// of each side and checked line for line, so a line is never coloured from a version of the file
/// it does not match: plain beats wrong.
///
/// Pure and synchronous, safe on any thread; `RepositoryStore+DiffSyntax` reads the sources and
/// calls it off the main actor.
enum DiffSyntax {
    /// Where one side's text comes from.
    enum Source: Hashable, Sendable {
        /// A blob, by the id on the diff's `index` line (full or abbreviated).
        case blob(String)
        /// The worktree file at this path under the repository's root: an unstaged diff's new side.
        case worktree(String)
        /// No text: the side does not exist, or the file is never coloured.
        case none
    }

    /// The old side is `oldBlob`; the new side is `newBlob`, except on the working copy's unstaged
    /// side, which is the worktree file. A side whose id is missing or all zeros has no text, and
    /// a binary file, one that is not UTF-8 or one with no hunks (a pure rename, a mode change)
    /// has neither.
    static func sourceSides(for diff: FileDiff, selection: Selection, staged: Bool) -> (old: Source, new: Source) {
        guard !diff.isBinary, diff.isValidUTF8, !diff.hunks.isEmpty else { return (.none, .none) }
        let old = blob(diff.oldBlob)
        switch selection {
        case .workingCopy where !staged:
            // A file deleted from the worktree shows zeros on the new side.
            guard let path = diff.newPath, blob(diff.newBlob) != .none else { return (old, .none) }
            return (old, .worktree(path))
        case .workingCopy, .commit, .stash, .comparisonChanges:
            return (old, blob(diff.newBlob))
        case .historyEnd:
            return (.none, .none)
        }
    }

    private static func blob(_ id: String?) -> Source {
        guard let id, !id.isEmpty, !id.utf8.allSatisfy({ $0 == UInt8(ascii: "0") }) else { return .none }
        return .blob(id)
    }

    /// Each line's tokens, by line id, ranges relative to its `displayText` in UTF-16 units.
    ///
    /// A context or added line is coloured from line `newNumber` of `new`, a removed line from
    /// line `oldNumber` of `old`, and only when that line's text equals the diff line's
    /// `displayText`, both without a trailing `\r`. A line that doesn't match, a `\ No newline`
    /// line and a line with no tokens get no entry; a binary or non-UTF-8 diff, or a side whose
    /// text is over the limits or failed to parse, gets none at all.
    static func lineTokens(
        for diff: FileDiff, old: String?, new: String?, language: SyntaxLanguage
    ) -> [DiffLine.ID: [SyntaxToken]] {
        guard !diff.isBinary, diff.isValidUTF8 else { return [:] }
        let oldSide = old.flatMap { Side($0, language: language) }
        let newSide = new.flatMap { Side($0, language: language) }
        guard oldSide != nil || newSide != nil else { return [:] }

        var result: [DiffLine.ID: [SyntaxToken]] = [:]
        for hunk in diff.hunks {
            for line in hunk.lines {
                let side: Side?
                let number: Int?
                switch line.kind {
                case .context, .added: (side, number) = (newSide, line.newNumber)
                case .removed: (side, number) = (oldSide, line.oldNumber)
                case .noNewline: continue
                }
                guard let side, let number, let tokens = side.tokens(ofLine: number, matching: line.displayText),
                    !tokens.isEmpty
                else { continue }
                result[line.id] = tokens
            }
        }
        return result
    }

    /// `lineTokens` from the sides' bytes: each decoded as UTF-8 (nil when it isn't), and the
    /// language detected from the displayed path and the first line of the new text, else the old.
    static func colours(for diff: FileDiff, old: Data?, new: Data?) -> [DiffLine.ID: [SyntaxToken]] {
        guard !diff.isBinary, diff.isValidUTF8 else { return [:] }
        let oldText = text(old)
        let newText = text(new)
        guard let sample = newText ?? oldText,
            let language = SyntaxLanguage.detect(path: diff.displayPath, firstLine: firstLine(of: sample))
        else { return [:] }
        return lineTokens(for: diff, old: oldText, new: newText, language: language)
    }

    /// The bytes as text, or nil when they are not valid UTF-8.
    static func text(_ data: Data?) -> String? {
        guard let data else { return nil }
        return String(validating: data, as: UTF8.self)
    }

    /// The bytes of the worktree file at `url`, or nil when it is missing, is not a regular file
    /// (a symlink, whose diff is its target's name; a FIFO, whose open would block), is over
    /// `limit` bytes or can't be read. No git: the diff's own new side is this file.
    static func worktreeBytes(at url: URL, limit: Int) -> Data? {
        // `attributesOfItem` does not follow a final symlink.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = (attributes[.size] as? NSNumber)?.intValue, size <= limit,
            let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        do {
            // One byte past the limit, in case the file grew since the size was read.
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            return data.count <= limit ? data : nil
        } catch {
            return nil
        }
    }

    /// The text before the first `\n`, found on UTF-16 units: `"\r\n"` is one `Character`.
    private static func firstLine(of text: String) -> Substring {
        guard let end = text.utf16.firstIndex(of: 0x0A) else { return text[...] }
        return text[..<end]
    }

    /// One side's text, split into lines exactly as `SyntaxHighlighter.lineTokens` splits it, with
    /// each line's tokens.
    private struct Side {
        let units: [UInt16]
        /// Each line's UTF-16 range in `units`, without its `\n` and a `\r` just before it.
        let lines: [Range<Int>]
        let tokens: [[SyntaxToken]]

        /// Nil when the text has no tokens at all: over the limits, a failed or timed-out parse.
        init?(_ text: String, language: SyntaxLanguage) {
            let all = SyntaxHighlighter.tokens(in: text, language: language)
            guard !all.isEmpty else { return nil }
            units = Array(text.utf16)
            var lines: [Range<Int>] = []
            var start = 0
            for (offset, unit) in units.enumerated() where unit == 0x0A {
                let end = offset > start && units[offset - 1] == 0x0D ? offset - 1 : offset
                lines.append(start..<end)
                start = offset + 1
            }
            lines.append(start..<units.count)
            self.lines = lines
            tokens = SyntaxHighlighter.lineTokens(all, in: text)
            guard tokens.count == lines.count else { return nil }
        }

        /// Line `number`'s tokens (1-based), when its text is `display`, both without a
        /// trailing `\r`; compared unit for unit, never by `String` equality, which would call
        /// canonically equivalent texts of different lengths equal.
        func tokens(ofLine number: Int, matching display: String) -> [SyntaxToken]? {
            let index = number - 1
            guard lines.indices.contains(index) else { return nil }
            var line = lines[index]
            if !line.isEmpty, units[line.upperBound - 1] == 0x0D { line = line.lowerBound..<(line.upperBound - 1) }
            var shown = Array(display.utf16)
            if shown.last == 0x0D { shown.removeLast() }
            guard units[line].elementsEqual(shown) else { return nil }
            return tokens[index]
        }
    }
}
