import Foundation

// `\ No newline at end of file` handling.
//
// A marker after line L is a claim about the files, not about L: it says that every side L
// occupies ends at L without a trailing newline. Rewriting a hunk can falsify that claim —
// dropping L, or letting other lines follow it on one side — and `git apply` then joins two
// lines together without reporting anything. So the builder never copies a marker: it emits
// the lines first and re-derives the markers from what actually came out.
extension PatchBuilder {

    struct EmittedLine {
        enum Kind { case context, added, removed }

        let kind: Kind
        let text: String
        /// The `DiffLine` this came from, used to look the original marker up.
        let sourceID: DiffLine.ID

        var isOnOldSide: Bool { kind != .added }
        var isOnNewSide: Bool { kind != .removed }

        var rendered: String {
            switch kind {
            case .context: return " " + text
            case .added: return "+" + text
            case .removed: return "-" + text
            }
        }
    }

    /// The IDs of the lines a marker follows in the original hunk, and the marker's own text.
    ///
    /// `DiffParser` strips the leading `"\ "`, so the text is normally
    /// `No newline at end of file`.
    static func noNewlineMarkers(in hunk: Hunk) -> (ids: Set<DiffLine.ID>, text: String) {
        var ids: Set<DiffLine.ID> = []
        var text = "No newline at end of file"
        var previous: DiffLine.ID?
        for line in hunk.lines {
            if line.kind == .noNewline {
                if let previous { ids.insert(previous) }
                text = line.text
            } else {
                previous = line.id
            }
        }
        return (ids, text)
    }

    /// Renders `lines`, putting a marker back only where it is still true.
    ///
    /// A marker can only belong after the last emitted line of a side, and only if that line
    /// carried one in the source. Three cases arise:
    /// - the line ends both sides (a context line): a plain marker after it says so;
    /// - the line ends one side and already sits on that side alone (`-` or `+`): likewise;
    /// - the line ends one side but is emitted as context because it was converted from an
    ///   unselected change, while the other side runs on past it. A marker after a context
    ///   line would wrongly claim both sides end there, so the line is split back into its two
    ///   halves and the marker is bound to the half that really ends.
    static func withMarkers(
        _ lines: [EmittedLine], markedIDs: Set<DiffLine.ID>, marker text: String
    ) -> [String] {
        guard !markedIDs.isEmpty else { return lines.map(\.rendered) }
        let marker = "\\ " + text
        let lastOld = lines.lastIndex(where: \.isOnOldSide)
        let lastNew = lines.lastIndex(where: \.isOnNewSide)

        var out: [String] = []
        out.reserveCapacity(lines.count + 2)
        for (index, line) in lines.enumerated() {
            let ends = markedIDs.contains(line.sourceID)
            switch (ends, index == lastOld, index == lastNew) {
            case (true, true, true):
                out.append(line.rendered)
                out.append(marker)
            case (true, true, false):
                // The old side ends here; the new side does not.
                out.append("-" + line.text)
                out.append(marker)
                if line.kind == .context { out.append("+" + line.text) }
            case (true, false, true):
                // The new side ends here; the old side does not.
                if line.kind == .context { out.append("-" + line.text) }
                out.append("+" + line.text)
                out.append(marker)
            default:
                // Either the line carried no marker, or it is no longer the last line of any
                // side it occupies, which makes the old claim false: drop it.
                out.append(line.rendered)
            }
        }
        return out
    }
}
