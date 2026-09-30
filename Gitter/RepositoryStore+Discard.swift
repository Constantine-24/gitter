import Foundation
import GitCore

/// One row of the discard sheet: a file and what it loses.
struct DiscardRow: Hashable {
    /// The path as the list shows it (`old → new` for a rename).
    let name: String
    /// `DiscardWording.loss`: "+12 −3", "3 lines", "untracked → Trash".
    let loses: String
    /// A line discard's lines, marked (`DiscardWording.preview`); empty for the other kinds.
    let preview: [String]
}

/// The discard sheet, as a snapshot of what it shows: the requests carry the `expected` diffs
/// (or untracked items) the rows were built from, and GitCore's stale check compares exactly
/// those again before anything is written.
struct DiscardSheetModel: Hashable {
    /// In the order they run: the tracked request first, then the untracked one (ruling 1). One
    /// request, except for Discard All… and a selection holding both kinds.
    let requests: [DiscardRequest]
    let rows: [DiscardRow]
    /// `DiscardWording.destination`: where the copy goes.
    let destination: String
    /// Discard All… (the unstaged header), which the title and button say.
    let isAll: Bool

    var title: String { DiscardWording.title(requests, all: isAll) }
    var confirmTitle: String { DiscardWording.confirmButton(requests, all: isAll) }

    /// What a confirm re-reads before the first request runs: the requests after it. GitCore
    /// checks each request itself as it starts, so the first needs nothing more; a later one
    /// changed while the sheet was up must refuse the confirm before the first has written
    /// anything (fix round 1), not be found after it.
    var checkedBeforeTheFirstRuns: [DiscardRequest] { Array(requests.dropFirst()) }
}

/// What the discard sheet's tracked reads depend on, read with `lstat` alone: each tracked
/// path, the index, HEAD, and the attributes and config that change how a diff reads. The
/// sheet's stale line reads git again only when this moved since its last read (final review
/// I1: the whole read after every reload took 3 s for 200 files). Not covered: the user's
/// global config and attributes file, and a `.gitattributes` in a folder that holds none of the
/// paths — the confirm still reads everything again and refuses (GitCore's stale check).
struct DiscardSheetFingerprint: Hashable {
    /// One file as `lstat` sees it; absent is nil. Any write moves the times, and an editor's
    /// save that replaces the file moves the inode too.
    struct Stamp: Hashable {
        let device: Int64
        let inode: UInt64
        let mode: UInt16
        let size: Int64
        let modified: [Int]
        let changed: [Int]
    }

    struct Entry: Hashable {
        let path: String
        let stamp: Stamp?
    }

    let entries: [Entry]
    let head: String?

    /// Nil when the git directory cannot be found: then there is nothing to compare, and the
    /// sheet reads again after every reload.
    static func take(tracked paths: [String], root: URL, head: String?) -> DiscardSheetFingerprint? {
        guard let gitDirectory = gitDirectory(of: root) else { return nil }
        var files = paths.map { root.appendingPathComponent($0).path }
        files += ["index", "config", "info/attributes"].map { gitDirectory.appendingPathComponent($0).path }
        let folders = Set([""] + paths.flatMap(folders(of:))).sorted()
        files += folders.map { root.appendingPathComponent($0).appendingPathComponent(".gitattributes").path }
        return DiscardSheetFingerprint(entries: files.map { Entry(path: $0, stamp: stamp($0)) }, head: head)
    }

    /// `root/.git`, or where a `.git` file's `gitdir:` line points (a linked worktree).
    static func gitDirectory(of root: URL) -> URL? {
        let dotGit = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
            let line = text.split(separator: "\n").first, line.hasPrefix("gitdir: ")
        else { return nil }
        let path = String(line.dropFirst("gitdir: ".count)).trimmingCharacters(in: .whitespaces)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }

    /// `a/b/c` → `a`, `a/b`.
    private static func folders(of path: String) -> [String] {
        let parts = path.split(separator: "/").dropLast()
        return parts.indices.map { parts[...$0].joined(separator: "/") }
    }

    private static func stamp(_ path: String) -> Stamp? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Stamp(
            device: Int64(info.st_dev), inode: UInt64(info.st_ino), mode: UInt16(info.st_mode),
            size: Int64(info.st_size),
            modified: [Int(info.st_mtimespec.tv_sec), Int(info.st_mtimespec.tv_nsec)],
            changed: [Int(info.st_ctimespec.tv_sec), Int(info.st_ctimespec.tv_nsec)])
    }
}

/// What the sheet's stale line found last, and what its tracked reads depended on then.
struct DiscardStaleCheck: Equatable {
    let fingerprint: DiscardSheetFingerprint?
    /// The tracked requests' answer, kept while the fingerprint stands still.
    let trackedStale: Bool
    let isStale: Bool

    /// Whether the tracked requests are read again: the first check, no fingerprint now or
    /// then, or one that moved since.
    static func mustReadTracked(after last: DiscardStaleCheck?, now: DiscardSheetFingerprint?) -> Bool {
        guard let last, let before = last.fingerprint, let now else { return true }
        return before != now
    }
}

/// Which discard a hunk header offers on the unstaged side (ruling 4).
enum HunkDiscardOffer: Hashable {
    case hunk
    case lines(Int)
    /// The file cannot be discarded line-wise (`PatchBuilder.supportsPartialDiscard` is false),
    /// or the patch would have a context-free hunk: the hunk offers the whole-file discard.
    case wholeFile

    var title: String {
        switch self {
        case .hunk: DiscardWording.discardHunk
        case .lines(let count): DiscardWording.discardLines(count)
        case .wholeFile: DiscardWording.discardFile
        }
    }

    /// Nil on the staged side, and when the selection holds no changed line.
    static func offer(
        for file: FileDiff, hunk: Hunk.ID, lines: Set<DiffLine.ID>?, onUnstagedSide: Bool
    ) -> HunkDiscardOffer? {
        guard onUnstagedSide else { return nil }
        guard PatchBuilder.supportsPartialDiscard(file) else { return .wholeFile }
        let chosen = chosenLines(lines)
        guard let patch = PatchBuilder.discardPatch(file: file, hunkIDs: [hunk], lineIDs: chosen)
        else { return nil }
        if patch.hasContextFreeHunk { return .wholeFile }
        guard chosen != nil else { return .hunk }
        return .lines(PatchBuilder.selectedLineCount(file: file, hunkIDs: [hunk], lineIDs: chosen))
    }

    /// An empty selection is the whole hunk.
    static func chosenLines(_ lines: Set<DiffLine.ID>?) -> Set<DiffLine.ID>? {
        lines?.isEmpty == false ? lines : nil
    }
}

/// Which files a discard is off for, from the status alone: the refusals GitCore would make,
/// said before the click (ruling 5). GitCore still makes each of them itself.
enum DiscardGate {
    /// `hasCommits` false is a repository before its first commit (an unborn HEAD): a tracked
    /// discard's record is a stash commit on HEAD, so GitCore could only fail there.
    static func block(for file: FileStatus, among files: [FileStatus], hasCommits: Bool = true)
        -> DiscardWording.FileBlock?
    {
        if file.staged == .unmerged || file.unstaged == .unmerged { return .unmerged(file.path) }
        if file.isIntentToAdd { return .intentToAdd(file.path) }
        if file.isSubmodule { return .submodule(file.path) }
        if file.isUntracked { return file.isNestedRepository ? .anotherRepository(file.path) : nil }
        if !hasCommits { return .noCommitYet }
        return typeChange(of: file, among: files).map { .typeChanged($0) }
    }

    /// A tracked path deleted in the worktree whose place an untracked item of the other shape
    /// took: `p` deleted with `p/` (or `p/x`) untracked is a file that became a folder; `d/x`
    /// deleted with `d` untracked is a folder that became a file (or a link). Restoring it would
    /// overwrite what is there, which is in no record (`DiscardRefusal.pathTypeChanged`).
    static func typeChange(of file: FileStatus, among files: [FileStatus]) -> StashWording.TypeChange? {
        guard file.unstaged == .deleted else { return nil }
        for other in files where other.isUntracked {
            let bare = other.path.hasSuffix("/") ? String(other.path.dropLast()) : other.path
            if bare == file.path || other.path.hasPrefix(file.path + "/") {
                return .fileBecameFolder(file.path)
            }
            if !other.path.hasSuffix("/"), file.path.hasPrefix(other.path + "/") {
                return .folderBecameFile(path: file.path, file: other.path)
            }
        }
        return nil
    }
}

/// Discard: the sheet's entry points, its confirm, and Undo Discard.
///
/// Every discard is recoverable (GitCore): tracked changes are recorded in the Stashes list
/// first, untracked items go to the Trash. The sheet is a snapshot — its model carries what it
/// showed, and the confirm hands exactly that to GitCore, which re-reads and refuses when it is
/// no longer so. After a discard a sticky notice says what went, with Undo Discard; the undo's
/// outcome replaces it. Every write goes through `mutate`; `DiscardWording` holds every
/// sentence.
extension RepositoryStore {

    // MARK: - Why an entry point is off

    /// Why every discard is off right now, or nil: no repository, a sheet is up, an operation is
    /// in progress (GitCore refuses it too, M 13), or another change is running.
    var discardBlockedReason: String? {
        guard root != nil, snapshot != nil else { return DiscardWording.nothingToDiscard }
        if activeSheet != nil { return StashWording.blockedBySheet }
        if let operation = operationInProgress { return DiscardWording.blockedDuringOperation(operation) }
        if isMutating { return StashWording.busy }
        return nil
    }

    /// Why discarding `file` is off: the reasons above, or the file's own (`DiscardGate`).
    func discardBlockedReason(for file: FileStatus) -> String? {
        if let reason = discardBlockedReason { return reason }
        return DiscardGate.block(for: file, among: snapshot?.status.files ?? [], hasCommits: headSha != nil)
            .map(DiscardWording.blocked)
    }

    /// The same for the file a working-copy diff belongs to.
    func discardBlockedReason(forDiffOf diff: FileDiff) -> String? {
        guard let file = statusOfUnstagedDiff(diff) else { return DiscardWording.nothingToDiscard }
        return discardBlockedReason(for: file)
    }

    /// Discard All…: off when any unstaged file is off, rather than leaving it out unsaid.
    var discardAllBlockedReason: String? {
        if let reason = discardBlockedReason { return reason }
        let files = unstagedFiles
        if files.isEmpty { return DiscardWording.nothingToDiscard }
        let all = snapshot?.status.files ?? []
        return files.lazy.compactMap { DiscardGate.block(for: $0, among: all, hasCommits: self.headSha != nil) }
            .first.map(DiscardWording.blocked)
    }

    private func statusOfUnstagedDiff(_ diff: FileDiff) -> FileStatus? {
        let path = diff.displayPath
        return unstagedFiles.first { $0.path == path }
    }

    // MARK: - Opening the sheet

    /// "Discard Changes…" / "Move to Trash…" (and ⌫) on unstaged rows: tracked files lose their
    /// unstaged changes, untracked ones go to the Trash. A blocked file says why in the banner
    /// — ⌫ has no tooltip to say it in.
    func requestDiscardUnstaged(_ files: [FileStatus]) {
        guard !files.isEmpty else { return }
        if let reason = files.lazy.compactMap(discardBlockedReason(for:)).first {
            showStickyError(reason)
            return
        }
        openDiscardSheet(
            tracked: files.filter { !$0.isUntracked }, includingStaged: false,
            untracked: files.filter(\.isUntracked).map(\.path), all: false)
    }

    /// "Discard Staged and Unstaged Changes…" (and ⌫) on a staged row. A rename passes both
    /// paths, and is undone whole.
    func requestDiscardStaged(_ file: FileStatus) {
        if let reason = discardBlockedReason(for: file) {
            showStickyError(reason)
            return
        }
        openDiscardSheet(tracked: [file], includingStaged: true, untracked: [], all: false)
    }

    /// Discard All… on the unstaged header: every tracked file's unstaged changes, and every
    /// untracked item to the Trash — two requests in one confirm (ruling 1).
    func requestDiscardAllUnstaged() {
        if let reason = discardAllBlockedReason {
            showStickyError(reason)
            return
        }
        let files = unstagedFiles
        openDiscardSheet(
            tracked: files.filter { !$0.isUntracked }, includingStaged: false,
            untracked: files.filter(\.isUntracked).map(\.path), all: true)
    }

    /// "Discard Hunk…" / "Discard N Lines…" / "Discard File…" on an unstaged hunk. `lines` nil
    /// (or empty) is the whole hunk. The sheet is built from the diff read again now, which
    /// must be the one on screen: the line ids are that parse's.
    func requestDiscardHunk(_ hunk: Hunk.ID, lines: Set<DiffLine.ID>?, in diff: FileDiff) {
        guard selection == .workingCopy, !diffIsStaged, let file = statusOfUnstagedDiff(diff) else { return }
        if let reason = discardBlockedReason(for: file) {
            showStickyError(reason)
            return
        }
        guard let offer = HunkDiscardOffer.offer(for: diff, hunk: hunk, lines: lines, onUnstagedSide: true)
        else { return }
        if offer == .wholeFile {
            requestDiscardUnstaged([file])
            return
        }
        let chosen = HunkDiscardOffer.chosenLines(lines)
        guard let root, let patch = PatchBuilder.discardPatch(file: diff, hunkIDs: [hunk], lineIDs: chosen)
        else { return }
        let count = PatchBuilder.selectedLineCount(file: diff, hunkIDs: [hunk], lineIDs: chosen)
        let path = file.path
        let generation = self.generation
        Task { [self] in
            let expected: DiscardExpectation
            do {
                expected = try await backend.discardExpectation(tracked: [path], includingStaged: false, at: root)
            } catch {
                guard self.generation == generation else { return }
                showStickyError(Self.describe(error))
                return
            }
            guard self.generation == generation, activeSheet == nil else { return }
            guard expected == .diffs([diff]) else {
                showStickyError(DiscardWording.refusal(.changedSinceShown([path])))
                return
            }
            let request = DiscardRequest.lines(path: path, patch: patch, lineCount: count, expected: expected)
            let row = DiscardRow(
                name: path, loses: DiscardWording.loss(.lines(count)),
                preview: Self.preview(diff, hunk: hunk, lines: chosen))
            activeSheet = .discard(
                DiscardSheetModel(
                    requests: [request], rows: [row],
                    destination: DiscardWording.destination(record: request.recordMessage, untracked: false),
                    isAll: false))
        }
    }

    /// Reads what the sheet shows — the very reads GitCore's stale check repeats — and opens it.
    /// Nothing left to discard (a file that changed back meanwhile) says so instead.
    private func openDiscardSheet(tracked: [FileStatus], includingStaged: Bool, untracked: [String], all: Bool) {
        guard let root else { return }
        let paths = tracked.flatMap { [$0.path] + (includingStaged ? $0.originalPath.map { [$0] } ?? [] : []) }
        let generation = self.generation
        Task { [self] in
            var requests: [DiscardRequest] = []
            var rows: [DiscardRow] = []
            var record: String?
            var anyUntracked = false
            do {
                if !paths.isEmpty {
                    let expected = try await backend.discardExpectation(
                        tracked: paths, includingStaged: includingStaged, at: root)
                    if case .diffs(let diffs) = expected, !diffs.isEmpty {
                        let request: DiscardRequest =
                            includingStaged
                            ? .stagedAndUnstaged(paths: paths, expected: expected)
                            : .unstaged(paths: paths, expected: expected)
                        requests.append(request)
                        record = request.recordMessage
                        rows += Self.rows(for: tracked, diffs: diffs)
                    }
                }
                if !untracked.isEmpty {
                    let expected = try await backend.discardExpectation(untracked: untracked, at: root)
                    if case .untracked(let items) = expected, !items.isEmpty {
                        // The items found now: one gone meanwhile is not named, nor asked for.
                        requests.append(.untracked(paths: items.map(\.path), expected: expected))
                        anyUntracked = true
                        rows += items.map {
                            DiscardRow(
                                name: $0.path,
                                loses: DiscardWording.loss($0.isDirectory ? .untrackedFolder : .untrackedFile),
                                preview: [])
                        }
                    }
                }
            } catch {
                guard self.generation == generation else { return }
                showStickyError(Self.describe(error))
                return
            }
            guard self.generation == generation, activeSheet == nil else { return }
            guard !requests.isEmpty else {
                showStickyError(DiscardWording.refusal(.nothingSelected))
                return
            }
            activeSheet = .discard(
                DiscardSheetModel(
                    requests: requests, rows: rows,
                    destination: DiscardWording.destination(record: record, untracked: anyUntracked),
                    isAll: all))
        }
    }

    /// One row per file, counted from the diffs the sheet shows for it (both paths of a rename).
    static func rows(for files: [FileStatus], diffs: [FileDiff]) -> [DiscardRow] {
        files.map { file in
            let paths = Set([file.path] + (file.originalPath.map { [$0] } ?? []))
            let own = diffs.filter { diff in
                [diff.oldPath, diff.newPath].contains { $0.map(paths.contains) ?? false }
            }
            let name = file.originalPath.map { "\($0) \u{2192} \(file.path)" } ?? file.path
            return DiscardRow(name: name, loses: DiscardWording.loss(.init(of: own)), preview: [])
        }
    }

    /// The changed lines a line discard takes, marked, capped at `previewLimit`.
    private static func preview(_ diff: FileDiff, hunk: Hunk.ID, lines chosen: Set<DiffLine.ID>?) -> [String] {
        let taken = diff.hunks.filter { $0.id == hunk }.flatMap(\.lines).filter { line in
            (line.kind == .added || line.kind == .removed) && (chosen?.contains(line.id) ?? true)
        }
        let shown = taken.prefix(DiscardWording.previewLimit).map(DiscardWording.preview)
        let more = taken.count - shown.count
        return shown + (more > 0 ? [DiscardWording.previewMore(more)] : [])
    }

    // MARK: - The sheet while it is up

    /// Whether what the sheet shows is still what a confirm would find: the same reads again,
    /// and for untracked items the status still listing them as untracked. Read-only, no
    /// mutation lock. A read that fails counts as changed — the confirm cannot be shown to
    /// match either.
    func discardSheetIsStale(_ model: DiscardSheetModel) async -> Bool {
        await areStale(model.requests)
    }

    /// The live stale line's check, after every snapshot load (RF3): the untracked items every
    /// time (`lstat` and the status on screen, no process), the tracked requests only when
    /// what their reads depend on moved since `last` (`DiscardSheetFingerprint`, final review
    /// I1). The fingerprint is taken before the reads, so a change made during them is still
    /// found by the next check.
    func discardSheetStaleness(_ model: DiscardSheetModel, after last: DiscardStaleCheck?) async -> DiscardStaleCheck {
        let tracked = model.requests.filter { if case .untracked = $0 { false } else { true } }
        let fingerprint = root.flatMap {
            DiscardSheetFingerprint.take(tracked: tracked.flatMap(\.paths), root: $0, head: headSha)
        }
        let trackedStale =
            DiscardStaleCheck.mustReadTracked(after: last, now: fingerprint)
            ? await areStale(tracked) : last?.trackedStale ?? true
        let untrackedStale = await areStale(model.requests.filter { if case .untracked = $0 { true } else { false } })
        return DiscardStaleCheck(
            fingerprint: fingerprint, trackedStale: trackedStale, isStale: trackedStale || untrackedStale)
    }

    private func areStale(_ requests: [DiscardRequest]) async -> Bool {
        guard !requests.isEmpty else { return false }
        guard let root else { return true }
        for request in requests {
            let now: DiscardExpectation?
            switch request {
            case .unstaged(let paths, _):
                now = try? await backend.discardExpectation(tracked: paths, includingStaged: false, at: root)
            case .stagedAndUnstaged(let paths, _):
                now = try? await backend.discardExpectation(tracked: paths, includingStaged: true, at: root)
            case .lines(let path, _, _, _):
                now = try? await backend.discardExpectation(tracked: [path], includingStaged: false, at: root)
            case .untracked(let paths, _):
                let listed = unstagedFiles.filter(\.isUntracked).map(\.path)
                let stillUntracked = paths.allSatisfy { path in
                    listed.contains { $0 == path || ($0.hasSuffix("/") && path.hasPrefix($0)) }
                }
                if !stillUntracked { return true }
                now = try? await backend.discardExpectation(untracked: paths, at: root)
            }
            if now != request.expected { return true }
        }
        return false
    }

    // MARK: - Confirm

    /// What a confirm did: the receipts of the requests that ran, then the first failure, if
    /// any, in its sentence, and a failed Trash's receipt when some items did go (undoable).
    struct DiscardRun {
        var receipts: [DiscardReceipt] = []
        var failure: String?
        var partlyTrashed: DiscardReceipt?
    }

    /// The sheet's destructive button, **only** as the answer to the sheet that showed this
    /// model. The requests go to GitCore as the sheet had them — with the diffs it showed — and
    /// GitCore refuses (`changedSinceShown`) when the files moved on meanwhile.
    ///
    /// Discard All… runs its tracked request first and its untracked one second (ruling 1).
    /// Each request's own stale check runs only as it starts, so the requests after the first
    /// are checked before the first runs: an untracked item changed while the sheet was up must
    /// refuse the confirm, not be found after the tracked files were already discarded (fix
    /// round 1). The first is left to GitCore's own check, which comes before it writes
    /// anything; reading it here as well read the whole sheet twice (final review I1). What is
    /// left is the window of the tracked discard itself; when the second fails then, the notice
    /// still names what the first did, with its Undo.
    func confirmDiscard(_ model: DiscardSheetModel) {
        guard case .discard(let shown) = activeSheet, shown == model else { return }
        activeSheet = nil
        let trasher = self.trasher
        mutate(result: { [self] backend, root in
            var run = DiscardRun()
            if await areStale(model.checkedBeforeTheFirstRuns) {
                run.failure = DiscardWording.refusal(.changedSinceShown(model.requests.flatMap(\.paths)))
                return run
            }
            for request in model.requests {
                do {
                    run.receipts.append(try await backend.discard(request, trasher: trasher, at: root))
                } catch {
                    run.failure = Self.discardFailureText(error, afterDiscarding: !run.receipts.isEmpty, root: root)
                    // Ruling 2: Undo only where something went and can come back — items the
                    // Trash took. A tracked failure's record is named in the sentence instead:
                    // its undo would be refused (the files may be part-way restored, ruling 3).
                    if let failure = error as? DiscardFailure, case .untracked = failure.receipt.request,
                        !failure.receipt.trashed.isEmpty
                    {
                        run.partlyTrashed = failure.receipt
                    }
                    break
                }
            }
            return run
        }, onSuccess: { [self] run in
            let discarded = run.receipts + (run.partlyTrashed.map { [$0] } ?? [])
            // Undo only for what it can put back (minor 1): a line discard whose after-state
            // could not be read would be refused as "moved since the discard". The notice names
            // that one's copy in the Stashes list instead.
            let undoable = discarded.filter(DiscardWording.isUndoable)
            if !discarded.isEmpty {
                showStickyNotice(
                    Notice(
                        text: DiscardWording.done(discarded),
                        actions: undoable.isEmpty ? [] : [.undoDiscard(undoable)]))
            }
            if let failure = run.failure { showStickyError(failure) }
        })
    }

    /// A discard's error in its sentence. After a request that discarded (`afterDiscarding`),
    /// a refusal is about the untracked part only.
    static func discardFailureText(_ error: Error, afterDiscarding: Bool, root: URL) -> String {
        switch error {
        case let refusal as DiscardRefusal:
            if afterDiscarding { return DiscardWording.untrackedPartRefused(refusal) }
            if case .pathTypeChanged(let paths) = refusal {
                return DiscardWording.typeChanged(paths.map { typeChange(of: $0, under: root) })
            }
            return DiscardWording.refusal(refusal)
        case let failure as DiscardFailure:
            return DiscardWording.failure(failure)
        default:
            // Anything else was thrown before anything was written, or after a change that
            // provably changed nothing (GitCore drops the record again then).
            return afterDiscarding
                ? DiscardWording.untrackedPartFailed(describe(error))
                : DiscardWording.discardError(describe(error))
        }
    }

    // MARK: - Undo

    /// The notice's Undo Discard: each receipt in reverse order — the untracked items back
    /// from the Trash first, then the tracked record (ruling 1). The outcome replaces the
    /// notice: a notice when everything came back, a banner otherwise.
    func undoDiscard(_ receipts: [DiscardReceipt]) {
        if let reason = discardBlockedReason {
            // The notice's button is not disabled; a click that says nothing reads as broken.
            showStickyError(reason)
            return
        }
        let trasher = self.trasher
        mutate(result: { backend, root in
            var results: [(DiscardReceipt, Result<UndoDiscardOutcome, Error>)] = []
            for receipt in receipts.reversed() {
                do {
                    results.append((receipt, .success(try await backend.undoDiscard(receipt, trasher: trasher, at: root))))
                } catch {
                    results.append((receipt, .failure(error)))
                }
            }
            return results
        }, onSuccess: { [self] results in
            let head = headSha ?? ""
            var texts: [String] = []
            var allBack = true
            // Said in the order the notice named them.
            for (receipt, result) in results.reversed() {
                switch result {
                case .success(let outcome):
                    allBack = allBack && DiscardWording.isNotice(outcome)
                    texts.append(
                        DiscardWording.undone(outcome, of: receipt, headMoved: head != receipt.headAtDiscard))
                case .failure(let error):
                    allBack = false
                    texts.append(Self.undoFailureText(error))
                }
            }
            let text = texts.joined(separator: " ")
            if allBack {
                showStickyNotice(Notice(text: text))
            } else {
                dismissStickyNotice()
                showStickyError(text)
            }
        })
    }

    private static func undoFailureText(_ error: Error) -> String {
        switch error {
        case let refusal as DiscardRefusal: DiscardWording.undoRefused(refusal)
        case let failure as DiscardFailure: DiscardWording.undoFailed(failure)
        default: DiscardWording.undoError(describe(error))
        }
    }
}
