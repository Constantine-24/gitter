import Foundation

/// The pure message helpers of the pending message and of Continue (split from
/// `CLIGitBackend+Continue`, E3 Task 7): where an operation's message lives, git's comment
/// rules (`core.commentChar=auto`, the trailing comment block, scissors) and `MERGE_MSG`'s name.
/// Code moved only.
extension CLIGitBackend {
    /// The branch, tag or remote-tracking branch `MERGE_MSG`'s first line names (M 26): `Merge
    /// branch 'x'`, `Merge tag 'v1'`, `Merge remote-tracking branch 'origin/x'`, each optionally
    /// followed by ` into <branch>` (a merge into anything but main or master). Anything else,
    /// and a name holding a `'`, is nil.
    static func mergedName(_ line: String) -> String? {
        for prefix in ["Merge branch '", "Merge tag '", "Merge remote-tracking branch '"] where line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count)
            let name: Substring
            if let into = rest.range(of: "' into ", options: .backwards) {
                name = rest[rest.startIndex..<into.lowerBound]
                guard !rest[into.upperBound...].isEmpty else { return nil }
            } else if rest.hasSuffix("'") {
                name = rest.dropLast()
            } else {
                return nil
            }
            return name.isEmpty || name.contains("'") ? nil : String(name)
        }
        return nil
    }

    /// Where the operation's message lives. `pending: true` is what the composer shows (a squash
    /// reads `SQUASH_MSG`, M 19); `false` is where a continue writes (rebase, pick, revert only).
    static func messageFile(of operation: RepositoryOperation, pending: Bool) -> String? {
        switch operation {
        case .rebase: return "rebase-merge/message"
        case .cherryPick, .revert: return "MERGE_MSG"
        case .merge: return pending ? "MERGE_MSG" : nil
        case .squash: return pending ? "SQUASH_MSG" : nil
        case .applyingPatches: return nil
        }
    }

    /// `text` without the lines that begin with `comment`, and without trailing blank lines.
    static func withoutComments(_ text: String, comment: String) -> String {
        var lines = text.components(separatedBy: "\n").filter { !$0.hasPrefix(comment) }
        while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// git's `core.commentChar=auto` choice (builtin/commit.c `adjust_comment_line_char`), as
    /// measured on git 2.54 (A2 Task 3, 22 messages — `ContinueTests.autoChoosesTheCharacterGitChooses`):
    /// `#` when the text holds no `#` at all; otherwise the first of `#;@!$%^&|:` that is neither
    /// the text's first byte nor the first byte of a line starting before the trailing block of
    /// comment and blank lines git ignores (`ignoredTrailingBytes`).
    static func autoCommentChar(for text: String) -> Character {
        let bytes = Array(text.utf8)
        guard bytes.contains(defaultCommentByte) else { return Character(defaultComment) }
        var candidates = Array("#;@!$%^&|:".utf8)
        func rule(out byte: UInt8) {
            if let index = candidates.firstIndex(of: byte) { candidates[index] = UInt8(ascii: " ") }
        }
        if let first = bytes.first { rule(out: first) }
        let boundary = bytes.count - ignoredTrailingBytes(bytes)
        for index in bytes.indices where bytes[index] == 0x0A || bytes[index] == 0x0D {
            if index + 1 < boundary { rule(out: bytes[index + 1]) }
        }
        // git gives up ("unable to select a comment character") when all ten start lines; the
        // commit then fails, and `#` is as good an answer as any for the prefill.
        guard let chosen = candidates.first(where: { $0 != UInt8(ascii: " ") }) else { return Character(defaultComment) }
        return Character(Unicode.Scalar(chosen))
    }

    /// How many bytes at the end of `bytes` git ignores as the message's trailing comment block
    /// (`ignored_log_message_bytes`, with `#`): a run of `#` lines and empty lines — and an old
    /// style `Conflicts:` block with its tab-indented paths — reaching the end, or everything
    /// from a scissors line. A run that starts on the very first line does not count, as in git.
    static func ignoredTrailingBytes(_ bytes: [UInt8]) -> Int {
        let cutoff = scissorsOffset(in: bytes, comment: defaultComment) ?? bytes.count
        let conflicts = Array("Conflicts:\n".utf8)
        var blockStart = 0
        var lineStart = 0
        var inOldConflictsBlock = false
        while lineStart < cutoff {
            let next = bytes[lineStart..<cutoff].firstIndex(of: 0x0A).map { $0 + 1 } ?? cutoff
            let first = bytes[lineStart]
            if first == defaultCommentByte || first == 0x0A {
                if blockStart == 0 { blockStart = lineStart }
            } else if bytes[lineStart..<cutoff].starts(with: conflicts) {
                inOldConflictsBlock = true
                if blockStart == 0 { blockStart = lineStart }
            } else if inOldConflictsBlock && first == 0x09 {
                // A path of the old conflicts block.
            } else if blockStart != 0 {
                blockStart = 0
                inOldConflictsBlock = false
            }
            lineStart = next
        }
        return blockStart != 0 ? bytes.count - blockStart : bytes.count - cutoff
    }

    /// Where git's scissors line (`<comment> ------------------------ >8 ------------------------`)
    /// begins in `bytes`, if it holds one at the start of a line.
    static func scissorsOffset(in bytes: [UInt8], comment: String) -> Int? {
        let line = Array("\(comment) ------------------------ >8 ------------------------\n".utf8)
        if bytes.starts(with: line) { return 0 }
        let pattern = [UInt8(0x0A)] + line
        guard bytes.count >= pattern.count else { return nil }
        for start in 0...(bytes.count - pattern.count) where bytes[start..<(start + pattern.count)].elementsEqual(pattern) {
            return start + 1
        }
        return nil
    }

    /// Whether git's cleanup of `message` leaves nothing: a rebase continues under `scissors`
    /// (whitespace, and a cut at a scissors line, M 29), a cherry-pick or revert strips comment
    /// lines whatever `commit.cleanup` says (measured, A2 Task 3).
    static func isEmptyAfterCleanup(_ message: String, comment: String, for operation: RepositoryOperation) -> Bool {
        let kept: String
        if operation == .rebase {
            let bytes = Array(message.utf8)
            kept = String(decoding: bytes.prefix(scissorsOffset(in: bytes, comment: comment) ?? bytes.count), as: UTF8.self)
        } else {
            kept = withoutComments(message, comment: comment)
        }
        return kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
