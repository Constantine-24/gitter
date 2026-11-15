import Foundation
import GitCore

/// The question before a draft is dropped by Gitter itself (`BranchSheet.discardDrafts`): the
/// files whose drafts have changes, and whether answering it closes focus mode (Done) or lets
/// one of Gitter's own actions go on.
struct DraftQuestion: Hashable, Sendable {
    enum Purpose: Hashable, Sendable {
        /// Mark Resolved, a whole-file take, delete or keep, the row's stage button, Take for N
        /// Files, Skip, an open in this window: Cancel / Discard Changes.
        case action
        /// Done (or Escape) over read-only drafts with changes (Ruling 36).
        case done
    }

    /// The files with changes it names, sorted.
    let paths: [String]
    let purpose: Purpose

    /// Done over several files asks the close question, with Discard and Close.
    var closes: Bool { purpose == .done && paths.count > 1 }
}

/// What the question's Discard runs, beside the sheet (a closure is not `Hashable`): every
/// draft of the action's files goes — the pristine ones too, so Gitter's own write never leaves
/// one detached under an "outside" label (Ruling 35) — and then the action.
struct PendingDraftDiscard {
    let question: DraftQuestion
    let drops: [String]
    let action: @MainActor () -> Void
}

/// Never lose a draft (spec, "Unsaved work"; Task 7): every action of Gitter's own that would
/// write over or remove a file whose draft has changes asks first (`confirmDiscardingDrafts`),
/// and Done asks before it drops read-only drafts with changes (`requestCloseResolver`). Closing
/// a window and quitting ask through `WindowRegistry` and `QuitGuard`, counting
/// `changedDraftPaths`.
///
/// A pristine draft never asks. Cancel does nothing at all: nothing is read, written or dropped.
extension RepositoryStore {

    /// The files whose drafts have changes — read-only ones too, which a close or quit loses
    /// as well — sorted.
    var changedDraftPaths: [String] {
        resolverDrafts.filter { $0.value.hasUserChanges }.keys.sorted()
    }

    /// Runs `action`, which writes over or removes `paths` — after asking, when any of their
    /// drafts has changes ("Discard your changes to <file>?", Cancel / Discard Changes). Before
    /// `action` runs, every draft of `paths` is dropped, pristine ones included. Nothing is asked
    /// while another sheet is up; the action is then not run either.
    func confirmDiscardingDrafts(for paths: [String], then action: @escaping @MainActor () -> Void) {
        var drops: [String] = []
        for path in paths where resolverDrafts[path] != nil && !drops.contains(path) { drops.append(path) }
        let changed = drops.filter { resolverDrafts[$0]?.hasUserChanges == true }.sorted()
        guard !changed.isEmpty else {
            dropDrafts(drops)
            action()
            return
        }
        ask(DraftQuestion(paths: changed, purpose: .action), drops: drops, then: action)
    }

    /// Done (the toolbar's, Escape's, the harness's): asks first when it would drop read-only
    /// drafts — resolved outside, or left by their operation — that have changes; one names its
    /// file, several are counted with Discard and Close (Ruling 36). Pristine ones go silently,
    /// and an edited draft changed outside is kept (Ruling 25).
    func requestCloseResolver() {
        guard resolverFocus != nil else { return }
        let dropped = resolverDrafts.filter { $0.value.hasUserChanges && !$0.value.isEditable }.keys.sorted()
        guard !dropped.isEmpty else {
            closeResolver()
            return
        }
        ask(DraftQuestion(paths: dropped, purpose: .done), drops: []) { [weak self] in self?.closeResolver() }
    }

    private func ask(_ question: DraftQuestion, drops: [String], then action: @escaping @MainActor () -> Void) {
        guard activeSheet == nil, !isClosed else { return }
        pendingDraftDiscard = PendingDraftDiscard(question: question, drops: drops, action: action)
        activeSheet = .discardDrafts(question)
    }

    /// The question's destructive button, only as the answer to the question on screen: the
    /// drafts go, then what was asked runs.
    func confirmDiscardDrafts(_ question: DraftQuestion) {
        guard case .discardDrafts(let shown) = activeSheet, shown == question,
            let pending = pendingDraftDiscard, pending.question == question
        else { return }
        activeSheet = nil
        pendingDraftDiscard = nil
        dropDrafts(pending.drops)
        pending.action()
    }

    /// Cancel (or Escape): the question goes, and nothing else happens.
    func cancelDiscardDrafts() {
        if case .discardDrafts = activeSheet { activeSheet = nil }
        pendingDraftDiscard = nil
    }

    /// Drops the drafts of `paths`, with nothing read again: the action that follows writes, and
    /// its refresh reads the focused file afresh — a read now would open a draft on what that
    /// write is about to change. `reread` (a quit's Discard, after which nothing writes): the
    /// focused file is read again, or the focus moves on (`discardDraft`).
    func dropDrafts(_ paths: [String], reread: Bool = false) {
        let present = paths.filter { resolverDrafts[$0] != nil }
        guard !present.isEmpty else { return }
        let focused = resolverFocus?.path
        var drafts = resolverDrafts
        for path in present where !(reread && path == focused) { drafts[path] = nil }
        setResolverDrafts(drafts)
        if reread, let focused, present.contains(focused) { discardDraft(focused) }
        if resolverFocus == nil, resolverDrafts.isEmpty { setResolverOperation(nil) }
    }
}
