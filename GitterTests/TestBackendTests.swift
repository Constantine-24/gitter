import Foundation
import GitCore
import GitCoreTestSupport
import Synchronization
import Testing

@testable import Gitter

/// `TestBackend` itself (E3 Task 3): its keys, the forwarding to real git, the hooks, `fail`,
/// `hold`, the call log — each with a control that shows its check can fail.
@MainActor @Suite struct TestBackendTests {

    // MARK: - The keys

    @Test func thereIsOneKeyPerRequirementAndNoTwoAreSpelledAlike() {
        #expect(TestBackend.Call.allCases.count == 104)
        #expect(Set(TestBackend.Call.allCases.map(\.rawValue)).count == 104)
    }

    /// Plan correction 2 makes a misspelt key a compile error; this is the other half: every
    /// forwarder in `TestBackend.swift` passes the key whose raw value is its own `#function`
    /// spelling, and each key is passed by exactly one forwarder. Read from the source file
    /// beside this one.
    @Test func everyForwarderPassesTheKeySpelledLikeItself() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "TestBackend.swift")
        let forwarders = ForwarderKeys.read(try String(contentsOf: file, encoding: .utf8))

        #expect(forwarders.count == 104)
        #expect(Set(forwarders.map(\.key)).count == 104)
        #expect(ForwarderKeys.mismatches(forwarders).isEmpty, "\(ForwarderKeys.mismatches(forwarders))")
    }

    /// Control: a forwarder that passes another method's key is found.
    @Test func aForwarderPassingAnotherMethodsKeyIsFound() {
        let forged = """
                func snapshot(at root: URL) async throws -> RepoSnapshot {
                    try await around(.commitFiles) { try await real.snapshot(at: root) }
                }
                func push(_ branch: String, to remote: String, remoteRef: String, setUpstream: Bool, at root: URL, progress: @escaping @Sendable (String) -> Void) async throws -> PushResult {
                    try await around(.push) {
                        try await real.push(branch, to: remote, remoteRef: remoteRef, setUpstream: setUpstream, at: root, progress: progress)
                    }
                }
            """
        let forwarders = ForwarderKeys.read(forged)

        #expect(forwarders.map(\.spelling) == ["snapshot(at:)", "push(_:to:remoteRef:setUpstream:at:progress:)"])
        #expect(ForwarderKeys.mismatches(forwarders) == ["snapshot(at:) passes commitFiles"])
    }

    /// The same check at run time: `around` records an issue when the key it is handed is not
    /// the calling method's own. Control: called from a function whose name is no key's.
    @Test(.timeLimit(.minutes(10))) func aCallKeyedByAnotherNameIsRecorded() async throws {
        let backend = TestBackend()
        try await withKnownIssue("`notACommit(_:)` is not `commit(message:amend:allTracked:at:)`") {
            try await Self.notACommit(backend)
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("is keyed as commit(message:amend:allTracked:at:)") }
        }
        #expect(backend.calls == [.commit])
    }

    // MARK: - The row read's answer (H1 Task 2)

    /// `replaceHistoryRow`: the call is still logged, and answers what the replacement says.
    @Test(.timeLimit(.minutes(10))) func aReplacedRowReadAnswersTheReplacement() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let sha = try repo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        let backend = TestBackend()
        let seen = Mutex<(sha: String, realRow: Int?)?>(nil)
        backend.replaceHistoryRow { asked, root, real in
            let realRow = try await real.historyRow(of: asked, at: root)
            seen.withLock { $0 = (asked, realRow) }
            return 60_000
        }
        #expect(try await backend.historyRow(of: sha, at: repo.url) == 60_000)
        #expect(backend.calls == [.historyRow])
        #expect(seen.withLock { $0?.sha } == sha)
        #expect(seen.withLock { $0?.realRow } == 0)
    }

    /// Control: with no replacement, git answers — the commit's real row.
    @Test(.timeLimit(.minutes(10))) func anUnreplacedRowReadIsGits() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let sha = try repo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        let backend = TestBackend()
        let row = try await backend.historyRow(of: sha, at: repo.url)
        withKnownIssue("nothing replaced the read, so it is git's row 0") {
            #expect(row == 60_000)
        }
        #expect(row == 0)
    }

    // MARK: - Forwarding and the call log

    @Test(.timeLimit(.minutes(10))) func aStoreOnTheTestBackendOpensThroughRealGit() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }

        #expect(store.lastError == nil)
        #expect(store.snapshot?.commits.map(\.summary) == ["first"])
        #expect(backend.calls.first == .snapshot)
    }

    /// The log is in order: a stage, then the reload `mutate` ends it with.
    @Test(.timeLimit(.minutes(10))) func theCallLogKeepsTheOrderTheCallsCameIn() async throws {
        let (repo, store, backend, cleanup) = try await Self.storeWithAChange()
        defer { repo.remove() }
        defer { cleanup() }
        let before = backend.calls.count

        store.stage(try #require(Self.file("a.txt", in: store)))
        await waitUntilIdle(store)

        let since = Array(backend.calls.dropFirst(before))
        #expect(since.first == .stage)
        #expect(since.dropFirst().contains(.snapshot))
    }

    /// Control for the log: a call the store never made is not in it, and the order is not
    /// what the reverse would say.
    @Test(.timeLimit(.minutes(10))) func theCallLogHoldsOnlyTheCallsMade() async throws {
        let (repo, store, backend, cleanup) = try await Self.storeWithAChange()
        defer { repo.remove() }
        defer { cleanup() }
        let before = backend.calls.count
        store.stage(try #require(Self.file("a.txt", in: store)))
        await waitUntilIdle(store)
        let since = Array(backend.calls.dropFirst(before))

        withKnownIssue("nothing pushed") {
            #expect(backend.calls.contains(.push))
        }
        withKnownIssue("the reload comes after the stage, not before it") {
            #expect(since.first == .snapshot)
        }
    }

    // MARK: - Hooks

    /// A before hook runs before git does and an after hook once git has: each reads the index.
    @Test(.timeLimit(.minutes(10))) func hooksRunBeforeAndAfterTheRealCall() async throws {
        let (repo, store, backend, cleanup) = try await Self.storeWithAChange()
        defer { repo.remove() }
        defer { cleanup() }
        let seen = Recorded<[String]>([])
        backend.hook(.stage, .before) { seen.update { $0.append("before: " + (try? Self.staged(repo)).orNone) } }
        backend.hook(.stage, .after) { seen.update { $0.append("after: " + (try? Self.staged(repo)).orNone) } }

        store.stage(try #require(Self.file("a.txt", in: store)))
        await waitUntilIdle(store)

        #expect(seen.value == ["before: ", "after: a.txt"])
        #expect(store.lastError == nil)
    }

    /// Control for the hooks' order: the wrong order is not what they record.
    @Test(.timeLimit(.minutes(10))) func theHooksOrderIsNotTheReverse() async throws {
        let (repo, store, backend, cleanup) = try await Self.storeWithAChange()
        defer { repo.remove() }
        defer { cleanup() }
        let seen = Recorded<[String]>([])
        backend.hook(.stage, .after) { seen.update { $0.append("after") } }
        backend.hook(.stage, .before) { seen.update { $0.append("before") } }

        store.stage(try #require(Self.file("a.txt", in: store)))
        await waitUntilIdle(store)

        withKnownIssue("the after hook runs after the before hook, whatever order they were added in") {
            #expect(seen.value == ["after", "before"])
        }
        #expect(seen.value == ["before", "after"])
    }

    /// A before hook that throws: the call throws that error, and git never runs.
    @Test(.timeLimit(.minutes(10))) func aHookThatThrowsMakesTheCallThrowWithoutGit() async throws {
        let (repo, store, backend, cleanup) = try await Self.storeWithAChange()
        defer { repo.remove() }
        defer { cleanup() }
        let refusal = GitError.commandFailed(exitCode: 1, stderr: "refused by the test's hook")
        backend.hook(.stage, .before) { throw refusal }

        store.stage(try #require(Self.file("a.txt", in: store)))
        await waitUntilIdle(store)

        #expect(store.lastError == RepositoryStore.describe(refusal))
        #expect(try Self.staged(repo) == "")
    }

    /// An `.after` hook runs only once git has: a call that throws before it (here a `fail`) never
    /// reaches it.
    @Test(.timeLimit(.minutes(10))) func anAfterHookDoesNotRunWhenTheCallThrows() async throws {
        let (repo, store, backend, cleanup) = try await Self.storeWithAChange()
        defer { repo.remove() }
        defer { cleanup() }
        let failure = GitError.commandFailed(exitCode: 1, stderr: "injected by the test: the stage was refused")
        let after = Recorded<Int>(0)
        backend.hook(.stage, .after) { after.update { $0 += 1 } }
        backend.fail(.stage, with: failure)

        store.stage(try #require(Self.file("a.txt", in: store)))
        await waitUntilIdle(store)

        #expect(store.lastError == RepositoryStore.describe(failure))
        #expect(after.value == 0)
        #expect(try Self.staged(repo) == "")

        // The control: the next stage runs git, and the hook after it.
        store.dismissError()
        store.stage(try #require(Self.file("a.txt", in: store)))
        await waitUntilIdle(store)
        #expect(after.value == 1)
    }

    /// An `.after` hook that throws replaces the call's result with its error — git having run:
    /// the stage is in the index, and the store shows the hook's error.
    @Test(.timeLimit(.minutes(10))) func aThrowingAfterHookReplacesTheResultGitHavingRun() async throws {
        let (repo, store, backend, cleanup) = try await Self.storeWithAChange()
        defer { repo.remove() }
        defer { cleanup() }
        let refusal = GitError.commandFailed(exitCode: 1, stderr: "refused by the test's after hook")
        backend.hook(.stage, .after) { throw refusal }

        store.stage(try #require(Self.file("a.txt", in: store)))
        await waitUntilIdle(store)

        #expect(store.lastError == RepositoryStore.describe(refusal))
        #expect(try Self.staged(repo) == "a.txt", "git ran before the hook threw")
    }

    // MARK: - fail

    /// The next commit throws the error it was given, git never runs, and the one after it is
    /// real again — which is also the control: the "no new commit" check can fail.
    @Test(.timeLimit(.minutes(10))) func aFailedCommitShowsItsBannerAndCommitsNothing() async throws {
        let (repo, store, backend, cleanup) = try await Self.storeWithAChange()
        defer { repo.remove() }
        defer { cleanup() }
        let failure = GitError.commandFailed(exitCode: 1, stderr: "injected by the test: the commit was refused")
        backend.fail(.commit, with: failure)

        store.draft.subject = "second"
        store.commit()
        await waitUntilIdle(store)

        #expect(store.lastError == RepositoryStore.describe(failure))
        #expect(try Self.commitCount(repo) == 1)
        #expect(store.draft.subject == "second", "a refused commit keeps the draft")
        #expect(backend.calls.contains(.commit))

        store.commit()
        await waitUntilIdle(store)

        #expect(store.lastError == nil)
        #expect(try Self.commitCount(repo) == 2)
        #expect(store.snapshot?.commits.first?.summary == "second")
    }

    // MARK: - hold

    /// A held push holds the lane with a write and leaves the remote as it was; released, the
    /// push lands.
    @Test(.timeLimit(.minutes(10))) func aHeldPushHoldsTheLaneUntilReleased() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        let bare = try HeldTransport.remoteOneCommitBehind(repo)
        let before = try repo.git("-C", bare.path, "rev-parse", "main")
        let local = try repo.git("rev-parse", "main")
        #expect(before != local)
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        defer { backend.releaseAll() }
        let gate = backend.hold(.push)

        store.push()
        #expect(await waitUntil("the push parked") { gate.waiting })
        #expect(store.remoteActivity?.kind == .push)
        #expect(store.remoteActivity?.isWrite == true)
        #expect(try repo.git("-C", bare.path, "rev-parse", "main") == before)

        gate.release()
        await waitUntilIdle(store)

        #expect(store.remoteActivity == nil)
        #expect(store.lastError == nil)
        #expect(try repo.git("-C", bare.path, "rev-parse", "main") == local)
    }

    /// RF4's control: a hold nobody releases is caught by the hang guard — the wait is cancelled
    /// as `.timeLimit` cancels it — and `releaseAll()` lets the held call, and the test, end.
    @Test(.timeLimit(.minutes(10))) func aHoldNeverReleasedIsCaughtByTheTimeLimit() async throws {
        let (repo, store, backend, cleanup) = try await Self.storeWithAChange()
        defer { repo.remove() }
        defer { cleanup() }
        defer { backend.releaseAll() }
        let gate = backend.hold(.commit)
        store.draft.subject = "second"
        store.commit()
        #expect(await waitUntil("the commit parked") { gate.waiting })

        await withKnownIssue("the hold is never released, so the store never goes idle") {
            let waiter = Task { @MainActor in await waitUntilIdle(store) }
            try? await Task.sleep(for: .milliseconds(150))
            waiter.cancel()
            await waiter.value
        } matching: { $0.isNeverCameBack }

        backend.releaseAll()
        await waitUntilIdle(store)
        #expect(try Self.commitCount(repo) == 2)
        #expect(!gate.waiting)
    }

    /// `waitUntilSettled`'s control (`releaseAndSettle`, final review M2): a push still held is a
    /// store that has not settled — the wait is cancelled as `.timeLimit` cancels it — and released
    /// and settled, its lane is free.
    @Test(.timeLimit(.minutes(10))) func aStoreWithAHeldWriteDoesNotSettleUntilReleased() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try HeldTransport.remoteOneCommitBehind(repo)
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        defer { backend.releaseAll() }
        let gate = backend.hold(.push)
        store.push()
        #expect(await waitUntil("the push parked") { gate.waiting })

        await withKnownIssue("the push is held, so the store never settles") {
            let waiter = Task { @MainActor in await waitUntilSettled(store) }
            try? await Task.sleep(for: .milliseconds(150))
            waiter.cancel()
            await waiter.value
        } matching: { $0.isNeverCameBack }

        await releaseAndSettle([backend], [store])
        #expect(store.remoteActivity == nil)
        #expect(!store.isMutating)
    }

    /// `releaseAll()` also drops a hold no call has reached yet, so a later call goes straight
    /// through instead of parking with nobody left to release it.
    @Test(.timeLimit(.minutes(10))) func releaseAllDropsAHoldNoCallReachedYet() async throws {
        let (repo, store, backend, cleanup) = try await Self.storeWithAChange()
        defer { repo.remove() }
        defer { cleanup() }
        let gate = backend.hold(.commit)
        backend.releaseAll()

        store.draft.subject = "second"
        store.commit()
        await waitUntilIdle(store)

        #expect(!gate.waiting)
        #expect(try Self.commitCount(repo) == 2)
    }

    // MARK: - Fixtures

    /// Hands `around` the commit's key from a function that is not the commit.
    nonisolated static func notACommit(_ backend: TestBackend) async throws {
        try await backend.around(.commit) {}
    }

    /// `a.txt` committed and then changed, on a store opened through a fresh `TestBackend`.
    static func storeWithAChange() async throws -> (ScratchRepo, RepositoryStore, TestBackend, () -> Void) {
        let repo = try ScratchRepo()
        try repo.commit("a.txt", "one\n", "first")
        try repo.write("a.txt", "two\n")
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        return (repo, store, backend, cleanup)
    }

    static func file(_ path: String, in store: RepositoryStore) -> FileStatus? {
        store.snapshot?.status.files.first { $0.path == path }
    }

    /// The staged paths, one per line, without the last newline.
    nonisolated static func staged(_ repo: ScratchRepo) throws -> String {
        try repo.git("diff", "--cached", "--name-only").trimmingCharacters(in: .newlines)
    }

    static func commitCount(_ repo: ScratchRepo) throws -> Int {
        Int(try repo.git("rev-list", "--count", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }
}

extension Optional<String> {
    fileprivate var orNone: String { self ?? "(git failed)" }
}

/// The forwarders of `TestBackend.swift` read as text: each `func` line's `#function` spelling
/// and the key its next line hands `around`. The generated shape is one signature line followed
/// by `try await around(.key)`.
enum ForwarderKeys {
    struct Forwarder: Equatable {
        let spelling: String
        let key: String
    }

    static func read(_ source: String) -> [Forwarder] {
        let lines = source.components(separatedBy: "\n")
        var found: [Forwarder] = []
        for (index, line) in lines.enumerated() {
            guard let spelling = spelling(of: line), index + 1 < lines.count,
                let key = key(in: lines[index + 1])
            else { continue }
            found.append(Forwarder(spelling: spelling, key: key))
        }
        return found
    }

    /// `"<spelling> passes <key>"` for each forwarder whose key is not its own.
    static func mismatches(_ forwarders: [Forwarder]) -> [String] {
        forwarders.compactMap { forwarder in
            let call = TestBackend.Call.allCases.first { "\($0)" == forwarder.key }
            return call?.rawValue == forwarder.spelling ? nil : "\(forwarder.spelling) passes \(forwarder.key)"
        }
    }

    /// `name(label:label:)` for a line `    func name(label local: Type, …) async throws…`.
    private static func spelling(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("func "), trimmed.contains(") async throws"),
            let open = trimmed.firstIndex(of: "(")
        else { return nil }
        let name = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5)..<open]
        var depth = 0
        var parameters: [String] = []
        var current = ""
        var previous: Character = " "
        for character in trimmed[trimmed.index(after: open)...] {
            defer { previous = character }
            if "([<".contains(character) { depth += 1 }
            // The `>` of a closure's `->` closes nothing.
            if ")]".contains(character) || (character == ">" && previous != "-") {
                if depth == 0 { break }
                depth -= 1
            }
            if character == ",", depth == 0 {
                parameters.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parameters.append(current) }
        let labels = parameters.compactMap { $0.split(separator: ":").first?.split(separator: " ").first }
        return "\(name)(" + labels.map { "\($0):" }.joined() + ")"
    }

    private static func key(in line: String) -> String? {
        guard let start = line.range(of: "around(.") else { return nil }
        return String(line[start.upperBound...].prefix { $0.isLetter || $0.isNumber })
    }
}
