import Foundation

/// File-level stage/unstage operations. See `GitWorkingCopyBackend` for the command each
/// method runs.
extension CLIGitBackend: GitWorkingCopyBackend {
    public func stage(paths: [String], at root: URL) async throws {
        guard !paths.isEmpty else { return }
        _ = try await run(["add", "--"] + paths.map(literalPathspec), cwd: root)
    }

    public func unstage(paths: [String], at root: URL) async throws {
        guard !paths.isEmpty else { return }
        if try await hasCommits(at: root) {
            // `--no-recurse-submodules` changes nothing here (`--staged` never touches the
            // worktree; measured with `submodule.recurse=true`: the submodule's checkout and
            // an untracked file inside it were kept), and the scanner requires it of every
            // `restore` vector, because on `--worktree` it is what keeps a submodule's work.
            _ = try await run(
                ["restore", "--no-recurse-submodules", "--staged", "--"] + paths.map(literalPathspec),
                cwd: root)
        } else {
            // `--ignore-unmatch`: without commits, a caller may pass a mix of paths that are
            // and aren't in the index (e.g. after another change already removed one). Without
            // this flag `git rm` fails outright on the first unmatched path and leaves every
            // path — matched or not — still staged. `unstageAll`'s `rm --cached -r -- .` fallback
            // doesn't need it: `.` either matches something or the empty-index case is handled
            // separately below.
            _ = try await run(
                ["rm", "--cached", "-q", "--ignore-unmatch", "--"] + paths.map(literalPathspec),
                cwd: root)
        }
    }

    public func stageAll(at root: URL) async throws {
        _ = try await run(["add", "-A"], cwd: root)
    }

    public func unstageAll(at root: URL) async throws {
        if try await hasCommits(at: root) {
            _ = try await run(["reset", "-q"], cwd: root)
            return
        }

        do {
            // The `.` is a real pathspec — "everything below the repository root" — not a file
            // name, so it deliberately stays unprefixed: `:(literal).` would mean a file
            // called `.` instead.
            _ = try await run(["rm", "--cached", "-r", "-q", "--", "."], cwd: root)
        } catch let GitError.commandFailed(_, stderr) where stderr.contains("did not match any files") {
            // Nothing is staged yet in a repository with no commits: there is nothing to
            // unstage, so treat this the same as `git reset -q` on an empty index — a no-op.
        }
    }

    public func applyToIndex(patch: Patch, reverse: Bool, at root: URL) async throws {
        // First, that the index (and HEAD, for a reverse patch) is still exactly what the diff
        // was built from: git itself would put a hunk with context wherever that context
        // matches, and staged `X` into the wrong block of a file (see `Patch.oldBlob`).
        try await requireSource(of: patch, reverse: reverse, at: root)

        // Outside the repository on purpose: a patch file inside the worktree would itself
        // show up as an untracked change while it exists.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-patch-\(UUID().uuidString).diff")
        defer { try? FileManager.default.removeItem(at: file) }
        try patch.text.write(to: file, atomically: true, encoding: .utf8)

        // Never with `--unidiff-zero`, even for a hunk with no context line (the only kind
        // `patch.hasContextFreeHunk` marks). Without it git anchors such a hunk to the start
        // and end of the file, so it applies only to an index that is exactly its preimage;
        // with it, an index that changed after the diff was loaded took the hunk at an offset
        // and gained lines the user never selected (measured in A1 Task 3, Step 5, and pinned
        // by `PartialStagingStaleTests`). Refused, the caller shows "the file changed".
        var arguments = ["apply", "--cached", "--whitespace=nowarn"]
        if reverse { arguments.append("--reverse") }
        // No `--` before the file: it is the patch `git apply` reads, not a pathspec, and
        // `--` would make git treat the rest as paths to restrict the patch to.
        arguments.append(file.path)
        _ = try await run(arguments, cwd: root)
    }

    /// Throws `commandFailed` — worded like git's own "patch does not apply", which the app
    /// turns into "The file changed since this diff was loaded…" — unless the side of the
    /// repository `patch` is applied to is exactly the one its diff was loaded from.
    ///
    /// - Forward (staging, the diff was index → worktree): the path's stage-0 index entry holds
    ///   `patch.oldBlob`, read with `ls-files -s`. An unmerged path (stages 1–3 only), a path
    ///   with no entry and an intent-to-add entry (git shows its old side as zeros, the index
    ///   holds the empty blob) are all refused.
    /// - Reverse (unstaging, the diff was HEAD → index): `diff --cached --raw` for the path shows
    ///   exactly `patch.oldBlob → patch.newBlob`. That is HEAD and the index at once, and it
    ///   works on an unborn HEAD. HEAD counts too: after a terminal commit of the staged lines,
    ///   the index still matches but reverse-applying would stage their DELETION from HEAD.
    ///   A new file's absent HEAD side is all zeros on both lines. Renames are not detected
    ///   (`--no-renames`), just as they cannot be in a diff limited to one path.
    ///
    /// Blob ids that are missing or abbreviated prove nothing and are refused; the working-copy
    /// diff always asks for full ones (`--full-index`). Mode is not compared: a partial patch
    /// is a plain modification and changes content only, whatever the modes. What is left is
    /// the moment between this read and `git apply`, which no git option closes.
    private func requireSource(of patch: Patch, reverse: Bool, at root: URL) async throws {
        func refuse(_ why: String) -> GitError {
            let side = reverse ? "index or HEAD" : "index"
            return .commandFailed(
                exitCode: -1,
                stderr: "error: \(patch.path): patch does not apply\n"
                    + "the \(side) no longer holds what the diff was loaded from: \(why)\n")
        }
        guard let old = patch.oldBlob, let new = patch.newBlob,
            Self.isFullObjectID(old), Self.isFullObjectID(new)
        else {
            throw refuse("the diff named no full blob id to check against")
        }

        let pathspec = literalPathspec(patch.path)
        if reverse {
            let data = try await run(
                ["diff", "--cached", "--raw", "-z", "--no-abbrev", "--no-renames", "--no-color", "--", pathspec],
                cwd: root)
            let found = Self.rawDiffRecords(data)
            guard found.count == 1, found[0].path == Array(patch.path.utf8) else {
                throw refuse("\(found.count) staged changes where the diff showed one")
            }
            guard found[0].old == old, found[0].new == new else {
                throw refuse("\(found[0].old)..\(found[0].new), the diff showed \(old)..\(new)")
            }
        } else {
            let data = try await run(["ls-files", "-s", "-z", "--", pathspec], cwd: root)
            let entries = Self.indexEntries(data)
            guard entries.count == 1, entries[0].path == Array(patch.path.utf8),
                entries[0].stage == "0"
            else {
                throw refuse("\(entries.count) index entries where the diff had one at stage 0")
            }
            guard entries[0].blob == old else {
                throw refuse("\(entries[0].blob), the diff showed \(old)")
            }
        }
    }

    /// 40 (SHA-1) or 64 (SHA-256) lowercase hex digits; zeros included, as git's name for a
    /// side that does not exist.
    static func isFullObjectID(_ id: String) -> Bool {
        (id.utf8.count == 40 || id.utf8.count == 64)
            && id.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
    }

    /// `ls-files -s -z`: `<mode> SP <object> SP <stage> TAB <path> NUL` per entry. The path is
    /// kept as bytes, so it compares exactly.
    static func indexEntries(_ data: Data) -> [(blob: String, stage: String, path: [UInt8])] {
        [UInt8](data).split(separator: 0, omittingEmptySubsequences: true).compactMap { record in
            guard let tab = record.firstIndex(of: UInt8(ascii: "\t")) else { return nil }
            let fields = record[..<tab].split(separator: UInt8(ascii: " "))
            guard fields.count == 3 else { return nil }
            return (
                String(decoding: fields[1], as: UTF8.self), String(decoding: fields[2], as: UTF8.self),
                Array(record[record.index(after: tab)...])
            )
        }
    }

    /// `diff --raw -z --no-renames`: `:<mode> SP <mode> SP <old> SP <new> SP <status> NUL <path>
    /// NUL` per change.
    static func rawDiffRecords(_ data: Data) -> [(old: String, new: String, path: [UInt8])] {
        let fields = [UInt8](data).split(separator: 0, omittingEmptySubsequences: false)
        var records: [(old: String, new: String, path: [UInt8])] = []
        var index = 0
        while index + 1 < fields.count, fields[index].first == UInt8(ascii: ":") {
            let meta = fields[index].split(separator: UInt8(ascii: " "))
            if meta.count == 5 {
                records.append((
                    String(decoding: meta[2], as: UTF8.self), String(decoding: meta[3], as: UTF8.self),
                    Array(fields[index + 1])
                ))
            }
            index += 2
        }
        return records
    }

    public func commit(message: String, amend: Bool, allTracked: Bool, at root: URL) async throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitError.emptyCommitMessage
        }

        // Amending while an operation is in progress rewrites the commit that operation is
        // standing on, and git only refuses two of the six (see the protocol's table). The
        // other four leave the previous tip on no ref at all — the one thing this milestone
        // promises never to happen without a confirmation naming it. Asked of git here, at the
        // moment of the write, rather than taken from a caller's snapshot: a terminal can start
        // a merge between a refresh and this call, and a guard fed stale state is not a guard.
        // If the question cannot be answered the error propagates and nothing is committed.
        if amend, let operation = try await operationInProgress(at: root) {
            throw GitError.amendDuringOperation(operation)
        }

        // Outside the repository on purpose, same as `applyToIndex`'s patch file: a message
        // file inside the worktree would itself show up as an untracked change while it exists.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-commit-message-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try message.write(to: file, atomically: true, encoding: .utf8)

        var arguments = ["commit", "-q"]
        if allTracked { arguments.append("-a") }
        if amend { arguments.append("--amend") }
        arguments += ["-F", file.path]
        _ = try await run(arguments, cwd: root)

        let sha = try await run(["rev-parse", "HEAD"], cwd: root)
        return String(decoding: sha, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func headMessage(at root: URL) async throws -> String {
        guard try await hasCommits(at: root) else { return "" }
        let data = try await run(["log", "-1", "--format=%B"], cwd: root)
        return trimmingTrailingWhitespaceAndNewlines(String(decoding: data, as: UTF8.self))
    }

    /// Trims only trailing whitespace and newline characters, leaving the rest of `string`
    /// (including any leading whitespace) untouched.
    private func trimmingTrailingWhitespaceAndNewlines(_ string: String) -> String {
        var result = Substring(string)
        while let last = result.last, last.isWhitespace {
            result.removeLast()
        }
        return String(result)
    }

    /// Whether `root` has at least one commit reachable from HEAD.
    ///
    /// `rev-parse --verify -q HEAD` exits 1 with empty stdout when there are none; exit 0
    /// with the resolved sha on stdout otherwise.
    private func hasCommits(at root: URL) async throws -> Bool {
        let data = try await run(["rev-parse", "--verify", "-q", "HEAD"], cwd: root, allowedExitCodes: [1])
        return !data.isEmpty
    }
}
