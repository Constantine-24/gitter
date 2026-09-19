import Foundation
import Testing

@testable import GitCore

/// Reads every regular file under `repo.root` except anything inside `.git`, keyed by path
/// relative to the root. Used to prove index operations never touch the worktree.
///
/// Uses the string-path enumerator (`enumerator(atPath:)`), which yields paths already
/// relative to the root, rather than the URL-based enumerator: the latter's URLs are resolved
/// through symlinks (e.g. `/var` → `/private/var` for the system temp directory on macOS),
/// which would never match `repo.root.path` and silently made every snapshot empty.
func worktreeSnapshot(_ repo: TestRepo) -> [String: Data] {
    var result: [String: Data] = [:]
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(atPath: repo.root.path) else { return result }

    for case let relativePath as String in enumerator {
        if relativePath == ".git" {
            enumerator.skipDescendants()
            continue
        }
        if relativePath.hasPrefix(".git/") { continue }
        let url = repo.root.appendingPathComponent(relativePath)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue
        else { continue }
        if let data = try? Data(contentsOf: url) {
            result[relativePath] = data
        }
    }
    return result
}

/// Asserts the worktree still holds exactly the bytes `before` recorded.
///
/// Also fails when `before` is empty: an empty baseline compares equal to any worktree the
/// snapshot cannot read, which is how a symlink bug once made every such assertion vacuous.
/// Callers that genuinely have an empty worktree should assert that directly instead.
func assertWorktreeUnchanged(
    _ repo: TestRepo, since before: [String: Data],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        !before.isEmpty,
        "worktree baseline is empty, so comparing against it would prove nothing",
        sourceLocation: sourceLocation
    )
    let after = worktreeSnapshot(repo)
    #expect(after == before, "the worktree changed", sourceLocation: sourceLocation)
    for (path, bytes) in before where after[path] != bytes {
        let was = String(decoding: bytes, as: UTF8.self).debugDescription
        let now = after[path].map { String(decoding: $0, as: UTF8.self).debugDescription } ?? "<missing>"
        Issue.record("worktree file \(path) changed: \(was) → \(now)", sourceLocation: sourceLocation)
    }
}

/// Proves `assertWorktreeUnchanged` can actually fail; without these the helper could be
/// silently vacuous and every worktree-safety assertion in the suite would mean nothing.
@Suite struct WorktreeAssertionsTests {
    @Test func failsWhenAFileChangesBetweenSnapshotAndAssertion() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        let before = worktreeSnapshot(repo)
        #expect(before["a.txt"] == Data("one\n".utf8))

        try repo.write("a.txt", "two\n")

        withKnownIssue("the worktree really did change") {
            assertWorktreeUnchanged(repo, since: before)
        }
    }

    @Test func failsOnAnEmptyBaseline() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")

        withKnownIssue("an empty baseline proves nothing") {
            assertWorktreeUnchanged(repo, since: [:])
        }
    }
}
