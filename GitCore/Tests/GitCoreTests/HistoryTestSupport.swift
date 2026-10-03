import Foundation
import Testing

@testable import GitCore

/// Repository shapes the history suites (`HistoryPlanTests`, `HistoryRunTests`,
/// `RebaseOntoTests`) share.
extension TestRepo {
    /// Writes `file`, stages everything and commits it as `subject`; returns the new commit's
    /// full object id. `date` (any form git reads, e.g. `2024-01-01T00:00:00Z`) is both the
    /// author's and the committer's date — the committer's is what `rev-list` orders by, and
    /// git takes it only from `GIT_COMMITTER_DATE`, so this commit runs with that variable for
    /// this one command.
    @discardableResult
    func commit(_ file: String, _ content: String, _ subject: String, date: String? = nil) async throws -> String {
        try write(file, content + "\n")
        try await git(["add", "-A"])
        if let date {
            _ = try await CLIGitBackend().runWithEnvironment(
                ["commit", "-q", "-m", subject], cwd: root,
                extra: ["GIT_COMMITTER_DATE": date, "GIT_AUTHOR_DATE": date])
        } else {
            try await git(["commit", "-q", "-m", subject])
        }
        return try await headSha()
    }

    /// The subjects of `range`'s commits, oldest first.
    func subjects(_ range: String) async throws -> [String] {
        let data = try await git(["log", "--reverse", "--format=%s", range])
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// The `CommitRef` git has for `rev`.
    func ref(_ rev: String) async throws -> CommitRef {
        CommitRef(sha: try await revParse(rev), subject: try await subject(of: rev))
    }

    /// A failing `gpg.program` (it logs its arguments and exits 1) with `commit.gpgSign=true`:
    /// every commit git makes from now on fails to sign. Never a real gpg, never a key.
    func failSigning() async throws {
        let script = root.appendingPathComponent(".git/fake-gpg.sh")
        try writeExecutable(".git/fake-gpg.sh", "#!/bin/sh\necho \"$@\" >> \"\(root.path)/.git/fake-gpg.log\"\necho fakegpg: refusing >&2\nexit 1\n")
        try await git(["config", "gpg.program", script.path])
        try await git(["config", "commit.gpgSign", "true"])
    }
}

/// The before-and-after a history run is judged by: `RepoState` (HEAD, the index, every ref)
/// and the worktree's bytes.
struct HistorySnapshot {
    let state: RepoState
    let worktree: [String: Data]

    static func capture(_ repo: TestRepo) async throws -> HistorySnapshot {
        HistorySnapshot(state: try await RepoState.capture(repo), worktree: worktreeSnapshot(repo))
    }

    /// Nothing changed: a refusal's promise.
    func assertUnchanged(_ repo: TestRepo, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await assertRepoUnchanged(repo, since: state, worktree: worktree, sourceLocation: sourceLocation)
    }
}
