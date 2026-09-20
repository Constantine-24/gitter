import Foundation

/// Scans Swift source text for git invocations that could destroy uncommitted work.
///
/// This milestone's safety promise — "Gitter never discards uncommitted work or commits
/// without a confirmation that names what will be lost" — rests entirely on the *absence* of
/// certain git flags. An absence is invisible in a diff, so the suite enforces it directly.
///
/// How it works: comments and string contents are lexed away first, then every array literal
/// is read as a candidate argument vector (`["switch", "--detach", rev]`). Elements that are
/// plain string literals become their value; anything else becomes `nil`, so an array mixing
/// literals and variables still gets checked for the literals it does contain. Rules are then
/// applied per git subcommand, because the same token can be safe or fatal depending on it:
/// `reset --merge` is how a pending squash is undone, while `switch --merge` silently merges
/// local changes into the branch being switched to.
///
/// Known limits, stated so nobody mistakes this for a proof:
///
/// - It only sees flags written as string literals in an array literal. A flag built at
///   runtime (`"--" + verb`), read from config, or passed in by a caller is invisible to it.
/// - It has no idea which array literals actually reach git; a non-git array whose first
///   element happens to be `"clean"` would be flagged. That false positive is the safe
///   direction and has not come up.
/// - It parses text, not Swift. Multi-line (`"""`) and raw (`#"..."#`) string literals are
///   not understood and could shift the element boundaries; `GitCore/Sources` contains
///   neither, and the whole-file literal sweep still catches an always-forbidden token
///   wherever it sits.
/// - It covers `GitCore/Sources` only — deliberately, since this file's own rule tables would
///   otherwise flag themselves. The app target runs no git commands of its own.
enum ForceFlagScanner {
    /// A human-readable description of each violation found in `source`, empty when clean.
    static func findings(in source: String) -> [String] {
        let code = strippingCommentsAndStringContents(source)
        var findings: [String] = []

        for (token, literal) in literals(in: source, code: code) where alwaysForbidden.contains(literal) {
            findings.append("forbidden literal \(literal.debugDescription) (offset \(token))")
        }

        for arguments in argumentArrays(in: source, code: code) {
            guard let subcommand = arguments.first ?? nil else { continue }
            let flags = arguments.compactMap { $0 }.dropFirst()

            if let reason = forbiddenSubcommands[subcommand] {
                findings.append("forbidden git subcommand \(subcommand.debugDescription): \(reason)")
                continue
            }
            for flag in flags where (forbiddenFlags[subcommand] ?? [:])[flag] != nil {
                let reason = forbiddenFlags[subcommand]![flag]!
                findings.append("forbidden `git \(subcommand) \(flag)`: \(reason)")
            }
        }
        return findings
    }

    /// Every `.swift` file under `GitCore/Sources`, keyed by path relative to that directory.
    static func gitCoreSources(root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return result }
        for case let relativePath as String in enumerator where relativePath.hasSuffix(".swift") {
            let url = root.appendingPathComponent(relativePath)
            result[relativePath] = try String(contentsOf: url, encoding: .utf8)
        }
        return result
    }

    // MARK: - The rules

    /// Tokens that are fatal wherever they appear, whatever command they belong to.
    static let alwaysForbidden: Set<String> = [
        "--force", "-f", "--force-with-lease", "--discard-changes", "--hard", "--ignore-unmerged",
    ]

    /// Subcommands Gitter must never run at all. `checkout` is here because `git checkout --
    /// <path>` overwrites a file with no confirmation and no recovery; `switch` and `restore
    /// --staged` cover everything Gitter legitimately needs.
    static let forbiddenSubcommands: [String: String] = [
        "clean": "deletes untracked files outright",
        "stash": "moves the user's changes somewhere they did not ask for",
        "checkout": "`checkout -- <path>` discards a file's changes with no undo",
    ]

    /// Per-subcommand flags. The allow-list is what is *absent* here: `branch -D` (behind a
    /// second confirmation), the `--abort` family, and `reset --merge` (undoing a pending
    /// squash) are all permitted, and later tasks in this milestone add them.
    static let forbiddenFlags: [String: [String: String]] = [
        "switch": [
            "-f": "force", "--force": "force", "--discard-changes": "throws local changes away",
            "-C": "force-creates over an existing branch", "--merge": "merges local changes in silently",
            "--ours": "resolves conflicts by discarding one side",
            "--theirs": "resolves conflicts by discarding one side",
        ],
        "branch": [
            "-M": "force-renames over an existing branch", "-C": "force-copies over an existing branch",
            "--force": "force", "-f": "force",
        ],
        "reset": ["--keep": "can still discard local changes"],  // `--hard` is always forbidden
        "restore": [
            "--worktree": "overwrites files on disk", "-W": "overwrites files on disk",
            "--source": "overwrites files on disk from another commit",
        ],
        "merge": ["-f": "force", "--force": "force"],
    ]

    // MARK: - Lexing

    /// `code` with every comment and every string literal's *contents* replaced by spaces, so
    /// brackets, commas and quotes inside them cannot shift the parse. Offsets line up with
    /// `source` byte for byte (UTF-8 scalar for scalar), so a literal's position in `code`
    /// indexes straight back into `source`.
    private static func strippingCommentsAndStringContents(_ source: String) -> [Character] {
        var out: [Character] = []
        out.reserveCapacity(source.count)
        var characters = Array(source)
        var index = 0
        var blockDepth = 0

        while index < characters.count {
            let c = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : "\0"

            if blockDepth > 0 {
                if c == "*", next == "/" { blockDepth -= 1; out.append(contentsOf: "  "); index += 2; continue }
                if c == "/", next == "*" { blockDepth += 1; out.append(contentsOf: "  "); index += 2; continue }
                out.append(c == "\n" ? "\n" : " ")
                index += 1
                continue
            }
            if c == "/", next == "*" { blockDepth = 1; out.append(contentsOf: "  "); index += 2; continue }
            if c == "/", next == "/" {
                while index < characters.count, characters[index] != "\n" { out.append(" "); index += 1 }
                continue
            }
            if c == "\"" {
                // Keep the quotes (so literals stay findable) and blank the contents.
                out.append("\"")
                index += 1
                while index < characters.count {
                    let s = characters[index]
                    if s == "\\", index + 1 < characters.count {
                        out.append(contentsOf: "  ")
                        index += 2
                        continue
                    }
                    if s == "\"" { out.append("\""); index += 1; break }
                    out.append(s == "\n" ? "\n" : " ")
                    index += 1
                }
                continue
            }
            out.append(c)
            index += 1
        }
        characters = []
        return out
    }

    /// Every string literal in the file as (offset in `source`, value).
    private static func literals(in source: String, code: [Character]) -> [(Int, String)] {
        let raw = Array(source)
        var result: [(Int, String)] = []
        var index = 0
        while index < code.count {
            guard code[index] == "\"" else { index += 1; continue }
            var end = index + 1
            while end < code.count, code[end] != "\"" { end += 1 }
            guard end < code.count else { break }
            result.append((index, String(raw[(index + 1)..<end])))
            index = end + 1
        }
        return result
    }

    /// Each `[...]` array literal's top-level elements: the literal's value, or nil for an
    /// element that is not a plain string literal.
    private static func argumentArrays(in source: String, code: [Character]) -> [[String?]] {
        let raw = Array(source)
        var result: [[String?]] = []

        for open in code.indices where code[open] == "[" {
            var depth = 0
            var close = open
            var found = false
            while close < code.count {
                if "[({".contains(code[close]) { depth += 1 }
                if "])}".contains(code[close]) {
                    depth -= 1
                    if depth == 0 { found = true; break }
                }
                close += 1
            }
            guard found, close > open + 1 else { continue }
            result.append(elements(raw: raw, code: code, from: open + 1, to: close))
        }
        return result
    }

    private static func elements(
        raw: [Character], code: [Character], from start: Int, to end: Int
    ) -> [String?] {
        var elements: [String?] = []
        var current: [Character] = []
        var currentLiteral: String?
        var literalCount = 0
        var depth = 0
        var index = start

        func flush() {
            let trimmed = String(current).trimmingCharacters(in: .whitespacesAndNewlines)
            elements.append(literalCount == 1 && trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")
                ? currentLiteral : nil)
            current = []
            currentLiteral = nil
            literalCount = 0
        }

        while index < end {
            let c = code[index]
            if "[({".contains(c) { depth += 1 }
            if "])}".contains(c) { depth -= 1 }
            if c == "," && depth == 0 { flush(); index += 1; continue }
            if c == "\"" {
                var stop = index + 1
                while stop < end, code[stop] != "\"" { stop += 1 }
                guard stop < end else { break }
                currentLiteral = String(raw[(index + 1)..<stop])
                literalCount += 1
                current += ["\"", "\""]
                index = stop + 1
                continue
            }
            current.append(c)
            index += 1
        }
        flush()
        return elements
    }
}
