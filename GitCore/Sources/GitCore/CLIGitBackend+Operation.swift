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
    /// `SQUASH_MSG` has no pseudo-ref to verify that way, so it rides along with the sequencer
    /// directories in `gitPaths`' one `--absolute-git-dir` call instead.
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

    /// What the sequencer directories — and a pending squash's message file — say, from one
    /// `rev-parse --absolute-git-dir` call.
    ///
    /// Neither a rebase nor `git am` has a pseudo-ref; both keep a directory. `rebase-merge/`
    /// belongs to the merge backend (and `rebase -i`), `rebase-apply/` to the older `am`
    /// backend — and to `git am` itself, which is why the directory alone cannot tell them
    /// apart. Git's own `wt-status` discriminates on the file `rebase-apply/applying`, and so
    /// does this: `git rebase --apply` leaves that file out, `git am` writes it. `SQUASH_MSG`
    /// has nothing to discriminate — a pending squash is a pending squash — so it is just a
    /// stat, read from the same answer because it costs nothing extra to ask for.
    ///
    /// **One value, composed, rather than four `--git-path` answers** (E3, measured on git 2.54,
    /// B4.2). The four came back one per line, and a raw newline in the main checkout's path —
    /// which a linked worktree's absolute answers hold — made eight lines of them, so the count
    /// check failed and a rebase in progress read as none. `-z` is not an option there (git
    /// echoes it as an argument), and `--path-format=absolute` only made the main checkout's own
    /// answers break the same way. `--absolute-git-dir` prints one path, so stripping exactly one
    /// trailing `\n` gives it back exactly, and for all four names `<absolute-git-dir>/<name>`
    /// equals `rev-parse --path-format=absolute --git-path <name>`, in a linked worktree and in
    /// the main checkout alike. All four are per-worktree files, so the common directory is not
    /// needed. A worktree's own admin name cannot hold a newline (git sanitises `wt\nree` to
    /// `wt-ree`). **Not measured:** `GIT_DIR` or `GIT_COMMON_DIR` set in Gitter's environment,
    /// where `--git-path` could answer differently from the composition.
    ///
    /// An empty answer — nothing git would print for a repository — is read as no operation, the
    /// fallback the four-line count check had.
    private func gitPaths(at root: URL) async throws -> (rebase: RebaseState, hasSquashMsg: Bool) {
        var data = try await run(["rev-parse", "--absolute-git-dir"], cwd: root)
        if data.last == 0x0A { data.removeLast() }
        guard !data.isEmpty else { return (.none, false) }
        let gitDir = String(decoding: data, as: UTF8.self)
        let rebase: RebaseState
        if exists(gitDir, "rebase-apply/applying", directory: false) {
            rebase = .applyingPatches
        } else if exists(gitDir, "rebase-merge", directory: true)
            || exists(gitDir, "rebase-apply", directory: true) {
            rebase = .rebase
        } else {
            rebase = .none
        }
        return (rebase, exists(gitDir, "SQUASH_MSG", directory: false))
    }

    private enum RebaseState {
        case none, rebase, applyingPatches
    }

    /// Whether `<gitDir>/<name>` is there, as a directory or as a file. `gitDir` is absolute:
    /// `--absolute-git-dir`'s answer.
    private func exists(_ gitDir: String, _ name: String, directory: Bool) -> Bool {
        var isDirectory: ObjCBool = false
        let found = FileManager.default.fileExists(atPath: gitDir + "/" + name, isDirectory: &isDirectory)
        return found && isDirectory.boolValue == directory
    }
}
