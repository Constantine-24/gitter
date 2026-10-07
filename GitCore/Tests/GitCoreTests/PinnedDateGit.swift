import Foundation
import Testing

@testable import GitCore

/// Writes a bash script into `dir` that stands in for `/usr/bin/git` with both of git's dates
/// pinned: it exports `GIT_AUTHOR_DATE` and `GIT_COMMITTER_DATE` as `date`, then execs the real
/// git. Returns its path, for `CLIGitBackend(gitPath:)`.
///
/// What it is for: git stamps a commit with the second it is made in, so two commits of the
/// same tree, parents and message are the same commit only if they are made within one second.
/// A test that needs that has to own the clock rather than race it — under a full parallel
/// `swift test` push, apply and push took 1.6–58.5 s, against 0.16 s alone (E1 survey S16).
/// Only the dates git reads change; the rest is the real git, as `GitLaunchLog`'s wrapper is.
///
/// `date` is any date git accepts (`2026-01-01T00:00:00Z`); it may not contain a `'`.
func pinnedDateGitPath(at date: String, in dir: URL) throws -> String {
    precondition(!date.contains("'"), "a date with a quote would break the wrapper's quoting")
    let wrapper = dir.appendingPathComponent("git-pinned-\(UUID().uuidString)")
    let script = """
        #!/bin/bash
        export GIT_AUTHOR_DATE='\(date)' GIT_COMMITTER_DATE='\(date)'
        exec /usr/bin/git "$@"

        """
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    return wrapper.path
}

/// The controls for `pinnedDateGitPath`: git run through it stamps the pinned second, and run
/// without it does not.
@Suite struct PinnedDateGitTests {
    /// `git var GIT_<who>_IDENT` through `gitPath`: `Tester <t@example.com> <epoch> <zone>`.
    private func ident(_ who: String, gitPath: String, in repo: TestRepo) async throws -> String {
        let data = try await isolatedRunner().run(gitPath, ["var", "GIT_\(who)_IDENT"], cwd: repo.root)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func bothDatesArePinnedToTheGivenSecond() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let gitPath = try pinnedDateGitPath(at: "2026-01-01T00:00:00Z", in: repo.root.appendingPathComponent(".git"))

        // 2026-01-01T00:00:00Z is 1767225600 seconds after the epoch.
        #expect(try await ident("AUTHOR", gitPath: gitPath, in: repo).hasSuffix(" 1767225600 +0000"))
        #expect(try await ident("COMMITTER", gitPath: gitPath, in: repo).hasSuffix(" 1767225600 +0000"))
    }

    /// Non-vacuous: the real git, and a wrapper pinned one second later, each stamp something
    /// else — so the suffix above is the wrapper's doing, and the date passed is the one used.
    @Test func withoutTheWrapperOrWithAnotherDateTheStampDiffers() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let later = try pinnedDateGitPath(at: "2026-01-01T00:00:01Z", in: repo.root.appendingPathComponent(".git"))

        #expect(!(try await ident("COMMITTER", gitPath: "/usr/bin/git", in: repo)).hasSuffix(" 1767225600 +0000"))
        #expect(try await ident("COMMITTER", gitPath: later, in: repo).hasSuffix(" 1767225601 +0000"))
    }

    /// The wrapper is git otherwise: a commit made through it is an ordinary commit, and two
    /// made seconds apart of the same tree, parent and message are one and the same.
    @Test func aCommitThroughTheWrapperIsTheSameCommitWhateverTheClock() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("f", "f\n")
        try await repo.commitAll("root")
        let gitPath = try pinnedDateGitPath(at: "2026-01-01T00:00:00Z", in: repo.root.appendingPathComponent(".git"))
        let tree = try await repo.git(["rev-parse", "HEAD^{tree}"])
        let treeID = String(decoding: tree, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        func commitTree() async throws -> String {
            let data = try await isolatedRunner().run(
                gitPath, ["commit-tree", treeID, "-p", "HEAD", "-m", "same"], cwd: repo.root)
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let first = try await commitTree()
        try await Task.sleep(for: .milliseconds(1_100))
        let second = try await commitTree()
        #expect(first == second)
        #expect(first.count == 40)
    }
}
