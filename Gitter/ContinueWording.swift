import Foundation
import GitCore

/// Every sentence the operation bar, the composer's Continue, the three confirmations (an empty
/// rebase result, other staged files, Skip), Stage All's confirmation during an operation, and
/// the outcomes of Continue and Skip put on screen.
///
/// Pure: nothing here reads the store, the disk or git. `ContinueWordingTests` pins each one.
/// The operation's noun comes from `OperationWording` (`RepositoryOperation.noun`).
enum ContinueWording {

    // MARK: - Helpers

    private static func names(_ paths: [String]) -> String { StashWording.names(paths) }

    private static func short(_ sha: String) -> String { String(sha.prefix(7)) }

    private static func number(_ count: Int, _ one: String, _ many: String) -> String {
        count == 1 ? one : many
    }

    private static func files(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }

    /// "9f8e7d6 Change the parser".
    private static func commit(_ ref: CommitRef) -> String { "\(short(ref.sha)) \(ref.subject)" }

    /// "9f8e7d6 "Change the parser"".
    private static func quoted(_ ref: CommitRef) -> String { "\(short(ref.sha)) \"\(ref.subject)\"" }

    /// "the rebase", "a cherry-pick".
    private static func the(_ operation: RepositoryOperation) -> String { "the \(operation.noun.lowercased())" }
    private static func a(_ operation: RepositoryOperation) -> String { "a \(operation.noun.lowercased())" }

    /// git's words in one line, without the blank and indented lines it prints around them.
    private static func flat(_ words: String) -> String {
        words.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Progress

    /// Where the operation stopped (M 16), or nil when there is nothing to say beyond its name:
    /// a squash and `git am` keep no progress, and an unread one has none yet.
    ///
    /// - A rebase: the branch, what it replays onto, "commit k of N" and the commit; a stop with
    ///   no commit (a failed `exec`, a `break`) says so, since git's words about it are not kept.
    /// - A cherry-pick or revert: the commit, and for a range how many are left, this one
    ///   included (`sequencer/todo` has no total).
    /// - A merge: what comes in and into what.
    static func progress(_ operation: RepositoryOperation, _ progress: OperationProgress?, branch: String?) -> String? {
        guard let progress else { return nil }
        switch operation {
        case .rebase:
            let head = progress.headName ?? "a detached HEAD"
            let onto = progress.onto.map { " onto \(short($0.sha))" } ?? ""
            let lead = "Rebasing \(head)\(onto): stopped at"
            switch (progress.current, progress.step, progress.total) {
            case (let current?, let step?, let total?):
                return "\(lead) commit \(step) of \(total), \(commit(current))."
            case (let current?, _, _):
                return "\(lead) \(commit(current))."
            case (nil, let step?, let total?):
                return "\(lead) step \(step) of \(total), which has no commit to resolve "
                    + "(an exec command that failed, or a break)."
            case (nil, _, _):
                return "\(lead) a step that has no commit to resolve (an exec command that failed, or a break)."
            }
        case .cherryPick, .revert:
            guard let current = progress.current else { return nil }
            let verb = operation == .cherryPick ? "Cherry-picking" : "Reverting"
            switch progress.remaining {
            case nil: return "\(verb) \(commit(current))."
            case 1?: return "\(verb) \(commit(current)), the last commit of the range."
            case let remaining?: return "\(verb) \(commit(current)): \(remaining) commits to go, this one included."
            }
        case .merge:
            let incoming = progress.mergedName ?? progress.mergeHead.map { short($0.sha) }
            guard let incoming else { return nil }
            return "Merging \(incoming) into \(branch ?? "HEAD")."
        case .squash, .applyingPatches:
            return nil
        }
    }

    /// What to do next. A merge and a squash conclude with Commit; a rebase, cherry-pick and
    /// revert with Continue; `git am` stays abort-only in Gitter, so its way forward is still a
    /// terminal.
    static func nextStep(_ operation: RepositoryOperation, hasConflicts: Bool) -> String {
        switch operation {
        case .merge:
            hasConflicts ? "Resolve the conflicts, then commit." : "Commit to complete the merge."
        case .squash:
            hasConflicts ? "Resolve the conflicts, then commit." : "Commit to finish the squash."
        case .rebase, .cherryPick, .revert:
            hasConflicts ? "Resolve the conflicts, then continue." : "Continue when ready."
        case .applyingPatches:
            hasConflicts
                ? "Resolve the conflicts, then run `git am --continue` in a terminal."
                : "Run `git am --continue` in a terminal."
        }
    }

    /// The bar's sentence: where, then what next — or, with no progress to tell, the
    /// operation's note. `continueBlocked`: Continue is off for a reason of the repository's,
    /// which the line under the bar gives; "Continue when ready." would contradict it, so only
    /// the conflicts' next step is kept.
    static func bar(
        _ operation: RepositoryOperation, _ progress: OperationProgress?, branch: String?, hasConflicts: Bool,
        continueBlocked: Bool = false
    ) -> String {
        guard let sentence = self.progress(operation, progress, branch: branch) else {
            return operation.note(hasConflicts: hasConflicts)
        }
        if continueBlocked, !hasConflicts { return sentence }
        return sentence + " " + nextStep(operation, hasConflicts: hasConflicts)
    }

    // MARK: - Buttons

    /// The bar's and the composer's Continue: the operation's name, with the ellipsis when it
    /// asks first (an empty rebase result, other staged files).
    static func continueTitle(_ operation: RepositoryOperation, asks: Bool) -> String {
        operation.commitButtonTitle + (asks ? "\u{2026}" : "")
    }

    static let skipButton = "Skip This Commit\u{2026}"

    static func continueHelp(_ operation: RepositoryOperation) -> String {
        "Commit the resolution with the message in the composer, and go on with \(the(operation))."
    }

    static func skipHelp(_ operation: RepositoryOperation) -> String {
        "Leave this commit out of \(the(operation)). Gitter keeps a copy of its changes in the Stashes list first."
    }

    // MARK: - Why Continue is off

    static func unresolved(_ paths: [String]) -> String {
        paths.count == 1
            ? "Resolve the conflict in \(names(paths)) first."
            : "Resolve the conflicts in \(files(paths.count)) first: \(names(paths))."
    }

    /// A rebase refuses any unstaged change; a cherry-pick or revert range is held back by any
    /// (conservative: Gitter does not know which later commit touches what, so it claims no
    /// collision).
    static func unstaged(_ operation: RepositoryOperation, _ paths: [String]) -> String {
        let which = number(paths.count, "a tracked file has", "tracked files have")
        switch operation {
        case .rebase:
            return "A rebase can't continue while \(which) unstaged changes: \(names(paths)). Stage or discard them first."
        default:
            return "\(the(operation).capitalizedFirst) has more commits to apply, and Gitter doesn't continue it "
                + "while \(which) unstaged changes: \(names(paths)). Stage or discard them first."
        }
    }

    /// A cherry-pick or revert whose resolution equals HEAD (M 30): git refuses to continue,
    /// Skip is the way on. With other staged files Skip is refused too (Ruling 20); the way out
    /// is to take them out of the index — stash is refused during an operation, and the app's
    /// own unstage is (it would end the operation's state), so a terminal or a discard.
    static func emptyResult(_ operation: RepositoryOperation, _ current: CommitRef?, otherStaged: [String]) -> String {
        let it = current.map { short($0.sha) } ?? "the commit"
        guard !otherStaged.isEmpty else {
            return "The resolution leaves \(it) with no changes, so there is nothing to commit. Skip it instead."
        }
        let are = number(otherStaged.count, "is", "are")
        let them = number(otherStaged.count, "it", "them")
        return "The resolution leaves \(it) with no changes of its own, and \(names(otherStaged)) \(are) staged but "
            + "not part of it, so it can't be continued or skipped. Unstage \(names(otherStaged)) in a terminal "
            + "(git restore --staged), or discard \(them) (Gitter keeps a copy in the Stashes list), then skip the commit."
    }

    static let enterMessage = "Enter a commit message first."

    static func reading(_ operation: RepositoryOperation) -> String {
        "Gitter is still reading where \(the(operation)) is."
    }

    static func readFailed(_ operation: RepositoryOperation, _ detail: String) -> String {
        "Gitter couldn't read where \(the(operation)) is: \(detail)"
    }

    static func notContinuable(_ operation: RepositoryOperation) -> String {
        switch operation {
        case .applyingPatches: "Gitter doesn't continue git am; run `git am --continue` in a terminal."
        case .merge, .squash: "\(a(operation).capitalizedFirst) is concluded by committing it, not by Continue."
        // Readiness said so although the snapshot shows one: the repository moved on.
        case .rebase, .cherryPick, .revert: "No \(operation.noun.lowercased()) is in progress any more."
        }
    }

    static func noStoppedCommit(_ operation: RepositoryOperation) -> String {
        "Gitter couldn't read which commit \(the(operation)) stopped on."
    }

    static let nothingToContinue = "No rebase, cherry-pick or revert is in progress."

    static let blockedBySheet = StashWording.blockedBySheet
    static let busy = StashWording.busy

    // MARK: - Why Skip is off

    static let noCommitToSkip = "There is no commit to skip at this step."

    static func skipOtherChanges(_ paths: [String]) -> String {
        "\(names(paths)) \(number(paths.count, "has", "have")) changes that are not part of this commit, and "
            + "Gitter skips only when every change belongs to it. Discard them first (Gitter keeps a copy in the "
            + "Stashes list)."
    }

    static func skipNeedsCleanPaths(_ paths: [String]) -> String {
        "Stage or discard these first: \(names(paths)). Git can't put them back as they are."
    }

    // MARK: - The empty-result confirmation (rebase, M 30)

    static func emptyTitle(_ current: CommitRef, otherStaged: [String] = []) -> String {
        guard !otherStaged.isEmpty else { return "Leave \(short(current.sha)) out of the rebase?" }
        return "Commit \(otherStaged.count) other staged \(number(otherStaged.count, "file", "files")) "
            + "as \(short(current.sha))?"
    }

    /// Two facts when other files are staged (Ruling 20): the commit's own changes are empty,
    /// and the commit is kept anyway — holding those files under its own title and author.
    static func emptyBody(_ current: CommitRef, otherStaged: [String]) -> String {
        guard !otherStaged.isEmpty else {
            return "The resolution leaves \(quoted(current)) with no changes against what the rebase has built so far, "
                + "so the rebase leaves this commit out and goes on with the next one."
        }
        let count = otherStaged.count
        return "The resolution leaves \(quoted(current)) with no changes of its own. "
            + "\(count) other staged \(number(count, "file is", "files are")) not part of it: \(names(otherStaged)). "
            + "The commit is not left out: it keeps \(number(count, "it", "them")), under its own title and author, "
            + "as if \(number(count, "it were", "they were")) its changes."
    }

    static func emptyButton(otherStaged: [String]) -> String {
        switch otherStaged.count {
        case 0: "Leave It Out and Continue"
        case 1: "Continue and Commit It"
        default: "Continue and Commit Them"
        }
    }

    // MARK: - The other-staged confirmation (Ruling 16)

    static func othersTitle(_ count: Int) -> String {
        "Commit \(count) other staged \(number(count, "file", "files")) too?"
    }

    /// Git commits the whole index (A2 Task 3, measured for all three): these ride in. A rebase
    /// and a cherry-pick keep the original author; a revert's commit is the reverter's.
    static func othersBody(_ operation: RepositoryOperation, _ current: CommitRef?, _ paths: [String]) -> String {
        let are = number(paths.count, "is", "are")
        let go = number(paths.count, "it goes", "they go")
        switch operation {
        case .revert:
            let what = current.map { "the revert of \(short($0.sha))" } ?? "the revert"
            return "\(names(paths)) \(are) staged but not part of \(what). Git commits everything that is staged, "
                + "so \(go) into the revert commit."
        default:
            let what =
                current.map(quoted)
                ?? (operation == .cherryPick ? "the commit being cherry-picked" : "the commit the rebase stopped on")
            return "\(names(paths)) \(are) staged but not part of \(what). Git commits everything that is staged, "
                + "so \(go) into that commit, under its title and author."
        }
    }

    static func othersButton(_ count: Int) -> String {
        count == 1 ? "Continue and Commit It" : "Continue and Commit Them"
    }

    // MARK: - The skip confirmation

    static func skipQuestion(_ current: CommitRef) -> String { "Skip \(quoted(current))?" }

    static func skipBody(_ operation: RepositoryOperation) -> String {
        switch operation {
        case .cherryPick: "The cherry-pick goes on without this commit: it is not picked."
        case .revert: "The revert goes on without this commit: it is not reverted."
        default: "The rebase goes on without this commit: its changes are not applied."
        }
    }

    /// Every skip returns the stopped commit's paths to HEAD (M 32), resolutions included.
    static func skipFiles(_ paths: [String]) -> String {
        switch paths.count {
        case 0: "Nothing has changed yet, so no file is put back."
        case 1: "This file goes back to how it is in HEAD, resolved or not:"
        default: "These \(paths.count) files go back to how they are in HEAD, resolved or not:"
        }
    }

    /// Where the partial work goes first (GitCore's `Skipped by Gitter: <short> <subject>`); nil
    /// when nothing is filed.
    static func skipDestination(_ current: CommitRef, paths: [String]) -> String? {
        guard !paths.isEmpty else { return nil }
        return "Gitter first keeps a copy of their current contents in the Stashes list, as "
            + "\"Skipped by Gitter: \(commit(current))\"."
    }

    static let skipConfirm = "Skip Commit"

    // MARK: - Stage All during an operation (M 22)

    static func stageAllQuestion(_ operation: RepositoryOperation) -> String {
        "Stage files that are not part of \(the(operation))?"
    }

    /// `known` is false when the operation's own paths could not be read: every file is listed,
    /// and the sentence does not claim any of them is outside it.
    static func stageAllBody(_ operation: RepositoryOperation, count: Int, known: Bool) -> String {
        guard known else {
            return "Gitter can't tell which changes belong to \(the(operation)), so these are all \(files(count)) "
                + "Stage All would add. Every one of them will be in its commit:"
        }
        let these = count == 1 ? "This file is" : "These \(count) files are"
        switch operation {
        case .rebase:
            return "\(these) not part of the commit the rebase stopped on and will be committed with it:"
        default:
            return "\(these) not part of \(the(operation)) and will be in its commit:"
        }
    }

    static let stageAllConfirm = "Stage All"

    // MARK: - Outcomes

    static func finished(_ operation: RepositoryOperation) -> String { "\(operation.noun) finished." }

    /// The rebase's autostash conflicted as it was applied back (M 18); git keeps the entry.
    static func finishedWithConflicts(_ operation: RepositoryOperation, _ count: Int) -> String {
        guard operation == .rebase else {
            return "\(the(operation).capitalizedFirst) finished, but left \(files(count)) conflicted."
        }
        return "The rebase finished, but its autostash conflicted in \(files(count)). Git kept the autostash in the "
            + "Stashes list."
    }

    /// git refused or failed and the operation is where it was (a hook, signing).
    static func failed(_ operation: RepositoryOperation, _ gitsWords: String) -> String {
        let words = flat(gitsWords)
        guard !words.isEmpty else {
            return "\(the(operation).capitalizedFirst) did not continue, and git said nothing about why."
        }
        return "\(the(operation).capitalizedFirst) did not continue. Git said: \(words)"
    }

    /// A Continue that made its commit and then had the next one refused (A2 Task 3,
    /// `.sequenceHalted`). The bar (`halted`) names what was not applied and the way on.
    static func sequenceHalted(_ operation: RepositoryOperation, _ gitsWords: String) -> String {
        "Git made the commit, then stopped \(the(operation)) before the next one\(said(gitsWords)) "
            + haltedTail(operation)
    }

    /// A Skip whose next commit was refused: the skip happened, and **no** commit was made (fix
    /// round 1, measured: HEAD unchanged).
    static func skipHalted(_ operation: RepositoryOperation, _ current: CommitRef, recorded: Bool, _ gitsWords: String)
        -> String
    {
        let lead =
            recorded
            ? "Skipped \(short(current.sha)) \u{2014} its changes are in the Stashes list."
            : "Skipped \(short(current.sha))."
        return "\(lead) Git then stopped \(the(operation)) before the next commit\(said(gitsWords)) "
            + haltedTail(operation)
    }

    /// ": <git's words>." or ".".
    private static func said(_ gitsWords: String) -> String {
        var words = flat(gitsWords)
        guard !words.isEmpty else { return "." }
        if let last = words.last, !".!?".contains(last) { words += "." }
        return ": " + words
    }

    private static func haltedTail(_ operation: RepositoryOperation) -> String {
        "No \(operation.noun.lowercased()) is in progress now. The bar above lists the commits it did not apply and "
            + "how to apply them."
    }

    // MARK: - A halted sequence (the bar's place, fix round 1)

    /// "1600000 Pick two".
    private static func listed(_ halted: HaltedSequence) -> String {
        let shown = halted.notApplied.prefix(5).map(commit)
        let more = halted.total - shown.count
        guard more > 0 else {
            switch shown.count {
            case 0: return ""
            case 1: return shown[0]
            default: return shown.dropLast().joined(separator: ", ") + " and " + shown.last!
            }
        }
        return shown.joined(separator: ", ") + " and \(more) more"
    }

    static func halted(_ halted: HaltedSequence) -> String {
        let count = halted.total == 1 ? "1 commit" : "\(halted.total) commits"
        return "\(the(halted.operation).capitalizedFirst) stopped part-way and is not in progress: git did not apply "
            + "\(count), \(listed(halted))."
    }

    /// Measured (fix round 1): `--quit` keeps HEAD, the index and the worktree and removes
    /// `sequencer/`; picking (reverting) the listed commits again then applies them; a later
    /// `--continue` leaves the first of them out.
    static func haltedWayForward(_ halted: HaltedSequence) -> String {
        let command = halted.operation == .revert ? "git revert" : "git cherry-pick"
        let verb = halted.operation == .revert ? "revert" : "cherry-pick"
        let them = halted.total == 1 ? "it" : "them"
        let again: String
        if halted.total > halted.notApplied.count {
            again = "then \(verb) \(them) again in the order .git/sequencer/todo lists them (copy that list first: "
                + "--quit removes it)."
        } else {
            again = "then \(verb) \(them) again: `\(command) \(halted.notApplied.map { short($0.sha) }.joined(separator: " "))`."
        }
        let first = halted.notApplied.first.map { short($0.sha) } ?? "the first of them"
        return "To apply \(them), move away what git refused over, run `\(command) --quit` in a terminal (it changes "
            + "no file and no commit), \(again) Don't run `\(command) --continue`: it would leave out \(first)."
    }

    // MARK: - A draft written for another commit (fix round 1)

    /// "the Merge", "the Cherry-Pick": a button's title case.
    private static func titleNoun(_ operation: RepositoryOperation) -> String {
        switch operation {
        case .cherryPick: "Cherry-Pick"
        case .applyingPatches: "Patch"
        default: operation.noun
        }
    }

    static func foreignNote(writtenFor: CommitRef?, operation: RepositoryOperation, current: CommitRef?) -> String {
        switch (writtenFor, current) {
        case (let written?, let current?): "This message was written for \(short(written.sha)), not \(short(current.sha))."
        case (let written?, nil): "This message was written for \(short(written.sha))."
        case (nil, let current?): "This message was written before \(the(operation)) stopped at \(short(current.sha))."
        case (nil, nil): "This message was written before \(the(operation)) began."
        }
    }

    static func useMessage(_ operation: RepositoryOperation, current: CommitRef?) -> String {
        current.map { "Use \(short($0.sha))\u{2019}s Message" } ?? "Use the \(titleNoun(operation))\u{2019}s Message"
    }

    static let keepMessage = "Keep This Message"

    static func foreignReason(writtenFor: CommitRef?, operation: RepositoryOperation, current: CommitRef?) -> String {
        let whose = current.map { "\(short($0.sha))\u{2019}s" } ?? "\(the(operation))\u{2019}s"
        return foreignNote(writtenFor: writtenFor, operation: operation, current: current)
            + " Use \(whose) message or keep this one first."
    }

    /// The skip's notice, with what the operation did next (`then`), if anything.
    static func skipped(_ current: CommitRef, recorded: Stash?, then: String?) -> String {
        let lead =
            recorded == nil
            ? "Skipped \(short(current.sha))."
            : "Skipped \(short(current.sha)) \u{2014} its changes are in the Stashes list"
        guard let then else { return lead }
        return (lead.hasSuffix(".") ? lead : lead + ".") + " " + then
    }

    static func skipFailed(_ operation: RepositoryOperation, _ current: CommitRef, _ gitsWords: String, recorded: Bool)
        -> String
    {
        let words = flat(gitsWords)
        let said = words.isEmpty ? "" : " Git said: \(words)"
        let copy = recorded ? " The copy Gitter made first stays in the Stashes list." : ""
        return "Couldn't skip \(short(current.sha)).\(said)\(copy)"
    }

    // MARK: - Refusals

    /// `commit()` during a rebase, cherry-pick or revert stop: `commit -F` there loses the
    /// author or breaks the next continue (M 15).
    static func commitRefused(_ operation: RepositoryOperation) -> String {
        "\(a(operation).capitalizedFirst) stop is concluded with \(operation.commitButtonTitle), which makes the "
            + "commit; Gitter doesn't commit on its own there."
    }

    /// The stop on screen is not the one in the repository any more.
    static func movedOn(_ operation: RepositoryOperation) -> String {
        "\(the(operation).capitalizedFirst) moved on since this was shown, so nothing was done. Look at it again."
    }

    /// A non-empty acknowledgement with nothing else staged now: GitCore's
    /// `.notReady(.otherStagedChanges([]))`.
    static let acknowledgementStale =
        "The staged files changed since you were asked, so nothing was continued. Continue again to see what would "
        + "be committed now."

    static func error(_ error: OperationError) -> String {
        switch error {
        case .operationMismatch(let expected, nil):
            return "No \(expected.noun.lowercased()) is in progress any more, so nothing was done."
        case .operationMismatch(let expected, let found?):
            return "\(a(found).capitalizedFirst) is in progress now, not \(a(expected)), so nothing was done."
        case .stoppedCommitChanged:
            return "The operation moved on to another commit since this was shown, so nothing was skipped."
        case .emptyMessage:
            return "The commit message is empty once git removes its comment lines, so nothing was continued."
        case .notReady(.otherStagedChanges([])):
            return acknowledgementStale
        case .notReady(let readiness):
            return continueRefusal(readiness) + " Nothing was continued."
        case .skipRefused(let readiness):
            return skipRefusal(readiness) + " Nothing was skipped."
        }
    }

    private static func continueRefusal(_ readiness: ContinueReadiness) -> String {
        switch readiness {
        case .unresolved(let paths): unresolved(paths)
        case .emptyResult: "The resolution leaves the commit with no changes, so there is nothing to commit."
        case .unstagedChanges(let paths):
            "Tracked files have unstaged changes: \(names(paths)). Stage or discard them first."
        case .otherStagedChanges(let paths):
            "\(names(paths)) \(number(paths.count, "is", "are")) staged but not part of the commit."
        case .notContinuable: "No rebase, cherry-pick or revert is in progress."
        case .ready: "Gitter could not continue."
        }
    }

    private static func skipRefusal(_ readiness: SkipReadiness) -> String {
        switch readiness {
        case .otherChanges(let paths): skipOtherChanges(paths)
        case .needsCleanPaths(let paths): skipNeedsCleanPaths(paths)
        case .notSkippable: noCommitToSkip
        case .ready: "Gitter could not skip."
        }
    }

    // MARK: - The composer

    /// A cherry-pick or revert strips comment lines whatever the setting (A2 Task 3).
    static func commentNote(_ commentChar: Character) -> String {
        "Lines starting with \(commentChar) are removed from the message."
    }
}

extension String {
    /// The first letter upper-cased, the rest as it is: "the rebase" → "The rebase".
    fileprivate var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
