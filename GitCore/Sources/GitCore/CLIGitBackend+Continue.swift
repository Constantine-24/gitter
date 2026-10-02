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

    /// Ruling 22 (A2 Task 4, fix round 1): the union of three reads, because `AUTO_MERGE` alone
    /// can be stale while an operation is in progress — only ort writes it, so `merge -s
    /// resolve`, an octopus merge and `--strategy=resolve` picks and reverts stop over whatever
    /// a clean cherry-pick, a clean finished rebase or a clean `stash apply` left (measured).
    ///
    /// 1. `diff --name-only -z --no-renames HEAD AUTO_MERGE`: ort's result, which alone has the
    ///    paths a rename carried a change to. Left out only when provably stale
    ///    (`autoMergeState`, Ruling 23): a text conflict exists and it differs from HEAD at none
    ///    of them — a fresh one differs at every text conflict (its markers; under rerere too)
    ///    and equals HEAD at a whole-file one (measured). With no text conflict to test it by
    ///    (all whole-file, or nothing unmerged) it is kept.
    /// 2. The paths the operation's source commits change (`sourcePaths`; a squash's from
    ///    `SQUASH_MSG`, a merge commit's against its mainline), exact for a non-ort stop, which
    ///    follows no rename.
    /// 3. The unmerged paths.
    ///
    /// When the source is unknown — a squash whose `SQUASH_MSG` lists no commit, a rebase stop
    /// with no commit pending (`exec`, `break`, `edit`), an `am` patch that does not parse, or
    /// any source read that fails (a missing commit, a hand-edited `MERGE_HEAD`) — the paths
    /// are (1) ∪ (3) when a text conflict proves `AUTO_MERGE` fresh, else nil (every staged
    /// path counts as the operation's). A source read never makes this throw. A superset only
    /// over-refuses a staged-side discard. Accepted costs: Skip may count a user's change to a
    /// path the commit also changes as the commit's (Skip records first), and Continue's
    /// other-staged check misses such a path — and, where a stale `AUTO_MERGE` cannot be
    /// proved stale (a non-ort stop with no text conflict), a user's path it lists.
    public func operationPaths(at root: URL) async throws -> [String]? {
        guard let operation = try await operationInProgress(at: root) else { return nil }
        let unmergedRecords = Self.indexRecords(try await run(["ls-files", "-u", "-z"], cwd: root))
        let unmerged = unmergedRecords.map(\.path)
        let autoMerge: [String]?
        if case .usable(let diff) = try await autoMergeState(unmerged: unmergedRecords, at: root) {
            autoMerge = diff
        } else {
            autoMerge = nil
        }

        // A source read that fails (a hand-edited `SQUASH_MSG` or `MERGE_HEAD`, commits pruned
        // while the operation waits) leaves the source unknown, exactly like one with nothing
        // to read: it never makes this throw (fix round 4).
        let source: [String]?
        do {
            source = try await sourcePaths(of: operation, autoMerge: autoMerge, at: root)
        } catch {
            source = nil
        }
        let parts: [[String]]
        if let source {
            parts = [autoMerge ?? [], source, unmerged]
        } else if let paths = autoMerge,
            try await autoMergeIsProvedFresh(paths, unmerged: unmergedRecords, at: root)
        {
            // The source unknown: a text conflict it differs at shows `AUTO_MERGE` fresh, ort's
            // own result for this stop, renames included.
            parts = [paths, unmerged]
        } else {
            return nil
        }
        var seen = Set<String>()
        return parts.joined().filter { seen.insert($0).inserted }
    }

    /// Every path the commit or commits the operation applies change, both sides of a rename;
    /// nil when there is none to read (see `operationPaths`). `autoMerge`: the usable
    /// `AUTO_MERGE` diff, if any, which picks a merge commit's mainline when nothing records it.
    ///
    /// - merge: for each line of `MERGE_HEAD` (an octopus has several), its changes since each
    ///   merge base with HEAD (`--all`: a criss-cross's virtual base changes nothing the bases
    ///   all agree on).
    /// - squash (Ruling 25): the same for its tips — `merge-base --independent` of the
    ///   commits `SQUASH_MSG` lists (`commit <sha>` lines; every commit of `HEAD..tip`, merges
    ///   included, measured), in batches (`independentTips`). Nil when it lists none (the
    ///   message was edited).
    /// - cherry-pick, revert, rebase: `CHERRY_PICK_HEAD` / `REVERT_HEAD` / `REBASE_HEAD`
    ///   against its parent (`commitPaths`; a root commit against nothing).
    /// - `git am`: the current patch, `rebase-apply/patch`, read by `DiffParser` — only with no
    ///   `apply-opt` (`-p`, `--directory` would move its paths) and only when every `diff --git`
    ///   header parsed.
    private func sourcePaths(
        of operation: RepositoryOperation, autoMerge: [String]?, at root: URL
    ) async throws -> [String]? {
        switch operation {
        case .merge:
            guard let text = try? String(contentsOf: try await gitPath("MERGE_HEAD", at: root), encoding: .utf8)
            else { return nil }
            return try await changesSinceMergeBases(of: text.split(whereSeparator: \.isNewline).map(String.init), at: root)
        case .squash:
            guard let text = try? String(contentsOf: try await gitPath("SQUASH_MSG", at: root), encoding: .utf8)
            else { return nil }
            let listed = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                guard line.hasPrefix("commit ") else { return nil }
                let name = String(line.dropFirst("commit ".count))
                return Self.isObjectName(name) ? name : nil
            }
            guard !listed.isEmpty, let tips = try await independentTips(of: listed, at: root) else { return nil }
            return try await changesSinceMergeBases(of: tips, at: root)
        case .cherryPick:
            return try await commitPaths("CHERRY_PICK_HEAD", mainline: try await sequencerMainline(at: root), autoMerge: autoMerge, at: root)
        case .revert:
            return try await commitPaths("REVERT_HEAD", mainline: try await sequencerMainline(at: root), autoMerge: autoMerge, at: root)
        case .rebase:
            guard try await hasPendingCommit(.rebase, at: root) else { return nil }
            return try await commitPaths("REBASE_HEAD", mainline: nil, autoMerge: autoMerge, at: root)
        case .applyingPatches: return try await currentPatchPaths(at: root)
        }
    }

    /// `merge-base --independent` of `commits`, folded over batches of `independentBatch`: the
    /// tips of a batch plus the tips so far have the same tips as both together, so the
    /// argument list never grows with the squash. A squash's message lists every commit (one
    /// per ≈41 bytes), and `Process` refuses more than 4096 arguments by raising an Objective-C
    /// exception, not an error — a crash (measured, `NSInvalidArgumentException` "too many
    /// arguments (30002) -- limit is 4096"); past that, macOS's 1 MiB `ARG_MAX` (E2BIG between
    /// 20 000 and 24 000 names, measured). Nil when the tips themselves reach a batch (no real
    /// squash has that many; the caller then falls back to the conservative rule).
    private func independentTips(of commits: [String], at root: URL) async throws -> [String]? {
        var tips: [String] = []
        for start in stride(from: 0, to: commits.count, by: Self.independentBatch) {
            let batch = commits[start..<min(start + Self.independentBatch, commits.count)]
            tips = GitLines.split(try await run(["merge-base", "--independent"] + tips + batch, cwd: root))
            guard tips.count < Self.independentBatch else { return nil }
        }
        return tips
    }

    /// Commits per `merge-base --independent`: `stageAllBatch`'s 1000, so a call carries at
    /// most 2001 arguments (≈82 KB), under both limits above.
    static let independentBatch = 1_000

    /// Each head's changes since each of its merge bases with HEAD; nil for a head that is not
    /// a full object name or that shares no base with HEAD.
    private func changesSinceMergeBases(of heads: [String], at root: URL) async throws -> [String]? {
        guard !heads.isEmpty, heads.allSatisfy(Self.isObjectName) else { return nil }
        var paths: [String] = []
        for head in heads {
            let bases = GitLines.split(try await run(["merge-base", "--all", "HEAD", head], cwd: root, allowedExitCodes: [1]))
            guard !bases.isEmpty, bases.allSatisfy(Self.isObjectName) else { return nil }
            for base in bases { paths += try await namesChanged(from: base, to: head, at: root) }
        }
        return paths
    }

    /// `diff --name-only -z --no-renames from to`.
    private func namesChanged(from: String, to: String, at root: URL) async throws -> [String] {
        Self.nulSeparated(try await run(["diff", "--name-only", "-z", "--no-renames", from, to], cwd: root))
    }

    /// `pseudoRef`'s changes against its parent, or nil when it does not resolve. A root commit
    /// against nothing. A merge commit (`-m`, Ruling 25) against its mainline: `mainline` when
    /// recorded (`sequencer/opts`, a range); else the parent whose changes cover `autoMerge` —
    /// the fewest, when several do — since against the other parent it lists everything the
    /// mainline did since the fork (measured); else, with no `AUTO_MERGE` to tell or none
    /// covering it, every parent (safe for a discard; Continue's other-staged check may then
    /// miss a mainline path).
    private func commitPaths(
        _ pseudoRef: String, mainline: Int?, autoMerge: [String]?, at root: URL
    ) async throws -> [String]? {
        guard try await resolves(pseudoRef, at: root) else { return nil }
        let parents = GitLines.split(try await run(["rev-parse", "\(pseudoRef)^@"], cwd: root))
        guard parents.count > 1 else {
            return Self.nulSeparated(try await run(
                ["diff-tree", "-r", "--root", "--name-only", "-z", "--no-renames", "--no-commit-id", pseudoRef], cwd: root))
        }
        guard parents.allSatisfy(Self.isObjectName) else { return nil }
        if let mainline, parents.indices.contains(mainline - 1) {
            return try await namesChanged(from: parents[mainline - 1], to: pseudoRef, at: root)
        }
        var perParent: [[String]] = []
        for parent in parents { perParent.append(try await namesChanged(from: parent, to: pseudoRef, at: root)) }
        if let autoMerge, !autoMerge.isEmpty {
            let wanted = Set(autoMerge)
            if let covering = perParent.filter({ Set($0).isSuperset(of: wanted) }).min(by: { $0.count < $1.count }) {
                return covering
            }
        }
        return perParent.flatMap { $0 }
    }

    /// `mainline = <n>` in `sequencer/opts`, which a pick or revert range with `-m` records (a
    /// single one records none, measured); nil without it.
    private func sequencerMainline(at root: URL) async throws -> Int? {
        guard let text = try? String(contentsOf: try await gitPath("sequencer/opts", at: root), encoding: .utf8)
        else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "mainline", let n = Int(parts[1]) { return n }
        }
        return nil
    }

    /// The paths of the patch `git am` stopped on (`rebase-apply/patch`), old and new names.
    private func currentPatchPaths(at root: URL) async throws -> [String]? {
        let directory = try await gitPath("rebase-apply", at: root)
        let options = (try? String(contentsOf: directory.appendingPathComponent("apply-opt"), encoding: .utf8)) ?? ""
        guard options.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let data = FileManager.default.contents(atPath: directory.appendingPathComponent("patch").path)
        else { return nil }
        let files = DiffParser.parse(data)
        let headers = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("diff --git ") }
        guard !files.isEmpty, files.count == headers.count else { return nil }
        return files.flatMap { [$0.oldPath, $0.newPath].compactMap { $0 } }
    }

    /// `-z` output: one name per NUL-terminated record.
    static func nulSeparated(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
    }

    /// A full object name, as git writes one into `MERGE_HEAD` (SHA-1 or SHA-256).
    private static func isObjectName(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64) && text.allSatisfy(\.isHexDigit)
    }

    // MARK: - Continue

    public func continueReadiness(at root: URL) async throws -> ContinueReadiness {
        guard let operation = try await operationInProgress(at: root),
            Self.sequencerOperations.contains(operation)
        else { return .notContinuable }
        if let stale = try await staleSequence(at: root) { return .staleSequence(stale) }
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
        // three. The operation's own are `operationPaths`; when that is nil there is no telling
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
        // Ruling 29: `--continue` would resume an older range's list.
        if let stale = try await staleSequence(at: root) { throw OperationError.staleSequence(stale) }
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
        if let stale = try await staleSequence(at: root) { return .staleSequence(stale) }
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
        if case .staleSequence(let stale) = readiness { throw OperationError.staleSequence(stale) }
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

    // MARK: - A halted sequence

    public func haltedSequence(at root: URL) async throws -> HaltedSequence? {
        // The common answer costs one process: no todo, no halt. Only a todo is worth the
        // operation check (a range stopped at a conflict keeps a todo too, and is an operation).
        guard let todo = Self.contents(of: try await gitPath("sequencer/todo", at: root), trimmed: false) else {
            return nil
        }
        let entries = Self.todoEntries(todo)
        guard let first = entries.first, try await operationInProgress(at: root) == nil else { return nil }
        // Ruling 30: a range stop the user concluded with `git commit` leaves the same state, its
        // commit first in the todo. Then the rest is waiting for `--continue`, not halted.
        if let committed = try await committedFirst(first, at: root) {
            let rest = Array(entries.dropFirst())
            guard !rest.isEmpty else { return nil }
            let waiting = try await sequence(rest, at: root)
            return HaltedSequence(
                operation: first.revert ? .revert : .cherryPick, notApplied: waiting.notApplied, total: waiting.total,
                committed: committed)
        }
        return try await sequence(entries, at: root)
    }

    /// The todo's first commit, when HEAD is it, committed since git stopped (measured, Ruling
    /// 30): HEAD's parent is `sequencer/abort-safety` — a git-made halt leaves that file at HEAD
    /// itself — and HEAD is that commit's pick (the same author, email and date: a pick keeps
    /// them) or its revert (git's "This reverts commit <sha>." line). The stale way-out's commit
    /// also sits on `abort-safety` but is another commit's pick, so it is not this.
    private func committedFirst(_ first: (revert: Bool, name: String, subject: String), at root: URL) async throws
        -> CommitRef?
    {
        guard let safety = Self.contents(of: try await gitPath("sequencer/abort-safety", at: root)),
            let head = try await commit("HEAD", at: root)?.ref, head.sha != safety,
            try await commit("HEAD^", at: root)?.ref.sha == safety,
            let listed = try await commit(first.name, at: root)?.ref,
            let made = try await authorship("HEAD", at: root)
        else { return nil }
        if first.revert {
            return made.message.contains("This reverts commit \(listed.sha).") ? listed : nil
        }
        guard let original = try await authorship(listed.sha, at: root), made.ident == original.ident else { return nil }
        // Identity alone can coincide (one author, the same second, in a scripted history): HEAD
        // also changes nothing but paths that commit changes (its own resolution of them). A
        // root or merge commit is not judged: nil, a halt — the conservative reading.
        guard let parent = try await commit("\(listed.sha)^", at: root)?.ref.sha,
            try await commit("\(listed.sha)^2", at: root) == nil
        else { return nil }
        let changed = Set(try await namesChanged(from: safety, to: head.sha, at: root))
        let ownPaths = Set(try await namesChanged(from: parent, to: listed.sha, at: root))
        return !changed.isEmpty && changed.isSubset(of: ownPaths) ? listed : nil
    }

    /// `rev`'s author name, email and date (seconds), and its whole message.
    private func authorship(_ rev: String, at root: URL) async throws -> (ident: [String], message: String)? {
        let data = try await run(["log", "-1", "--no-show-signature", "--format=%an%x00%ae%x00%at%x00%B", "--end-of-options", rev], cwd: root, allowedExitCodes: [128])
        let fields = String(decoding: data, as: UTF8.self).split(separator: "\0", maxSplits: 3, omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count == 4 else { return nil }
        return (Array(fields.prefix(3)), fields[3])
    }

    public func staleSequence(at root: URL) async throws -> HaltedSequence? {
        guard let todo = Self.contents(of: try await gitPath("sequencer/todo", at: root), trimmed: false) else {
            return nil
        }
        let entries = Self.todoEntries(todo)
        guard let first = entries.first, let operation = try await operationInProgress(at: root),
            operation == .cherryPick || operation == .revert
        else { return nil }
        // Measured (Ruling 29): at every genuine range stop the todo's first line is the commit
        // the pseudo-ref names, with the same command. Anything else is an older range's list —
        // also a first line that no longer resolves: nothing proves it is this stop's.
        let pseudo = operation == .cherryPick ? "CHERRY_PICK_HEAD" : "REVERT_HEAD"
        let stopped = try await commit(pseudo, at: root)?.ref.sha
        let listedFirst = try await commit(first.name, at: root)?.ref.sha
        if first.revert == (operation == .revert), let stopped, stopped == listedFirst { return nil }
        return try await sequence(entries, at: root)
    }

    /// The todo's commits as a `HaltedSequence`: the first `listed` named, every one counted.
    private func sequence(_ entries: [(revert: Bool, name: String, subject: String)], at root: URL) async throws
        -> HaltedSequence
    {
        var listed: [CommitRef] = []
        for entry in entries.prefix(HaltedSequence.listed) {
            listed.append(try await commit(entry.name, at: root)?.ref ?? CommitRef(sha: entry.name, subject: entry.subject))
        }
        return HaltedSequence(
            operation: entries.first?.revert == true ? .revert : .cherryPick, notApplied: listed, total: entries.count)
    }

    /// The `pick <name> <subject>` / `revert <name> <subject>` lines of `sequencer/todo`, in
    /// order; comments, blank lines and anything else git would not write there are skipped.
    static func todoEntries(_ text: String) -> [(revert: Bool, name: String, subject: String)] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0] == "pick" || parts[0] == "revert" else { return nil }
            return (parts[0] == "revert", String(parts[1]), parts.count > 2 ? String(parts[2]) : "")
        }
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
