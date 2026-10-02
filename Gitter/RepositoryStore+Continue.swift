import Foundation
import GitCore

/// A button on the operation bar: on, or off with the reason (the tooltip, and for Continue the
/// line under the bar).
enum BarActionState: Hashable {
    case enabled
    case disabled(String)

    var reason: String? {
        if case .disabled(let reason) = self { reason } else { nil }
    }
}

/// What the store knows about where the operation in progress stopped, read with the snapshot
/// that shows it (`RepositoryStore.readOperationStop`).
struct OperationStop: Hashable {
    let operation: RepositoryOperation
    var progress: OperationProgress?
    /// Rebase, cherry-pick and revert only.
    var continueReadiness: ContinueReadiness?
    /// Rebase, cherry-pick and revert only.
    var skipReadiness: SkipReadiness?
    /// What git prepared for the next commit; nil for `git am`, at a rebase's `exec` / `break`
    /// stop, or when there is none.
    var pendingMessage: PendingMessage?
    /// At `.emptyResult` only (Ruling 20): staged paths that are not the operation's — readiness
    /// names one case, and the empty result outranks them. Continue then acknowledges exactly
    /// these, and the confirmation says the commit keeps them.
    var otherStagedAtEmpty: [String] = []
    /// At a rebase's `.emptyResult` only: tracked files with unstaged changes, which git refuses
    /// and which the readiness, ranking the empty result first, does not name.
    var unstagedAtEmpty: [String] = []
    /// Why a read failed; the bar's buttons stay off and say it.
    var readFailure: String?
}

/// What Continue does when it is on.
enum ContinueStep: Hashable {
    case run
    /// A rebase's empty result (M 30): ask first, naming any other staged files (Ruling 20).
    case confirmEmpty(CommitRef, otherStaged: [String])
    /// Staged files that are not the stopped commit's (Ruling 16): ask first, naming them.
    case confirmOthers([String])
}

/// The operation bar's decisions, pure: Continue's and Skip's state from the readiness, a running
/// change and a sheet; what Continue does; the files Stage All would sweep in; the composer's
/// comment-line note. `OperationBarStateTests` covers each.
enum OperationBarState {

    /// Continue and Skip exist for these three; a merge and a squash conclude with Commit and
    /// `git am` stays abort-only (spec, "Decisions").
    static func isContinuable(_ operation: RepositoryOperation) -> Bool {
        switch operation {
        case .rebase, .cherryPick, .revert: true
        case .merge, .squash, .applyingPatches: false
        }
    }

    // MARK: - Continue

    /// `hasMessage`: the draft has a subject. Needed only where git has a message to replace.
    /// `foreign`: the draft was written for another commit (or before this stop), and git has a
    /// message it would replace — Continue does not send it silently.
    static func continueState(
        _ operation: RepositoryOperation, _ stop: OperationStop?, isMutating: Bool, sheetUp: Bool, hasMessage: Bool,
        foreign: ForeignDraft? = nil
    ) -> BarActionState {
        guard isContinuable(operation) else { return .disabled(ContinueWording.notContinuable(operation)) }
        if sheetUp { return .disabled(ContinueWording.blockedBySheet) }
        if isMutating { return .disabled(ContinueWording.busy) }
        return readinessState(operation, stop, hasMessage: hasMessage, foreign: foreign)
    }

    /// The line under the bar: Continue's reason when it is about the repository — never a
    /// sheet or a running change, which pass.
    static func reasonLine(
        _ operation: RepositoryOperation, _ stop: OperationStop?, hasMessage: Bool, foreign: ForeignDraft? = nil
    ) -> String? {
        guard isContinuable(operation) else { return nil }
        return readinessState(operation, stop, hasMessage: hasMessage, foreign: foreign).reason
    }

    private static func readinessState(
        _ operation: RepositoryOperation, _ stop: OperationStop?, hasMessage: Bool, foreign: ForeignDraft?
    ) -> BarActionState {
        guard let stop, stop.operation == operation, stop.progress.map({ $0.operation == operation }) ?? true else {
            return .disabled(ContinueWording.reading(operation))
        }
        if let failure = stop.readFailure { return .disabled(ContinueWording.readFailed(operation, failure)) }
        guard let readiness = stop.continueReadiness else { return .disabled(ContinueWording.reading(operation)) }
        switch readiness {
        case .staleSequence:
            return .disabled(ContinueWording.staleReason(operation))
        case .notContinuable:
            return .disabled(ContinueWording.notContinuable(operation))
        case .unresolved(let paths):
            return .disabled(ContinueWording.unresolved(paths))
        case .unstagedChanges(let paths):
            return .disabled(ContinueWording.unstaged(operation, paths))
        case .emptyResult:
            guard operation == .rebase else {
                return .disabled(
                    ContinueWording.emptyResult(operation, stop.progress?.current, otherStaged: stop.otherStagedAtEmpty))
            }
            if !stop.unstagedAtEmpty.isEmpty { return .disabled(ContinueWording.unstaged(.rebase, stop.unstagedAtEmpty)) }
            if stop.progress?.current == nil { return .disabled(ContinueWording.noStoppedCommit(operation)) }
        case .otherStagedChanges, .ready:
            break
        }
        if stop.pendingMessage != nil, !hasMessage { return .disabled(ContinueWording.enterMessage) }
        if stop.pendingMessage != nil, let foreign {
            return .disabled(
                ContinueWording.foreignReason(
                    writtenFor: foreign.writtenFor, operation: operation, current: stop.progress?.current))
        }
        return .enabled
    }

    /// What an enabled Continue does: run, or ask first.
    static func continueStep(_ stop: OperationStop) -> ContinueStep {
        switch stop.continueReadiness {
        case .emptyResult? where stop.operation == .rebase:
            guard let current = stop.progress?.current else { return .run }
            return .confirmEmpty(current, otherStaged: stop.otherStagedAtEmpty)
        case .otherStagedChanges(let paths)?:
            return .confirmOthers(paths)
        default:
            return .run
        }
    }

    // MARK: - Skip

    /// On only with a stopped commit (an `exec` / `break` stop reports `.ready` with none,
    /// Task 3) and every change the commit's own.
    static func skipState(_ operation: RepositoryOperation, _ stop: OperationStop?, isMutating: Bool, sheetUp: Bool)
        -> BarActionState
    {
        guard isContinuable(operation) else { return .disabled(ContinueWording.notContinuable(operation)) }
        if sheetUp { return .disabled(ContinueWording.blockedBySheet) }
        if isMutating { return .disabled(ContinueWording.busy) }
        guard let stop, stop.operation == operation else { return .disabled(ContinueWording.reading(operation)) }
        if let failure = stop.readFailure { return .disabled(ContinueWording.readFailed(operation, failure)) }
        guard let readiness = stop.skipReadiness else { return .disabled(ContinueWording.reading(operation)) }
        switch readiness {
        case .staleSequence: return .disabled(ContinueWording.staleReason(operation))
        case .notSkippable: return .disabled(ContinueWording.noCommitToSkip)
        case .otherChanges(let paths): return .disabled(ContinueWording.skipOtherChanges(paths))
        case .needsCleanPaths(let paths): return .disabled(ContinueWording.skipNeedsCleanPaths(paths))
        case .ready: return stop.progress?.current == nil ? .disabled(ContinueWording.noCommitToSkip) : .enabled
        }
    }

    // MARK: - A stale sequencer list (Ruling 29)

    /// The older range's list this stop sits over, when GitCore found one.
    static func staleList(_ stop: OperationStop?) -> HaltedSequence? {
        if case .staleSequence(let old)? = stop?.continueReadiness { return old }
        if case .staleSequence(let old)? = stop?.skipReadiness { return old }
        return nil
    }

    /// The bar's abort button: off while a change runs, and over a stale list, where git's
    /// `--abort` would rewind HEAD to before the older range (GitCore refuses it too).
    static func abortState(_ operation: RepositoryOperation, _ stop: OperationStop?, isMutating: Bool) -> BarActionState {
        if isMutating { return .disabled(ContinueWording.busy) }
        if staleList(stop) != nil { return .disabled(ContinueWording.staleReason(operation)) }
        return .enabled
    }

    // MARK: - The files

    private static func isUnmerged(_ file: FileStatus) -> Bool {
        file.staged == .unmerged || file.unstaged == .unmerged
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// The staged paths that are not the operation's (Ruling 20): `diff --cached --no-renames
    /// HEAD` as the status shows it — both names of a rename, never an unmerged path — minus
    /// `own`. Nil `own` cannot tell them apart, and GitCore does not judge them then either.
    static func otherStaged(in files: [FileStatus], own: [String]?) -> [String] {
        guard let own else { return [] }
        let ownSet = Set(own)
        let staged = files.filter { $0.staged != nil && !isUnmerged($0) }
            .flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        return unique(staged.filter { !ownSet.contains($0) })
    }

    /// What `rebase --continue` refuses: a tracked file whose worktree differs from its index
    /// entry — not untracked, not unmerged, not a submodule (git's check ignores those).
    static func unstaged(in files: [FileStatus]) -> [String] {
        files.filter { !$0.isUntracked && !$0.isSubmodule && !isUnmerged($0) && $0.unstaged != nil }.map(\.path)
    }

    /// The paths Stage All would add (every unstaged change but an unmerged path, M 22) that
    /// are not among `own` — all of them when `own` is nil.
    static func stageAllSweep(_ files: [FileStatus], own: [String]?) -> [String] {
        let ownSet = Set(own ?? [])
        let added = files.filter { $0.unstaged != nil && !isUnmerged($0) }
            .flatMap { file in
                // A worktree-side rename (an intent-to-add entry) adds its old name's deletion too.
                [file.path] + (file.unstaged == .renamed ? file.originalPath.map { [$0] } ?? [] : [])
            }
        return unique(added.filter { !ownSet.contains($0) })
    }

    // MARK: - The composer

    /// "Lines starting with # are removed": a cherry-pick or revert strips comment lines
    /// whatever the setting (A2 Task 3); a rebase continues under `scissors` and a merge commits
    /// with `-F`, which both keep them.
    static func commentNote(_ operation: RepositoryOperation, _ stop: OperationStop?, message: String) -> String? {
        guard operation == .cherryPick || operation == .revert, let char = stop?.pendingMessage?.commentChar else {
            return nil
        }
        let hasCommentLine = message.split(separator: "\n", omittingEmptySubsequences: false).contains { $0.first == char }
        return hasCommentLine ? ContinueWording.commentNote(char) : nil
    }
}

/// Filling the composer with git's prepared message (spec, "Commit"): an empty draft, once per
/// stop, never over text the user typed. When the stop changes, a prefill the user left
/// untouched gives way to the next one, and edited text stays — marked as written for the commit
/// it was written for (`ForeignDraft`), which Continue and Commit then refuse to send until the
/// user uses the stop's message or keeps the text (fix round 1, I1). Text already there when an
/// operation first stops is marked the same way. When the operation ends, an untouched prefill
/// is taken back and the mark is dropped.
enum ComposerPrefill {

    /// A stop as the prefill knows it: what makes two reads the same stop — the operation, the
    /// commit and step it stopped at, a merge's incoming commit, whether git had a message (one
    /// that failed to read and then arrived fills the draft then) — and that stop's commit.
    struct Stop: Hashable {
        let key: String
        let commit: CommitRef?
    }

    static func stop(_ stop: OperationStop) -> Stop {
        let progress = stop.progress
        let key = [
            "\(stop.operation)", progress?.current?.sha ?? "-", progress?.step.map(String.init) ?? "-",
            progress?.mergeHead?.sha ?? "-", stop.pendingMessage == nil ? "0" : "1",
        ].joined(separator: "|")
        return Stop(key: key, commit: progress?.current)
    }

    /// Applies `stop` to `draft` and returns the stop to remember.
    @MainActor static func apply(_ stop: OperationStop?, lastKey: Stop?, to draft: CommitDraft) -> Stop? {
        guard let stop else {
            // Only a prefill of ours is taken back — never an amend's, never typed text.
            if lastKey != nil {
                draft.clearPrefillIfUntouched()
                draft.keepForeign()
            }
            return nil
        }
        let current = self.stop(stop)
        guard current.key != lastKey?.key else { return lastKey }
        if lastKey != nil { draft.clearPrefillIfUntouched() }
        guard !draft.amend else { return current }
        if draft.subject.isEmpty, draft.body.isEmpty {
            if let message = stop.pendingMessage { draft.prefill(from: message.text) }
        } else if draft.foreign == nil, lastKey == nil || lastKey?.commit?.sha != current.commit?.sha {
            // Text that stayed across a change of commit, or was there before the operation
            // stopped: not written for this stop. A key change for the same commit (a message
            // read that failed and came back, a step change) leaves it this commit's. A mark
            // already there keeps naming where it was written.
            draft.markForeign(ForeignDraft(writtenFor: lastKey?.commit))
        }
        return current
    }

    /// What Continue sends: nil — git's own message, which GitCore writes back stripped — at a
    /// stop with no message file, and for an untouched prefill of this stop's message; the
    /// draft otherwise.
    @MainActor static func continueMessage(_ stop: OperationStop?, _ draft: CommitDraft) -> String? {
        guard let pending = stop?.pendingMessage else { return nil }
        if draft.isUntouchedPrefill, draft.prefilledMessage == pending.text { return nil }
        return draft.message
    }
}

/// What a continue attempt came back with: git's outcome, or a question to ask first (the
/// staged files changed between the read and the run).
private enum ContinueAttempt {
    case outcome(ContinueOutcome)
    case ask(BranchSheet)
}

/// The operation bar and the composer's Continue: reading the stop, Continue (with its two
/// confirmations), Skip This Commit…, and Stage All's confirmation during an operation.
///
/// Every write goes through `mutate`. Continue re-reads the stop before running and refuses
/// when it is not the one on screen — the composer's message belongs to that commit — and
/// GitCore re-detects the operation and refuses unready states itself. A rebase's empty result
/// and other staged files are asked about first, and Continue acknowledges exactly the files the
/// sheet named (GitCore refuses any other set). Skip files the stopped commit's work in the
/// Stashes list before git discards it (GitCore). `ContinueWording` holds every sentence.
extension RepositoryStore {

    // MARK: - Reading

    /// The stop of the operation `status` shows, or nil with none. A failed read is kept as the
    /// reason the buttons are off rather than failing the snapshot.
    // internal (not private): used by +Refresh.swift's `loadSnapshot()`
    static func readOperationStop(_ status: WorkingCopyStatus, backend: Backend, root: URL) async -> OperationStop? {
        guard let operation = status.operationInProgress else { return nil }
        var stop = OperationStop(operation: operation)
        do {
            stop.progress = try await backend.operationProgress(at: root)
            if operation != .applyingPatches { stop.pendingMessage = try await backend.pendingMessage(at: root) }
            guard OperationBarState.isContinuable(operation) else { return stop }
            let readiness = try await backend.continueReadiness(at: root)
            stop.continueReadiness = readiness
            stop.skipReadiness = try await backend.skipReadiness(at: root)
            if readiness == .emptyResult {
                let own = try await backend.operationPaths(at: root)
                stop.otherStagedAtEmpty = OperationBarState.otherStaged(in: status.files, own: own)
                if operation == .rebase { stop.unstagedAtEmpty = OperationBarState.unstaged(in: status.files) }
            }
        } catch {
            stop.readFailure = describe(error)
        }
        return stop
    }

    // MARK: - State

    var operationProgress: OperationProgress? { operationStop?.progress }

    var continueState: BarActionState {
        guard let operation = operationInProgress else { return .disabled(ContinueWording.nothingToContinue) }
        return OperationBarState.continueState(
            operation, operationStop, isMutating: isMutating, sheetUp: activeSheet != nil, hasMessage: draft.canCommit,
            foreign: draft.foreign)
    }

    var skipState: BarActionState {
        guard let operation = operationInProgress else { return .disabled(ContinueWording.nothingToContinue) }
        return OperationBarState.skipState(operation, operationStop, isMutating: isMutating, sheetUp: activeSheet != nil)
    }

    /// The older range's list this cherry-pick or revert stops over (Ruling 29), when GitCore
    /// found one: the bar names it and the safe way out, and Continue, Skip and Abort are off.
    var staleSequence: HaltedSequence? { OperationBarState.staleList(operationStop) }

    /// The bar's abort button.
    var abortState: BarActionState {
        guard let operation = operationInProgress else { return .disabled(ContinueWording.nothingToContinue) }
        return OperationBarState.abortState(operation, operationStop, isMutating: isMutating)
    }

    /// The line under the bar.
    var continueReasonLine: String? {
        guard let operation = operationInProgress else { return nil }
        return OperationBarState.reasonLine(operation, operationStop, hasMessage: draft.canCommit, foreign: draft.foreign)
    }

    /// The bar's and the composer's Continue title, with an ellipsis when it will ask first.
    var continueTitle: String {
        guard let operation = operationInProgress else { return "" }
        let asks = operationStop.map { OperationBarState.continueStep($0) != .run } ?? false
        return ContinueWording.continueTitle(operation, asks: asks)
    }

    /// The bar's sentence: where the operation is and what to do next.
    var operationBarSentence: String {
        guard let operation = operationInProgress else { return "" }
        let progress = operationStop?.operation == operation ? operationStop?.progress : nil
        return ContinueWording.bar(
            operation, progress, branch: currentBranch, hasConflicts: hasUnmergedFiles,
            continueBlocked: continueReasonLine != nil, stale: staleSequence != nil)
    }

    /// The composer's note under a cherry-pick's or revert's message.
    var composerCommentNote: String? {
        guard let operation = operationInProgress else { return nil }
        return OperationBarState.commentNote(operation, operationStop, message: draft.message)
    }

    /// Whether the composer's button is Continue: during a rebase, cherry-pick or revert.
    var composerContinues: Bool {
        operationInProgress.map(OperationBarState.isContinuable) ?? false
    }

    // MARK: - Continue

    /// The bar's and the composer's Continue. Runs, or opens the confirmation the stop needs.
    func continueOperation() {
        guard let operation = operationInProgress, continueState == .enabled, let stop = operationStop else { return }
        switch OperationBarState.continueStep(stop) {
        case .run:
            runContinue(
                operation, expected: stop.progress?.current, step: stop.progress?.step, message: continueMessage,
                acknowledging: [], askingEmpty: false)
        case .confirmEmpty(let current, let otherStaged):
            activeSheet = .continueEmpty(current, otherStaged: otherStaged)
        case .confirmOthers(let paths):
            activeSheet = .continueOthers(operation, stop.progress?.current, paths: paths)
        }
    }

    /// The empty-result sheet's button, only as the answer to that sheet: continues the rebase
    /// acknowledging exactly the files it named.
    func confirmContinueEmpty() {
        guard case .continueEmpty(let current, let otherStaged) = activeSheet else { return }
        activeSheet = nil
        guard sheetStillApplies(to: .rebase) else { return }
        runContinue(
            .rebase, expected: current, step: nil, message: continueMessage, acknowledging: otherStaged,
            askingEmpty: true)
    }

    /// The other-staged sheet's button, only as the answer to that sheet.
    func confirmContinueOthers() {
        guard case .continueOthers(let operation, let current, let paths) = activeSheet else { return }
        activeSheet = nil
        guard sheetStillApplies(to: operation) else { return }
        runContinue(
            operation, expected: current, step: nil, message: continueMessage, acknowledging: paths, askingEmpty: false)
    }

    /// What Continue sends (`ComposerPrefill.continueMessage`): nil for git's own message — at a
    /// stop without one, and for an untouched prefill, which GitCore writes back as git wrote it.
    private var continueMessage: String? {
        ComposerPrefill.continueMessage(operationStop, draft)
    }

    /// Whether a Continue confirmation can still be acted on: the same operation, and a message
    /// where git has one to replace. Says why not in the banner (the sheet is closed by then).
    private func sheetStillApplies(to operation: RepositoryOperation) -> Bool {
        guard operationInProgress == operation else {
            showStickyError(ContinueWording.movedOn(operation))
            return false
        }
        guard operationStop?.pendingMessage == nil || draft.canCommit else {
            showStickyError(ContinueWording.enterMessage)
            return false
        }
        if operationStop?.pendingMessage != nil, let foreign = draft.foreign {
            showStickyError(
                ContinueWording.foreignReason(
                    writtenFor: foreign.writtenFor, operation: operation, current: operationStop?.progress?.current))
            return false
        }
        return true
    }

    private func runContinue(
        _ operation: RepositoryOperation, expected: CommitRef?, step: Int?, message: String?, acknowledging: [String],
        askingEmpty: Bool
    ) {
        mutate(result: { backend, root -> ContinueAttempt in
            // The stop the user was shown, still: the composer's message is that commit's, and
            // an empty-result confirmation was about that commit.
            let now = try await backend.operationProgress(at: root)
            guard let now, now.operation == operation, now.current?.sha == expected?.sha,
                step == nil || now.step == step
            else { throw BranchActionBlocked(reason: ContinueWording.movedOn(operation)) }
            if askingEmpty, try await backend.continueReadiness(at: root) != .emptyResult {
                throw BranchActionBlocked(reason: ContinueWording.movedOn(operation))
            }
            do {
                return .outcome(
                    try await backend.continueOperation(
                        operation, message: message, acknowledgingOtherStaged: acknowledging, at: root))
            } catch OperationError.notReady(.otherStagedChanges(let current)) where !current.isEmpty {
                // Staged or unstaged since the read: ask about the files as they are now.
                if askingEmpty, let expected { return .ask(.continueEmpty(expected, otherStaged: current)) }
                return .ask(.continueOthers(operation, expected, paths: current))
            }
        }, onSuccess: { [self] attempt in
            switch attempt {
            case .ask(let sheet):
                if activeSheet == nil { activeSheet = sheet }
            case .outcome(let outcome):
                finishContinue(operation, outcome)
            }
        })
    }

    private func finishContinue(_ operation: RepositoryOperation, _ outcome: ContinueOutcome) {
        switch outcome {
        case .finished:
            restartDraft()
            select(.workingCopy)
            showNotice(ContinueWording.finished(operation))
        case .stoppedAgain:
            // The bar says where; the next stop's message fills the composer.
            restartDraft()
        case .finishedWithConflicts(let paths):
            restartDraft()
            select(.workingCopy)
            showStickyNotice(Notice(text: ContinueWording.finishedWithConflicts(operation, paths.count)))
        case .failed(let words):
            // Nothing was committed: the draft stays as typed.
            showStickyError(ContinueWording.failed(operation, words))
        case .sequenceHalted(let words):
            // A commit was made with the message. The bar shows what git left for as long as it
            // stays (`haltedSequence`); this says what happened.
            restartDraft()
            select(.workingCopy)
            showStickyError(ContinueWording.sequenceHalted(operation, words))
        }
    }

    /// The draft was used for a commit: empty it, and let the stop now on screen fill it.
    private func restartDraft() {
        draft.reset()
        syncDraftWithOperation(restart: true)
    }

    // MARK: - The composer's message

    /// Where the draft came from, when it was not written for this stop and git has a message
    /// it would replace: the composer names it and offers the two ways on.
    var composerForeignDraft: ForeignDraft? {
        guard operationInProgress != nil, operationStop?.pendingMessage != nil else { return nil }
        return draft.foreign
    }

    /// "Use 0f3161e's Message": git's prepared message for this stop, in place of the draft.
    func useOperationMessage() {
        guard let message = operationStop?.pendingMessage else { return }
        draft.subject = ""
        draft.body = ""
        draft.prefill(from: message.text)
    }

    /// "Keep This Message": the draft is for this stop now.
    func keepDraftMessage() {
        draft.keepForeign()
    }

    // MARK: - Skip

    /// Skip This Commit…: reads the readiness again for the paths the sheet lists, and opens it.
    func requestSkip() {
        guard let operation = operationInProgress, skipState == .enabled, let root,
            let current = operationStop?.progress?.current
        else { return }
        let generation = self.generation
        Task { [self] in
            let readiness: SkipReadiness
            do {
                readiness = try await backend.skipReadiness(at: root)
            } catch {
                guard self.generation == generation else { return }
                showStickyError(Self.describe(error))
                return
            }
            guard self.generation == generation, activeSheet == nil, operationInProgress == operation,
                operationStop?.progress?.current == current
            else { return }
            guard case .ready(let paths) = readiness else {
                showStickyError(ContinueWording.error(.skipRefused(readiness)))
                return
            }
            activeSheet = .skip(operation, current, paths: paths)
        }
    }

    /// The Skip sheet's destructive button, only as the answer to the sheet about this commit.
    /// GitCore refuses if the operation stopped elsewhere since, files the paths, then skips.
    func confirmSkip(stoppedAt sha: String) {
        guard case .skip(let operation, let current, _) = activeSheet, current.sha == sha else { return }
        activeSheet = nil
        mutate(result: { backend, root in
            try await backend.skip(operation, stoppedAt: sha, at: root)
        }, onSuccess: { [self] result in
            finishSkip(operation, current, result)
        })
    }

    private func finishSkip(_ operation: RepositoryOperation, _ current: CommitRef, _ result: SkipOutcome) {
        let recorded = result.recorded
        // The skipped commit's message has no commit left to go to: the draft starts again from
        // the next stop's (fix round 1, I1). A failed skip skipped nothing and keeps it.
        if case .failed = result.outcome {} else { restartDraft() }
        switch result.outcome {
        case .finished:
            select(.workingCopy)
            // Pop only once nothing is in progress: it is refused during an operation.
            let text = ContinueWording.skipped(current, recorded: recorded, then: ContinueWording.finished(operation))
            announceSkip(text, recorded, canPop: true)
        case .stoppedAgain:
            announceSkip(ContinueWording.skipped(current, recorded: recorded, then: nil), recorded, canPop: false)
        case .finishedWithConflicts(let paths):
            select(.workingCopy)
            announceSkip(
                ContinueWording.skipped(
                    current, recorded: recorded, then: ContinueWording.finishedWithConflicts(operation, paths.count)),
                recorded, canPop: false, sticky: true)
        case .failed(let words):
            showStickyError(ContinueWording.skipFailed(operation, current, words, recorded: recorded != nil))
        case .sequenceHalted(let words):
            // No commit was made (measured). Sticky, with Show Copy for the entry the skip filed;
            // the bar names what git left.
            select(.workingCopy)
            announceSkip(
                ContinueWording.skipHalted(operation, current, recorded: recorded != nil, words), recorded,
                canPop: false, sticky: true)
        }
    }

    /// A transient notice, or — when an entry was filed — a sticky one that offers it.
    private func announceSkip(_ text: String, _ recorded: Stash?, canPop: Bool, sticky: Bool = false) {
        if let recorded {
            showStickyNotice(
                Notice(text: text, actions: canPop ? [.popStash(recorded), .showStash(recorded)] : [.showStash(recorded)]))
        } else if sticky {
            showStickyNotice(Notice(text: text))
        } else {
            showNotice(text)
        }
    }

    // MARK: - Stage All

    /// The Stage All button. With no operation it stages at once; during one it first reads the
    /// operation's paths and asks about the files outside them (M 22) — at once when there are
    /// none.
    func requestStageAll() {
        guard let operation = operationInProgress else {
            stageAll()
            return
        }
        guard let root, !isMutating, activeSheet == nil else { return }
        let generation = self.generation
        Task { [self] in
            // A failed read cannot tell: every file is listed (conservative).
            let own = (try? await backend.operationPaths(at: root)) ?? nil
            guard self.generation == generation, activeSheet == nil, !isMutating, operationInProgress == operation,
                let files = snapshot?.status.files
            else { return }
            let sweep = OperationBarState.stageAllSweep(files, own: own)
            if sweep.isEmpty {
                stageAll()
            } else {
                activeSheet = .stageAll(operation, sweep: sweep, known: own != nil)
            }
        }
    }

    /// The Stage All sheet's button, only as the answer to it. Read again first: a file that
    /// is not on the sheet — appeared since it opened — is asked about instead of staged.
    func confirmStageAll() {
        guard case .stageAll(let operation, let shown, _) = activeSheet else { return }
        activeSheet = nil
        let conflicted = Set(unmergedPaths)
        mutate(result: { [self] backend, root -> (sweep: [String], known: Bool)? in
            let own = (try? await backend.operationPaths(at: root)) ?? nil
            let now = OperationBarState.stageAllSweep(snapshot?.status.files ?? [], own: own)
            guard Set(now).isSubset(of: Set(shown)) else { return (now, own != nil) }
            try await backend.stageAll(at: root)
            return nil
        }, onSuccess: { [self] grown in
            if let grown {
                if activeSheet == nil { activeSheet = .stageAll(operation, sweep: grown.sweep, known: grown.known) }
                return
            }
            announceStageAllSkipped(conflicted)
        })
    }
}
