import Foundation
import Testing

@testable import GitCore

/// The sidebar's Recent input (N1 Task 1): the HEAD reflog's checkout lines and each local
/// branch's tip date.
@Suite struct BranchActivityTests {
    private let backend = CLIGitBackend()

    // MARK: - The parser

    @Test func parserKeepsOnlyCheckoutTargetsNewestFirst() {
        let text = """
            rebase (finish): returning to refs/heads/main
            rebase (start): checkout feature/a
            checkout: moving from 7b4bd77 to main
            checkout: moving from fix/b to HEAD~0
            checkout: moving from feature/a to fix/b
            checkout: moving from main to feature/a
            commit: a
            """
        #expect(ReflogSwitchParser.targets(text) == ["main", "HEAD~0", "fix/b", "feature/a"])
    }

    @Test func parserDropsDuplicatesFurtherDown() {
        let text = """
            checkout: moving from b to a
            checkout: moving from a to b
            checkout: moving from b to a
            """
        #expect(ReflogSwitchParser.targets(text) == ["a", "b"])
    }

    @Test func parserTakesTheTextAfterTheLastTo() {
        #expect(ReflogSwitchParser.targets("checkout: moving from to to into") == ["into"])
    }

    /// With `log.showSignature` an old git could print gpg lines among the subjects; the parser
    /// keeps only the checkout lines, whatever sits between them.
    @Test func parserIgnoresSignatureLines() {
        let plain = "checkout: moving from a to b\ncheckout: moving from main to a\n"
        let noisy = """
            gpg: Signature made Mon Nov 16 10:00:00 2026 UTC
            gpg: Good signature from "Tester <t@t>"
            checkout: moving from a to b
            gpg: Signature made Mon Nov 16 09:00:00 2026 UTC
            gpg: Good signature from "Tester <t@t>"
            checkout: moving from main to a

            """
        #expect(ReflogSwitchParser.targets(noisy) == ReflogSwitchParser.targets(plain))
        #expect(ReflogSwitchParser.targets(plain) == ["b", "a"])
    }

    // MARK: - The backend

    @Test func switchesAreReadNewestFirst() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.commit("a.txt", "one", "root")
        try await repo.git(["switch", "-q", "-c", "feature/a"])
        try await repo.git(["switch", "-q", "-c", "fix/b"])
        try await repo.git(["switch", "-q", "main"])
        try await repo.git(["switch", "-q", "feature/a"])

        let activity = try await backend.branchActivity(at: repo.root)

        #expect(Array(activity.switchTargets.prefix(3)) == ["feature/a", "main", "fix/b"])
    }

    @Test func tipDatesCoverEveryLocalBranch() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.commit("a.txt", "one", "root", date: "2026-01-01T00:00:00Z")
        try await repo.git(["switch", "-q", "-c", "later"])
        try await repo.commit("b.txt", "two", "later", date: "2026-03-01T00:00:00Z")

        let activity = try await backend.branchActivity(at: repo.root)

        #expect(activity.tipDates == [
            "main": Date(timeIntervalSince1970: 1767225600),
            "later": Date(timeIntervalSince1970: 1772323200),
        ])
    }

    @Test func aFileNamedHEADDoesNotBreakTheRead() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "feature"])
        try repo.write("HEAD", "not a ref\n")

        let activity = try await backend.branchActivity(at: repo.root)

        #expect(activity.switchTargets.first == "feature")
    }

    /// An unborn HEAD (no commit yet) reads as no switches; see `GitBackend.branchActivity`.
    @Test func anEmptyRepositoryHasNoSwitches() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }

        let activity = try await backend.branchActivity(at: repo.root)

        #expect(activity == .none)
    }

    /// `switch --orphan` leaves HEAD unborn on a new name while the other branches keep their
    /// commits: no switches are read, and every existing branch's tip date still is.
    @Test func anOrphanHEADKeepsTheTipDates() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.commit("a.txt", "one", "root")
        try await repo.git(["branch", "x"])
        try await repo.git(["switch", "-q", "x"])
        try await repo.git(["switch", "-q", "--orphan", "o"])

        let activity = try await backend.branchActivity(at: repo.root)

        #expect(activity.switchTargets == [])
        #expect(Set(activity.tipDates.keys) == ["main", "x"])
    }

    /// Positive control: a reflog failure that is not the unborn one still throws, with git's
    /// own words. A detached HEAD naming an object that does not exist (measured, git 2.54): the
    /// reflog read exits 128 with `fatal: bad object HEAD`, while the tip-date read of
    /// `refs/heads` still exits 0 — so the throw is the reflog clause's, reached through git.
    @Test func anyOtherFailureThrows() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.commit("a.txt", "one", "root")
        try repo.write(".git/HEAD", String(repeating: "1", count: 40) + "\n")

        do {
            _ = try await backend.branchActivity(at: repo.root)
            Issue.record("expected a throw, but activity came back")
        } catch GitError.commandFailed(let exitCode, let stderr) {
            #expect(exitCode == 128)
            #expect(stderr.contains("bad object"), "\(stderr)")
        } catch {
            Issue.record("expected GitError.commandFailed, got \(error)")
        }
    }

    @Test func aLinkedWorktreeReadsItsOwnSwitches() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        _ = try await fixture.addOnNewBranch("wt", "w")
        let linked = fixture.repo(at: "wt")
        try await linked.git(["switch", "-q", "-c", "w2"])

        let inLinked = try await backend.branchActivity(at: linked.root)
        let inMain = try await backend.branchActivity(at: fixture.repo.root)

        #expect(inLinked.switchTargets.first == "w2")
        #expect(!inMain.switchTargets.contains("w2"))
    }
}
