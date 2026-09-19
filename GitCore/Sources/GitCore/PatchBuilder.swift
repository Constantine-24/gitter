import Foundation

/// Which way a generated patch is meant to be applied to the index.
public enum PatchDirection: Sendable, Hashable {
    /// `git apply --cached`; the source diff is index → worktree.
    case stage
    /// `git apply --cached --reverse`; the source diff is HEAD → index.
    case unstage
}

/// A unified diff ready for `git apply --cached [--reverse]`.
public struct Patch: Sendable, Hashable {
    public let text: String
    /// True when some emitted hunk carries no context line at all. `git apply` refuses such a
    /// hunk unless it is also given `--unidiff-zero`.
    public let needsUnidiffZero: Bool

    public init(text: String, needsUnidiffZero: Bool) {
        self.text = text
        self.needsUnidiffZero = needsUnidiffZero
    }
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

    /// Whether the selection covers the entire change of a file that is being created or
    /// removed, rather than a part of it.
    ///
    /// Such a selection cannot go through a patch: the header is always a plain modification,
    /// so applying it would leave an empty blob in the index instead of adding or removing the
    /// entry. Callers must route these to the file-level commands (`git add`, `git rm
    /// --cached` / `git restore --staged`) instead; `patch` returns nil for them.
    public static func isWholeFileChange(
        file: FileDiff, hunkIDs: Set<Hunk.ID>, lineIDs: Set<DiffLine.ID>?,
        direction: PatchDirection
    ) -> Bool {
        switch (direction, file.kind) {
        case (.stage, .deleted), (.unstage, .added): break
        default: return false
        }
        guard !file.hunks.isEmpty else { return false }
        for hunk in file.hunks {
            guard hunkIDs.contains(hunk.id) else { return false }
            guard let lineIDs else { continue }
            for line in hunk.lines where line.kind == .added || line.kind == .removed {
                guard lineIDs.contains(line.id) else { return false }
            }
        }
        return true
    }

    /// The patch for the hunks in `hunkIDs`, restricted to the changed lines in `lineIDs`.
    ///
    /// `lineIDs == nil` selects every changed line of those hunks (hunk-level staging).
    /// Returns nil when no chosen hunk has a changed line left, or when the selection is a
    /// whole-file change (see `isWholeFileChange`).
    public static func patch(
        file: FileDiff, hunkIDs: Set<Hunk.ID>, lineIDs: Set<DiffLine.ID>?,
        direction: PatchDirection
    ) -> Patch? {
        guard
            !isWholeFileChange(
                file: file, hunkIDs: hunkIDs, lineIDs: lineIDs, direction: direction)
        else { return nil }

        var body = ""
        var needsUnidiffZero = false
        // Net line-count change contributed by the hunks emitted so far. Omitted hunks change
        // nothing, so they do not count.
        var delta = 0
        for hunk in file.hunks where hunkIDs.contains(hunk.id) {
            guard
                let rendered = render(
                    hunk: hunk, lineIDs: lineIDs, direction: direction, delta: delta)
            else { continue }
            body += rendered.text
            needsUnidiffZero = needsUnidiffZero || !rendered.hasContext
            delta += rendered.newCount - rendered.oldCount
        }
        guard !body.isEmpty, let path = file.newPath ?? file.oldPath else { return nil }
        return Patch(text: fileHeader(for: path) + body, needsUnidiffZero: needsUnidiffZero)
    }

    // MARK: - Hunks

    private struct RenderedHunk {
        let text: String
        let oldCount: Int
        let newCount: Int
        let hasContext: Bool
    }

    enum Disposition { case keep, toContext, drop }

    /// What becomes of a changed line the user did not select.
    static func dispositionOfUnselected(isAdded: Bool, direction: PatchDirection) -> Disposition {
        switch (isAdded, direction) {
        // An unselected `+` stays out of the index when staging, and stays in it when
        // unstaging — where the reverse-applied patch must still match it as context.
        case (true, .stage): return .drop
        case (true, .unstage): return .toContext
        // Mirrored: an unselected `-` is still in the index when staging, and was already
        // gone from it when unstaging.
        case (false, .stage): return .toContext
        case (false, .unstage): return .drop
        }
    }

    private static func render(
        hunk: Hunk, lineIDs: Set<DiffLine.ID>?, direction: PatchDirection, delta: Int
    ) -> RenderedHunk? {
        var emitted: [EmittedLine] = []
        var oldCount = 0
        var newCount = 0
        var hasChange = false

        for line in hunk.lines {
            // Markers are not copied; they are re-derived from the emitted lines below.
            guard line.kind != .noNewline else { continue }
            var kind = EmittedLine.Kind.context
            if line.kind != .context {
                let selected = lineIDs.map { $0.contains(line.id) } ?? true
                let action =
                    selected
                    ? Disposition.keep
                    : dispositionOfUnselected(isAdded: line.kind == .added, direction: direction)
                switch action {
                case .keep:
                    kind = line.kind == .added ? .added : .removed
                    hasChange = true
                case .toContext:
                    kind = .context
                case .drop:
                    continue
                }
            }
            if kind != .added { oldCount += 1 }
            if kind != .removed { newCount += 1 }
            emitted.append(EmittedLine(kind: kind, text: line.text, sourceID: line.id))
        }

        guard hasChange else { return nil }

        let markers = noNewlineMarkers(in: hunk)
        let lines = withMarkers(emitted, markedIDs: markers.ids, marker: markers.text)
        let (oldStart, newStart) = starts(
            hunk: hunk, oldCount: oldCount, newCount: newCount, direction: direction, delta: delta)
        let header = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
            + sectionHeading(hunk.header)
        return RenderedHunk(
            text: ([header] + lines).map { $0 + "\n" }.joined(), oldCount: oldCount,
            newCount: newCount, hasContext: lines.contains { $0.first == " " })
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
}
