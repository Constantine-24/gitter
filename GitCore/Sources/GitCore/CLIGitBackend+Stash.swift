import Foundation

/// Reading the stash. See `GitStashBackend` for what each method promises.
///
/// Every vector here is one complete array literal beginning with its subcommand, spelled as
/// `ForceFlagScannerTests.allowsTheWorkingCopyOperationsThisMilestoneNeeds` pins it: the
/// scanner permits `stash` only in whole shapes.
extension CLIGitBackend: GitStashBackend {
    public func stashes(at root: URL) async throws -> [Stash] {
        let data = try await run(
            ["stash", "list", "-z", "--format=%H%x1f%gd%x1f%gs%x1f%ct%x1f%P"], cwd: root)
        return StashListParser.parse(data)
    }

    /// `diff-tree` with two tree-ish arguments prints no commit-id line, and with explicit
    /// `--no-color --no-ext-diff -U3` it ignores `diff.noprefix`, `diff.srcPrefix`,
    /// `color.ui`, `diff.external` and `diff.context` (M A.6).
    public func stashDiff(_ stash: Stash, at root: URL) async throws -> [FileDiff] {
        let sha = stash.sha
        let tracked = try await run(
            ["diff-tree", "-p", "--no-color", "--no-ext-diff", "-U3", "-M", "\(sha)^1", sha],
            cwd: root)
        var diffs = DiffParser.parse(tracked)
        if stash.hasUntrackedPart {
            // The third parent against git's empty tree: every untracked file as an addition.
            let untracked = try await run(
                ["diff-tree", "-p", "--no-color", "--no-ext-diff", "-U3", "4b825dc642cb6eb9a060e54bf8d69288fbee4904", "\(sha)^3"],
                cwd: root)
            diffs += DiffParser.parse(untracked)
        }
        return diffs
    }
}
