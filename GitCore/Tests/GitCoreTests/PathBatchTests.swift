import Foundation
import Testing

@testable import GitCore

/// The two ways a path list reaches git without one argument per path (Ruling 26): the batches
/// of a read, and the pathspec file of a write.
@Suite struct PathBatchTests {

    // MARK: - Batches of a read

    @Test func batchesHoldAtMostTheLimitInOrder() {
        let paths = (0..<2_500).map { "p\($0)" }
        let batches = CLIGitBackend.pathBatches(paths)
        #expect(batches.map(\.count) == [1_000, 1_000, 500])
        #expect(Array(batches.joined()) == paths)
    }

    /// The byte cap keeps a batch of long names under macOS's 1 MiB `ARG_MAX` (E2BIG is a
    /// thrown launch failure, not a crash, but a failure all the same). A name longer than the
    /// cap goes alone rather than not at all.
    @Test func batchesHoldAtMostTheByteCap() {
        let long = String(repeating: "x", count: 100_000)
        let paths = (0..<6).map { long + "\($0)" } + [String(repeating: "y", count: 400_000)]
        let batches = CLIGitBackend.pathBatches(paths, bytes: 256 * 1024)
        #expect(Array(batches.joined()) == paths)
        #expect(batches.map(\.count) == [2, 2, 2, 1])
    }

    /// No paths is one call with none, as before the batching: what such a read does is the
    /// caller's to decide (every caller passes at least one).
    @Test func noPathsIsOneEmptyBatch() {
        #expect(CLIGitBackend.pathBatches([]) == [[]])
    }

    /// A path another named path covers — equal, or under it as a directory — is left out of a
    /// batched read; `d` covers `d/`, not the other way round; order is kept.
    @Test func coveredPathsAreLeftOut() {
        let named = ["a/b", "a", "c/", "c/d", "c", "e", "e", "f/", "f/g/h", "ab", "a b"]
        #expect(CLIGitBackend.withoutCoveredPaths(named) == ["a", "c", "e", "f/", "ab", "a b"])
    }

    // MARK: - The pathspec file of a write

    /// Each path as a literal pathspec, NUL-terminated, in a file of its own that is gone once
    /// the body returns — or throws.
    @Test func thePathspecFileHoldsLiteralPathspecsAndIsRemoved() async throws {
        let backend = CLIGitBackend()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-pathspec-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var seen = ""
        let bytes = try await backend.withPathspecFile(["a*.txt", "new\nline", ":c"], in: directory) { path in
            seen = path
            return try Data(contentsOf: URL(fileURLWithPath: path))
        }
        #expect(bytes == Data(":(literal)a*.txt\0:(literal)new\nline\0:(literal):c\0".utf8))
        #expect(seen.hasPrefix(directory.path + "/"))
        #expect(!FileManager.default.fileExists(atPath: seen))

        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await backend.withPathspecFile(["a"], in: directory) { path -> Void in
                seen = path
                throw Boom()
            }
        }
        #expect(!FileManager.default.fileExists(atPath: seen))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
