import Foundation
import Testing

@testable import GitCore

/// `merge.autoStash=true` — or `branch.<name>.mergeOptions=--autostash`, which is the same
/// thing set per branch — turns git's "your local changes would be overwritten" refusal into a
/// stash, a merge, and a re-apply that can conflict. Measured on git 2.54 in the final review
/// (`frqa/as`), with an uncommitted edit to a file the other side changed: every one of the
/// three vectors **exited 0**, the edit ended up in `stash@{0}: autostash` and the file was
/// left with conflict markers (`UU`, no operation in progress). A squash on a diverged branch
/// is quieter still: exit 0, no stash in the list at all — the edit sits in
/// `.git/MERGE_AUTOSTASH` until the squash is committed — and `a.txt` holds the other side's
/// content. Pull's fast-forward and the merge sheet both reported success.
///
/// Each vector now carries `--no-autostash`, which beats both keys (measured), so git's own
/// refusal comes back and the repository is left exactly as it was.
@Suite struct MergeAutoStashTests {
    enum Key: String, CaseIterable, CustomTestStringConvertible {
        case mergeAutoStash = "merge.autoStash=true"
        case branchMergeOptions = "branch.main.mergeOptions=--autostash"
        var testDescription: String { rawValue }
    }

    @Test(arguments: MergeMode.allCases, Key.allCases)
    func anEditTheMergeWouldOverwriteIsRefusedAndNotStashed(mode: MergeMode, key: Key) async throws {
        for diverged in [false, true] {
            let repo = diverged ? try await TestRepo.makeDiverged() : try await TestRepo.makeBranched()
            defer { repo.cleanUp() }
            let setting = key.rawValue.split(separator: "=", maxSplits: 1).map(String.init)
            try await repo.git(["config", setting[0], setting[1]])
            try repo.write("a.txt", "my local edit\n")
            let state = try await RepoState.capture(repo)
            let worktree = worktreeSnapshot(repo)

            let error = await branchError {
                _ = try await CLIGitBackend().merge("feature", mode: mode, at: repo.root)
            }

            #expect(error == .wouldOverwrite(tracked: ["a.txt"], untracked: []),
                    "diverged: \(diverged)")
            // `refs/stash` is a ref, so `RepoState.refs` would see a stash — and the squash's
            // `MERGE_AUTOSTASH` is not a ref, so it is asked about by name.
            try await assertRepoUnchanged(repo, since: state, worktree: worktree)
            #expect(try await repo.git(["stash", "list"]).isEmpty, "diverged: \(diverged)")
            #expect(try await !repo.gitFileExists("MERGE_AUTOSTASH"), "diverged: \(diverged)")
            #expect(try repo.fileContents("a.txt") == "my local edit\n", "diverged: \(diverged)")
            #expect(try await repo.unmergedEntries().isEmpty, "diverged: \(diverged)")
        }
    }
}
