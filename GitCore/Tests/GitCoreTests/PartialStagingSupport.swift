import Foundation
import Testing

@testable import GitCore

// Helpers shared by the line-staging round trips in PartialStagingTests and
// PartialStagingNewlineTests. Everything here drives the real pipeline the app uses:
// `workingCopyDiff` → `PatchBuilder.patch` → `applyToIndex`, against a real repository.

/// The diff for one file, exactly as the app loads it before handing it to `PatchBuilder`.
func loadDiff(_ repo: TestRepo, _ path: String, staged: Bool = false) async throws -> FileDiff {
    let files = try await CLIGitBackend().workingCopyDiff(at: repo.root, path: path, staged: staged)
    return try #require(files.first, "no diff for \(path) (staged: \(staged))")
}

func everyHunkID(_ file: FileDiff) -> Set<Hunk.ID> { Set(file.hunks.map(\.id)) }

/// The IDs of the changed (`+`/`-`) lines whose text is one of `texts`.
func changedLineIDs(_ file: FileDiff, _ texts: String...) -> Set<DiffLine.ID> {
    Set(
        file.hunks.flatMap(\.lines)
            .filter { ($0.kind == .added || $0.kind == .removed) && texts.contains($0.text) }
            .map(\.id)
    )
}

/// The ID of the hunk holding a changed line with text `text`.
func hunkID(_ file: FileDiff, containing text: String) throws -> Hunk.ID {
    let hunk = try #require(
        file.hunks.first { hunk in
            hunk.lines.contains { $0.text == text && ($0.kind == .added || $0.kind == .removed) }
        },
        "no hunk changes a line reading \(text.debugDescription)"
    )
    return hunk.id
}

/// Builds the patch for a selection and applies it to the index, returning what was applied.
@discardableResult
func applySelection(
    _ repo: TestRepo, _ file: FileDiff, direction: PatchDirection,
    hunks: Set<Hunk.ID>? = nil, lines: Set<DiffLine.ID>? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> Patch {
    let patch = try #require(
        PatchBuilder.patch(
            file: file, hunkIDs: hunks ?? everyHunkID(file), lineIDs: lines, direction: direction),
        "PatchBuilder returned nil for this selection",
        sourceLocation: sourceLocation
    )
    try await CLIGitBackend().applyToIndex(
        patch: patch, reverse: direction == .unstage, at: repo.root)
    return patch
}

/// Every changed line of one side of the working copy, rendered the way the diff shows it.
func changedLines(_ repo: TestRepo, _ path: String, staged: Bool) async throws -> [String] {
    let files = try await CLIGitBackend().workingCopyDiff(at: repo.root, path: path, staged: staged)
    return files.flatMap(\.hunks).flatMap(\.lines).compactMap { line in
        switch line.kind {
        case .added: return "+" + line.text
        case .removed: return "-" + line.text
        case .context, .noNewline: return nil
        }
    }
}

/// The index entry's bytes, decoded for readable failure messages. Comparisons stay exact:
/// `String(decoding:as:)` is lossless for the UTF-8 content these tests write.
func indexText(_ repo: TestRepo, _ path: String) async throws -> String {
    String(decoding: try await repo.indexContent(of: path), as: UTF8.self)
}

/// Fails if any line of `content` is two of `sources` glued together.
///
/// That is the exact shape of the silent corruption a wrong `\ No newline at end of file`
/// marker causes: `git apply` joins the line before the marker with the one after it
/// (`old` + `one` → `oldone`) and reports success.
func expectNoJoinedLines(
    _ content: String, sources: [String], sourceLocation: SourceLocation = #_sourceLocation
) {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let parts = sources.filter { !$0.isEmpty }
    for line in lines {
        for first in parts {
            for second in parts where line == first + second {
                Issue.record(
                    Comment(
                        rawValue: "index line \(line.debugDescription) is "
                            + "\(first.debugDescription) joined to \(second.debugDescription)"
                            + " — a no-newline marker corrupted the index"),
                    sourceLocation: sourceLocation
                )
            }
        }
    }
}
