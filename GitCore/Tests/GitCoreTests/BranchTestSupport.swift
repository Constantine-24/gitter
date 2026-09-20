import Foundation
import Testing

@testable import GitCore

/// Repository shapes and queries the branch-operation suites share.
extension TestRepo {
    /// `main` with `a.txt` = "one", a `feature` branch where `a.txt` = "feature", a `keep.txt`
    /// that is identical on both branches, and a tag `v1` on `main`'s only commit. Checked out
    /// on `main`.
    ///
    /// Two files on purpose: `a.txt` differs between the branches (so a local edit to it
    /// blocks a switch) while `keep.txt` does not (so a local edit to *it* is carried across).
    static func makeBranched() async throws -> TestRepo {
        let repo = try await makeEmpty()
        try repo.write("a.txt", "one\n")
        try repo.write("keep.txt", "keep\n")
        try await repo.commitAll("root")
        try await repo.git(["tag", "v1"])
        try await repo.git(["switch", "-q", "-c", "feature"])
        try repo.write("a.txt", "feature\n")
        try await repo.commitAll("feature change")
        try await repo.git(["switch", "-q", "main"])
        return repo
    }

    /// The branch HEAD is on, or nil when HEAD is detached.
    func currentBranch() async throws -> String? {
        let data = try await git(["symbolic-ref", "-q", "--short", "HEAD"], allowedExitCodes: [1])
        let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    func localBranches() async throws -> [String] {
        let data = try await git(["for-each-ref", "--format=%(refname:short)", "refs/heads"])
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init).sorted()
    }

    /// `git rev-parse --abbrev-ref <branch>@{upstream}`, or nil when the branch has none.
    func upstream(of branch: String) async throws -> String? {
        let data = try await git(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "\(branch)@{upstream}"],
            allowedExitCodes: [128])
        let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    func fileContents(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Adds a remote (a bare repo beside this one) holding `main` and `feat/x`, with no local
    /// `feat/x`. Returns the remote's URL so the caller can clean it up. `named` exists so a
    /// test can use a remote whose own name contains a slash.
    @discardableResult
    func addOriginWithFeatureBranch(named remoteName: String = "origin") async throws -> URL {
        let remote = root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-origin.git", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        let runner = ProcessRunner()
        _ = try await runner.run("/usr/bin/git", ["init", "-q", "--bare", "."], cwd: remote)

        try await git(["remote", "add", remoteName, remote.path])
        try await git(["push", "-q", remoteName, "main"])
        try await git(["push", "-q", remoteName, "refs/heads/feature:refs/heads/feat/x"])
        try await git(["fetch", "-q", remoteName])
        return remote
    }
}

/// Runs `body` and returns the `BranchOperationError` it threw, failing the test when it threw
/// something else or nothing at all.
@discardableResult
func branchError(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> Void
) async -> BranchOperationError? {
    do {
        try await body()
        Issue.record("expected a BranchOperationError, but nothing was thrown",
                     sourceLocation: sourceLocation)
        return nil
    } catch let error as BranchOperationError {
        return error
    } catch {
        Issue.record("expected a BranchOperationError, got \(error)", sourceLocation: sourceLocation)
        return nil
    }
}
