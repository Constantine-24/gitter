import CryptoKit
import Foundation
import Testing

@testable import GitCore

/// Everything a stopped merge, squash, cherry-pick, revert, rebase or `git am` keeps in the git
/// directory — the M 20 fingerprint. A read that must leave the operation alone, or a write
/// that must change only the index, is checked against it before and after.
///
/// md5 of each of `pseudoFiles` that exists, md5 of every file under `rebase-merge/`,
/// `rebase-apply/` and `sequencer/`, and md5 of `ls-files -u -s`, `rev-parse HEAD`,
/// `symbolic-ref -q HEAD` and every ref but `refs/stash`. Paths come from
/// `rev-parse --git-path`, so a linked worktree's own files are the ones read.
struct OperationState: Equatable {
    /// Name (`MERGE_MSG`, `rebase-merge/done`, `ls-files -u -s`, …) → md5 in hex.
    let fingerprint: [String: String]

    static let pseudoFiles = [
        "MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "CHERRY_PICK_HEAD", "REVERT_HEAD", "SQUASH_MSG",
        "AUTO_MERGE", "ORIG_HEAD", "REBASE_HEAD",
    ]
    static let directories = ["rebase-merge", "rebase-apply", "sequencer"]

    static func capture(_ repo: TestRepo) async throws -> OperationState {
        var fingerprint: [String: String] = [:]
        let fm = FileManager.default
        for name in pseudoFiles {
            let url = try await ConflictFixtures.gitPath(repo, name)
            if let data = fm.contents(atPath: url.path) { fingerprint[name] = md5(data) }
        }
        for directory in directories {
            let url = try await ConflictFixtures.gitPath(repo, directory)
            for (relative, data) in files(under: url) {
                fingerprint["\(directory)/\(relative)"] = md5(data)
            }
        }
        fingerprint["ls-files -u -s"] = md5(try await repo.git(["ls-files", "-u", "-s"]))
        fingerprint["HEAD"] = md5(try await repo.git(["rev-parse", "HEAD"], allowedExitCodes: [128]))
        // Which branch HEAD names, as `RepoState` reads it: a switch to another branch at the
        // same commit leaves `rev-parse HEAD` as it was (A2 Task 1's gap).
        fingerprint["symbolic-ref HEAD"] = md5(try await repo.git(["symbolic-ref", "-q", "HEAD"], allowedExitCodes: [1]))
        let refs = try await repo.git(["for-each-ref", "--format=%(objectname) %(refname)"])
        let kept = String(decoding: refs, as: UTF8.self).split(separator: "\n")
            .filter { !$0.hasSuffix(" refs/stash") }.joined(separator: "\n")
        fingerprint["refs"] = md5(Data(kept.utf8))
        return OperationState(fingerprint: fingerprint)
    }

    /// Every regular file under `url` (none when it does not exist), by relative path.
    private static func files(under url: URL) -> [(String, Data)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: url.path) else { return [] }
        var result: [(String, Data)] = []
        for case let relative as String in enumerator {
            var isDirectory: ObjCBool = false
            let file = url.appendingPathComponent(relative)
            guard fm.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                let data = fm.contents(atPath: file.path)
            else { continue }
            result.append((relative, data))
        }
        return result
    }

    private static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Asserts the operation's state is exactly as `before` recorded it, naming each entry that
/// changed, appeared or went.
func assertOperationUnchanged(
    _ repo: TestRepo, since before: OperationState,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let after = try await OperationState.capture(repo)
    for name in Set(before.fingerprint.keys).union(after.fingerprint.keys).sorted()
    where before.fingerprint[name] != after.fingerprint[name] {
        let was = before.fingerprint[name] ?? "<absent>"
        let now = after.fingerprint[name] ?? "<absent>"
        Issue.record("the operation's \(name) changed: \(was) → \(now)", sourceLocation: sourceLocation)
    }
}

/// Proves the fingerprint sees the operation's files; without this every "the operation is
/// intact" assertion could be vacuous.
@Suite struct OperationStateTests {
    @Test func aStoppedMergeHasAFingerprintOfItsOwn() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }

        let state = try await OperationState.capture(repo)

        // A baseline that can fail: the merge's own files were read.
        #expect(state.fingerprint["MERGE_HEAD"] != nil)
        #expect(state.fingerprint["MERGE_MSG"] != nil)
        #expect(state.fingerprint["AUTO_MERGE"] != nil)
    }

    @Test func aStoppedRebaseFingerprintsItsDirectory() async throws {
        let repo = try await ConflictFixtures.rebase(kind: .bothModified)
        defer { repo.cleanUp() }

        let state = try await OperationState.capture(repo)

        #expect(state.fingerprint["REBASE_HEAD"] != nil)
        #expect(state.fingerprint["rebase-merge/done"] != nil)
        #expect(state.fingerprint.keys.filter { $0.hasPrefix("rebase-merge/") }.count > 5)
    }

    @Test func failsWhenTheMergeMessageIsDeleted() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let before = try await OperationState.capture(repo)

        try FileManager.default.removeItem(at: try await ConflictFixtures.gitPath(repo, "MERGE_MSG"))

        await withKnownIssue("MERGE_MSG really is gone") {
            try await assertOperationUnchanged(repo, since: before)
        }
    }

    /// HEAD moved to another branch at the same commit — `rev-parse HEAD` cannot see it, which
    /// branch HEAD names can (A2 Task 1's gap): a write that switched branches during the stop
    /// would otherwise pass every "the operation is intact" assertion.
    @Test func failsWhenHEADNamesAnotherBranchAtTheSameCommit() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        try await repo.git(["branch", "twin", "HEAD"])
        let before = try await OperationState.capture(repo)
        let head = try await repo.headSha()

        try await repo.git(["symbolic-ref", "HEAD", "refs/heads/twin"])
        #expect(try await repo.headSha() == head, "the commit HEAD names did not change")

        await withKnownIssue("HEAD names twin now, not the branch the merge stopped on") {
            try await assertOperationUnchanged(repo, since: before)
        }
    }

    @Test func aStashEntryIsNotPartOfTheOperation() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let before = try await OperationState.capture(repo)

        // What a record filed during the stop moves; a stash entry is not the operation's.
        try await repo.git(["update-ref", "refs/stash", "HEAD"])
        #expect(try await repo.git(["for-each-ref", "refs/stash"]).isEmpty == false)

        try await assertOperationUnchanged(repo, since: before)
    }
}
