import Foundation
import GitCore

/// Every sentence the history actions put on screen: the commit and branch menus' items and
/// reasons, the Cherry-Pick / Revert sheet, the Rebase sheet, their notices and their refusals.
/// Pure, so `HistoryWordingTests` pins each one.
///
/// Subjects are somebody else's text and go through `RemoteWording.plain` (a bidi override or an
/// escape sequence cannot rearrange a line); lists stop at three and say how many more.
enum HistoryWording {

    // MARK: - Names and lists

    /// `1a2b3c4 Add parser`.
    static func commit(_ ref: CommitRef) -> String {
        "\(ref.sha.prefix(7)) \(RemoteWording.plain(ref.subject))"
    }

    /// The first three commits, then "and N more".
    static func commits(_ refs: [CommitRef]) -> String {
        capped(refs.map(commit))
    }

    /// The first three paths, then "and N more".
    static func names(_ paths: [String]) -> String {
        capped(paths.map(RemoteWording.plain))
    }

    private static func capped(_ items: [String]) -> String {
        let shown = items.prefix(3).joined(separator: ", ")
        return items.count > 3 ? "\(shown) and \(items.count - 3) more" : shown
    }

    static func count(_ n: Int) -> String {
        n == 1 ? "1 commit" : "\(n) commits"
    }

    /// What HEAD named when the plan was made (`HistoryPlan.headRef`): the quoted branch, or
    /// "the detached HEAD" for an empty one.
    static func branch(headRef: String) -> String {
        guard !headRef.isEmpty else { return "the detached HEAD" }
        let prefix = "refs/heads/"
        let name = headRef.hasPrefix(prefix) ? String(headRef.dropFirst(prefix.count)) : headRef
        return "\"\(name)\""
    }

    /// A rebase target as the user picked it: a branch quoted (`"feature"`, `"origin/main"`), a
    /// full object id as its short sha.
    static func target(_ name: String) -> String {
        if isObjectID(name) { return String(name.prefix(7)) }
        for prefix in ["refs/heads/", "refs/remotes/"] where name.hasPrefix(prefix) {
            return "\"\(name.dropFirst(prefix.count))\""
        }
        return "\"\(name)\""
    }

    /// The target without quotes, for a stash message (`Gitter: before rebasing onto feature`).
    static func bareTarget(_ name: String) -> String {
        let quoted = target(name)
        return quoted.hasPrefix("\"") ? String(quoted.dropFirst().dropLast()) : quoted
    }

    private static func isObjectID(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64) && text.allSatisfy(\.isHexDigit)
    }

    /// "cherry-pick 3 commits" — what reads on from "Can't …" and "did not try to … again".
    static func attempt(_ action: HistoryAction, count: Int) -> String {
        "\(verb(action)) \(self.count(count))"
    }

    static func rebaseAttempt(_ target: String) -> String {
        "rebase onto \(self.target(target))"
    }

    private static func verb(_ action: HistoryAction) -> String {
        switch action {
        case .cherryPick: "cherry-pick"
        case .revert: "revert"
        }
    }

    private static func pastVerb(_ action: HistoryAction) -> String {
        switch action {
        case .cherryPick: "cherry-picked"
        case .revert: "reverted"
        }
    }

    // MARK: - Menus

    static func menuTitle(_ action: HistoryAction, count: Int) -> String {
        let name =
            switch action {
            case .cherryPick: "Cherry-Pick"
            case .revert: "Revert"
            }
        return count == 1 ? "\(name) Commit…" : "\(name) \(count) Commits…"
    }

    /// `current` nil is a detached HEAD; `onto` nil is the commit row's "Here".
    static func rebaseMenuTitle(current: String?, onto: String?) -> String {
        let what = current.map { "\"\($0)\"" } ?? "Detached HEAD"
        let target = onto.map { "\"\($0)\"" } ?? "Here"
        return "Rebase \(what) onto \(target)…"
    }

    static let rebaseNeedsOneCommit = "Rebase onto a commit needs exactly one commit selected."
    static let rebaseOntoHead = "HEAD is on this commit already."
    static let mergesInSelection =
        "Merge commits can't be cherry-picked or reverted. Leave them out of the selection."

    /// The detail pane's line over the first selected commit, with more than one selected.
    static func selectionLine(_ count: Int) -> String? {
        count > 1 ? "\(count) commits selected. Showing the first." : nil
    }

    // MARK: - History's depth (H1)

    /// The end row while older commits may exist.
    static let loadingOlder = "Loading older commits…"
    /// The end row once the history is complete.
    static let startOfHistory = "Start of history"
    /// The end row at `HistoryDepth.cap` with older commits left (Ruling 5): nothing more loads.
    /// The number is written out, as in `beyondCap`.
    static let capReached = "The list stops at 50,000 commits; older ones aren't loaded."

    /// A reveal of a commit no branch, tag or HEAD reaches (a stash's): it stays selected.
    static func notInHistory(shortSha: String) -> String {
        "\(shortSha) isn't in the history list: no branch, tag or HEAD reaches it."
    }

    /// A reveal of a commit `HistoryDepth.cap` rows back or more: it stays selected. The number is
    /// written out, not formatted, so it reads the same in every locale.
    static func beyondCap(shortSha: String) -> String {
        "\(shortSha) is more than 50,000 commits back, past what the history list loads."
    }

    // MARK: - The Cherry-Pick / Revert sheet

    static func sheetTitle(_ plan: HistoryPlan) -> String {
        let branch = branch(headRef: plan.headRef)
        let count = count(plan.commits.count)
        return switch plan.action {
        case .cherryPick: "Cherry-pick \(count) onto \(branch)?"
        case .revert: "Revert \(count) on \(branch)?"
        }
    }

    /// The line over the list, which is in the order git gets the commits.
    static func sheetOrder(_ plan: HistoryPlan) -> String {
        let branch = branch(headRef: plan.headRef)
        let one = plan.commits.count == 1
        return switch plan.action {
        case .cherryPick where one: "It is applied on top of \(branch) as a new commit:"
        case .cherryPick: "Each is applied on top of \(branch) as a new commit, oldest first:"
        case .revert where one: "It is undone by a new commit on \(branch):"
        case .revert: "Each is undone by a new commit on \(branch), newest first:"
        }
    }

    static func leftOut(_ plan: HistoryPlan) -> String? {
        guard !plan.leftOut.isEmpty else { return nil }
        return "Left out, already on \(branch(headRef: plan.headRef)): \(commits(plan.leftOut))."
    }

    /// A prediction (`HistoryPlan.mayDrop`), wrong in both directions: "may".
    static func mayDrop(_ plan: HistoryPlan) -> String? {
        guard !plan.mayDrop.isEmpty else { return nil }
        return "May be skipped as already applied, since \(branch(headRef: plan.headRef)) has the "
            + "same change: \(commits(plan.mayDrop))."
    }

    static let onStop =
        "If git stops on a commit (a conflict, say), the operation bar takes over: resolve it and "
        + "Continue, Skip that commit, or Abort."

    static func confirmButton(_ action: HistoryAction) -> String {
        switch action {
        case .cherryPick: "Cherry-Pick"
        case .revert: "Revert"
        }
    }

    // MARK: - The Rebase sheet

    static func rebaseTitle(_ plan: RebasePlan) -> String {
        "Rebase \(branch(headRef: plan.headRef)) onto \(target(plan.targetName))?"
    }

    /// The line over the replay list, or — when nothing is replayed — what happens instead.
    /// `incoming` is how many commits the target has that HEAD lacks (nil while unknown): with
    /// nothing replayed, nothing flattened and nothing skipped, it tells "already contains" (0)
    /// from a fast-forward.
    static func rebaseSummary(_ plan: RebasePlan, incoming: Int?) -> String {
        let target = target(plan.targetName)
        switch plan.replayed.count {
        case 1:
            return "This commit is replayed onto \(target) as a new commit:"
        case let n where n > 1:
            return "These \(n) commits are replayed onto \(target) as new commits, oldest first:"
        default:
            break
        }
        if plan.flattenedMerges > 0 || plan.skippedAsApplied > 0 {
            return "No commit is replayed onto \(target)."
        }
        let branch = branch(headRef: plan.headRef)
        if plan.head == plan.target || incoming == 0 {
            return "\(branch) already contains \(target): nothing changes."
        }
        guard let incoming else {
            return "No commit is replayed: \(branch) already contains \(target) or moves straight "
                + "forward to it."
        }
        return "\(branch) moves straight forward to \(target) (\(count(incoming))): nothing is "
            + "rewritten."
    }

    static func flattened(_ n: Int) -> String? {
        switch n {
        case 0: nil
        case 1: "1 merge commit is dropped; the commits it merged are replayed in a line."
        default: "\(n) merge commits are dropped; the commits they merged are replayed in a line."
        }
    }

    static func skipped(_ n: Int, _ plan: RebasePlan) -> String? {
        let target = target(plan.targetName)
        return switch n {
        case 0: nil
        case 1: "1 commit is skipped: \(target) already has its change."
        default: "\(n) commits are skipped: \(target) already has their changes."
        }
    }

    static func alreadyPushed(_ n: Int) -> String? {
        switch n {
        case 0:
            nil
        case 1:
            "1 of the commits this rewrites is already on a remote. Pushing afterwards needs a "
                + "force push, and anyone who has it must deal with the rewrite."
        default:
            "\(n) of the commits this rewrites are already on a remote. Pushing afterwards needs "
                + "a force push, and anyone who has them must deal with the rewrite."
        }
    }

    static func rebaseOnStop(_ plan: RebasePlan) -> String {
        "If git stops on a commit (a conflict, say), the operation bar takes over: resolve it and "
            + "Continue, Skip that commit, or Abort to put \(branch(headRef: plan.headRef)) back "
            + "as it was."
    }

    static let rebaseButton = "Rebase"

    /// The button beside a `headMoved` or `planChanged` refusal: plans the action again and puts
    /// its sheet back up (`RepositoryStore.askAgain`).
    static let askAgain = "Ask Again"

    // MARK: - Notices

    /// `.applied`: how many, which were dropped as already applied, and the way back — HEAD's
    /// old commit, also the reflog's entry before the run (B24). A run that dropped everything
    /// made no commit and has nothing to undo.
    static func applied(_ plan: HistoryPlan, count: Int, dropped: [CommitRef]) -> String {
        let branch = branch(headRef: plan.headRef)
        guard count > 0 else {
            let what = dropped.isEmpty ? plan.commits : dropped
            return "Nothing was \(pastVerb(plan.action)): \(branch) already has the changes of "
                + "\(commits(what))."
        }
        let done =
            switch plan.action {
            case .cherryPick: "Cherry-picked \(self.count(count)) onto \(branch)."
            case .revert: "Reverted \(self.count(count)) on \(branch)."
            }
        let skipped = dropped.isEmpty ? "" : " Skipped as already applied: \(commits(dropped))."
        return done + skipped + " The reflog keeps where it was; to undo: git reset --keep \(plan.head)"
    }

    /// A rebase's ending. `.conflicts` says nothing: the operation bar says it.
    static func rebaseNotice(_ outcome: RebaseOutcome, plan: RebasePlan) -> String? {
        let branch = branch(headRef: plan.headRef)
        let target = target(plan.targetName)
        return switch outcome {
        case .upToDate: "\(branch) already contains \(target); nothing changed."
        case .fastForwarded: "Fast-forwarded \(branch) to \(target)."
        case .rebased:
            "Rebased \(branch) onto \(target). The old tip, \(plan.head.prefix(7)), is ORIG_HEAD "
                + "for now; to undo: git reset --keep \(plan.head)"
        case .conflicts: nil
        }
    }

    static func alreadyReverted(_ commit: CommitRef, plan: HistoryPlan) -> String {
        "Nothing to revert: \(branch(headRef: plan.headRef)) already undoes \(self.commit(commit)). "
            + "Nothing changed."
    }

    /// `.unsignedRevertLeftStaged` (Ruling 4): a signing failure or a `prepare-commit-msg` hook
    /// saying no — so it says what git said, never "signing". `messageInComposer` is whether the
    /// store put git's message into the (empty) draft.
    static func revertLeftStaged(gitsWords: String, messageInComposer: Bool) -> String {
        let said = oneLine(gitsWords)
        let words = said.isEmpty ? "" : " It said: \(said)\(said.hasSuffix(".") ? "" : ".")"
        let wayOn =
            messageInComposer
            ? " The revert's changes are staged and its message is in the commit box: Commit them, "
                + "or Discard the staged changes."
            : " The revert's changes are staged: write a message and Commit them, or Discard the "
                + "staged changes."
        return "git could not make the revert commit." + words + wayOn
    }

    /// The message git's revert writes (`--no-reference`, B9/B10): `Revert "<subject>"`, or
    /// `Reapply "<subject>"` for a revert of a revert.
    static func revertMessage(_ commit: CommitRef) -> String {
        let subject = commit.subject
        let open = "Revert \""
        let title =
            subject.hasPrefix(open) && subject.hasSuffix("\"") && subject.count > open.count
            ? "Reapply \"\(subject.dropFirst(open.count))" : "Revert \"\(subject)\""
        return "\(title)\n\nThis reverts commit \(commit.sha)."
    }

    static func failed(_ action: HistoryAction, gitsWords: String) -> String {
        let said = oneLine(gitsWords)
        let what = "The \(verb(action)) failed."
        return said.isEmpty ? what : "\(what) git said: \(said)"
    }

    /// git's lines as one, each made plain.
    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { RemoteWording.plain(String($0)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Refusals

    static func refusal(_ refusal: HistoryRefusal, action: HistoryAction, count: Int) -> String {
        let attempt = attempt(action, count: count)
        let again = "Ask again to see what it would do now."
        switch refusal {
        case .headMoved:
            return "The branch changed while this was open, so nothing was \(pastVerb(action)). \(again)"
        case .planChanged:
            return "What this would do changed while it was open, so nothing was "
                + "\(pastVerb(action)). \(again)"
        case .nothingToApply:
            return switch action {
            case .cherryPick: "Nothing to cherry-pick: the current branch already has every selected commit."
            case .revert: "Nothing to revert: no commit is selected."
            }
        case .notOnBranch(let refs):
            return "Can't \(attempt): the current branch does not contain \(commits(refs)), so there "
                + "is nothing to undo."
        case .mergeCommits(let refs):
            let (are, them) = refs.count == 1 ? ("is a merge commit", "it") : ("are merge commits", "them")
            return "Can't \(attempt): \(commits(refs)) \(are), which Gitter does not cherry-pick or "
                + "revert. Leave \(them) out of the selection."
        case .operationInProgress, .trackedChanges, .unbornHead:
            return common(refusal, attempt: attempt) ?? "Can't \(attempt)."
        }
    }

    static func rebaseRefusal(_ refusal: HistoryRefusal, target: String) -> String {
        let attempt = rebaseAttempt(target)
        let again = "Ask again to see what it would do now."
        switch refusal {
        case .headMoved:
            return "The branch changed while this was open, so nothing was rebased. \(again)"
        case .planChanged:
            return "What the rebase would do changed while this was open (the target, the commits to "
                + "replay, or how many are already pushed), so nothing was rebased. \(again)"
        default:
            return common(refusal, attempt: attempt) ?? "Can't \(attempt)."
        }
    }

    /// The refusals that read the same for every action.
    private static func common(_ refusal: HistoryRefusal, attempt: String) -> String? {
        switch refusal {
        case .operationInProgress(let operation):
            let sentence = operation.movingHeadBlocked
            return "Can't \(attempt): \(sentence.prefix(1).lowercased())\(sentence.dropFirst())"
        case .trackedChanges(let paths):
            let have = paths.count == 1 ? "has" : "have"
            return "Can't \(attempt): \(names(paths)) \(have) uncommitted changes. Commit or stash "
                + "them first."
        case .unbornHead:
            return "Can't \(attempt): the current branch has no commits yet."
        default:
            return nil
        }
    }

    // MARK: - Errors for the banner

    /// `error` as the banner shows it for `action` — a `.history` or a `.rebaseOnto`: a
    /// `HistoryRefusal` in these sentences (tracked changes carrying Stash and Continue), a
    /// `BranchOperationError` git refused with as the action that was refused (with the offer
    /// where a stash answers it), anything else — git's own words — as it is.
    static func error(_ error: Error, for action: PendingBranchAction) -> Error {
        if let refusal = error as? HistoryRefusal {
            let sentence =
                switch action {
                case .history(let kind, let shas): self.refusal(refusal, action: kind, count: shas.count)
                case .rebaseOnto(let target): rebaseRefusal(refusal, target: target)
                default: action.summary
                }
            let refused = HistoryActionRefused(
                sentence: sentence, retry: refusal == .headMoved || refusal == .planChanged ? action : nil)
            guard let offer = StashAndContinue.offer(forHistory: refusal, action: action) else {
                return refused
            }
            return RefusalWithStashOffer(failure: refused, offer: offer)
        }
        if let refusal = error as? BranchOperationError {
            let failure = BranchActionFailure(
                verb: .rebaseOnto, target: "", refusal: refusal, attempt: action.summary)
            return StashAndContinue.offering(failure, for: action)
        }
        return error
    }
}

/// A history action refused before git ran, in `HistoryWording`'s sentence: nothing changed.
struct HistoryActionRefused: LocalizedError {
    let sentence: String
    /// The action to plan again, for the refusals that mean "look again" — HEAD moved, or the
    /// plan changed, while the sheet was open: the banner offers Ask Again with it
    /// (`RepositoryStore.offeredAskAgain`). Nil for every other refusal.
    var retry: PendingBranchAction? = nil

    var errorDescription: String? { sentence }
}

/// A cherry-pick or revert git failed in a way nothing else describes (`HistoryOutcome.failed`),
/// in git's words.
struct HistoryActionFailed: LocalizedError {
    let sentence: String

    var errorDescription: String? { sentence }
}
