import Foundation

/// Which way a generated patch is meant to be applied to the index.
public enum PatchDirection: Sendable, Hashable {
    /// `git apply --cached`; the source diff is index → worktree.
    case stage
    /// `git apply --cached --reverse`; the source diff is HEAD → index.
    case unstage
}

/// Builds a unified diff that stages or unstages a chosen subset of a file's changed lines.
///
/// Pure: it never touches git or the file system, it only rewrites a parsed `FileDiff`.
public enum PatchBuilder {

    /// Whether `file` can be staged or unstaged hunk- or line-wise at all.
    ///
    /// A staged deletion has no index entry left to patch, and an unstaged addition is an
    /// untracked file, so both are file-level only.
    public static func supportsPartial(_ file: FileDiff, direction: PatchDirection) -> Bool {
        guard !file.isBinary, !file.hunks.isEmpty else { return false }
        switch direction {
        case .stage: return file.kind == .modified || file.kind == .deleted
        case .unstage: return file.kind == .modified || file.kind == .added
        }
    }

    /// The patch for the hunks in `hunkIDs`, restricted to the changed lines in `lineIDs`.
    ///
    /// `lineIDs == nil` selects every changed line of those hunks (hunk-level staging).
    /// Returns nil when no chosen hunk has a changed line left.
    public static func patch(
        file: FileDiff, hunkIDs: Set<Hunk.ID>, lineIDs: Set<DiffLine.ID>?,
        direction: PatchDirection
    ) -> String? {
        var body = ""
        // Net line-count change contributed by the hunks emitted so far. Omitted hunks change
        // nothing, so they do not count.
        var delta = 0
        for hunk in file.hunks where hunkIDs.contains(hunk.id) {
            guard
                let rendered = render(
                    hunk: hunk, lineIDs: lineIDs, direction: direction, delta: delta)
            else { continue }
            body += rendered.text
            delta += rendered.newCount - rendered.oldCount
        }
        guard !body.isEmpty, let path = file.newPath ?? file.oldPath else { return nil }
        return fileHeader(for: path) + body
    }

    // MARK: - Hunks

    private struct RenderedHunk {
        let text: String
        let oldCount: Int
        let newCount: Int
    }

    private enum Disposition { case keep, toContext, drop }

    private static func disposition(
        of kind: DiffLineKind, selected: Bool, direction: PatchDirection
    ) -> Disposition {
        if selected { return .keep }
        switch (kind, direction) {
        // An unselected `+` stays out of the index when staging, and stays in it when
        // unstaging — where the reverse-applied patch must still match it as context.
        case (.added, .stage): return .drop
        case (.added, .unstage): return .toContext
        // Mirrored: an unselected `-` is still in the index when staging, and was already
        // gone from it when unstaging.
        case (.removed, .stage): return .toContext
        case (.removed, .unstage): return .drop
        default: return .keep
        }
    }

    private static func render(
        hunk: Hunk, lineIDs: Set<DiffLine.ID>?, direction: PatchDirection, delta: Int
    ) -> RenderedHunk? {
        var lines: [String] = []
        var oldCount = 0
        var newCount = 0
        var hasChange = false
        // Whether the nearest preceding non-marker line survived; a `\ No newline` marker
        // annotates that line and shares its fate.
        var precedingLineSurvived = true

        for line in hunk.lines {
            switch line.kind {
            case .context:
                lines.append(" " + line.text)
                oldCount += 1
                newCount += 1
                precedingLineSurvived = true
            case .noNewline:
                if precedingLineSurvived { lines.append("\\ " + line.text) }
            case .added, .removed:
                let selected = lineIDs.map { $0.contains(line.id) } ?? true
                switch disposition(of: line.kind, selected: selected, direction: direction) {
                case .keep:
                    lines.append((line.kind == .added ? "+" : "-") + line.text)
                    if line.kind == .added { newCount += 1 } else { oldCount += 1 }
                    hasChange = true
                    precedingLineSurvived = true
                case .toContext:
                    lines.append(" " + line.text)
                    oldCount += 1
                    newCount += 1
                    precedingLineSurvived = true
                case .drop:
                    precedingLineSurvived = false
                }
            }
        }

        guard hasChange else { return nil }

        let (oldStart, newStart) = starts(
            hunk: hunk, oldCount: oldCount, newCount: newCount, direction: direction, delta: delta)
        let header = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
            + sectionHeading(hunk.header)
        return RenderedHunk(
            text: ([header] + lines).map { $0 + "\n" }.joined(), oldCount: oldCount,
            newCount: newCount)
    }

    /// Recomputes the hunk's start lines.
    ///
    /// One side is an anchor that must stay exactly where the source diff put it, because the
    /// patch's content on that side is unchanged by the selection and has to match what git
    /// reads. For `.stage` the patch is applied forward, so git matches its OLD side against
    /// the index: `oldStart` is the anchor. For `.unstage` the patch is applied with
    /// `--reverse`, so git matches its NEW side against the index instead, and `newStart` is
    /// the anchor. The other side is then derived through the running delta of the hunks
    /// emitted before this one.
    ///
    /// A start is stated relative to the first line of the hunk's region on that side. When a
    /// count is zero there is no such line, and git writes the line *before* the change
    /// instead (`@@ -2,0 +3,2 @@`, `@@ -1,2 +0,0 @@`), which is what the ±1 corrections do.
    private static func starts(
        hunk: Hunk, oldCount: Int, newCount: Int, direction: PatchDirection, delta: Int
    ) -> (old: Int, new: Int) {
        switch direction {
        case .stage:
            let anchor = hunk.oldCount > 0 ? hunk.oldStart : hunk.oldStart + 1
            let derived = anchor + delta
            return (oldCount > 0 ? anchor : anchor - 1, newCount > 0 ? derived : derived - 1)
        case .unstage:
            let anchor = hunk.newCount > 0 ? hunk.newStart : hunk.newStart + 1
            let derived = anchor - delta
            return (oldCount > 0 ? derived : derived - 1, newCount > 0 ? anchor : anchor - 1)
        }
    }

    /// Everything after the second `@@` of the original header (the section heading).
    private static func sectionHeading(_ header: String) -> String {
        guard let first = header.range(of: "@@"),
            let second = header.range(of: "@@", range: first.upperBound..<header.endIndex)
        else { return "" }
        return String(header[second.upperBound...])
    }

    // MARK: - File header

    /// Always a plain modification: `git apply --cached` patches the index entry, so mode
    /// lines for an addition or a deletion would be wrong for a partial selection.
    private static func fileHeader(for path: String) -> String {
        let old = quote(prefix: "a/", path: path)
        let new = quote(prefix: "b/", path: path)
        // git appends a TAB when the rendered name contains a space, so the name stays
        // unambiguous on the `---`/`+++` lines.
        let oldTab = old.contains(" ") ? "\t" : ""
        let newTab = new.contains(" ") ? "\t" : ""
        return "diff --git \(old) \(new)\n--- \(old)\(oldTab)\n+++ \(new)\(newTab)\n"
    }

    /// git's `quote_c_style`: the prefix and the path are quoted together inside one pair of
    /// double quotes as soon as any byte needs escaping.
    private static func quote(prefix: String, path: String) -> String {
        let bytes = Array((prefix + path).utf8)
        guard bytes.contains(where: needsEscape) else { return prefix + path }
        var out = "\""
        for byte in bytes {
            switch byte {
            case 0x07: out += "\\a"
            case 0x08: out += "\\b"
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0B: out += "\\v"
            case 0x0C: out += "\\f"
            case 0x0D: out += "\\r"
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            default:
                if needsEscape(byte) {
                    let octal = String(byte, radix: 8)
                    out += "\\" + String(repeating: "0", count: 3 - octal.count) + octal
                } else {
                    out.append(Character(UnicodeScalar(byte)))
                }
            }
        }
        return out + "\""
    }

    private static func needsEscape(_ byte: UInt8) -> Bool {
        byte < 0x20 || byte >= 0x7F || byte == 0x22 || byte == 0x5C
    }
}
