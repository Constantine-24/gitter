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

@Suite struct ContinueTests {
    static let backend = CLIGitBackend()
    static let sequences: [RepositoryOperation] = [.rebase, .cherryPick, .revert]

    // MARK: - Continuing

    @Test(arguments: sequences)
    func aResolvedStopContinuesToTheNextAndThenFinishes(operation: RepositoryOperation) async throws {
        let repo = try await SequenceFixtures.stopped(operation, commits: 2)
        defer { repo.cleanUp() }
        let firstPaths = try await SequenceFixtures.unmerged(repo)
        #expect(try await Self.backend.continueReadiness(at: repo.root) == .unresolved(firstPaths))
        let first = try #require(try await Self.backend.operationProgress(at: repo.root)?.current)
        try await SequenceFixtures.resolve(repo)
        #expect(try await Self.backend.continueReadiness(at: repo.root) == .ready)

        let outcome = try await Self.backend.continueOperation(operation, message: nil, at: repo.root)

        guard case .stoppedAgain(let progress) = outcome else {
            Issue.record("expected the next stop, got \(outcome)")
            return
        }
        #expect(progress.operation == operation)
        let second = try #require(progress.current)
        #expect(second != first)
        #expect(progress == (try await Self.backend.operationProgress(at: repo.root)))
        let secondPaths = try await SequenceFixtures.unmerged(repo)
        #expect(!secondPaths.isEmpty && secondPaths != firstPaths)
        try await SequenceFixtures.resolve(repo)

        #expect(try await Self.backend.continueOperation(operation, message: nil, at: repo.root) == .finished)

        #expect(try await Self.backend.operationProgress(at: repo.root) == nil)
        #expect(try await repo.git(["status", "--porcelain"]).isEmpty)
        let expected: [String] =
            operation == .revert ? ["Revert \"r1 f\"", "Revert \"r2 g\""] : ["c2 g", "c1 f"]
        #expect(try await SequenceFixtures.subjects(repo, "HEAD~2..HEAD") == expected)
        // git's `# Conflicts:` block is not in either commit.
        #expect(try await !SequenceFixtures.message(repo).contains("Conflicts"))
        #expect(try await !SequenceFixtures.message(repo, "HEAD~1").contains("Conflicts"))
    }

    /// M 15, M 29: the message is written where git reads it, and a rebase or pick keeps the
    /// stopped commit's author and date (a revert is the reverter's commit).
    @Test(arguments: sequences)
    func theWrittenMessageIsTheCommitsWithItsOriginalAuthor(operation: RepositoryOperation) async throws {
        let repo = try await SequenceFixtures.stopped(operation, commits: 1)
        defer { repo.cleanUp() }
        try await SequenceFixtures.resolve(repo)

        let outcome = try await Self.backend.continueOperation(
            operation, message: "Edited subject\n\nbody line\n", at: repo.root)

        #expect(outcome == .finished)
        #expect(try await SequenceFixtures.message(repo) == "Edited subject\n\nbody line")
        let author = String(decoding: try await repo.git(["log", "-1", "--format=%an%x00%ad"]), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        if operation == .revert {
            #expect(author.hasPrefix("Tester\u{0}"))
        } else {
            #expect(author == SequenceFixtures.originalAuthor)
        }
    }

    /// M 29: under `commit.cleanup=verbatim` a rebase continue commits git's whole editor
    /// template. Gitter continues with `scissors`: the template is gone, and the user's own
    /// `#` line stays.
    @Test func aRebaseUnderVerbatimCommitsNoTemplateAndKeepsTheUsersHashLine() async throws {
        let repo = try await SequenceFixtures.stopped(.rebase, commits: 1)
        defer { repo.cleanUp() }
        try await repo.git(["config", "commit.cleanup", "verbatim"])
        try await SequenceFixtures.resolve(repo)

        let outcome = try await Self.backend.continueOperation(
            .rebase, message: "Edited subject\n\n#123 fix\n", at: repo.root)

        #expect(outcome == .finished)
        let message = try await SequenceFixtures.message(repo)
        #expect(message == "Edited subject\n\n#123 fix")
        #expect(!message.contains("Please enter"))
    }

    /// The control: the same continue run by git alone, with the same message file, commits the
    /// template — so the test above is about the setting Gitter passes.
    @Test func withoutScissorsGitCommitsTheTemplateUnderVerbatim() async throws {
        let repo = try await SequenceFixtures.stopped(.rebase, commits: 1)
        defer { repo.cleanUp() }
        try await repo.git(["config", "commit.cleanup", "verbatim"])
        try await SequenceFixtures.resolve(repo)
        try Data("Edited subject\n\n#123 fix\n".utf8).write(to: try await SequenceFixtures.messageFile(repo, .rebase))

        try await repo.git(["rebase", "--continue"])

        #expect(try await SequenceFixtures.message(repo).contains("# Please enter the commit message"))
    }

    // MARK: - The pending message

    @Test(arguments: [RepositoryOperation.rebase, .cherryPick])
    func thePendingMessageHasNoCommentLines(operation: RepositoryOperation) async throws {
        let repo = try await SequenceFixtures.stopped(operation, commits: 1)
        defer { repo.cleanUp() }
        let raw = try String(contentsOf: try await SequenceFixtures.messageFile(repo, operation), encoding: .utf8)
        #expect(raw.contains("# Conflicts:"), "git wrote no comment block: the test proves nothing")

        #expect(try await Self.backend.pendingMessage(at: repo.root) == PendingMessage(text: "c1 f", commentChar: "#"))
    }

    /// `core.commentChar=;`: git writes `; Conflicts:`, and the prefill has no `;` line.
    @Test(arguments: [RepositoryOperation.rebase, .cherryPick])
    func aConfiguredCommentCharIsTheOneStripped(operation: RepositoryOperation) async throws {
        let repo = try await SequenceFixtures.stopped(operation, commits: 1) { repo in
            try await repo.git(["config", "core.commentChar", ";"])
        }
        defer { repo.cleanUp() }
        let raw = try String(contentsOf: try await SequenceFixtures.messageFile(repo, operation), encoding: .utf8)
        #expect(raw.contains("; Conflicts:"), "git did not use `;`: the test proves nothing")

        let pending = try #require(try await Self.backend.pendingMessage(at: repo.root))

        #expect(pending == PendingMessage(text: "c1 f", commentChar: ";"))
        #expect(!pending.text.split(separator: "\n").contains { $0.hasPrefix(";") })
        try await SequenceFixtures.resolve(repo)
        #expect(try await Self.backend.continueOperation(operation, message: nil, at: repo.root) == .finished)
        #expect(try await SequenceFixtures.message(repo) == "c1 f")
    }

    /// `core.commentChar=auto`, measured (A2 Task 3): git keeps `#` unless a line of the message
    /// outside its trailing comment block starts with `#` (or the message does); then the first
    /// of `;@!$%^&|:` no such line starts with. A stopped commit whose subject is `#123 fix`
    /// makes git keep its own `# Conflicts:` block — and the prefill shows exactly that.
    @Test func underAutoThePrefillIsWhatGitWouldCommit() async throws {
        let repo = try await SequenceFixtures.history()
        defer { repo.cleanUp() }
        try await repo.git(["config", "core.commentChar", "auto"])
        try await repo.git(["switch", "-q", "one"])
        try await repo.git(["commit", "-q", "--amend", "-m", "#123 fix"])
        try await repo.git(["switch", "-q", "main"])
        try await repo.git(["cherry-pick", "one"], allowedExitCodes: [1])
        try await ConflictFixtures.requireUnmerged(repo)

        let pending = try #require(try await Self.backend.pendingMessage(at: repo.root))

        #expect(pending == PendingMessage(text: "#123 fix\n\n# Conflicts:\n#\tf.txt", commentChar: ";"))
        try await SequenceFixtures.resolve(repo)
        #expect(try await Self.backend.continueOperation(.cherryPick, message: nil, at: repo.root) == .finished)
        #expect(try await SequenceFixtures.message(repo) == pending.text)
    }

    @Test func underAutoAPlainMessageIsStrippedOfHashLines() async throws {
        let repo = try await SequenceFixtures.stopped(.cherryPick, commits: 1) { repo in
            try await repo.git(["config", "core.commentChar", "auto"])
        }
        defer { repo.cleanUp() }

        #expect(try await Self.backend.pendingMessage(at: repo.root) == PendingMessage(text: "c1 f", commentChar: "#"))
    }

    /// git's `auto` choice, one measured message each (A2 Task 3, `git commit` under
    /// `core.commentChar=auto` with the text as `MERGE_MSG`; the character is the one whose lines
    /// git stripped).
    @Test(arguments: [
        ("c1 f\n\n# Conflicts:\n#\tf.txt\n", "#"),
        ("fix #12\n\nbody\n\n# Conflicts:\n#\tf.txt\n", "#"),
        ("subj\n\n; semi\n\n# Conflicts:\n#\tf.txt\n", "#"),
        ("subj\n\n#hash\n\n# C\n", "#"),
        ("subj\n\n#hash\n;semi\n\n# C\n", "@"),
        ("#123 fix\n\n# Conflicts:\n#\tf.txt\n", ";"),
        ("subj\n\n#a\n\n#b\n", "#"),
        ("subj\n\n;a\n#b\n", "#"),
        ("subj\n\n#a\n@b\n", ";"),
        ("subj\n\n@b\n#a\n", "#"),
        ("#subj\n", ";"),
        ("#subj\n;x\n", "@"),
        ("subj\n;a\n@b\n#c\n!d\n", "$"),
        ("subj\n#a\n;b\n@c\n", "!"),
        ("subj\n\n\t#a\n#b\n", "#"),
        ("subj\n#a\nbody\n#b\n", ";"),
        ("subj\n#a\n\nConflicts:\n\tf.txt\n", "#"),
        ("subj\n#a\n\n@b\n", ";"),
        ("subj\n#a", "#"),
        ("subj\n\n#a\n\t#tab\n", ";"),
        ("subj\n\n#a\nConflicts:\n\tf\n#b\n", "#"),
        ("subj\n;x\n#a\n;y\n", "@"),
    ])
    func autoChoosesTheCharacterGitChooses(text: String, expected: String) {
        #expect(CLIGitBackend.autoCommentChar(for: text) == Character(expected))
    }

    // MARK: - Refusals before git runs

    @Test(arguments: sequences)
    func anUnresolvedStopIsNotContinued(operation: RepositoryOperation) async throws {
        let repo = try await SequenceFixtures.stopped(operation, commits: 1)
        defer { repo.cleanUp() }
        let paths = try await SequenceFixtures.unmerged(repo)
        let untouched = try await SequenceFixtures.Untouched.capture(repo)

        await #expect(throws: OperationError.notReady(.unresolved(paths))) {
            try await Self.backend.continueOperation(operation, message: "a message", at: repo.root)
        }

        try await untouched.assert(repo)
    }

    @Test(arguments: sequences)
    func anEmptyMessageIsRefused(operation: RepositoryOperation) async throws {
        let repo = try await SequenceFixtures.stopped(operation, commits: 1)
        defer { repo.cleanUp() }
        try await SequenceFixtures.resolve(repo)
        let untouched = try await SequenceFixtures.Untouched.capture(repo)

        await #expect(throws: OperationError.emptyMessage) {
            try await Self.backend.continueOperation(operation, message: " \n\n\t\n", at: repo.root)
        }
        if operation != .rebase {
            // Comment lines are all a pick or revert strips (whatever `commit.cleanup` says).
            await #expect(throws: OperationError.emptyMessage) {
                try await Self.backend.continueOperation(operation, message: "# only a comment\n", at: repo.root)
            }
        }

        try await untouched.assert(repo)
    }

    /// M 30: a resolution equal to HEAD. A rebase continues and leaves the commit out, silently
    /// (the UI said so first); a pick or revert is not continued — git would refuse (exit 1) —
    /// and Skip is the way on.
    @Test func anEqualToHEADRebaseContinuesAndTheCommitIsLeftOut() async throws {
        let repo = try await SequenceFixtures.stopped(.rebase, commits: 1)
        defer { repo.cleanUp() }
        try await repo.git(["checkout", "HEAD", "--", "f.txt"])
        #expect(try await Self.backend.continueReadiness(at: repo.root) == .emptyResult)

        let outcome = try await Self.backend.continueOperation(.rebase, message: nil, at: repo.root)

        #expect(outcome == .finished)
        #expect(try await Self.backend.operationProgress(at: repo.root) == nil)
        // `one` now holds main and nothing else: `c1 f` is gone.
        #expect(try await SequenceFixtures.subjects(repo, "one") == ["m", "base"])
    }

    /// Fix round 1 (I1): the resolution equals HEAD and an unrelated file is staged. The index
    /// differs from HEAD, but only by the unrelated file — the stopped commit's own result is
    /// still empty, and git would make a commit titled as the stopped one holding only `h.txt`.
    @Test(arguments: sequences)
    func anEqualToHEADResolutionIsEmptyEvenWithAnUnrelatedStagedFile(operation: RepositoryOperation) async throws {
        let repo = try await SequenceFixtures.stopped(operation, commits: 1)
        defer { repo.cleanUp() }
        try await repo.git(["checkout", "HEAD", "--", "f.txt"])
        try repo.write("h.txt", "h STAGED\n")
        try await repo.git(["add", "--", "h.txt"])

        #expect(try await Self.backend.continueReadiness(at: repo.root) == .emptyResult)
        // A rebase may continue past an empty result, but not with `h.txt` unacknowledged: it
        // would be the whole of the commit. A pick or revert does not continue at all.
        let untouched = try await SequenceFixtures.Untouched.capture(repo)
        let refusal: ContinueReadiness = operation == .rebase ? .otherStagedChanges(["h.txt"]) : .emptyResult
        await #expect(throws: OperationError.notReady(refusal)) {
            try await Self.backend.continueOperation(operation, message: nil, at: repo.root)
        }
        try await untouched.assert(repo)
    }

    @Test(arguments: [RepositoryOperation.cherryPick, .revert])
    func anEqualToHEADPickOrRevertIsNotContinued(operation: RepositoryOperation) async throws {
        let repo = try await SequenceFixtures.stopped(operation, commits: 1)
        defer { repo.cleanUp() }
        try await repo.git(["checkout", "HEAD", "--", "f.txt"])
        #expect(try await Self.backend.continueReadiness(at: repo.root) == .emptyResult)
        let untouched = try await SequenceFixtures.Untouched.capture(repo)

        await #expect(throws: OperationError.notReady(.emptyResult)) {
            try await Self.backend.continueOperation(operation, message: nil, at: repo.root)
        }

        try await untouched.assert(repo)
    }

    /// The operation ended in a terminal between the readiness the UI read and the click.
    @Test func anOperationAbortedInATerminalIsAMismatch() async throws {
        let repo = try await SequenceFixtures.stopped(.cherryPick, commits: 1)
        defer { repo.cleanUp() }
        try await SequenceFixtures.resolve(repo)
        #expect(try await Self.backend.continueReadiness(at: repo.root) == .ready)
        try await repo.git(["cherry-pick", "--abort"])
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect(throws: OperationError.operationMismatch(expected: .cherryPick, found: nil)) {
            try await Self.backend.continueOperation(.cherryPick, message: "c1 f", at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    @Test func anotherOperationIsAMismatch() async throws {
        let repo = try await SequenceFixtures.stopped(.cherryPick, commits: 1)
        defer { repo.cleanUp() }
        try await SequenceFixtures.resolve(repo)
        let untouched = try await SequenceFixtures.Untouched.capture(repo)

        await #expect(throws: OperationError.operationMismatch(expected: .rebase, found: .cherryPick)) {
            try await Self.backend.continueOperation(.rebase, message: "c1 f", at: repo.root)
        }
        try await untouched.assert(repo)
    }

    @Test func aMergeIsNotContinued() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let clean = try await SequenceFixtures.history()
        defer { clean.cleanUp() }
        #expect(try await Self.backend.continueReadiness(at: repo.root) == .notContinuable)
        #expect(try await Self.backend.continueReadiness(at: clean.root) == .notContinuable)
        #expect(try await Self.backend.skipReadiness(at: repo.root) == .notSkippable)
        #expect(try await Self.backend.skipReadiness(at: clean.root) == .notSkippable)

        await #expect(throws: OperationError.notReady(.notContinuable)) {
            try await Self.backend.continueOperation(.merge, message: "m", at: repo.root)
        }
    }

    // MARK: - git refuses: the stop survives

    /// M 14, M 18: a failing hook stops a pick or revert (a rebase runs neither hook).
    @Test(arguments: [
        (RepositoryOperation.cherryPick, "pre-commit", "PRECOMMIT-FAIL"),
        (.cherryPick, "commit-msg", "MSGHOOK-FAIL"),
        (.revert, "pre-commit", "PRECOMMIT-FAIL"),
        (.revert, "commit-msg", "MSGHOOK-FAIL"),
    ])
    func aFailingHookLeavesTheStop(operation: RepositoryOperation, hook: String, word: String) async throws {
        let repo = try await SequenceFixtures.stopped(operation, commits: 1)
        defer { repo.cleanUp() }
        try await SequenceFixtures.resolve(repo)
        try repo.writeExecutable(".git/hooks/\(hook)", "#!/bin/sh\necho \(word) >&2\nexit 1\n")
        let untouched = try await SequenceFixtures.Untouched.capture(repo)

        let outcome = try await Self.backend.continueOperation(operation, message: nil, at: repo.root)

        guard case .failed(let words) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(words.contains(word))
        try await untouched.assert(repo)
    }

    /// M 18: `commit.gpgSign` with a signing program that fails — a script in the test's own
    /// repository, never the user's gpg. A pick or revert reads it at continue time; a rebase
    /// only when it starts.
    @Test(arguments: sequences)
    func aFailedSignatureLeavesTheStop(operation: RepositoryOperation) async throws {
        let log = "gpg-called.log"
        let sign: SequenceFixtures.Configure = { repo in
            let script = repo.root.appendingPathComponent(".git/fake-gpg.sh")
            try repo.writeExecutable(".git/fake-gpg.sh", "#!/bin/sh\necho \"$@\" >> \"\(repo.root.path)/.git/\(log)\"\nexit 1\n")
            try await repo.git(["config", "gpg.program", script.path])
            try await repo.git(["config", "commit.gpgSign", "true"])
        }
        let repo = try await SequenceFixtures.stopped(operation, commits: 1, before: operation == .rebase ? sign : { _ in })
        defer { repo.cleanUp() }
        if operation != .rebase { try await sign(repo) }
        try await SequenceFixtures.resolve(repo)
        // The message the continue will write, written first, so the fingerprint can hold it.
        let message = "c1 f signed"
        try Data(message.utf8).write(to: try await SequenceFixtures.messageFile(repo, operation))
        let untouched = try await SequenceFixtures.Untouched.capture(repo)

        let outcome = try await Self.backend.continueOperation(operation, message: message, at: repo.root)

        guard case .failed(let words) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(words.contains("gpg failed to sign"))
        #expect(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent(".git/\(log)").path),
                "the fake signing program was not the one called")
        try await untouched.assert(repo)
    }

    /// M 18: a rebase's autostash that conflicts when applied back ends the rebase with `u UU`
    /// and no operation; the changes are in the stash list.
    @Test func anAutostashThatConflictsFinishesWithConflicts() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("f.txt", "a\nb\nc\n")
        try repo.write("w.txt", "w\n")
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "one"])
        try repo.write("f.txt", "a\nb F1\nc\n")
        try await repo.commitAll("c1 f")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("f.txt", "a\nb M\nc\n")
        try repo.write("w.txt", "w MAIN\n")
        try await repo.commitAll("m")
        try await repo.git(["switch", "-q", "one"])
        try repo.write("w.txt", "w DIRTY\n")
        try await repo.git(["config", "rebase.autoStash", "true"])
        try await repo.git(["rebase", "main"], allowedExitCodes: [1])
        try await ConflictFixtures.requireUnmerged(repo)
        try await SequenceFixtures.resolve(repo)

        let outcome = try await Self.backend.continueOperation(.rebase, message: nil, at: repo.root)

        #expect(outcome == .finishedWithConflicts(["w.txt"]))
        #expect(try await Self.backend.operationProgress(at: repo.root) == nil)
        #expect(String(decoding: try await repo.git(["stash", "list"]), as: UTF8.self).contains("autostash"))
    }

    /// RF5, measured (A2 Task 3): an unrelated staged edit (`h.txt`) and an unstaged one
    /// (`i.txt`) during a stop. A rebase refuses any unstaged change, so readiness says so and
    /// nothing runs (fix round 1, I2). A single pick or revert keeps the unstaged edit, and the
    /// staged one goes into the stopped commit — only once it is acknowledged (fix round 1, I1).
    @Test(arguments: sequences)
    func unrelatedEditsDuringAStop(operation: RepositoryOperation) async throws {
        let repo = try await SequenceFixtures.stopped(operation, commits: 1)
        defer { repo.cleanUp() }
        try await SequenceFixtures.resolve(repo)
        try repo.write("h.txt", "h STAGED\n")
        try await repo.git(["add", "--", "h.txt"])
        try repo.write("i.txt", "i UNSTAGED\n")

        if operation == .rebase {
            #expect(try await Self.backend.continueReadiness(at: repo.root) == .unstagedChanges(["i.txt"]))
            let untouched = try await SequenceFixtures.Untouched.capture(repo)
            await #expect(throws: OperationError.notReady(.unstagedChanges(["i.txt"]))) {
                try await Self.backend.continueOperation(
                    operation, message: nil, acknowledgingOtherStaged: ["h.txt"], at: repo.root)
            }
            try await untouched.assert(repo)
        } else {
            #expect(try await Self.backend.continueReadiness(at: repo.root) == .otherStagedChanges(["h.txt"]))
            let outcome = try await Self.backend.continueOperation(
                operation, message: nil, acknowledgingOtherStaged: ["h.txt"], at: repo.root)
            #expect(outcome == .finished)
            #expect(try repo.bytes("i.txt") == Data("i UNSTAGED\n".utf8))
            #expect(try await repo.git(["show", ":i.txt"]) == Data("i\n".utf8), "the unstaged edit was staged")
            #expect(try await repo.git(["show", "HEAD:h.txt"]) == Data("h STAGED\n".utf8))
        }
    }

    // MARK: - Fix round 1: other staged paths (I1)

    /// What a user may have staged that the stopped commit does not change, measured riding
    /// into the continued commit for all three (fix round 1).
    enum StagedShape: String, CaseIterable, Sendable {
        case newFile, deletion, move, modeChange, stagedThenRevertedInTheWorktree

        func apply(_ repo: TestRepo) async throws {
            switch self {
            case .newFile:
                try repo.write("new.txt", "new\n")
                try await repo.git(["add", "--", "new.txt"])
            case .deletion:
                try await repo.git(["rm", "-q", "--", "h.txt"])
            case .move:
                try await repo.git(["mv", "h.txt", "h2.txt"])
            case .modeChange:
                try repo.chmod("h.txt", 0o755)
                try await repo.git(["add", "--", "h.txt"])
            case .stagedThenRevertedInTheWorktree:
                try repo.write("h.txt", "h X\n")
                try await repo.git(["add", "--", "h.txt"])
                try repo.write("h.txt", "h\n")
            }
        }

        var paths: [String] {
            switch self {
            case .newFile: return ["new.txt"]
            case .move: return ["h.txt", "h2.txt"]
            default: return ["h.txt"]
            }
        }
    }

    static let shapes: [(RepositoryOperation, StagedShape)] =
        sequences.flatMap { operation in StagedShape.allCases.map { (operation, $0) } }

    @Test(arguments: shapes)
    func anUnrelatedStagedChangeIsNamedAndRefused(operation: RepositoryOperation, shape: StagedShape) async throws {
        let repo = try await SequenceFixtures.stopped(operation, commits: 1)
        defer { repo.cleanUp() }
        try await SequenceFixtures.resolve(repo)
        try await shape.apply(repo)
        // The worktree reverted under a staged change is an unstaged change too, which a rebase
        // refuses first.
        let expected: ContinueReadiness =
            operation == .rebase && shape == .stagedThenRevertedInTheWorktree
            ? .unstagedChanges(shape.paths) : .otherStagedChanges(shape.paths)

        #expect(try await Self.backend.continueReadiness(at: repo.root) == expected)

        let untouched = try await SequenceFixtures.Untouched.capture(repo)
        await #expect(throws: OperationError.notReady(expected)) {
            try await Self.backend.continueOperation(operation, message: nil, at: repo.root)
        }
        try await untouched.assert(repo)
    }

    @Test(arguments: sequences)
    func anUnrelatedStagedFileInARangeIsNamed(operation: RepositoryOperation) async throws {
        let repo = try await SequenceFixtures.stopped(operation, commits: 2)
        defer { repo.cleanUp() }
        try await SequenceFixtures.resolve(repo)
        try await StagedShape.newFile.apply(repo)

        #expect(try await Self.backend.continueReadiness(at: repo.root) == .otherStagedChanges(["new.txt"]))
    }

    /// Acknowledged by name, the file goes into the continued commit.
    @Test(arguments: sequences)
    func anAcknowledgedStagedFileIsCommitted(operation: RepositoryOperation) async throws {
        let repo = try await SequenceFixtures.stopped(operation, commits: 1)
        defer { repo.cleanUp() }
        try await SequenceFixtures.resolve(repo)
        try await StagedShape.newFile.apply(repo)

        let outcome = try await Self.backend.continueOperation(
            operation, message: nil, acknowledgingOtherStaged: ["new.txt"], at: repo.root)

        #expect(outcome == .finished)
        let files = String(decoding: try await repo.git(["show", "--name-only", "--format=", "HEAD"]), as: UTF8.self)
        #expect(files.split(separator: "\n").contains("new.txt"))
        #expect(files.split(separator: "\n").contains("f.txt"))
    }

    /// An acknowledgement is of a list, not a yes: a different list — a file staged or unstaged
    /// between the click and the run — is refused with the current one, and nothing runs.
    @Test(arguments: sequences)
    func aStaleAcknowledgementIsRefused(operation: RepositoryOperation) async throws {
        let repo = try await SequenceFixtures.stopped(operation, commits: 1)
        defer { repo.cleanUp() }
        try await SequenceFixtures.resolve(repo)
        try await StagedShape.newFile.apply(repo)
        try await StagedShape.deletion.apply(repo)
        let untouched = try await SequenceFixtures.Untouched.capture(repo)

        for acknowledged in [["new.txt"], ["new.txt", "h.txt", "other.txt"], ["other.txt"]] {
            await #expect(throws: OperationError.notReady(.otherStagedChanges(["h.txt", "new.txt"]))) {
                try await Self.backend.continueOperation(
                    operation, message: "a message", acknowledgingOtherStaged: acknowledged, at: repo.root)
            }
        }

        try await untouched.assert(repo)
    }

    /// An intent-to-add entry does not ride into a pick or revert (measured); a rebase refuses
    /// it as an unstaged change.
    @Test(arguments: sequences)
    func anIntentToAddEntry(operation: RepositoryOperation) async throws {
        let repo = try await SequenceFixtures.stopped(operation, commits: 1)
        defer { repo.cleanUp() }
        try await SequenceFixtures.resolve(repo)
        try repo.write("new.txt", "new\n")
        try await repo.git(["add", "-N", "--", "new.txt"])

        if operation == .rebase {
            #expect(try await Self.backend.continueReadiness(at: repo.root) == .unstagedChanges(["new.txt"]))
        } else {
            #expect(try await Self.backend.continueReadiness(at: repo.root) == .ready)
            #expect(try await Self.backend.continueOperation(operation, message: nil, at: repo.root) == .finished)
            let files = String(decoding: try await repo.git(["show", "--name-only", "--format=", "HEAD"]), as: UTF8.self)
            #expect(!files.contains("new.txt"))
        }
    }

    // MARK: - Fix round 1: unstaged changes and a stranded sequence (I2)

    /// A range with an unstaged edit in the file the next commit touches: git would commit the
    /// current commit, refuse the next and strand the sequence (M 17). Readiness says so first.
    @Test(arguments: sequences)
    func anUnstagedEditBlocksARange(operation: RepositoryOperation) async throws {
        let repo = try await SequenceFixtures.stopped(operation, commits: 2)
        defer { repo.cleanUp() }
        try await SequenceFixtures.resolve(repo)
        // The second commit's file: g.txt (c2 g), or for the revert f.txt (r1 f).
        let next = operation == .revert ? "f.txt" : "g.txt"
        try repo.write(next, "USER EDIT\n")

        #expect(try await Self.backend.continueReadiness(at: repo.root) == .unstagedChanges([next]))
        let untouched = try await SequenceFixtures.Untouched.capture(repo)
        await #expect(throws: OperationError.notReady(.unstagedChanges([next]))) {
            try await Self.backend.continueOperation(operation, message: nil, at: repo.root)
        }
        try await untouched.assert(repo)
    }

    /// A single pick or revert keeps an unstaged edit and has no next commit to collide with
    /// (measured): not blocked.
    @Test(arguments: [RepositoryOperation.cherryPick, .revert])
    func anUnstagedEditDoesNotBlockASinglePickOrRevert(operation: RepositoryOperation) async throws {
        let repo = try await SequenceFixtures.stopped(operation, commits: 1)
        defer { repo.cleanUp() }
        try await SequenceFixtures.resolve(repo)
        try repo.write("i.txt", "i UNSTAGED\n")

        #expect(try await Self.backend.continueReadiness(at: repo.root) == .ready)
        #expect(try await Self.backend.continueOperation(operation, message: nil, at: repo.root) == .finished)
        #expect(try repo.bytes("i.txt") == Data("i UNSTAGED\n".utf8))
    }

    /// A range whose next commit adds a file the user created untracked meanwhile: readiness
    /// cannot see it coming. git commits the current commit and refuses the next (exit 128),
    /// leaving `sequencer/` with no `CHERRY_PICK_HEAD` — measured. Reported as a halted
    /// sequence, not a failure: a commit was made, and no operation is detected any more.
    @Test func anUntrackedFileTheNextCommitAddsHaltsAPickRange() async throws {
        let repo = try await Self.nextCommitAddsAFile()
        defer { repo.cleanUp() }
        try await repo.git(["cherry-pick", "base..feature"], allowedExitCodes: [1])
        try await ConflictFixtures.requireUnmerged(repo)
        try await SequenceFixtures.resolve(repo)
        try repo.write("n.txt", "n USER\n")
        #expect(try await Self.backend.continueReadiness(at: repo.root) == .ready)

        let outcome = try await Self.backend.continueOperation(.cherryPick, message: nil, at: repo.root)

        guard case .sequenceHalted(let words) = outcome else {
            Issue.record("expected .sequenceHalted, got \(outcome)")
            return
        }
        #expect(words.contains("untracked working tree files would be overwritten"))
        #expect(try await Self.backend.operationProgress(at: repo.root) == nil)
        try await ConflictFixtures.requireGitPath(repo, "sequencer")
        #expect(try await SequenceFixtures.subjects(repo, "-1") == ["c1 f"])
        #expect(try repo.bytes("n.txt") == Data("n USER\n".utf8))
    }

    /// The same collision in a rebase stops the rebase at the next step, still detected.
    @Test func anUntrackedFileTheNextCommitAddsStopsARebaseAgain() async throws {
        let repo = try await Self.nextCommitAddsAFile()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "feature"])
        try await repo.git(["rebase", "main"], allowedExitCodes: [1])
        try await ConflictFixtures.requireUnmerged(repo)
        try await SequenceFixtures.resolve(repo)
        try repo.write("n.txt", "n USER\n")

        let outcome = try await Self.backend.continueOperation(.rebase, message: nil, at: repo.root)

        guard case .stoppedAgain(let progress) = outcome else {
            Issue.record("expected .stoppedAgain, got \(outcome)")
            return
        }
        #expect(progress.step == 2)
        #expect(progress.current?.subject == "c2 adds n")
        #expect(try repo.bytes("n.txt") == Data("n USER\n".utf8))
    }

    /// `c1 f` conflicts with main; `c2 adds n` adds `n.txt` cleanly.
    static func nextCommitAddsAFile() async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("f.txt", "a\nb\nc\n")
        try await repo.commitAll("base")
        try await repo.git(["tag", "base"])
        try await repo.git(["switch", "-q", "-c", "feature"])
        try repo.write("f.txt", "a\nb F1\nc\n")
        try await repo.commitAll("c1 f")
        try repo.write("n.txt", "n C2\n")
        try await repo.commitAll("c2 adds n")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("f.txt", "a\nb M\nc\n")
        try await repo.commitAll("m")
        return repo
    }
}
