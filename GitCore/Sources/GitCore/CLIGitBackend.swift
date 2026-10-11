import Foundation

/// A `GitBackend` implementation that shells out to the real `git` CLI and composes the
/// parsers over its output.
public struct CLIGitBackend: GitBackend {
    private let gitPath: String
    private let runner: ProcessRunner
    private let commandLog: any CommandLog

    /// `commandLog` hears of every git call this backend starts, once each, from `run`,
    /// `runStreaming` and `runWithEnvironment`; the default hears nothing.
    public init(gitPath: String = "/usr/bin/git", runner: ProcessRunner = ProcessRunner(),
                commandLog: any CommandLog = NoCommandLog()) {
        self.gitPath = gitPath
        self.runner = runner
        self.commandLog = commandLog
    }

    /// Runs `git --version` at `path` and reports whether it succeeded.
    public static func isGitAvailable(at path: String = "/usr/bin/git") async -> Bool {
        let runner = ProcessRunner()
        do {
            _ = try await runner.run(path, ["--version"], cwd: URL(fileURLWithPath: "/"))
            return true
        } catch {
            return false
        }
    }

    // MARK: - Format strings (must match the parsers' doc comments verbatim)

    // The tracking fields go at the END so that any output recorded from the shorter format
    // still parses: `RefParser` treats every field after the fifth as optional.
    //
    // B1 Task 2 grew it by the three tag fields (13–15) rather than adding a second
    // `for-each-ref refs/tags` read: one process, one parser, one place the list comes from, and
    // the parser already takes trailing fields as optional. What it costs was measured (git
    // 2.54): for a branch the fields are empty or the commit's subject, which `RefParser`
    // ignores, and `%(contents:subject)` is always one line — git joins the first paragraph
    // with spaces, CR LF included — so the line-per-ref split stays sound.
    //
    // B3 Task 2 appended `%(worktreepath)` (16), last for the same reason: the worktree another
    // branch is checked out in (R14). A path can hold a newline, the one field that can, and
    // `RefParser` joins such a record's continuation lines back (see its doc comment).
    private static let refFormat =
        "%(refname)%00%(objectname)%00%(HEAD)%00%(upstream:short)%00%(objecttype)%00%(*objectname)"
        + "%00%(upstream:track)%00%(upstream:remotename)%00%(upstream:remoteref)"
        + "%00%(symref)%00%(push:remotename)%00%(push:remoteref)"
        + "%00%(taggername)%00%(taggerdate:iso-strict)%00%(contents:subject)"
        + "%00%(worktreepath)"
    // Internal, not private: `CLIGitBackend+Remotes.swift`'s `commits(in:notIn:limit:)` reads a
    // second log through the same `LogParser`, and two format strings that must match one
    // parser's doc comment verbatim are one too many.
    static let logFormat = "%H%x00%P%x00%an%x00%ae%x00%aI%x00%s%x00%D"

    // MARK: - GitBackend

    public func snapshot(at root: URL) async throws -> RepoSnapshot {
        async let statusData = run(["status", "--porcelain=v2", "-z", "--branch"], cwd: root)
        async let refData = run(["for-each-ref", "--format=\(Self.refFormat)"], cwd: root)
        // Which remotes exist is configuration, not refs: a remote nothing has been fetched
        // from has no `refs/remotes/<name>/…` at all, and a remote's name may contain a slash.
        async let remoteData = run(["remote", "-v"], cwd: root)
        async let commits = commitLog(at: root)
        // Porcelain v2 says nothing about a merge, cherry-pick, revert or rebase that is
        // part-way through, so that comes from its own commands alongside these.
        async let operation = operationInProgress(at: root)
        async let stashList = stashes(at: root)

        let status = Self.markingNestedRepositories(
            in: StatusParser.parse(try await statusData), under: root
        ).with(operationInProgress: try await operation)
        let refs = Self.withoutBareRepositoryCheckouts(
            RefParser.parse(try await refData)
                .with(remotes: RemoteParser.parse(String(decoding: try await remoteData, as: UTF8.self))))
        let log = try await commits
        let graph = GraphLayout.layout(log)

        return RepoSnapshot(
            root: root, status: status, refs: refs, commits: log, graph: graph,
            stashes: try await stashList)
    }

    /// Porcelain v2 lists a nested repository as an ordinary untracked directory (`? nested/`,
    /// even with `-uall`; M 16), and git never looks inside it — so stashing or trashing it
    /// is a different thing from doing that to a directory of files. One stat per untracked
    /// directory entry tells them apart: a `.git` inside, a directory or a file (a linked
    /// worktree's or a separated git dir's `gitdir:` file).
    static func markingNestedRepositories(
        in status: WorkingCopyStatus, under root: URL
    ) -> WorkingCopyStatus {
        guard status.files.contains(where: { $0.isUntracked && $0.path.hasSuffix("/") }) else {
            return status
        }
        return status.with(
            files: status.files.map { file in
                guard file.isUntracked, file.path.hasSuffix("/") else { return file }
                let dotGit = root.appendingPathComponent(file.path).appendingPathComponent(".git")
                return file.with(
                    isNestedRepository: FileManager.default.fileExists(atPath: dotGit.path))
            })
    }

    public func workingCopyDiff(at root: URL, path: String, staged: Bool) async throws -> [FileDiff] {
        // `--full-index`: the `index` line carries full object ids, which is what a patch
        // built from this diff is checked against before it is applied (see `Patch.oldBlob`).
        //
        // `--no-ext-diff --no-textconv --submodule=short --src-prefix=a/ --dst-prefix=b/`: this
        // is porcelain `diff`, which reads the user's config, and the parser reads git's default
        // output only. Measured on git 2.54 (fix/diff-config-prefix): `diff.mnemonicPrefix`,
        // `diff.noprefix`, `diff.srcPrefix`/`dstPrefix` hid every diff; `diff.external` and
        // `GIT_EXTERNAL_DIFF` failed every read; a textconv driver replaced the file's lines
        // with its own output under the real blob ids; `diff.submodule=log|diff` replaced a
        // gitlink's lines. Explicit prefixes rather than `--default-prefix` (git 2.41+): they
        // override all four keys on every git, `--no-index` included. `ForceFlagScanner`
        // requires the five on every `diff` that prints a patch (`diffFormatPins`).
        if staged {
            let data = try await run(
                ["diff", "--cached", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/", "--full-index", "-U3", "-M", "--", literalPathspec(path)],
                cwd: root)
            return DiffParser.parse(data)
        }

        if try await isTracked(path, at: root) {
            let data = try await run(
                ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/", "--full-index", "-U3", "--", literalPathspec(path)],
                cwd: root)
            return DiffParser.parse(data)
        }

        // Untracked file: diff the whole file against /dev/null. This exits 1 when there is
        // any content (i.e. almost always), which is expected, not a failure.
        //
        // No `:(literal)` here: `--no-index` compares two *files* given by name, not
        // pathspecs, so the prefix would become part of the name git tries to open.
        let data = try await run(
            ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/", "--full-index", "-U3", "--no-index", "--", "/dev/null", path],
            cwd: root, allowedExitCodes: [1]
        )
        return DiffParser.parse(data)
    }

    public func commitFiles(at root: URL, sha: String) async throws -> [FileStatus] {
        let data = try await diffTree(
            at: root, arguments: ["--no-commit-id", "--name-status", "-z", "-r", "-M"], sha: sha
        )
        return parseNameStatus(data)
    }

    public func commitDiff(at root: URL, sha: String, path: String?) async throws -> [FileDiff] {
        let arguments = ["--no-commit-id", "-p", "-U3", "-M", "-r"]
        let trailing = path.map { ["--", literalPathspec($0)] } ?? []
        let data = try await diffTree(at: root, arguments: arguments, sha: sha, trailing: trailing)
        return DiffParser.parse(data)
    }

    // MARK: - Helpers

    /// The most arguments one git process is given (Ruling 26). `Process` raises an Objective-C
    /// exception for more than 4096 — the app crashes, and nothing can catch it (measured on
    /// macOS 27: `NSInvalidArgumentException`, "too many arguments (4097) -- limit is 4096";
    /// 4096 itself launches). The largest vector Gitter builds is a `--cacheinfo` batch's
    /// 2 002; a list of paths goes through a pathspec file or in batches
    /// (`CLIGitBackend+Pathspecs.swift`). `run`, `runStreaming` and `runWithEnvironment` — every
    /// way this type starts git — throw `GitError.tooManyArguments` over it instead of
    /// launching, so no future call can crash the app this way. (Over 1 MiB of arguments,
    /// `E2BIG`, is already a thrown `launchFailed`, measured.)
    static let argumentLimit = 4_000

    private static func checkArgumentCount(_ arguments: [String]) throws {
        guard arguments.count <= argumentLimit else {
            throw GitError.tooManyArguments(count: arguments.count, limit: argumentLimit)
        }
    }

    // Internal (not private) so CLIGitBackend+WorkingCopy.swift can share this helper.
    func run(_ arguments: [String], cwd: URL, allowedExitCodes: Set<Int32> = []) async throws -> Data {
        try await logged(arguments, cwd: cwd, outcome: { _ in .succeeded }, stderr: { _ in "" }) {
            try Self.checkArgumentCount(arguments)
            return try await runner.run(gitPath, arguments, cwd: cwd, allowedExitCodes: allowedExitCodes)
        }
    }

    /// Runs `body`, one of the three seams, and reports it to `commandLog` once, whichever way it
    /// ends. `checkArgumentCount` is inside `body`, so a refusal before launch is reported too.
    private func logged<T>(_ arguments: [String], cwd: URL,
                           outcome: (T) -> CommandLogEntry.Outcome,
                           stderr: (T) -> String,
                           _ body: () async throws -> T) async throws -> T {
        let started = Date()
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let value = try await body()
            commandLog.record(.init(started: started, duration: clock.now - start, directory: cwd,
                                    rawArguments: arguments, outcome: outcome(value), rawStderr: stderr(value)))
            return value
        } catch {
            commandLog.record(.init(started: started, duration: clock.now - start, directory: cwd,
                                    rawArguments: arguments, outcome: Self.outcome(of: error),
                                    rawStderr: Self.stderr(of: error)))
            throw error
        }
    }

    /// How a thrown error is told to the log. A killed git is checked before the generic
    /// `commandFailed`, which it is a case of.
    private static func outcome(of error: Error) -> CommandLogEntry.Outcome {
        if error is CancellationError { return .cancelled }
        if wasKilledBySignal(error) { return .killed }
        switch error as? GitError {
        case .commandFailed(let code, _)?: return .exitCode(code)
        case .launchFailed(let message)?: return .launchFailed(message)
        case .tooManyArguments?: return .refusedBeforeLaunch(String(describing: error))
        default: return .refusedBeforeLaunch(String(describing: error))
        }
    }

    private static func stderr(of error: Error) -> String {
        guard case GitError.commandFailed(_, let stderr)? = error as? GitError else { return "" }
        return stderr
    }

    /// `run`'s cancellable, streaming twin, for the network operations: the same git and the
    /// same environment, with stderr reported as it arrives and the whole of it returned
    /// (`remote:` lines and a hosting service's pull-request URL live there even on success).
    ///
    /// This lives here rather than in `CLIGitBackend+Remotes.swift` because `gitPath` and
    /// `runner` are private to this file, and they stay private: one file owns how git is
    /// invoked. It is the single seam every remote operation in this milestone goes through.
    ///
    /// **What it adds over `ProcessRunner.runStreaming` is the trim, and the refusal of a killed
    /// git** (`refusingAKilledGit`, E1 promise 4). git pads each progress line with spaces to
    /// erase the longer one before it (`remote: Counting objects: 100% (12/12)        \r`,
    /// measured), and an empty segment is not an update worth reporting. Both are dealt with here
    /// so that no caller — and no view — has to know that git does it.
    ///
    /// **The trim is not free, and the returned stderr is where the unmodified text lives.**
    /// It takes whitespace off *both* ends, so a `remote:` line the server indented arrives at
    /// `progress` without its indentation — a hook that lays its output out in columns loses
    /// that layout in the progress stream. `StreamedResult.stderr` is untrimmed and holds every
    /// byte git wrote, which is what Task 5's `remoteMessages` and any banner quoting the
    /// server are built from. Nothing that cares about the shape of a line should read it from
    /// a progress segment.
    ///
    /// `progress` is called on the pipe's readability queue, **not** the caller's executor, and
    /// the pipe is not drained while it runs; the work done on that queue is therefore kept to
    /// one `trimmingCharacters` and one `isEmpty`. See `ProcessRunner.runStreaming` for the
    /// full threading contract, and `GitRemoteBackend.fetch` for what a caller may do with it.
    func runStreaming(
        _ arguments: [String], cwd: URL, allowedExitCodes: Set<Int32> = [],
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessRunner.StreamedResult {
        try await logged(arguments, cwd: cwd, outcome: { .exitCode($0.exitCode) }, stderr: { $0.stderr }) {
            try Self.checkArgumentCount(arguments)
            let result = try await runner.runStreaming(
                gitPath, arguments, cwd: cwd, allowedExitCodes: allowedExitCodes,
                onStderr: { segment in
                    let trimmed = segment.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { progress(trimmed) }
                })
            try Self.refusingAKilledGit(result)
            return result
        }
    }

    /// `run` with variables of the caller's own added to the child's environment, for the
    /// one call that needs them: the record's `GIT_INDEX_FILE`, and the `GIT_CONFIG_COUNT`
    /// parameters that turn rerere off for a stash apply (`rerereOff`). A leading `-c` would do
    /// the latter too, and the scanner forbids it, because it hides the subcommand.
    ///
    /// It goes through the streaming runner's internal overload, whose `inheritedEnvironment`
    /// replaces `ProcessInfo.processInfo.environment` as the base; this passes that environment
    /// merged with `extra` (`extra` wins). The runner then sets `GIT_TERMINAL_PROMPT`,
    /// `LC_ALL`, `GIT_OPTIONAL_LOCKS` and `GIT_EDITOR` over it as it does for every call, so
    /// `extra` cannot change those four, and stdin is `/dev/null`. `ProcessRunner.swift`
    /// itself is untouched. The one difference from `run`'s environment is the streaming
    /// runner's `SSH_ASKPASS_REQUIRE=force`, which no local command reads.
    ///
    /// Failures are `run`'s: an exit code that is neither 0 nor in `allowedExitCodes` throws
    /// `GitError.commandFailed` with the trimmed stderr, a launch failure
    /// `GitError.launchFailed`, and more than `argumentLimit` arguments
    /// `GitError.tooManyArguments` before anything is launched. One more than `run`: a git killed
    /// by a signal is `commandFailed` with no exit code (-1), whatever codes are allowed
    /// (`refusingAKilledGit`). On success the result carries stdout, the untrimmed stderr and
    /// the exit code — which matters for an apply, where exit 1 is a conflict to report.
    ///
    /// Here rather than in `CLIGitBackend+Environment.swift` because `gitPath` and `runner`
    /// are private to this file (see `runStreaming`).
    func runWithEnvironment(
        _ arguments: [String], cwd: URL, extra: [String: String],
        allowedExitCodes: Set<Int32> = []
    ) async throws -> ProcessRunner.StreamedResult {
        try await logged(arguments, cwd: cwd, outcome: { .exitCode($0.exitCode) }, stderr: { $0.stderr }) {
            try Self.checkArgumentCount(arguments)
            let environment = ProcessInfo.processInfo.environment.merging(extra) { _, added in added }
            let result = try await runner.runStreaming(
                gitPath, arguments, cwd: cwd, allowedExitCodes: allowedExitCodes, onLaunch: nil,
                inheritedEnvironment: environment, onStderr: { _ in })
            try Self.refusingAKilledGit(result)
            return result
        }
    }

    /// **A killed git is never read as an exit code** (E1 promise 4). For a git a signal killed,
    /// `exitCode` is the signal's number — SIGHUP's is 1, the code of an ordinary refusal — and a
    /// caller that allows that code, above all one that allows every code (`anyExitCode`), would
    /// read it as git's answer. So both seams above refuse it before any caller sees the status:
    /// `GitError.commandFailed` with no exit code (-1) and `ProcessRunner.killedBySignal`'s
    /// words, git's own redacted after them. A signal that is not an allowed code is the
    /// runner's own refusal, in the same words.
    ///
    /// A caller that treats a git stopped part-way as an outcome it cannot know — its
    /// `CancellationError` branch — takes that branch for a killed git too
    /// (`wasKilledBySignal`): whether the write happened is just as unknown.
    static func refusingAKilledGit(_ result: ProcessRunner.StreamedResult) throws {
        guard result.terminationReason == .uncaughtSignal else { return }
        let words = RemoteFailureParser.gitsOwnWords(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        throw GitError.commandFailed(exitCode: -1, stderr: ProcessRunner.killedBySignal(result.exitCode, words: words))
    }

    /// Whether `error` is the refusal of a killed git (`refusingAKilledGit`, or the runner's own).
    static func wasKilledBySignal(_ error: Error) -> Bool {
        guard case GitError.commandFailed(-1, let stderr) = error else { return false }
        return stderr.hasPrefix(ProcessRunner.killedBySignalPrefix)
    }

    /// Turns a path into a pathspec that means exactly that one path.
    ///
    /// Everything git takes after `--` is a *pathspec*, not a file name: it is glob-matched,
    /// so a file really named `a*.txt` also selects `a b.txt`, `notes[1].txt` also selects
    /// `notes1.txt`, and a leading `:` is read as pathspec magic (`:colon.txt` is rejected
    /// outright). Every path here comes from git's own status or from a row the user clicked,
    /// so it is always a literal name and never a pattern the user typed. `:(literal)` is
    /// git's own way of saying so.
    ///
    /// Not for `git apply`'s patch file or for `diff --no-index`: those arguments are
    /// filenames, not pathspecs, and the prefix would be taken as part of the name.
    ///
    /// Internal (not private) for the same reason as `run`: `CLIGitBackend+WorkingCopy.swift`
    /// is the other half of this type and needs it too.
    func literalPathspec(_ path: String) -> String {
        ":(literal)" + path
    }

    /// History: every branch, tag and remote-tracking ref (and HEAD), **not the stash**.
    /// `refs/stash` is a ref under `refs/`, so a plain `--all` walks the newest entry's W and I
    /// commits (and U, a parentless root, for an entry with untracked files) and History drew
    /// them as rows to check out. `--exclude` applies to the `--all` after it, so its place in
    /// the argv is before it (measured on git 2.54: after it, it excludes nothing). HEAD stays:
    /// `--all` adds it whatever the exclusion says.
    private func commitLog(at root: URL) async throws -> [Commit] {
        do {
            let data = try await run(
                [
                    "log", "--exclude=refs/stash", "--all", "--topo-order", "-n", "500", "-z",
                    "--format=\(Self.logFormat)",
                ],
                cwd: root
            )
            return LogParser.parse(data)
        } catch let GitError.commandFailed(_, stderr) where stderr.contains("does not have any commits") {
            return []
        }
    }

    /// Whether `path` is tracked in the index (as opposed to untracked/new).
    ///
    /// `ls-files --error-unmatch` exits 1 specifically when the path isn't in the index;
    /// any other failure (e.g. `root` isn't a git repository at all) must propagate rather
    /// than being silently treated as "untracked".
    private func isTracked(_ path: String, at root: URL) async throws -> Bool {
        do {
            _ = try await run(["ls-files", "--error-unmatch", "--", literalPathspec(path)], cwd: root)
            return true
        } catch GitError.commandFailed(exitCode: 1, stderr: _) {
            return false
        }
    }

    /// Runs `diff-tree` for a commit, falling back to `--root` when the commit has no parent
    /// (so `<sha>^` doesn't resolve).
    private func diffTree(
        at root: URL, arguments: [String], sha: String, trailing: [String] = []
    ) async throws -> Data {
        do {
            return try await run(["diff-tree"] + arguments + ["\(sha)^", sha] + trailing, cwd: root)
        } catch let GitError.commandFailed(_, stderr)
            where stderr.contains("unknown revision") || stderr.contains("bad revision") {
            return try await run(["diff-tree"] + arguments + ["--root", sha] + trailing, cwd: root)
        }
    }

    /// Runs `diff-tree` between two explicit commits, `base` to `tip` — a comparison's changes
    /// (`CLIGitBackend+Compare.swift`), from its merge base to B's id.
    ///
    /// Two **full object ids**, refused otherwise before git runs
    /// (`BranchOperationError.invalidName`): given a 3-dot range, `diff-tree` prints nothing
    /// and exits 0 (R6), which would read as "B brings nothing"; given a name, it reads
    /// whatever the name holds *now*, not the id the comparison was read from (R12).
    /// `--end-of-options` follows the caller's options, which must all come before it (R10).
    func diffTree(
        at root: URL, arguments: [String], from base: String, to tip: String, trailing: [String] = []
    ) async throws -> Data {
        for id in [base, tip] where !Self.isFullObjectID(id) {
            throw BranchOperationError.invalidName(id)
        }
        return try await run(["diff-tree"] + arguments + ["--end-of-options", base, tip] + trailing, cwd: root)
    }

    /// Parses `diff-tree -z --name-status` output: a flat NUL-separated token stream, one
    /// record per file — `X\0path\0` for ordinary entries, `R<score>\0old\0new\0` for
    /// renames/copies. `-z` avoids git quoting non-ASCII paths as octal escapes (which it
    /// does under `LC_ALL=C` without `-z`), keeping paths byte-identical to what
    /// `StatusParser` (which also uses `-z`) produces.
    ///
    /// Internal (not private): a comparison's files (`CLIGitBackend+Compare.swift`) are the same
    /// `diff-tree` output.
    func parseNameStatus(_ data: Data) -> [FileStatus] {
        let text = String(decoding: data, as: UTF8.self)
        let fields = text.split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)

        var files: [FileStatus] = []
        var index = 0
        while index < fields.count {
            let statusField = fields[index]
            index += 1
            guard let kindChar = statusField.first else { continue }
            let staged = ChangeKind.from(porcelain: kindChar)

            if kindChar == "R" || kindChar == "C" {
                guard index + 1 < fields.count else { break }
                let originalPath = fields[index]
                let path = fields[index + 1]
                index += 2
                files.append(FileStatus(path: path, originalPath: originalPath, staged: staged, unstaged: nil))
            } else {
                guard index < fields.count else { break }
                let path = fields[index]
                index += 1
                files.append(FileStatus(path: path, originalPath: nil, staged: staged, unstaged: nil))
            }
        }

        files.sort { $0.path < $1.path }
        return files
    }
}
