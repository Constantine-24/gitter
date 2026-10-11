import Foundation
import Testing

@testable import GitCore

/// Stops for Continue and Skip, built with real git (M 13's `two` repository).
///
/// `base` holds `f.txt` (`a b c`), `g.txt`, `h.txt` and `i.txt`; `feature` adds `c1 f` (`b F1`)
/// and `c2 g` (`g F2`), both authored `Orig <o@o>` on 2001-01-01; `main` adds `m` (`b M`,
/// `g M`); branch `one` is `feature~1`. A revert stop adds `r1 f` (`b R1`), `r2 g` (`g R2`) and
/// `later` (`b L`, `g L`) on main and reverts back through them. Every builder checks that git
/// stopped with conflicts.
enum SequenceFixtures {
    typealias Configure = @Sendable (TestRepo) async throws -> Void

    /// `log -1 --format=%an%x00%ad` of a commit that kept the original authorship.
    static let originalAuthor = "Orig\u{0}Mon Jan 1 00:00:00 2001 +0000"

    static func history() async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("f.txt", "a\nb\nc\n")
        try repo.write("g.txt", "g\n")
        try repo.write("h.txt", "h\n")
        try repo.write("i.txt", "i\n")
        try await repo.commitAll("base")
        try await repo.git(["tag", "base"])
        try await repo.git(["switch", "-q", "-c", "feature"])
        try repo.write("f.txt", "a\nb F1\nc\n")
        try await commitAsOriginalAuthor(repo, "c1 f")
        try repo.write("g.txt", "g F2\n")
        try await commitAsOriginalAuthor(repo, "c2 g")
        try await repo.git(["branch", "one", "HEAD~1"])
        try await repo.git(["switch", "-q", "main"])
        try repo.write("f.txt", "a\nb M\nc\n")
        try repo.write("g.txt", "g M\n")
        try await repo.commitAll("m")
        return repo
    }

    static func commitAsOriginalAuthor(_ repo: TestRepo, _ message: String) async throws {
        try await repo.git(["add", "-A"])
        try await repo.git(["commit", "-q", "-m", message, "--author=Orig <o@o>", "--date=2001-01-01T00:00:00Z"])
    }

    /// `operation` stopped on its first conflict, over `commits` (1 or 2) commits. `before`
    /// runs just before the operation starts (configuration git reads when it stops).
    static func stopped(
        _ operation: RepositoryOperation, commits: Int, before: Configure = { _ in }
    ) async throws -> TestRepo {
        precondition(commits == 1 || commits == 2)
        let repo = try await history()
        if operation == .revert {
            try repo.write("f.txt", "a\nb R1\nc\n")
            try await repo.commitAll("r1 f")
            try repo.write("g.txt", "g R2\n")
            try await repo.commitAll("r2 g")
            try repo.write("f.txt", "a\nb L\nc\n")
            try repo.write("g.txt", "g L\n")
            try await repo.commitAll("later")
        }
        try await before(repo)
        switch (operation, commits) {
        case (.rebase, 2):
            try await repo.git(["switch", "-q", "feature"])
            try await repo.git(["rebase", "main"], allowedExitCodes: [1])
        case (.rebase, _):
            try await repo.git(["switch", "-q", "one"])
            try await repo.git(["rebase", "main"], allowedExitCodes: [1])
        case (.cherryPick, 2):
            try await repo.git(["cherry-pick", "base..feature"], allowedExitCodes: [1])
        case (.cherryPick, _):
            try await repo.git(["cherry-pick", "feature~1"], allowedExitCodes: [1])
        case (.revert, 2):
            // Newest first: `r2 g` (g.txt), then `r1 f` (f.txt).
            try await repo.git(["revert", "--no-edit", "HEAD~3..HEAD~1"], allowedExitCodes: [1])
        case (.revert, _):
            try await repo.git(["revert", "--no-edit", "HEAD~2"], allowedExitCodes: [1])
        default:
            preconditionFailure("no fixture for \(operation)")
        }
        try await ConflictFixtures.requireUnmerged(repo)
        return repo
    }

    /// The paths `ls-files -u` lists, once each.
    static func unmerged(_ repo: TestRepo) async throws -> [String] {
        let data = try await repo.git(["ls-files", "-u", "-z"])
        var seen = Set<String>()
        return String(decoding: data, as: UTF8.self).split(separator: "\0")
            .compactMap { $0.split(separator: "\t", maxSplits: 1).last.map(String.init) }
            .filter { seen.insert($0).inserted }
    }

    /// Resolves every unmerged path to `<name> RES` and stages it.
    static func resolve(_ repo: TestRepo) async throws {
        for path in try await unmerged(repo) {
            try repo.write(path, path == "f.txt" ? "a\nb RES\nc\n" : "\(path.prefix(1)) RES\n")
            try await repo.git(["add", "--", path])
        }
    }

    /// A commit's full message, final newlines trimmed.
    static func message(_ repo: TestRepo, _ rev: String = "HEAD") async throws -> String {
        let data = try await repo.git(["log", "-1", "--format=%B", rev])
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    static func subjects(_ repo: TestRepo, _ range: String) async throws -> [String] {
        let data = try await repo.git(["log", "--format=%s", range])
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Where git keeps the operation's pending message.
    static func messageFile(_ repo: TestRepo, _ operation: RepositoryOperation) async throws -> URL {
        try await ConflictFixtures.gitPath(repo, operation == .rebase ? "rebase-merge/message" : "MERGE_MSG")
    }

    /// Everything a refused or failed continue must leave as it was.
    struct Untouched {
        let state: RepoState
        let operation: OperationState
        let worktree: [String: Data]

        static func capture(_ repo: TestRepo) async throws -> Untouched {
            let operation = try await OperationState.capture(repo)
            #expect(!operation.fingerprint.isEmpty)
            return Untouched(
                state: try await RepoState.capture(repo), operation: operation, worktree: worktreeSnapshot(repo))
        }

        func assert(_ repo: TestRepo, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            try await assertRepoUnchanged(repo, since: state, worktree: worktree, sourceLocation: sourceLocation)
            try await assertOperationUnchanged(repo, since: operation, sourceLocation: sourceLocation)
        }
    }
}

/// Proves `Untouched` can fail: without it every "the stop survived" assertion could be vacuous.
@Suite struct UntouchedTests {
    @Test func failsWhenThePendingMessageIsRewritten() async throws {
        let repo = try await SequenceFixtures.stopped(.cherryPick, commits: 1)
        defer { repo.cleanUp() }
        let untouched = try await SequenceFixtures.Untouched.capture(repo)

        try Data("rewritten".utf8).write(to: try await SequenceFixtures.messageFile(repo, .cherryPick))

        await withKnownIssue("MERGE_MSG really changed") {
            try await untouched.assert(repo)
        }
    }
}
