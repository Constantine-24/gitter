import Foundation

/// Detecting a merge, cherry-pick, revert or rebase that is part-way through.
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
    /// The four checks run concurrently: each is a sub-10 ms `rev-parse`, but they happen on
    /// every refresh, and the common answer is "none", which needs all four.
    func operationInProgress(at root: URL) async throws -> RepositoryOperation? {
        async let rebase = hasRebaseDirectory(at: root)
        async let merge = hasPseudoRef("MERGE_HEAD", at: root)
        async let cherryPick = hasPseudoRef("CHERRY_PICK_HEAD", at: root)
        async let revert = hasPseudoRef("REVERT_HEAD", at: root)

        // Rebase first: it is the outer operation, and it replays commits through the same
        // sequencer as `cherry-pick`, so a pseudo-ref left behind mid-replay must not be
        // reported as a cherry-pick the user never started. (A conflicted `rebase` and
        // `rebase -i` were both checked on git 2.54 and leave none of the three set; this is
        // about not depending on that.)
        if try await rebase { return .rebase }
        if try await merge { return .merge }
        if try await cherryPick { return .cherryPick }
        if try await revert { return .revert }
        return nil
    }

    /// Whether `name` (`MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`) currently resolves.
    ///
    /// `-q --verify` exits 1 and prints nothing when it does not exist — expected here, not a
    /// failure — and prints the object id when it does. Asking the ref machinery rather than
    /// stat-ing a file also keeps this correct under ref backends other than the loose-file one.
    private func hasPseudoRef(_ name: String, at root: URL) async throws -> Bool {
        let data = try await run(["rev-parse", "-q", "--verify", name], cwd: root, allowedExitCodes: [1])
        return !String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether a rebase is under way. Unlike the other three, a rebase has no pseudo-ref: it
    /// keeps a directory — `rebase-merge/` for the merge backend (and `rebase -i`),
    /// `rebase-apply/` for the older `am` one — so git is asked where that would be and the
    /// answer is stat-ed.
    private func hasRebaseDirectory(at root: URL) async throws -> Bool {
        let data = try await run(
            ["rev-parse", "--git-path", "rebase-merge", "--git-path", "rebase-apply"], cwd: root)
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        return lines.contains { isDirectory(String($0), relativeTo: root) }
    }

    /// `--git-path` answers relative to the current directory (`.git/rebase-merge`) for an
    /// ordinary checkout and absolutely for a linked worktree, so both forms are handled.
    private func isDirectory(_ path: String, relativeTo root: URL) -> Bool {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
