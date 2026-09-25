import Foundation
import Testing

@testable import GitCore

/// `submodule.recurse=true` and `push.recurseSubmodules=on-demand` make a push of the
/// superproject **push the submodule's branch too** — to the submodule's own server, a ref
/// nobody named and no sheet mentioned. Measured on git 2.54 (final review's fix wave) with an
/// unpushed commit on the submodule's `main` and the superproject's gitlink bumped to it:
/// without a flag, both keys printed `Pushing submodule 'sub'` and the submodule server's
/// `main` moved; with `--no-recurse-submodules` it stayed where it was. All four push vectors
/// carry the flag now. (The delete vector sends no commits and was measured not to recurse
/// either way; it carries the flag so that all four read the same.)
@Suite struct PushSubmoduleTests {
    enum Key: String, CaseIterable, CustomTestStringConvertible {
        case submoduleRecurse = "submodule.recurse=true"
        case onDemand = "push.recurseSubmodules=on-demand"
        var testDescription: String { rawValue }
    }

    enum Vector: String, CaseIterable, CustomTestStringConvertible {
        case push, publish, forcePush
        var testDescription: String { rawValue }
    }

    /// The superproject (`repo`, pushing to `origin`) with a submodule `sub` whose own server is
    /// `sub`, an unpushed commit in the submodule, and the gitlink bumped to it and committed.
    private struct Fixture {
        let repo: TestRepo
        let origin: URL
        let sub: URL
        let subServerMain: String

        static func make() async throws -> Fixture {
            let repo = try await TestRepo.makeBranched()
            let origin = try await repo.addOriginWithFeatureBranch()
            let sub = repo.root.deletingLastPathComponent()
                .appendingPathComponent("\(repo.root.lastPathComponent)-sub.git", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try await bareGit(sub, ["init", "-q", "--bare", "-b", "main", "."])
            // The submodule's first commit, pushed to its server from a throwaway clone.
            let seed = repo.root.deletingLastPathComponent()
                .appendingPathComponent("\(repo.root.lastPathComponent)-subseed", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: seed) }
            _ = try await isolatedRunner().run(
                "/usr/bin/git", ["clone", "-q", sub.path, seed.path], cwd: sub)
            let seedRepo = TestRepo(root: seed)
            try await seedRepo.git(["config", "user.email", "t@example.invalid"])
            try await seedRepo.git(["config", "user.name", "T"])
            try await seedRepo.git(["config", "commit.gpgsign", "false"])
            try seedRepo.write("s.txt", "one\n")
            try await seedRepo.commitAll("sub one")
            try await seedRepo.git(["push", "-q", "origin", "main"])

            try await repo.git(
                ["-c", "protocol.file.allow=always", "submodule", "-q", "add", sub.path, "sub"])
            try await repo.git(["commit", "-qm", "add sub"])
            try await repo.git(["push", "-q", "origin", "main"])

            let inner = TestRepo(root: repo.root.appendingPathComponent("sub"))
            try await inner.git(["config", "user.email", "t@example.invalid"])
            try await inner.git(["config", "user.name", "T"])
            try await inner.git(["config", "commit.gpgsign", "false"])
            try inner.write("s.txt", "two\n")
            try await inner.commitAll("sub two, never pushed")
            try await repo.git(["add", "sub"])
            try await repo.git(["commit", "-qm", "bump sub"])
            return Fixture(
                repo: repo, origin: origin, sub: sub,
                subServerMain: try await bareGit(sub, ["rev-parse", "main"]))
        }

        func cleanUp() {
            repo.cleanUp()
            try? FileManager.default.removeItem(at: origin)
            try? FileManager.default.removeItem(at: sub)
        }
    }

    @Test(arguments: Vector.allCases, Key.allCases)
    func aPushNeverPushesTheSubmodulesBranch(vector: Vector, key: Key) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let setting = key.rawValue.split(separator: "=", maxSplits: 1).map(String.init)
        try await fixture.repo.git(["config", setting[0], setting[1]])
        let local = try await fixture.repo.headSha()
        let backend = CLIGitBackend()

        let result: PushResult
        switch vector {
        case .push, .publish:
            result = try await backend.push(
                "main", to: "origin", remoteRef: "refs/heads/main",
                setUpstream: vector == .publish, at: fixture.repo.root, progress: { _ in })
        case .forcePush:
            let serverMain = try await bareGit(fixture.origin, ["rev-parse", "main"])
            result = try await backend.forcePush(
                "main", to: "origin", remoteRef: "refs/heads/main", expectedRemoteTip: serverMain,
                expectedLocalTip: local, at: fixture.repo.root, progress: { _ in })
        }

        // The superproject's push went through — so the submodule assertion is about a push
        // that happened, not one that fell over first.
        guard case .pushed = result.outcome else {
            Issue.record("expected a fast-forward, got \(result.outcome)")
            return
        }
        #expect(try await bareGit(fixture.origin, ["rev-parse", "main"]) == local)
        #expect(
            try await bareGit(fixture.sub, ["rev-parse", "main"]) == fixture.subServerMain,
            "the submodule's branch was pushed to its server")
    }
}
