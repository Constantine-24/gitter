import Foundation

/// A `GitBackend` implementation that shells out to the real `git` CLI and composes the
/// parsers over its output.
public struct CLIGitBackend: GitBackend {
    private let gitPath: String
    private let runner: ProcessRunner

    public init(gitPath: String = "/usr/bin/git", runner: ProcessRunner = ProcessRunner()) {
        self.gitPath = gitPath
        self.runner = runner
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
    private static let refFormat =
        "%(refname)%00%(objectname)%00%(HEAD)%00%(upstream:short)%00%(objecttype)%00%(*objectname)"
        + "%00%(upstream:track)%00%(upstream:remotename)%00%(upstream:remoteref)"
        + "%00%(symref)%00%(push:remotename)%00%(push:remoteref)"
    private static let logFormat = "%H%x00%P%x00%an%x00%ae%x00%aI%x00%s%x00%D"

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

        let status = StatusParser.parse(try await statusData)
            .with(operationInProgress: try await operation)
        let refs = RefParser.parse(try await refData)
            .with(remotes: RemoteParser.parse(String(decoding: try await remoteData, as: UTF8.self)))
        let log = try await commits
        let graph = GraphLayout.layout(log)

        return RepoSnapshot(root: root, status: status, refs: refs, commits: log, graph: graph)
    }

    public func workingCopyDiff(at root: URL, path: String, staged: Bool) async throws -> [FileDiff] {
        if staged {
            let data = try await run(
                ["diff", "--cached", "--no-color", "-U3", "-M", "--", literalPathspec(path)], cwd: root)
            return DiffParser.parse(data)
        }

        if try await isTracked(path, at: root) {
            let data = try await run(
                ["diff", "--no-color", "-U3", "--", literalPathspec(path)], cwd: root)
            return DiffParser.parse(data)
        }

        // Untracked file: diff the whole file against /dev/null. This exits 1 when there is
        // any content (i.e. almost always), which is expected, not a failure.
        //
        // No `:(literal)` here: `--no-index` compares two *files* given by name, not
        // pathspecs, so the prefix would become part of the name git tries to open.
        let data = try await run(
            ["diff", "--no-color", "-U3", "--no-index", "--", "/dev/null", path],
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

    // Internal (not private) so CLIGitBackend+WorkingCopy.swift can share this helper.
    func run(_ arguments: [String], cwd: URL, allowedExitCodes: Set<Int32> = []) async throws -> Data {
        try await runner.run(gitPath, arguments, cwd: cwd, allowedExitCodes: allowedExitCodes)
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

    private func commitLog(at root: URL) async throws -> [Commit] {
        do {
            let data = try await run(
                ["log", "--all", "--topo-order", "-n", "500", "-z", "--format=\(Self.logFormat)"],
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

    /// Parses `diff-tree -z --name-status` output: a flat NUL-separated token stream, one
    /// record per file — `X\0path\0` for ordinary entries, `R<score>\0old\0new\0` for
    /// renames/copies. `-z` avoids git quoting non-ASCII paths as octal escapes (which it
    /// does under `LC_ALL=C` without `-z`), keeping paths byte-identical to what
    /// `StatusParser` (which also uses `-z`) produces.
    private func parseNameStatus(_ data: Data) -> [FileStatus] {
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
