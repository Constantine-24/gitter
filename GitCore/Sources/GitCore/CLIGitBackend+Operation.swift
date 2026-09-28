import Foundation

/// Detecting a merge, cherry-pick, revert, rebase, `git am` or pending squash that is part-way
/// through.
///
/// `git status --porcelain=v2` does not report any of them, so this is asked separately and
/// folded into `WorkingCopyStatus` by `snapshot(at:)`.
///
/// Everything here goes through git rather than through `<root>/.git/…`: in a linked worktree
/// `.git` is a *file* pointing at `<main>/.git/worktrees/<name>`, which is where that
/// worktree's own `MERGE_HEAD` and `rebase-merge/` live. Looking under `<root>/.git` directly
/// would miss a merge in a linked worktree and, from the other side, report the main
/// checkout's merge as if it were this one's.
extension CLIGitBackend {

    /// Which operation the worktree at `root` is in the middle of, if any.
    ///
    /// Four commands, run concurrently with each other and with the rest of the snapshot.
    /// That is three more processes per refresh than a single `--git-path` call listing every
    /// marker would cost, and it buys two things: `rev-parse --verify` proves the pseudo-ref
    /// actually *resolves*, where a stat would accept a truncated or half-written leftover,
    /// and it keeps working under ref backends that do not store refs as loose files. Each
    /// call is a few milliseconds, and the common answer — "none" — needs all of them anyway.
    /// `SQUASH_MSG` has no pseudo-ref to verify that way, so it rides along in the one
    /// `--git-path` call instead — see `gitPaths`.
    func operationInProgress(at root: URL) async throws -> RepositoryOperation? {
        async let paths = gitPaths(at: root)
        async let merge = hasPseudoRef("MERGE_HEAD", at: root)
        async let cherryPick = hasPseudoRef("CHERRY_PICK_HEAD", at: root)
        async let revert = hasPseudoRef("REVERT_HEAD", at: root)

        // `git am` before the rebase it shares `rebase-apply/` with, and the rebase before
        // everything else. A rebase is the outer operation: `rebase -r` re-creating a merge
        // commit sets `MERGE_HEAD` while `rebase-merge/` is still there (there is a test for
        // exactly that), and reporting such a state as a plain merge would tell the user to
        // run `git merge --abort`, which is not the way out of a rebase.
        let resolved = try await paths
        switch resolved.rebase {
        case .applyingPatches: return .applyingPatches
        case .rebase: return .rebase
        case .none: break
        }
        if try await merge { return .merge }
        if try await cherryPick { return .cherryPick }
        if try await revert { return .revert }
        // Checked last, after every real operation: see `RepositoryOperation.squash`'s doc
        // comment for why a leftover `SQUASH_MSG` must never shadow one of those.
        if resolved.hasSquashMsg { return .squash }
        return nil
    }

    /// Whether `name` (`MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`) currently resolves.
    ///
    /// `-q --verify` exits 1 and prints nothing when it does not exist — expected here, not a
    /// failure — and prints the object id when it does.
    private func hasPseudoRef(_ name: String, at root: URL) async throws -> Bool {
        let data = try await run(["rev-parse", "-q", "--verify", name], cwd: root, allowedExitCodes: [1])
        return !String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the sequencer directories — and a pending squash's message file — say, in one
    /// `rev-parse` call.
    ///
    /// Neither a rebase nor `git am` has a pseudo-ref; both keep a directory. `rebase-merge/`
    /// belongs to the merge backend (and `rebase -i`), `rebase-apply/` to the older `am`
    /// backend — and to `git am` itself, which is why the directory alone cannot tell them
    /// apart. Git's own `wt-status` discriminates on the file `rebase-apply/applying`, and so
    /// does this: `git rebase --apply` leaves that file out, `git am` writes it. `SQUASH_MSG`
    /// has nothing to discriminate — a pending squash is a pending squash — so it is just a
    /// stat, folded into the same call because it costs nothing extra to ask for.
    private func gitPaths(at root: URL) async throws -> (rebase: RebaseState, hasSquashMsg: Bool) {
        let data = try await run(
            [
                "rev-parse", "--git-path", "rebase-apply/applying", "--git-path", "rebase-merge",
                "--git-path", "rebase-apply", "--git-path", "SQUASH_MSG",
            ], cwd: root)
        // One path per line, cut at the `\n` byte only: a linked worktree's answers are
        // absolute and hold the main checkout's directory name, which may contain a character
        // `isNewline` would cut at (see `GitLines`).
        let paths = GitLines.split(data)
        guard paths.count == 4 else { return (.none, false) }
        let rebase: RebaseState
        if exists(paths[0], relativeTo: root, directory: false) {
            rebase = .applyingPatches
        } else if exists(paths[1], relativeTo: root, directory: true)
            || exists(paths[2], relativeTo: root, directory: true) {
            rebase = .rebase
        } else {
            rebase = .none
        }
        return (rebase, exists(paths[3], relativeTo: root, directory: false))
    }

    private enum RebaseState {
        case none, rebase, applyingPatches
    }

    /// `--git-path` answers relative to the current directory (`.git/rebase-merge`) for an
    /// ordinary checkout and absolutely for a linked worktree, so both forms are handled.
    private func exists(_ path: String, relativeTo root: URL, directory: Bool) -> Bool {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        let found = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return found && isDirectory.boolValue == directory
    }
}
