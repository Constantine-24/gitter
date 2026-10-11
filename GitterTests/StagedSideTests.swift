import Foundation
import GitCore
import GitCoreTestSupport
import Testing

@testable import Gitter

/// E3 Task 6 (spec Structure tidy-ups 4): the staged or unstaged side of the selected file is
/// shown only through `showSide(staged:)` and `select(_:staged:)`, and each loads the diff once.
/// Counted in `TestBackend.calls` (`workingCopyDiff`).
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct StagedSideTests {

    /// `a.txt` with a staged change and a further unstaged one, so both sides have a diff.
    static func repository() throws -> ScratchRepo {
        let repo = try ScratchRepo()
        try repo.commit("a.txt", "one\n", "first")
        try repo.write("a.txt", "two\n")
        try repo.git("add", "--", "a.txt")
        try repo.write("a.txt", "three\n")
        return repo
    }

    static func diffLoads(_ backend: TestBackend) -> Int {
        backend.calls.filter { $0 == .workingCopyDiff }.count
    }

    /// Runs `change`, waits for the diff of `staged`'s side to land and for any second load to
    /// have started, and returns how many loads it made.
    static func loads(
        _ store: RepositoryStore, _ backend: TestBackend, showing staged: Bool, _ change: () -> Void
    ) async -> Int {
        let before = diffLoads(backend)
        change()
        await waitUntil("the diff of the \(staged ? "staged" : "unstaged") side") {
            store.diffIsStaged == staged && !store.diff.isEmpty
        }
        try? await Task.sleep(for: .milliseconds(150))
        return diffLoads(backend) - before
    }

    @Test(.timeLimit(.minutes(10))) func selectingAPathOnASideLoadsTheDiffOnce() async throws {
        let repo = try Self.repository()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }

        let count = await Self.loads(store, backend, showing: true) { store.select("a.txt", staged: true) }

        #expect(count == 1)
        #expect(store.stagedView)
        #expect(store.selectedPath == "a.txt")
    }

    @Test(.timeLimit(.minutes(10))) func theOtherSideOfTheSamePathLoadsOnceAndTheSameSideNotAtAll() async throws {
        let repo = try Self.repository()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        _ = await Self.loads(store, backend, showing: false) { store.select("a.txt", staged: false) }

        let moved = await Self.loads(store, backend, showing: true) { store.select("a.txt", staged: true) }
        let shown = await Self.loads(store, backend, showing: false) { store.showSide(staged: false) }
        let before = Self.diffLoads(backend)
        store.showSide(staged: false)
        try await Task.sleep(for: .milliseconds(150))

        #expect(moved == 1)
        #expect(shown == 1)
        #expect(Self.diffLoads(backend) == before, "the side it already shows loads nothing")
        #expect(!store.stagedView)
    }

    /// The control: the two-step the views used to take (the side, then the path) loads twice,
    /// so the count above can fail.
    @Test(.timeLimit(.minutes(10))) func theTwoStepLoadsTwice() async throws {
        let repo = try Self.repository()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        _ = await Self.loads(store, backend, showing: false) { store.select("a.txt", staged: false) }

        let count = await Self.loads(store, backend, showing: true) {
            store.showSide(staged: true)
            store.selectPath("a.txt")
        }

        withKnownIssue("the side's load and the path's load are two reads of the same diff") {
            #expect(count == 1)
        }
        #expect(count == 2)
    }
}
