import Foundation
import Testing

@testable import GitCore

// MARK: - What a conflict write may change

/// Everything a write to one conflicted path must leave alone: every other index entry, every
/// other worktree entry (type, permission bits, bytes or link target), HEAD, every ref but
/// `refs/stash`, and the operation's files (the M 20 fingerprint without `ls-files -u -s`,
/// which the index entries above already cover path by path).
struct WriteBaseline {
    let path: String
    let otherIndexEntries: [String]
    let otherWorktree: [String: WorktreeEntry]
    let head: String
    let symbolicHead: String
    let refsOtherThanStash: String
    let operation: [String: String]

    static func capture(_ repo: TestRepo, path: String) async throws -> WriteBaseline {
        let state = try await RepoState.capture(repo)
        var worktree = worktreeState(repo)
        worktree[path] = nil
        var operation = try await OperationState.capture(repo).fingerprint
        operation["ls-files -u -s"] = nil
        return WriteBaseline(
            path: path, otherIndexEntries: try await otherEntries(repo, path),
            otherWorktree: worktree, head: state.head, symbolicHead: state.symbolicHead,
            refsOtherThanStash: try await refs(repo), operation: operation)
    }

    /// `ls-files -s -z` records of every path but `path`.
    static func otherEntries(_ repo: TestRepo, _ path: String) async throws -> [String] {
        let data = try await repo.git(["ls-files", "-s", "-z"])
        return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
            .filter { $0.split(separator: "\t", maxSplits: 1).last.map(String.init) != path }
    }

    static func refs(_ repo: TestRepo) async throws -> String {
        let data = try await repo.git(["for-each-ref", "--format=%(objectname) %(refname)"])
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .filter { !$0.hasSuffix(" refs/stash") }.joined(separator: "\n")
    }
}

/// Asserts that nothing but `baseline.path`'s index entries, its worktree entry and
/// `refs/stash` changed. Fails on an empty baseline.
func assertOnlyThePathChanged(
    _ repo: TestRepo, since baseline: WriteBaseline, sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    #expect(!baseline.otherIndexEntries.isEmpty && !baseline.otherWorktree.isEmpty,
            "the baseline is empty, so comparing against it proves nothing", sourceLocation: sourceLocation)
    let now = try await WriteBaseline.capture(repo, path: baseline.path)
    #expect(now.otherIndexEntries == baseline.otherIndexEntries, "another index entry changed",
            sourceLocation: sourceLocation)
    for path in Set(now.otherWorktree.keys).union(baseline.otherWorktree.keys).sorted()
    where now.otherWorktree[path] != baseline.otherWorktree[path] {
        let was = baseline.otherWorktree[path]?.description ?? "<absent>"
        let is_ = now.otherWorktree[path]?.description ?? "<absent>"
        Issue.record("worktree \(path) was \(was), is \(is_)", sourceLocation: sourceLocation)
    }
    #expect(now.head == baseline.head && now.symbolicHead == baseline.symbolicHead, "HEAD moved",
            sourceLocation: sourceLocation)
    #expect(now.refsOtherThanStash == baseline.refsOtherThanStash, "a ref other than refs/stash changed",
            sourceLocation: sourceLocation)
    for name in Set(now.operation.keys).union(baseline.operation.keys).sorted()
    where now.operation[name] != baseline.operation[name] {
        Issue.record("the operation's \(name) changed", sourceLocation: sourceLocation)
    }
}

/// Proves `assertOnlyThePathChanged` can fail on each thing it guards.
@Suite struct WriteBaselineTests {
    @Test func failsWhenAnotherWorktreeFileChanges() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let baseline = try await WriteBaseline.capture(repo, path: "f.txt")

        try repo.write("keep.txt", "keep CHANGED\n")

        await withKnownIssue("keep.txt really changed") {
            try await assertOnlyThePathChanged(repo, since: baseline)
        }
    }

    @Test func failsWhenTheOperationsMessageChanges() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let baseline = try await WriteBaseline.capture(repo, path: "f.txt")
        #expect(baseline.operation["MERGE_MSG"] != nil)

        try Data("other\n".utf8).write(to: try await ConflictFixtures.gitPath(repo, "MERGE_MSG"))

        await withKnownIssue("MERGE_MSG really changed") {
            try await assertOnlyThePathChanged(repo, since: baseline)
        }
    }

    @Test func thePathItselfMayChange() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let baseline = try await WriteBaseline.capture(repo, path: "f.txt")

        try repo.write("f.txt", "resolved\n")
        try await repo.git(["add", "--", "f.txt"])
        try await repo.git(["update-ref", "refs/stash", "HEAD"])

        try await assertOnlyThePathChanged(repo, since: baseline)
    }
}
