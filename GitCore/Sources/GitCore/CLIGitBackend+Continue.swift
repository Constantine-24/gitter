import Foundation

/// Progress, the pending message, Continue and Skip (M 13–M 19, M 26, M 29–M 32). See
/// `GitOperationBackend` for the contract; this file is about how git is asked.
///
/// Every read goes through git (`rev-parse --git-path`, `--verify`) so a linked worktree's own
/// files are the ones read (see `CLIGitBackend+Operation`). Every write re-detects the operation
/// first, as `abort` does, and runs one complete literal vector chosen by a `switch`.
///
/// **Measured for this task (A2 Task 3, git 2.54):**
/// - `commit.cleanup` does not reach a cherry-pick or revert continue: under `scissors` and
///   `verbatim` (as config parameters) `# hash line` was stripped as by default. Only the
///   rebase continue gets `scissors` (M 29).
/// - `core.commentChar=auto`: the sequencer writes its `# Conflicts:` block with `#`, and at
///   continue git picks the character with commit.c's rule — `#` when the text holds none;
///   otherwise the first of `#;@!$%^&|:` that neither the text's first byte nor the first byte
///   of any line before the trailing comment block is (`autoCommentChar`). A stopped commit
///   whose subject is `#123 fix` therefore keeps the `# Conflicts:` block in the commit.
/// - A multi-character `core.commentChar` strips lines starting with the whole string, and of
///   `core.commentChar` and `core.commentString` the one set last wins.
/// - An unrelated edit during a stop: `rebase --continue` refuses any unstaged change to a
///   tracked file (exit 1, stdout "You must edit all merge conflicts and then / mark them as
///   resolved using git add") with the stop and the edit intact; a staged one it commits into
///   the replayed commit. `cherry-pick|revert --continue` keep an unstaged edit and commit a
///   staged one into the stopped commit, as `git commit` would.
///
/// **Measured in fix round 1:**
/// - Every unrelated staged change rides into the continued commit, for all three, single and
///   range: a new file, a staged deletion, both halves of a staged `mv`, a mode change, a staged
///   edit whose worktree was put back. An intent-to-add entry does not (pick, revert); a rebase
///   refuses it. With the resolution equal to HEAD plus one such file, `diff --cached --quiet
///   HEAD` exits 1 and git commits the file alone under the stopped commit's title and author.
/// - A pick or revert range with an unstaged edit in a file a later commit touches: git commits
///   the current commit, refuses the next ("Your local changes to the following files would be
///   overwritten by merge", exit 128) and leaves `sequencer/` without `CHERRY_PICK_HEAD` /
///   `REVERT_HEAD`; a later `--continue` exits 0 and drops the rest. An untracked file the next
///   commit adds does the same ("untracked working tree files would be overwritten"); in a
///   rebase it stops the rebase at the next step instead. A single pick or revert keeps
///   unstaged edits and finishes.
/// - `cherry-pick|revert --skip` exit 128 ("Entry 'p' not uptodate. Cannot merge." / "fatal:
///   Could not reset index file") when a path of the commit's is staged and also changed in the
///   worktree (`MM`, `AM`); an unmerged path's worktree does not matter. All three refuse an
///   untracked file at a path the commit deleted ("would be overwritten by reset|merge").
/// - At a clean `edit` stop `rebase --skip` exits 0 and the commit stays.
extension CLIGitBackend: GitOperationBackend {
    /// The message of the entry filed before a skip.
    static let skippedByGitter = "Skipped by Gitter: "

    /// git's default comment character, `#`, as a byte and as text. Not written as a literal: a
    /// quote followed by that character reads to `ForceFlagScanner` as the start of a raw string
    /// literal, and it refuses to scan such a file.
    static let defaultCommentByte: UInt8 = 0x23
    static let defaultComment = String(Unicode.Scalar(defaultCommentByte))

    /// The three operations with a Continue and a Skip.
    static let sequencerOperations: Set<RepositoryOperation> = [.rebase, .cherryPick, .revert]

    /// A continue or skip exits 0, 1 (the next stop, a hook, a refusal) or 128 (git's own
    /// refusals); every code is an answer here, because the repository is read again afterwards
    /// and git's words go into `.failed`.
    static let anyExitCode: Set<Int32> = Set((1...255).map { Int32($0) })

    // MARK: - Progress

    public func operationProgress(at root: URL) async throws -> OperationProgress? {
        guard let operation = try await operationInProgress(at: root) else { return nil }
        switch operation {
        case .rebase:
            let directory = try await gitPath("rebase-merge", at: root)
            let onto = Self.contents(of: directory.appendingPathComponent("onto"))
            let headName = Self.contents(of: directory.appendingPathComponent("head-name")).flatMap { name in
                name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : nil
            }
            return OperationProgress(
                operation: operation,
                step: Self.contents(of: directory.appendingPathComponent("msgnum")).flatMap { Int($0) },
                total: Self.contents(of: directory.appendingPathComponent("end")).flatMap { Int($0) },
                current: try await commit("REBASE_HEAD", at: root)?.ref,
                headName: headName,
                onto: try await onto.asyncFlatMap { try await commit($0, at: root)?.ref })
        case .cherryPick, .revert:
            // `sequencer/todo` exists for a range only, and lists the current commit first (M 16).
            let todo = Self.contents(of: try await gitPath("sequencer/todo", at: root), trimmed: false)
            let remaining = todo.map { text in
                text.split(separator: "\n").filter { line in
                    let command = line.trimmingCharacters(in: .whitespaces)
                    return !command.isEmpty && !command.hasPrefix(Self.defaultComment)
                }.count
            }
            let head = operation == .cherryPick ? "CHERRY_PICK_HEAD" : "REVERT_HEAD"
            return OperationProgress(
                operation: operation, remaining: remaining, current: try await commit(head, at: root)?.ref)
        case .merge:
            let message = Self.contents(of: try await gitPath("MERGE_MSG", at: root), trimmed: false)
            let firstLine = message?.split(separator: "\n", omittingEmptySubsequences: false).first
            return OperationProgress(
                operation: operation, mergeHead: try await commit("MERGE_HEAD", at: root)?.ref,
                mergedName: firstLine.flatMap { Self.mergedName(String($0)) })
        case .squash, .applyingPatches:
            return OperationProgress(operation: operation)
        }
    }

    /// The branch, tag or remote-tracking branch `MERGE_MSG`'s first line names (M 26): `Merge
    /// branch 'x'`, `Merge tag 'v1'`, `Merge remote-tracking branch 'origin/x'`, each optionally
    /// followed by ` into <branch>` (a merge into anything but main or master). Anything else,
    /// and a name holding a `'`, is nil.
    static func mergedName(_ line: String) -> String? {
        for prefix in ["Merge branch '", "Merge tag '", "Merge remote-tracking branch '"] where line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count)
            let name: Substring
            if let into = rest.range(of: "' into ", options: .backwards) {
                name = rest[rest.startIndex..<into.lowerBound]
                guard !rest[into.upperBound...].isEmpty else { return nil }
            } else if rest.hasSuffix("'") {
                name = rest.dropLast()
            } else {
                return nil
            }
            return name.isEmpty || name.contains("'") ? nil : String(name)
        }
        return nil
    }

    // MARK: - The pending message

    public func pendingMessage(at root: URL) async throws -> PendingMessage? {
        guard let operation = try await operationInProgress(at: root),
            let name = Self.messageFile(of: operation, pending: true),
            let text = Self.contents(of: try await gitPath(name, at: root), trimmed: false)
        else { return nil }
        let comment = try await commentString(for: text, at: root)
        return PendingMessage(text: Self.withoutComments(text, comment: comment), commentChar: comment.first ?? Character(Self.defaultComment))
    }

    /// Where the operation's message lives. `pending: true` is what the composer shows (a squash
    /// reads `SQUASH_MSG`, M 19); `false` is where a continue writes (rebase, pick, revert only).
    static func messageFile(of operation: RepositoryOperation, pending: Bool) -> String? {
        switch operation {
        case .rebase: return "rebase-merge/message"
        case .cherryPick, .revert: return "MERGE_MSG"
        case .merge: return pending ? "MERGE_MSG" : nil
        case .squash: return pending ? "SQUASH_MSG" : nil
        case .applyingPatches: return nil
        }
    }

    /// The comment string git will use for `text`: the last of `core.commentChar` /
    /// `core.commentString` set, `#` when neither is, and under `auto` git's choice for this
    /// text (`autoCommentChar`).
    func commentString(for text: String, at root: URL) async throws -> String {
        let data = try await run(
            ["config", "-z", "--get-regexp", "^core[.]comment(char|string)$"], cwd: root, allowedExitCodes: [1])
        // `-z`: `key\nvalue\0` per entry, in the order git reads them; the last one wins.
        let entries = String(decoding: data, as: UTF8.self).split(separator: "\0")
        guard let last = entries.last, let newline = last.firstIndex(of: "\n") else { return Self.defaultComment }
        let value = String(last[last.index(after: newline)...])
        if value.isEmpty { return Self.defaultComment }
        if value.lowercased() == "auto" { return String(Self.autoCommentChar(for: text)) }
        return value
    }

    /// `text` without the lines that begin with `comment`, and without trailing blank lines.
    static func withoutComments(_ text: String, comment: String) -> String {
        var lines = text.components(separatedBy: "\n").filter { !$0.hasPrefix(comment) }
        while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// git's `core.commentChar=auto` choice (builtin/commit.c `adjust_comment_line_char`), as
    /// measured on git 2.54 (A2 Task 3, 22 messages — `ContinueTests.autoChoosesTheCharacterGitChooses`):
    /// `#` when the text holds no `#` at all; otherwise the first of `#;@!$%^&|:` that is neither
    /// the text's first byte nor the first byte of a line starting before the trailing block of
    /// comment and blank lines git ignores (`ignoredTrailingBytes`).
    static func autoCommentChar(for text: String) -> Character {
        let bytes = Array(text.utf8)
        guard bytes.contains(defaultCommentByte) else { return Character(defaultComment) }
        var candidates = Array("#;@!$%^&|:".utf8)
        func rule(out byte: UInt8) {
            if let index = candidates.firstIndex(of: byte) { candidates[index] = UInt8(ascii: " ") }
        }
        if let first = bytes.first { rule(out: first) }
        let boundary = bytes.count - ignoredTrailingBytes(bytes)
        for index in bytes.indices where bytes[index] == 0x0A || bytes[index] == 0x0D {
            if index + 1 < boundary { rule(out: bytes[index + 1]) }
        }
        // git gives up ("unable to select a comment character") when all ten start lines; the
        // commit then fails, and `#` is as good an answer as any for the prefill.
        guard let chosen = candidates.first(where: { $0 != UInt8(ascii: " ") }) else { return Character(defaultComment) }
        return Character(Unicode.Scalar(chosen))
    }

    /// How many bytes at the end of `bytes` git ignores as the message's trailing comment block
    /// (`ignored_log_message_bytes`, with `#`): a run of `#` lines and empty lines — and an old
    /// style `Conflicts:` block with its tab-indented paths — reaching the end, or everything
    /// from a scissors line. A run that starts on the very first line does not count, as in git.
    static func ignoredTrailingBytes(_ bytes: [UInt8]) -> Int {
        let cutoff = scissorsOffset(in: bytes, comment: defaultComment) ?? bytes.count
        let conflicts = Array("Conflicts:\n".utf8)
        var blockStart = 0
        var lineStart = 0
        var inOldConflictsBlock = false
        while lineStart < cutoff {
            let next = bytes[lineStart..<cutoff].firstIndex(of: 0x0A).map { $0 + 1 } ?? cutoff
            let first = bytes[lineStart]
            if first == defaultCommentByte || first == 0x0A {
                if blockStart == 0 { blockStart = lineStart }
            } else if bytes[lineStart..<cutoff].starts(with: conflicts) {
                inOldConflictsBlock = true
                if blockStart == 0 { blockStart = lineStart }
            } else if inOldConflictsBlock && first == 0x09 {
                // A path of the old conflicts block.
            } else if blockStart != 0 {
                blockStart = 0
                inOldConflictsBlock = false
            }
            lineStart = next
        }
        return blockStart != 0 ? bytes.count - blockStart : bytes.count - cutoff
    }

    /// Where git's scissors line (`<comment> ------------------------ >8 ------------------------`)
    /// begins in `bytes`, if it holds one at the start of a line.
    static func scissorsOffset(in bytes: [UInt8], comment: String) -> Int? {
        let line = Array("\(comment) ------------------------ >8 ------------------------\n".utf8)
        if bytes.starts(with: line) { return 0 }
        let pattern = [UInt8(0x0A)] + line
        guard bytes.count >= pattern.count else { return nil }
        for start in 0...(bytes.count - pattern.count) where bytes[start..<(start + pattern.count)].elementsEqual(pattern) {
            return start + 1
        }
        return nil
    }

    /// Whether git's cleanup of `message` leaves nothing: a rebase continues under `scissors`
    /// (whitespace, and a cut at a scissors line, M 29), a cherry-pick or revert strips comment
    /// lines whatever `commit.cleanup` says (measured, A2 Task 3).
    static func isEmptyAfterCleanup(_ message: String, comment: String, for operation: RepositoryOperation) -> Bool {
        let kept: String
        if operation == .rebase {
            let bytes = Array(message.utf8)
            kept = String(decoding: bytes.prefix(scissorsOffset(in: bytes, comment: comment) ?? bytes.count), as: UTF8.self)
        } else {
            kept = withoutComments(message, comment: comment)
        }
        return kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - The operation's paths (M 31)

    public func operationPaths(at root: URL) async throws -> [String]? {
        guard try await operationInProgress(at: root) != nil,
            try await resolves("AUTO_MERGE", at: root)
        else { return nil }
        let data = try await run(["diff", "--name-only", "-z", "--no-renames", "HEAD", "AUTO_MERGE"], cwd: root)
        var seen = Set<String>()
        return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
            .filter { seen.insert($0).inserted }
    }

    // MARK: - Continue

    public func continueReadiness(at root: URL) async throws -> ContinueReadiness {
        guard let operation = try await operationInProgress(at: root),
            Self.sequencerOperations.contains(operation)
        else { return .notContinuable }
        return try await continueFacts(operation, at: root).readiness
    }

    /// Everything readiness and `continueOperation` decide on, read once.
    private struct ContinueFacts {
        let unresolved: [String]
        /// The stopped commit's own result equals HEAD (M 30).
        let empty: Bool
        let unstaged: [String]
        let otherStaged: [String]

        /// In the order the UI must deal with them: an unresolved path first, then an empty
        /// result, then what git would refuse (unstaged) or silently take in (other staged).
        var readiness: ContinueReadiness {
            if !unresolved.isEmpty { return .unresolved(unresolved) }
            if empty { return .emptyResult }
            if !unstaged.isEmpty { return .unstagedChanges(unstaged) }
            if !otherStaged.isEmpty { return .otherStagedChanges(otherStaged) }
            return .ready
        }
    }

    private func continueFacts(_ operation: RepositoryOperation, at root: URL) async throws -> ContinueFacts {
        let unmerged = try await unmergedPaths(at: root)
        if !unmerged.isEmpty {
            return ContinueFacts(unresolved: unmerged, empty: false, unstaged: [], otherStaged: [])
        }
        // Fix round 1 (I1, measured): every staged path rides into the continued commit, for all
        // three. The operation's own are `operationPaths`; without `AUTO_MERGE` there is no telling
        // them apart, and none is needed — a rebase's `exec` / `break` stop refuses staged changes
        // itself, and at an `edit` stop amending is the point.
        let staged = try await stagedPaths(at: root)
        let own = try await operationPaths(at: root).map(Set.init)
        let empty =
            try await hasPendingCommit(operation, at: root)
            && (own.map { $0.isDisjoint(with: staged) } ?? staged.isEmpty)
        let otherStaged = own.map { own in staged.filter { !own.contains($0) } } ?? []
        // Fix round 1 (I2, measured): a rebase refuses any unstaged change; a range commits the
        // current commit and then refuses the next that would overwrite one, stranding the
        // sequence. A single pick or revert keeps them.
        let unstaged = try await refusesUnstagedChanges(operation, at: root) ? try await unstagedPaths(at: root) : []
        return ContinueFacts(unresolved: [], empty: empty, unstaged: unstaged, otherStaged: otherStaged)
    }

    /// `diff --cached --name-only HEAD`: every path whose index entry differs from HEAD's —
    /// both sides of a staged rename (`--no-renames`), not an intent-to-add entry.
    private func stagedPaths(at root: URL) async throws -> [String] {
        let data = try await run(["diff", "--cached", "--name-only", "-z", "--no-renames", "HEAD"], cwd: root)
        return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
    }

    /// Tracked paths whose worktree differs from the index — not unmerged, not a submodule (git's
    /// own rebase check ignores submodules); an intent-to-add entry counts, as git refuses it.
    private func unstagedPaths(at root: URL) async throws -> [String] {
        try await stashStatus(at: root).files
            .filter { !$0.isUntracked && !$0.isSubmodule && $0.staged != .unmerged && $0.unstaged != nil }
            .map(\.path)
    }

    /// A rebase, and a cherry-pick or revert with a sequence still to come (`sequencer/`).
    private func refusesUnstagedChanges(_ operation: RepositoryOperation, at root: URL) async throws -> Bool {
        operation == .rebase ? true : try await hasSequencer(at: root)
    }

    private func hasSequencer(at root: URL) async throws -> Bool {
        var isDirectory: ObjCBool = false
        let found = FileManager.default.fileExists(
            atPath: try await gitPath("sequencer", at: root).path, isDirectory: &isDirectory)
        return found && isDirectory.boolValue
    }

    /// Whether the stop has a commit still to make, which is what can come out empty. A pick or
    /// revert always has (its pseudo-ref is what makes it one); a rebase at a conflict stop has
    /// `rebase-merge/message`, but not at an `exec` or `break` stop, and at an `edit` stop the
    /// commit is already made (`rebase-merge/amend`) — measured, A2 Task 3.
    private func hasPendingCommit(_ operation: RepositoryOperation, at root: URL) async throws -> Bool {
        guard operation == .rebase else { return true }
        let directory = try await gitPath("rebase-merge", at: root)
        let has = { (name: String) in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        return has("message") && !has("amend")
    }

    public func continueOperation(
        _ expected: RepositoryOperation, message: String?, acknowledgingOtherStaged: [String], at root: URL
    ) async throws -> ContinueOutcome {
        // Asked of the repository, never of the caller's snapshot, as `abort` does.
        let actual = try await operationInProgress(at: root)
        guard actual == expected else { throw OperationError.operationMismatch(expected: expected, found: actual) }
        guard Self.sequencerOperations.contains(expected) else { throw OperationError.notReady(.notContinuable) }
        // Each refusal on its own, not only the first the readiness names: a rebase may go on
        // past an empty result, but never past unstaged changes or unacknowledged staged ones.
        let facts = try await continueFacts(expected, at: root)
        if !facts.unresolved.isEmpty { throw OperationError.notReady(.unresolved(facts.unresolved)) }
        if facts.empty && expected != .rebase { throw OperationError.notReady(.emptyResult) }
        if !facts.unstaged.isEmpty { throw OperationError.notReady(.unstagedChanges(facts.unstaged)) }
        // A list, not a yes: a file staged or unstaged between the click and this read is refused.
        if Set(facts.otherStaged) != Set(acknowledgingOtherStaged) {
            throw OperationError.notReady(.otherStagedChanges(facts.otherStaged))
        }
        try await writeMessage(message, for: expected, at: root)
        let before = try await operationProgress(at: root)

        // One complete literal vector per case. `GIT_EDITOR=true` (every call's) is what lets
        // `rebase --continue` commit without an editor (M 13); `scissors` keeps git's editor
        // template out of the commit under `commit.cleanup=verbatim|whitespace` (M 29).
        let result: ProcessRunner.StreamedResult
        switch expected {
        case .rebase:
            result = try await runWithEnvironment(["rebase", "--continue"], cwd: root, extra: Self.withConfig("commit.cleanup", "scissors", over: ProcessInfo.processInfo.environment), allowedExitCodes: Self.anyExitCode)
        case .cherryPick:
            result = try await runWithEnvironment(["cherry-pick", "--continue"], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
        case .revert:
            result = try await runWithEnvironment(["revert", "--continue"], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
        case .merge, .squash, .applyingPatches:
            throw OperationError.notReady(.notContinuable)
        }
        return try await outcome(of: result, from: before, expected: expected, at: root)
    }

    /// Validates the message and writes it, in place, where git reads it (M 15). With no
    /// pending message file there is nothing to write to, and `message` is not used. `nil` is
    /// git's own message: a rebase's is written back without its comment lines (under
    /// `scissors` git would keep them); a pick's or revert's is left for git to strip.
    private func writeMessage(_ message: String?, for operation: RepositoryOperation, at root: URL) async throws {
        guard let name = Self.messageFile(of: operation, pending: false) else { return }
        let url = try await gitPath(name, at: root)
        guard let existing = Self.contents(of: url, trimmed: false) else { return }
        let text: String
        if let message {
            text = message
        } else if operation == .rebase {
            text = Self.withoutComments(existing, comment: try await commentString(for: existing, at: root))
        } else {
            let comment = try await commentString(for: existing, at: root)
            if Self.isEmptyAfterCleanup(existing, comment: comment, for: operation) { throw OperationError.emptyMessage }
            return
        }
        let comment = try await commentString(for: text, at: root)
        if Self.isEmptyAfterCleanup(text, comment: comment, for: operation) { throw OperationError.emptyMessage }
        // In place (truncate and write), never a replacing rename (M 9).
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// What a continue or skip left, read from the repository (M 14: an exit code alone does not
    /// tell the next stop from a hook's refusal). No operation: `.sequenceHalted` when a pick or
    /// revert left `sequencer/` behind (fix round 1, I2), `.finishedWithConflicts` when paths are
    /// unmerged, `.finished` on exit 0, else `.failed`. An operation: `.stoppedAgain` when its
    /// progress moved, else `.failed` with git's words.
    private func outcome(
        of result: ProcessRunner.StreamedResult, from before: OperationProgress?, expected: RepositoryOperation,
        at root: URL
    ) async throws -> ContinueOutcome {
        guard let after = try await operationProgress(at: root) else {
            if expected != .rebase, try await hasSequencer(at: root) {
                return .sequenceHalted(gitsWords: Self.words(result))
            }
            let unmerged = try await unmergedPaths(at: root)
            if !unmerged.isEmpty { return .finishedWithConflicts(unmerged) }
            return result.exitCode == 0 ? .finished : .failed(gitsWords: Self.words(result))
        }
        return after != before ? .stoppedAgain(after) : .failed(gitsWords: Self.words(result))
    }

    // MARK: - Skip

    public func skipReadiness(at root: URL) async throws -> SkipReadiness {
        guard let operation = try await operationInProgress(at: root),
            Self.sequencerOperations.contains(operation)
        else { return .notSkippable }
        // Ruling 19: a rebase with no commit pending (`exec`, `break`, `edit`) has nothing to
        // skip — at an `edit` stop `rebase --skip` exits 0 and the commit stays (measured).
        if operation == .rebase, !(try await hasPendingCommit(operation, at: root)) { return .notSkippable }
        let status = try await stashStatus(at: root)
        var seen = Set<String>()
        let changed = status.files
            .filter { !$0.isUntracked && ($0.staged != nil || $0.unstaged != nil) }
            .flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
            .filter { seen.insert($0).inserted }
        let theCommits = Set(try await unmergedPaths(at: root)).union(try await operationPaths(at: root) ?? [])
        let others = changed.filter { !theCommits.contains($0) }
        if !others.isEmpty { return .otherChanges(others) }
        // Fix round 1 (I3, measured): all three refuse over an untracked file at a path they
        // reset (a deleted file recreated); a pick or revert also over a path whose worktree
        // differs from its index entry ("Entry 'p' not uptodate", exit 128) — unmerged ones apart.
        let untracked = status.files.filter(\.isUntracked).map(\.path)
        let dirty: Set<String> =
            operation == .rebase
            ? [] : Set(status.files.filter { !$0.isUntracked && $0.staged != .unmerged && $0.unstaged != nil }.map(\.path))
        let unclean = changed.filter { path in
            dirty.contains(path) || untracked.contains { $0 == path || ($0.hasSuffix("/") && path.hasPrefix($0)) }
        }
        return unclean.isEmpty ? .ready(paths: changed) : .needsCleanPaths(unclean)
    }

    public func skip(_ expected: RepositoryOperation, stoppedAt sha: String, at root: URL) async throws -> SkipOutcome {
        let actual = try await operationInProgress(at: root)
        guard actual == expected else { throw OperationError.operationMismatch(expected: expected, found: actual) }
        // Decided before anything is filed: a refused skip files nothing.
        let readiness = try await skipReadiness(at: root)
        if readiness == .notSkippable { throw OperationError.skipRefused(.notSkippable) }
        let before = try await operationProgress(at: root)
        guard let current = before?.current, current.sha == sha else { throw OperationError.stoppedCommitChanged }
        guard case .ready(let paths) = readiness else { throw OperationError.skipRefused(readiness) }

        // The stopped commit's partial work, unmerged paths as their worktree bytes (M 17: every
        // skip discards them, resolved or not).
        var recorded: Stash?
        if !paths.isEmpty {
            let summary = try await commit(sha, at: root).map { "\($0.short) \($0.ref.subject)" } ?? sha
            recorded = try await StashRecord.record(
                paths: paths, message: Self.skippedByGitter + summary, allowingUnmerged: true, backend: self, at: root)
        }

        // One complete literal vector per case: `skipShapes` permits exactly these three.
        let arguments: [String]
        switch expected {
        case .rebase: arguments = ["rebase", "--skip"]
        case .cherryPick: arguments = ["cherry-pick", "--skip"]
        case .revert: arguments = ["revert", "--skip"]
        case .merge, .squash, .applyingPatches: throw OperationError.skipRefused(.notSkippable)
        }
        let result = try await runWithEnvironment(arguments, cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
        return SkipOutcome(
            outcome: try await outcome(of: result, from: before, expected: expected, at: root), recorded: recorded)
    }

    // MARK: - Reads

    /// `rev-parse --git-path name`, as a URL: relative to `root` in an ordinary checkout,
    /// absolute in a linked worktree.
    func gitPath(_ name: String, at root: URL) async throws -> URL {
        let data = try await run(["rev-parse", "--git-path", name], cwd: root)
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }

    /// Whether `name` resolves (`-q --verify` exits 1 and prints nothing when it does not).
    func resolves(_ name: String, at root: URL) async throws -> Bool {
        let data = try await run(["rev-parse", "-q", "--verify", name], cwd: root, allowedExitCodes: [1])
        return !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The commit `rev` names, and its abbreviated id; nil when it does not resolve.
    /// `--no-show-signature`: `log.showSignature=true` would put gpg's lines into the text.
    func commit(_ rev: String, at root: URL) async throws -> (ref: CommitRef, short: String)? {
        let data = try await run(
            ["log", "-1", "--no-show-signature", "--format=%H%x00%h%x00%s", "--end-of-options", rev], cwd: root,
            allowedExitCodes: [128])
        let fields = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
            .split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3, !fields[0].isEmpty else { return nil }
        return (CommitRef(sha: fields[0], subject: fields[2]), fields[1])
    }

    /// A file's text; nil when it does not exist. `trimmed` drops surrounding whitespace, for
    /// the one-value files (`msgnum`, `onto`, `head-name`).
    static func contents(of url: URL, trimmed: Bool = true) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return trimmed ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }
}

extension Optional {
    /// `flatMap` for an async transform.
    fileprivate func asyncFlatMap<U>(_ transform: (Wrapped) async throws -> U?) async rethrows -> U? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
