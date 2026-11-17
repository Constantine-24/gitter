import Foundation
import GitCoreTestSupport
import Testing
@testable import GitCore

/// `blobBytes(_:at:limit:)` (syntax colours Task 3): a blob's raw bytes by id, for the diff
/// view's colours — `cat-file -s`, then `cat-file blob`, on a real scratch repository.
@Suite struct BlobBytesTests {
    /// A repository with `a.swift` committed, and that file's blob id.
    private func repository(_ contents: String) async throws -> (TestRepo, String) {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("a.swift", contents)
        try await repo.commitAll("root")
        let id = String(decoding: try await repo.git(["rev-parse", "HEAD:a.swift"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (repo, id)
    }

    @Test func readsABlob() async throws {
        let (repo, id) = try await repository("let a = 1\r\nlet b = 2\n")
        defer { repo.cleanUp() }

        let bytes = try await CLIGitBackend().blobBytes(id, at: repo.root, limit: 1_000)

        #expect(bytes == Data("let a = 1\r\nlet b = 2\n".utf8))
    }

    /// An abbreviated id (a commit diff's `index` line has no `--full-index`) reads the same blob.
    @Test func readsABlobByAnAbbreviatedID() async throws {
        let (repo, id) = try await repository("let a = 1\n")
        defer { repo.cleanUp() }

        let bytes = try await CLIGitBackend().blobBytes(String(id.prefix(12)), at: repo.root, limit: 1_000)

        #expect(bytes == Data("let a = 1\n".utf8))
    }

    /// The all-zeros id is git's name for a side that does not exist: nil, and git never runs.
    @Test func allZerosIsNil() async throws {
        let (repo, _) = try await repository("let a = 1\n")
        defer { repo.cleanUp() }
        let log = RecordingLog()
        let backend = CLIGitBackend(commandLog: log)

        #expect(try await backend.blobBytes(String(repeating: "0", count: 40), at: repo.root, limit: 1_000) == nil)
        #expect(try await backend.blobBytes("0000000", at: repo.root, limit: 1_000) == nil)
        #expect(log.all.isEmpty)
    }

    /// Over the limit: nil after the size read, and the blob itself is never read.
    @Test func overLimitIsNil() async throws {
        let (repo, id) = try await repository("123456789\n")
        defer { repo.cleanUp() }
        let log = RecordingLog()
        let backend = CLIGitBackend(commandLog: log)

        #expect(try await backend.blobBytes(id, at: repo.root, limit: 3) == nil)
        #expect(log.all.map(\.arguments) == [["cat-file", "-s", id]])
        // At the limit exactly, it is read.
        #expect(try await backend.blobBytes(id, at: repo.root, limit: 10) == Data("123456789\n".utf8))
    }

    @Test func missingObjectThrows() async throws {
        let (repo, _) = try await repository("let a = 1\n")
        defer { repo.cleanUp() }

        await #expect(throws: GitError.self) {
            _ = try await CLIGitBackend().blobBytes(String(repeating: "1", count: 40), at: repo.root, limit: 1_000)
        }
    }

    /// Only hex reaches git: anything else could be read as an option or a revision.
    @Test func aNameThatIsNotHexThrowsWithoutRunningGit() async throws {
        let (repo, _) = try await repository("let a = 1\n")
        defer { repo.cleanUp() }
        let log = RecordingLog()
        let backend = CLIGitBackend(commandLog: log)

        for name in ["--batch", "HEAD:a.swift", "", "ABCDEF1"] {
            await #expect(throws: (any Error).self) {
                _ = try await backend.blobBytes(name, at: repo.root, limit: 1_000)
            }
        }
        #expect(log.all.isEmpty)
    }
}
