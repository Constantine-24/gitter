import Foundation
import Testing

@testable import GitCore

/// History is every ref's commits **except the stash's own**. `refs/stash` is a ref under
/// `refs/` like any other, so a plain `git log --all` walks the newest entry's W and I commits —
/// and U, a parentless root, for an entry with untracked files — and History drew them as rows,
/// with Check Out and New Branch from Here in their menu. From the working-copy milestone every
/// discard files a record at `stash@{0}`, so they would top History after each one.
@Suite struct HistoryStashTests {
    private let backend = CLIGitBackend()

    @Test func historyHoldsEveryBranchTagAndRemoteCommitButNoneOfAStashEntrysOwn() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        let root = try await repo.headSha()

        try await repo.git(["switch", "-q", "-c", "side"])
        try repo.write("a.txt", "side\n")
        try await repo.commitAll("only on a branch")
        let onBranch = try await repo.headSha()

        try await repo.git(["switch", "-q", "--detach", "main"])
        try repo.write("t.txt", "tag\n")
        try await repo.commitAll("only under a tag")
        let underTag = try await repo.headSha()
        try await repo.git(["tag", "v1"])

        try await repo.git(["switch", "-q", "--detach", "main"])
        try repo.write("r.txt", "remote\n")
        try await repo.commitAll("only on a remote-tracking ref")
        let onRemote = try await repo.headSha()
        try await repo.git(["update-ref", "refs/remotes/origin/topic", onRemote])

        try await repo.git(["switch", "-q", "main"])
        try repo.write("a.txt", "dirty\n")
        try repo.write("new.txt", "untracked\n")
        try await repo.git(["stash", "push", "-q", "-u", "-m", "parked"])
        let w = try await repo.revParse("refs/stash")
        let i = try await repo.revParse("refs/stash^2")
        let u = try await repo.revParse("refs/stash^3")

        // Baseline: the fixture has what the fix is about. W, I and U are three distinct
        // commits, and a plain `--all` walk does reach all three.
        #expect(Set([w, i, u]).count == 3)
        let plainAll = Set(
            String(decoding: try await repo.git(["log", "--all", "--format=%H"]), as: UTF8.self)
                .split(separator: "\n").map(String.init))
        #expect(plainAll.isSuperset(of: [w, i, u]))

        let snapshot = try await backend.snapshot(at: repo.root)
        let history = Set(snapshot.commits.map(\.sha))

        #expect(history.isSuperset(of: [root, onBranch, underTag, onRemote]))
        #expect(history.isDisjoint(with: [w, i, u]))
        #expect(history.count == 4)
        #expect(snapshot.graph.count == snapshot.commits.count)
        // Still in the stash list: the entry is left out of History, not lost.
        #expect(snapshot.stashes.map(\.sha) == [w])
    }
}
