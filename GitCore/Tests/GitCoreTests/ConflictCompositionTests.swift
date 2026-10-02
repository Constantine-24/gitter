import Foundation
import Testing

@testable import GitCore

/// The public, pure halves the app shares with the resolver's writes (A2 Task 5): the bytes a
/// set of block choices composes to — the resolver's preview — and the worktree hash a snapshot
/// carries — what Reopen expects. Each is checked against what GitCore itself writes or reads
/// on a real conflict, so the app's preview cannot drift from the file a Resolve File writes.
@Suite struct ConflictCompositionTests {

    static let backend = CLIGitBackend()

    @Test func eachChoiceComposesTheBlocksBytes() {
        let block = ConflictBlock(ours: Data("o\n".utf8), base: Data("b\n".utf8), theirs: Data("t\r\n".utf8))
        #expect(block.composed(.ours) == Data("o\n".utf8))
        #expect(block.composed(.theirs) == Data("t\r\n".utf8))
        #expect(block.composed(.oursThenTheirs) == Data("o\nt\r\n".utf8))
        #expect(block.composed(.theirsThenOurs) == Data("t\r\no\n".utf8))
    }

    @Test func aFileComposesOnlyWithOneChoicePerBlock() {
        let segments: [ConflictSegment] = [
            .common(Data("a\n".utf8)),
            .block(ConflictBlock(ours: Data("o\n".utf8), base: nil, theirs: Data("t\n".utf8))),
            .common(Data("z\n".utf8)),
        ]
        #expect(ConflictSegment.composed(segments, choices: [.theirsThenOurs]) == Data("a\nt\no\nz\n".utf8))
        #expect(ConflictSegment.composed(segments, choices: []) == nil)
        #expect(ConflictSegment.composed(segments, choices: [.ours, .ours]) == nil)
    }

    /// The fixture's last segment is common text, so `resolve` writes exactly the composition:
    /// what the app previews is what lands in the file.
    @Test(arguments: ConflictWriteTests.choiceCases)
    func theCompositionIsWhatResolveWrites(choices: [BlockChoice]) async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let document = try await ConflictReadTests.document(repo, "f.txt")
        guard case .blocks(let segments) = document.presentation else {
            Issue.record("the fixture shows no blocks")
            return
        }
        guard case .common? = segments.last else {
            Issue.record("the fixture does not end in common text")
            return
        }
        let preview = try #require(ConflictSegment.composed(segments, choices: choices))

        _ = try await Self.backend.resolve(document.snapshot, choices: choices, recordIfEdited: false, at: repo.root)

        #expect(try repo.bytes("f.txt") == preview)
    }

    @Test func theWorktreeHashIsTheSnapshotsHash() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let document = try await ConflictReadTests.document(repo, "f.txt")
        let hash = try #require(ConflictSnapshot.worktreeHash(of: "f.txt", at: repo.root))
        #expect(hash == document.snapshot.worktreeHash)
        #expect(hash.count == 64)

        try repo.write("f.txt", "edited\n")
        #expect(ConflictSnapshot.worktreeHash(of: "f.txt", at: repo.root) != document.snapshot.worktreeHash)
        #expect(ConflictSnapshot.worktreeHash(of: "absent.txt", at: repo.root) == nil)
    }
}
