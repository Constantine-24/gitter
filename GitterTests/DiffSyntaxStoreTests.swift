import Foundation
import GitCore
import GitCoreTestSupport
import GitterSyntax
import Testing

@testable import Gitter

/// Syntax colours Task 3: after the diff lands, the store reads its sources, colours it off the
/// main actor and publishes `diffSyntax` — never before the diff, never for a diff no longer on
/// screen. On a real scratch repository, through `TestBackend` (its `blobBytes` can be held).
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct DiffSyntaxStoreTests {

    /// The diff on screen for `path`, once it has landed.
    static func shownDiff(_ store: RepositoryStore, _ path: String) async -> FileDiff? {
        await waitUntil("the diff of \(path)") { store.diff.first?.displayPath == path }
        return store.diff.first
    }

    static func line(_ kind: DiffLineKind, in diff: FileDiff) -> DiffLine? {
        diff.hunks.flatMap(\.lines).first { $0.kind == kind }
    }

    static func blobReads(_ backend: TestBackend) -> Int {
        backend.calls.filter { $0 == .blobBytes }.count
    }

    @Test(.timeLimit(.minutes(10))) func workingCopyDiffGetsColours() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.swift", "import Foundation\nlet a = 1\n", "first")
        try repo.write("a.swift", "import Foundation\nvar a = \"x\"\n")
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }

        store.select("a.swift", staged: false)
        let diff = try #require(await Self.shownDiff(store, "a.swift"))
        await store.diffSyntaxTask?.value

        let tokens = try #require(store.diffSyntax[diff.id])
        let added = try #require(Self.line(.added, in: diff))
        let removed = try #require(Self.line(.removed, in: diff))
        #expect(tokens[added.id]?.contains(SyntaxToken(range: 8..<11, kind: .string)) == true)
        #expect(tokens[removed.id]?.contains(SyntaxToken(range: 0..<3, kind: .keyword)) == true)
        // The old side is the index's blob; the new side is the file on disk, read without git.
        #expect(Self.blobReads(backend) == 1)
    }

    /// The staged side's new text is the index's blob, not the worktree file, which has moved on.
    @Test(.timeLimit(.minutes(10))) func stagedDiffUsesIndexBlob() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.swift", "let a = 1\n", "first")
        try repo.write("a.swift", "var b = \"staged\"\n")
        try repo.git("add", "--", "a.swift")
        try repo.write("a.swift", "something else entirely\n")
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }

        store.select("a.swift", staged: true)
        await waitUntil("the staged diff") { store.diffIsStaged && !store.diff.isEmpty }
        let diff = try #require(store.diff.first)
        await store.diffSyntaxTask?.value

        let added = try #require(Self.line(.added, in: diff))
        #expect(store.diffSyntax[diff.id]?[added.id]?.contains(SyntaxToken(range: 0..<3, kind: .keyword)) == true)
        #expect(Self.blobReads(backend) == 2)
    }

    /// A's colours, held until B is on screen, are dropped when they come.
    @Test(.timeLimit(.minutes(10))) func staleDiffSyntaxIsDropped() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.write("a.swift", "let a = 1\n")
        try repo.git("add", "--", "a.swift")
        try repo.commit("b.swift", "let b = 1\n", "first")
        try repo.write("a.swift", "var a = 2\n")
        try repo.write("b.swift", "var b = 2\n")
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        defer { backend.releaseAll() }

        let gate = backend.hold(.blobBytes)
        store.select("a.swift", staged: false)
        #expect(await waitUntil("A's syntax read parked") { gate.waiting })
        let a = try #require(store.diff.first)
        #expect(a.displayPath == "a.swift")
        let aTask = try #require(store.diffSyntaxTask)

        store.selectPath("b.swift")
        let b = try #require(await Self.shownDiff(store, "b.swift"))
        await store.diffSyntaxTask?.value
        #expect(Array(store.diffSyntax.keys) == [b.id])

        gate.release()
        await aTask.value
        #expect(store.diffSyntax[a.id] == nil)
        #expect(Array(store.diffSyntax.keys) == [b.id])
    }

    /// The diff shows, plain, while its colours are still being read.
    @Test(.timeLimit(.minutes(10))) func setDiffIsNotDelayed() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.swift", "let a = 1\n", "first")
        try repo.write("a.swift", "var a = 2\n")
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        defer { backend.releaseAll() }

        let gate = backend.hold(.blobBytes)
        store.select("a.swift", staged: false)
        let diff = try #require(await Self.shownDiff(store, "a.swift"))
        #expect(await waitUntil("the syntax read parked") { gate.waiting })
        #expect(store.diffSyntax.isEmpty)

        gate.release()
        await store.diffSyntaxTask?.value
        #expect(store.diffSyntax[diff.id] != nil)
    }

    @Test(.timeLimit(.minutes(10))) func unknownLanguageStaysEmpty() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("notes.txt", "let a = 1\n", "first")
        try repo.write("notes.txt", "var a = \"x\"\n")
        let (store, cleanup) = await openedTestStore(repo, backend: TestBackend())
        defer { cleanup() }

        store.select("notes.txt", staged: false)
        _ = try #require(await Self.shownDiff(store, "notes.txt"))
        await store.diffSyntaxTask?.value

        #expect(store.diffSyntax.isEmpty)
    }

    /// A commit's diff has abbreviated ids (no `--full-index`): both its sides are read by them,
    /// and a file the commit adds is coloured from its new side alone.
    @Test(.timeLimit(.minutes(10))) func commitDiffGetsColours() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.swift", "let a = 1\n", "first")
        try repo.write("n.swift", "let n = \"new\"\n")
        try repo.git("add", "--", "n.swift")
        try repo.commit("a.swift", "var a = \"x\"\n", "second")
        let sha = try repo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        let (store, cleanup) = await openedTestStore(repo, backend: TestBackend())
        defer { cleanup() }

        store.select(.commit(sha))
        await store.detailTask?.value
        store.selectPath("a.swift")
        let modified = try #require(await Self.shownDiff(store, "a.swift"))
        await store.diffSyntaxTask?.value
        let removed = try #require(Self.line(.removed, in: modified))
        let added = try #require(Self.line(.added, in: modified))
        #expect(store.diffSyntax[modified.id]?[removed.id]?.contains(SyntaxToken(range: 0..<3, kind: .keyword)) == true)
        #expect(store.diffSyntax[modified.id]?[added.id]?.contains(SyntaxToken(range: 8..<11, kind: .string)) == true)

        store.selectPath("n.swift")
        let new = try #require(await Self.shownDiff(store, "n.swift"))
        await store.diffSyntaxTask?.value
        let line = try #require(Self.line(.added, in: new))
        #expect(store.diffSyntax[new.id]?[line.id]?.contains(SyntaxToken(range: 0..<3, kind: .keyword)) == true)
    }
}
