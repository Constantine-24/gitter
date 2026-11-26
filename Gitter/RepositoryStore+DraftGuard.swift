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

/// What the question's Discard runs, beside the sheet (a closure is not `Hashable`).
struct PendingDraftDiscard {
    let question: DraftQuestion
    let action: @MainActor () -> Void
}

/// Never lose a draft (spec, "Unsaved work"; Task 7): every action of Gitter's own that would
/// write over or remove a file whose draft has changes asks first (`confirmDiscardingDrafts`),
/// and Done asks before it drops read-only drafts with changes (`requestCloseResolver`). Closing
/// a window and quitting ask through `WindowRegistry` and `QuitGuard`, counting
/// `changedDraftPaths`.
///
/// A pristine draft never asks. Cancel does nothing at all: nothing is read, written or dropped.
///
/// **A Discard drops nothing by itself** (Ruling 39): the drafts go only when the action goes
/// ahead — in the write's success, which runs before `finishMutation` checks the drafts against
/// the reload, so Gitter's own write never leaves one detached under an "outside" label
/// (`resolverDidResolve` for the resolving writes, the skip's success, `open`'s reset, Done's
/// `closeResolver`). A later sheet cancelled (the markers question, the Replace sheet), a
/// refusal or a failure keeps every draft.
extension RepositoryStore {

    /// The files whose drafts have changes — read-only ones too, which a close or quit loses
    /// as well — sorted.
    var changedDraftPaths: [String] {
        resolverDrafts.filter { $0.value.hasUserChanges }.keys.sorted()
    }

    /// Runs `action`, which writes over or removes `paths` — after asking, when any of their
    /// drafts has changes ("Discard your changes to <file>?", Cancel / Discard Changes). The
    /// action drops the drafts itself once it has gone ahead (Ruling 39). Nothing is asked while
    /// another sheet is up; the action is then not run either.
    func confirmDiscardingDrafts(for paths: [String], then action: @escaping @MainActor () -> Void) {
        let changed = Set(paths.filter { resolverDrafts[$0]?.hasUserChanges == true }).sorted()
        guard !changed.isEmpty else {
            action()
            return
        }
        ask(DraftQuestion(paths: changed, purpose: .action), then: action)
    }

    /// Opens `url` in this window in place of its repository (Open Worktree, an open routed to
    /// this window, a value set on it): its drafts with changes are asked about first — unless
    /// `open` would refuse (a closed window, git missing, a write in progress, not a repository),
    /// which then says why in the banner with nothing asked and nothing dropped.
    func openInPlace(_ url: URL) {
        let refuses = isClosed || gitMissing || isApplyingClipboardPatch || remoteActivity?.isWrite == true
            || Self.notARepository(url) != nil
        guard !refuses else {
            open(url)
            return
        }
        confirmDiscardingDrafts(for: Array(resolverDrafts.keys)) { [weak self] in self?.open(url) }
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
        ask(DraftQuestion(paths: dropped, purpose: .done)) { [weak self] in self?.closeResolver() }
    }

    private func ask(_ question: DraftQuestion, then action: @escaping @MainActor () -> Void) {
        guard activeSheet == nil, !isClosed else { return }
        pendingDraftDiscard = PendingDraftDiscard(question: question, action: action)
        activeSheet = .discardDrafts(question)
    }

    /// The question's destructive button, only as the answer to the question on screen: what was
    /// asked runs, and drops the drafts if it goes ahead.
    func confirmDiscardDrafts(_ question: DraftQuestion) {
        guard case .discardDrafts(let shown) = activeSheet, shown == question,
            let pending = pendingDraftDiscard, pending.question == question
        else { return }
        activeSheet = nil
        pendingDraftDiscard = nil
        pending.action()
    }

    /// Cancel (or Escape): the question goes, and nothing else happens.
    func cancelDiscardDrafts() {
        if case .discardDrafts = activeSheet { activeSheet = nil }
        pendingDraftDiscard = nil
    }

    /// Drops the drafts of `paths` — Gitter's own write that went ahead (the abort's, the skip's)
    /// or a window closed — with nothing read again: the write's own reload reads the focused
    /// file. `reread`: the focused file is read again, or the focus moves on (`discardDraft`).
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
