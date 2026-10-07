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

    /// `makeBranched()` plus one more commit on `main` touching a *different* file, so `main`
    /// and `feature` have diverged and a merge of the two is clean.
    static func makeDiverged() async throws -> TestRepo {
        let repo = try await makeBranched()
        try repo.write("b.txt", "main side\n")
        try await repo.commitAll("main side")
        return repo
    }

    /// `makeBranched()` plus one more commit on `main` touching **the same file** `feature`
    /// changed, so any merge of the two conflicts in `a.txt`.
    static func makeConflicting() async throws -> TestRepo {
        let repo = try await makeBranched()
        try repo.write("a.txt", "main change\n")
        try await repo.commitAll("main change")
        return repo
    }

    /// `makeBranched()` with `feature` already merged into `main` by a merge commit, so
    /// `feature` is an ancestor of HEAD while HEAD is *not* `feature`'s tip — which is what
    /// keeps "already up to date" distinguishable from "fast-forwarded".
    static func makeAlreadyMerged() async throws -> TestRepo {
        let repo = try await makeBranched()
        try await repo.git(["merge", "--no-ff", "--no-edit", "feature"])
        return repo
    }

    /// Index entries at a merge stage other than 0 — git's own definition of "this worktree
    /// has unresolved conflicts".
    func unmergedEntries() async throws -> String {
        let data = try await git(["ls-files", "-u"])
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether the pseudo-ref or file `name` (`MERGE_HEAD`, `SQUASH_MSG`) is present.
    func gitFileExists(_ name: String) async throws -> Bool {
        let data = try await git(["rev-parse", "--git-path", name])
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The subject line of `rev`'s commit message — what a merge commit is judged by.
    func subject(of rev: String) async throws -> String {
        let data = try await git(["log", "--format=%s", "-1", rev])
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The parent shas of `rev`, in git's order.
    func parents(of rev: String) async throws -> [String] {
        let data = try await git(["rev-list", "--parents", "-n", "1", rev])
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").map(String.init).dropFirst().map { $0 }
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

    /// The upstream `branch` is configured with, read through `for-each-ref`'s
    /// `%(upstream:short)` and `%(upstream:track)` — where `RefParser` reads them — so that a
    /// `[gone]` upstream is `.gone`, never mistaken for no upstream at all.
    ///
    /// It used to ask `rev-parse --abbrev-ref --symbolic-full-name <branch>@{upstream}`, which
    /// exits 128 for both and, for a `[gone]` upstream only, **echoes the argument back**, so
    /// the helper answered `"<branch>@{upstream}"` (measured on git 2.54). A branch that does
    /// not exist, or an answer of any other shape, is now a recorded issue rather than a quiet
    /// `.none`.
    func upstream(
        of branch: String, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> UpstreamState {
        let ref = "refs/heads/\(branch)"
        // `for-each-ref` matches by whole path components, so `refs/heads/feat` would also list
        // `refs/heads/feat/x`: the line is picked by its exact refname.
        let data = try await git(
            ["for-each-ref", "--format=%(refname)%00%(upstream:short)%00%(upstream:track)", ref])
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            .map { $0.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init) }
            .filter { $0.first == ref }
        guard lines.count == 1, lines[0].count == 3 else {
            Issue.record(
                "no single branch \(ref) to read an upstream from: \(lines)", sourceLocation: sourceLocation)
            return .none
        }
        let (name, track) = (lines[0][1], lines[0][2])
        switch (name.isEmpty, track) {
        case (true, ""): return .none
        case (false, "[gone]"): return .gone(name)
        case (false, _) where !track.hasPrefix("[gone"): return .tracking(name)
        default:
            Issue.record(
                "an upstream of an unexpected shape for \(ref): \(name) \(track)",
                sourceLocation: sourceLocation)
            return .none
        }
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
        // `-b main` is spelled out because the suite runs with `GIT_CONFIG_NOSYSTEM=1` (see
        // `TestGitEnvironment`): without the Xcode gitconfig's `init.defaultbranch=main` a bare
        // repository starts on `master`, and cloning one whose HEAD names a branch that does
        // not exist checks nothing out.
        _ = try await isolatedRunner().run(
            "/usr/bin/git", ["init", "-q", "--bare", "-b", "main", "."], cwd: remote)

        try await git(["remote", "add", remoteName, remote.path])
        try await git(["push", "-q", remoteName, "main"])
        try await git(["push", "-q", remoteName, "refs/heads/feature:refs/heads/feat/x"])
        try await git(["fetch", "-q", remoteName])
        return remote
    }

    /// What `ref` points at when it is a symbolic ref, or nil when it is not one (or absent):
    /// `git symbolic-ref` exits 128 in both of those cases.
    func symbolicRef(_ ref: String) async throws -> String? {
        let data = try await git(["symbolic-ref", "--quiet", ref], allowedExitCodes: [1, 128])
        let target = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? nil : target
    }

    /// Adds a second, empty bare repository as a remote — what the triangular-push cases
    /// (`branch.<name>.pushRemote`, `remote.pushDefault`) need: somewhere to push that is not
    /// where the branch fetches from. Returns the remote's URL so the caller can clean it up.
    @discardableResult
    func addEmptyRemote(named remoteName: String) async throws -> URL {
        let slug = remoteName.replacingOccurrences(of: "/", with: "-")
        let remote = root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-\(slug).git", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        _ = try await isolatedRunner().run(
            "/usr/bin/git", ["init", "-q", "--bare", "-b", "main", "."], cwd: remote)
        try await git(["remote", "add", remoteName, remote.path])
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

/// What `TestRepo.upstream(of:)` reads for a branch: no upstream configured, an upstream whose
/// remote-tracking ref exists (`origin/x`), or one whose ref is gone — git's `[gone]`, what a
/// branch deleted on the server and pruned here leaves behind.
enum UpstreamState: Equatable {
    case none
    case tracking(String)
    case gone(String)
}

/// The controls for `TestRepo.upstream(of:)`: each of its three answers is reached by a state
/// git really has, so a caller's `== .none` cannot be met by a `[gone]` upstream — the case
/// the helper it replaced answered with the echoed `"<branch>@{upstream}"` (E1 survey S12).
@Suite struct UpstreamStateTests {
    @Test func aDeletedRemoteBranchIsGoneAndABranchWithNoUpstreamIsNone() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        try await repo.git(["switch", "-q", "-c", "topic"])
        try await repo.git(["push", "-q", "-u", "origin", "topic"])
        try await repo.git(["branch", "-q", "plain"])
        #expect(try await repo.upstream(of: "topic") == .tracking("origin/topic"))

        // Deleted on the server, and the remote-tracking ref with it: `[gone]`.
        try await repo.git(["push", "-q", "origin", "--delete", "topic"])
        #expect(try await repo.configValue("branch.topic.merge") == "refs/heads/topic")
        #expect(try await repo.upstream(of: "topic") == .gone("origin/topic"))
        #expect(try await repo.upstream(of: "plain") == .none)
        try await repo.git(["branch", "-q", "--track", "feat/x", "origin/feat/x"])
        #expect(try await repo.upstream(of: "feat/x") == .tracking("origin/feat/x"))
    }

    /// Control: a branch that does not exist is named as a failure, never answered `.none` —
    /// the quiet answer the old helper gave for anything it could not read.
    @Test func aBranchThatDoesNotExistIsARecordedIssue() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await withKnownIssue("there is no branch named nowhere") {
            _ = try await repo.upstream(of: "nowhere")
        } matching: { $0.comments.contains { $0.rawValue.contains("no single branch") } }
        // Nor is a branch whose name is only a path prefix of one that does (`for-each-ref`
        // lists `refs/heads/feat/x` for `refs/heads/feat`).
        try await repo.git(["branch", "-q", "feat/x"])
        try await withKnownIssue("there is no branch named feat, only feat/x") {
            _ = try await repo.upstream(of: "feat")
        } matching: { $0.comments.contains { $0.rawValue.contains("no single branch") } }
    }
}
