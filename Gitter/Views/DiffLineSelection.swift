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

    private(set) var selected: [Hunk.ID: Set<DiffLine.ID>] = [:]
    private var anchor: Anchor?

    func ids(for hunk: Hunk) -> Set<DiffLine.ID> {
        selected[hunk.id] ?? []
    }

    /// Adds or removes one line, and makes it the anchor for a following shift-click.
    mutating func toggle(_ line: DiffLine, in hunk: Hunk) {
        guard Self.isSelectable(line) else { return }
        var ids = ids(for: hunk)
        if ids.contains(line.id) {
            ids.remove(line.id)
        } else {
            ids.insert(line.id)
        }
        store(ids, for: hunk)
        anchor = Anchor(hunk: hunk.id, line: line.id)
    }

    /// Selects every changed line between the anchor and `line`, inclusive.
    ///
    /// The range runs over positions in `hunk.lines`, so context lines caught in the middle are
    /// simply skipped rather than cutting the range short. Without a usable anchor — none yet,
    /// or one in a different hunk — this is just a click. The anchor is left where it was, so
    /// a second shift-click re-measures from the same line instead of from the last one.
    mutating func extend(to line: DiffLine, in hunk: Hunk) {
        guard Self.isSelectable(line) else { return }
        guard let anchor, anchor.hunk == hunk.id,
            let from = hunk.lines.firstIndex(where: { $0.id == anchor.line }),
            let to = hunk.lines.firstIndex(where: { $0.id == line.id })
        else {
            toggle(line, in: hunk)
            return
        }

        var ids = self.ids(for: hunk)
        for index in min(from, to)...max(from, to) where Self.isSelectable(hunk.lines[index]) {
            ids.insert(hunk.lines[index].id)
        }
        store(ids, for: hunk)
    }

    mutating func clear(_ hunk: Hunk) {
        selected[hunk.id] = nil
        if anchor?.hunk == hunk.id { anchor = nil }
    }

    mutating func clearAll() {
        selected.removeAll()
        anchor = nil
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
