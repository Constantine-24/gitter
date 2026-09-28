import Foundation

/// Parses the output of `git diff --no-color -U3` / `git show --format= -U3`
/// (a unified diff) into an array of `FileDiff`.
///
/// **Lines are split on the `\n` byte, never on the `Character` `"\n"`.** Swift reads `"\r\n"`
/// as one `Character`, so a character split never breaks a CRLF line: a whole CRLF hunk used
/// to arrive as a single line, and every patch built from it was wrong. Split on the byte,
/// each line keeps its own trailing `\r` as content, and `PatchBuilder` gives it back byte
/// for byte. A hunk line's marker (` `, `+`, `-`, `\`) is likewise read as its first byte, so
/// content that starts with a combining mark — which Swift would glue to the marker into one
/// `Character` — is still recognised and kept whole.
public enum DiffParser {
    public static func parse(_ data: Data) -> [FileDiff] {
        guard !data.isEmpty else { return [] }

        var raw = [UInt8](data).split(separator: newline, omittingEmptySubsequences: false)
        if raw.last?.isEmpty == true {
            raw.removeLast()
        }
        let lines = raw.map { String(decoding: $0, as: UTF8.self) }

        var files: [FileDiff] = []
        var index = 0

        while index < lines.count {
            guard let header = parseDiffGitHeader(lines[index]) else {
                index += 1
                continue
            }
            let firstLine = index
            index += 1

            var oldPath: String? = header.oldPath
            var newPath: String? = header.newPath
            var kind: FileDiffKind = .modified
            var isBinary = false
            var blobs: (old: String, new: String)?
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
                } else if hunks.isEmpty, let ids = parseIndexLine(line) {
                    blobs = ids
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
                        // The marker is the first byte and the text every byte after it.
                        let hunkLine = raw[index]
                        let text = String(decoding: hunkLine.dropFirst(), as: UTF8.self)
                        switch hunkLine.first {
                        case UInt8(ascii: " "):
                            hunkLines.append(
                                DiffLine(
                                    id: lineCounter, kind: .context, oldNumber: oldNumber,
                                    newNumber: newNumber, text: text
                                )
                            )
                            lineCounter += 1
                            oldNumber += 1
                            newNumber += 1
                            index += 1
                        case UInt8(ascii: "+"):
                            hunkLines.append(
                                DiffLine(
                                    id: lineCounter, kind: .added, oldNumber: nil,
                                    newNumber: newNumber, text: text
                                )
                            )
                            lineCounter += 1
                            newNumber += 1
                            index += 1
                        case UInt8(ascii: "-"):
                            hunkLines.append(
                                DiffLine(
                                    id: lineCounter, kind: .removed, oldNumber: oldNumber,
                                    newNumber: nil, text: text
                                )
                            )
                            lineCounter += 1
                            oldNumber += 1
                            index += 1
                        case UInt8(ascii: "\\"):
                            // `\ No newline at end of file`: the text after the `"\ "`.
                            hunkLines.append(
                                DiffLine(
                                    id: lineCounter, kind: .noNewline, oldNumber: nil,
                                    newNumber: nil,
                                    text: String(decoding: hunkLine.dropFirst(2), as: UTF8.self)
                                )
                            )
                            lineCounter += 1
                            index += 1
                        default:
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

            // Every byte of this file's part, header included, checked before the lossy
            // decoding above is trusted: see `FileDiff.isValidUTF8`.
            let isValidUTF8 = raw[firstLine..<index].allSatisfy { String(validating: $0, as: UTF8.self) != nil }
            files.append(
                FileDiff(
                    oldPath: oldPath, newPath: newPath, kind: kind, isBinary: isBinary, hunks: hunks,
                    oldBlob: blobs?.old, newBlob: blobs?.new, isValidUTF8: isValidUTF8)
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

    private static let newline = UInt8(ascii: "\n")

    /// `index <old>..<new>`, with ` <mode>` after it when the mode did not change. The ids are
    /// whatever length git printed: full under `--full-index`, abbreviated otherwise.
    private static func parseIndexLine(_ line: String) -> (old: String, new: String)? {
        guard let match = line.wholeMatch(of: /^index ([0-9a-f]+)\.\.([0-9a-f]+)(?: [0-7]+)?$/)
        else { return nil }
        return (String(match.1), String(match.2))
    }

    /// The section heading after the second `@@` is free text from the file (a function
    /// line), so `.` has to match a `\r` in it too, or the whole hunk would go unrecognised.
    private static func parseHunkHeader(_ line: String) -> HunkStart? {
        guard
            let match = line.wholeMatch(
                of: /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$/.dotMatchesNewlines())
        else { return nil }
        let oldStart = Int(match.1) ?? 0
        let oldCount = match.2.map { Int($0) ?? 1 } ?? 1
        let newStart = Int(match.3) ?? 0
        let newCount = match.4.map { Int($0) ?? 1 } ?? 1
        return HunkStart(header: line, oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount)
    }
}
