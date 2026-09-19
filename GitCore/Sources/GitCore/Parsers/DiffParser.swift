import Foundation

/// Parses the output of `git diff --no-color -U3` / `git show --format= -U3`
/// (a unified diff) into an array of `FileDiff`.
public enum DiffParser {
    public static func parse(_ data: Data) -> [FileDiff] {
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { return [] }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }

        var files: [FileDiff] = []
        var index = 0

        while index < lines.count {
            guard let header = parseDiffGitHeader(lines[index]) else {
                index += 1
                continue
            }
            index += 1

            var oldPath: String? = header.oldPath
            var newPath: String? = header.newPath
            var kind: FileDiffKind = .modified
            var isBinary = false
            var hunks: [Hunk] = []
            var lineCounter = 0

            while index < lines.count {
                let line = lines[index]

                if line.hasPrefix("diff --git ") {
                    break
                } else if line.hasPrefix("new file mode") {
                    kind = .added
                    index += 1
                } else if line.hasPrefix("deleted file mode") {
                    kind = .deleted
                    index += 1
                } else if line.hasPrefix("rename from ") {
                    oldPath = unquoteIfNeeded(String(line.dropFirst("rename from ".count)))
                    kind = .renamed
                    index += 1
                } else if line.hasPrefix("rename to ") {
                    newPath = unquoteIfNeeded(String(line.dropFirst("rename to ".count)))
                    kind = .renamed
                    index += 1
                } else if line.hasPrefix("copy from ") {
                    oldPath = unquoteIfNeeded(String(line.dropFirst("copy from ".count)))
                    kind = .copied
                    index += 1
                } else if line.hasPrefix("copy to ") {
                    newPath = unquoteIfNeeded(String(line.dropFirst("copy to ".count)))
                    kind = .copied
                    index += 1
                } else if line.hasPrefix("Binary files ") && line.hasSuffix(" differ") {
                    isBinary = true
                    index += 1
                } else if line.hasPrefix("GIT binary patch") {
                    isBinary = true
                    index += 1
                } else if line.hasPrefix("--- ") {
                    oldPath = parseUnifiedPath(line, markerLength: 4, prefix: "a/")
                    index += 1
                } else if line.hasPrefix("+++ ") {
                    newPath = parseUnifiedPath(line, markerLength: 4, prefix: "b/")
                    index += 1
                } else if let hunkStart = parseHunkHeader(line) {
                    index += 1
                    var hunkLines: [DiffLine] = []
                    var oldNumber = hunkStart.oldStart
                    var newNumber = hunkStart.newStart

                    hunkLoop: while index < lines.count {
                        let hunkLine = lines[index]
                        if hunkLine.hasPrefix(" ") {
                            hunkLines.append(
                                DiffLine(
                                    id: lineCounter, kind: .context, oldNumber: oldNumber,
                                    newNumber: newNumber, text: String(hunkLine.dropFirst(1))
                                )
                            )
                            lineCounter += 1
                            oldNumber += 1
                            newNumber += 1
                            index += 1
                        } else if hunkLine.hasPrefix("+") {
                            hunkLines.append(
                                DiffLine(
                                    id: lineCounter, kind: .added, oldNumber: nil,
                                    newNumber: newNumber, text: String(hunkLine.dropFirst(1))
                                )
                            )
                            lineCounter += 1
                            newNumber += 1
                            index += 1
                        } else if hunkLine.hasPrefix("-") {
                            hunkLines.append(
                                DiffLine(
                                    id: lineCounter, kind: .removed, oldNumber: oldNumber,
                                    newNumber: nil, text: String(hunkLine.dropFirst(1))
                                )
                            )
                            lineCounter += 1
                            oldNumber += 1
                            index += 1
                        } else if hunkLine.hasPrefix("\\") {
                            hunkLines.append(
                                DiffLine(
                                    id: lineCounter, kind: .noNewline, oldNumber: nil,
                                    newNumber: nil, text: String(hunkLine.dropFirst(min(2, hunkLine.count)))
                                )
                            )
                            lineCounter += 1
                            index += 1
                        } else {
                            break hunkLoop
                        }
                    }

                    hunks.append(
                        Hunk(
                            header: hunkStart.header, oldStart: hunkStart.oldStart,
                            oldCount: hunkStart.oldCount, newStart: hunkStart.newStart,
                            newCount: hunkStart.newCount, lines: hunkLines
                        )
                    )
                } else {
                    index += 1
                }
            }

            files.append(
                FileDiff(oldPath: oldPath, newPath: newPath, kind: kind, isBinary: isBinary, hunks: hunks)
            )
        }

        return files
    }

    // MARK: - Hunk header parsing

    private struct HunkStart {
        let header: String
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
    }

    private static func parseHunkHeader(_ line: String) -> HunkStart? {
        guard let match = line.wholeMatch(of: /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$/) else { return nil }
        let oldStart = Int(match.1) ?? 0
        let oldCount = match.2.map { Int($0) ?? 1 } ?? 1
        let newStart = Int(match.3) ?? 0
        let newCount = match.4.map { Int($0) ?? 1 } ?? 1
        return HunkStart(header: line, oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount)
    }
}
