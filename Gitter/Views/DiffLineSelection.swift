import GitCore

/// Which changed lines the user has picked, per hunk.
///
/// A plain value with no dependency on SwiftUI or on the store: all it knows is a hunk's
/// `lines` array, which is what makes the shift-click range well defined. Each hunk keeps its
/// own set, because each hunk has its own button — picking lines in one hunk never disturbs
/// another.
///
/// The ids are only meaningful within one parsed diff (`DiffLine.id` is an index assigned by
/// the parser), so whoever owns this value has to `clearAll()` whenever the diff reloads.
struct DiffLineSelection: Equatable {

    /// Where a shift-click measures from: the line of the last plain click or shift-click.
    private struct Anchor: Equatable {
        let hunk: Hunk.ID
        let line: DiffLine.ID
    }

    /// Keyed by `Hunk.ID` within ONE `FileDiff`; the diff pane shows a single file at a time,
    /// so a hunk id is unique here. (If it ever shows several, key by `(FileDiff.ID, Hunk.ID)`.)
    private(set) var selected: [Hunk.ID: Set<DiffLine.ID>] = [:]
    private var anchor: Anchor?
    /// What the last `extend` from the current anchor put in. Dragging the range back has to
    /// take those lines out again, while leaving alone whatever was picked before it.
    private var lastExtension: Set<DiffLine.ID> = []

    func ids(for hunk: Hunk) -> Set<DiffLine.ID> {
        selected[hunk.id] ?? []
    }

    /// Adds or removes one line.
    ///
    /// Selecting moves the anchor here, so the next shift-click measures from this line.
    /// Deselecting does not: the user is taking a line out of a range, not starting a new one —
    /// unless the line being deselected *is* the anchor, which then has nothing left to mean.
    mutating func toggle(_ line: DiffLine, in hunk: Hunk) {
        guard Self.isSelectable(line) else { return }
        var ids = ids(for: hunk)
        let selecting = !ids.contains(line.id)
        if selecting {
            ids.insert(line.id)
        } else {
            ids.remove(line.id)
        }
        store(ids, for: hunk)

        // Any hand-picked line ends the range the last shift-click drew: from here on a
        // shift-click builds a fresh one and has nothing of its own to take back.
        lastExtension = []
        let here = Anchor(hunk: hunk.id, line: line.id)
        if selecting {
            anchor = here
        } else if anchor == here {
            anchor = nil
        }
    }

    /// Selects every changed line between the anchor and `line`, inclusive.
    ///
    /// The range runs over positions in `hunk.lines`, so context lines caught in the middle are
    /// simply skipped rather than cutting the range short. Without a usable anchor — none yet,
    /// or one in a different hunk — this is just a click.
    ///
    /// Shift-clicking again *replaces* the range rather than growing the selection: the lines
    /// the previous extend added are taken out first, so a shorter range really is shorter.
    /// Lines picked by hand before the extend are untouched, and the anchor stays where it is,
    /// so every shift-click measures from the same line.
    mutating func extend(to line: DiffLine, in hunk: Hunk) {
        guard Self.isSelectable(line) else { return }
        guard let anchor, anchor.hunk == hunk.id,
            let from = hunk.lines.firstIndex(where: { $0.id == anchor.line }),
            let to = hunk.lines.firstIndex(where: { $0.id == line.id })
        else {
            toggle(line, in: hunk)
            return
        }

        var range: Set<DiffLine.ID> = []
        for index in min(from, to)...max(from, to) where Self.isSelectable(hunk.lines[index]) {
            range.insert(hunk.lines[index].id)
        }

        var ids = self.ids(for: hunk)
        ids.subtract(lastExtension)
        ids.formUnion(range)  // always contains the anchor, so subtracting cannot lose it
        store(ids, for: hunk)
        lastExtension = range
    }

    mutating func clear(_ hunk: Hunk) {
        selected[hunk.id] = nil
        if anchor?.hunk == hunk.id {
            anchor = nil
            lastExtension = []
        }
    }

    mutating func clearAll() {
        selected.removeAll()
        anchor = nil
        lastExtension = []
    }

    /// Keeps an emptied hunk out of the dictionary, so `selected` is empty exactly when
    /// nothing is picked anywhere.
    private mutating func store(_ ids: Set<DiffLine.ID>, for hunk: Hunk) {
        selected[hunk.id] = ids.isEmpty ? nil : ids
    }

    /// Only added and removed lines can be staged; context and "\ No newline" lines carry no
    /// change of their own.
    private static func isSelectable(_ line: DiffLine) -> Bool {
        line.kind == .added || line.kind == .removed
    }
}
