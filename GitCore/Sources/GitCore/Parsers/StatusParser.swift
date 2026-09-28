import Foundation

/// Parses the output of `git status --porcelain=v2 -z --branch` into a `WorkingCopyStatus`.
public enum StatusParser {
    public static func parse(_ data: Data) -> WorkingCopyStatus {
        let text = String(decoding: data, as: UTF8.self)
        let records = text.split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)

        var headSha: String?
        var branch: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var files: [FileStatus] = []

        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1

            if record.hasPrefix("# branch.oid ") {
                let value = String(record.dropFirst("# branch.oid ".count))
                headSha = value == "(initial)" ? nil : value
            } else if record.hasPrefix("# branch.head ") {
                let value = String(record.dropFirst("# branch.head ".count))
                branch = value == "(detached)" ? nil : value
            } else if record.hasPrefix("# branch.upstream ") {
                upstream = String(record.dropFirst("# branch.upstream ".count))
            } else if record.hasPrefix("# branch.ab ") {
                let value = record.dropFirst("# branch.ab ".count)
                let parts = value.split(separator: " ", omittingEmptySubsequences: true)
                for part in parts {
                    if part.hasPrefix("+"), let n = Int(part.dropFirst()) {
                        ahead = n
                    } else if part.hasPrefix("-"), let n = Int(part.dropFirst()) {
                        behind = n
                    }
                }
            } else if record.hasPrefix("1 ") {
                guard let file = parseOrdinary(record) else { continue }
                files.append(file)
            } else if record.hasPrefix("2 ") {
                guard index < records.count else { continue }
                let originalPath = records[index]
                index += 1
                guard let file = parseRename(record, originalPath: originalPath) else { continue }
                files.append(file)
            } else if record.hasPrefix("u ") {
                guard let file = parseUnmerged(record) else { continue }
                files.append(file)
            } else if record.hasPrefix("? ") {
                let path = String(record.dropFirst(2))
                files.append(FileStatus(path: path, originalPath: nil, staged: nil, unstaged: .untracked))
            } else if record.hasPrefix("! ") {
                let path = String(record.dropFirst(2))
                files.append(FileStatus(path: path, originalPath: nil, staged: nil, unstaged: .ignored))
            }
            // Anything else is skipped.
        }

        files.sort { $0.path < $1.path }

        return WorkingCopyStatus(
            headSha: headSha, branch: branch, upstream: upstream,
            ahead: ahead, behind: behind, files: files
        )
    }

    /// `1 XY sub mH mI mW hH hI path`
    private static func parseOrdinary(_ record: String) -> FileStatus? {
        let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard fields.count == 9 else { return nil }
        let xy = fields[1]
        guard let x = xy.first, let y = xy.dropFirst().first else { return nil }
        let path = String(fields[8])
        return FileStatus(
            path: path, originalPath: nil,
            staged: ChangeKind.from(porcelain: x), unstaged: ChangeKind.from(porcelain: y),
            isSubmodule: isSubmodule(fields[2]), isIntentToAdd: isIntentToAdd(y)
        )
    }

    /// `2 XY sub mH mI mW hH hI Xscore path`, followed separately by the original path.
    private static func parseRename(_ record: String, originalPath: String) -> FileStatus? {
        let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
        guard fields.count == 10 else { return nil }
        let xy = fields[1]
        guard let x = xy.first, let y = xy.dropFirst().first else { return nil }
        let path = String(fields[9])
        return FileStatus(
            path: path, originalPath: originalPath,
            staged: ChangeKind.from(porcelain: x), unstaged: ChangeKind.from(porcelain: y),
            isSubmodule: isSubmodule(fields[2]), isIntentToAdd: isIntentToAdd(y)
        )
    }

    /// The `sub` field: `N...` for an ordinary path, `S<c><m><u>` for a submodule.
    private static func isSubmodule(_ sub: Substring) -> Bool {
        sub.first == "S"
    }

    /// Whether the worktree side says the index entry is intent-to-add (`git add -N`).
    ///
    /// Measured on git 2.54, porcelain v2 shows such an entry as `1 .A N... 000000 000000
    /// 100644 <zeros> <zeros> path` — zero modes and shas, not the empty blob `ls-files -s`
    /// shows (M A.0). The worktree side (Y) can only be `A` for an intent-to-add entry, since
    /// a path the index does not hold is untracked (`?`) instead. It can only be `R` for one
    /// too: git pairs a deleted i-t-a entry with a new i-t-a entry as a worktree rename
    /// (`2 .R N... … R100 e`, then `q`), and the new path is the i-t-a entry. The deleted one
    /// has no status line of its own then. `C` is the same pairing under
    /// `status.renames=copies`.
    private static func isIntentToAdd(_ y: Character) -> Bool {
        y == "A" || y == "R" || y == "C"
    }

    /// `u XY sub m1 m2 m3 mW h1 h2 h3 path`
    private static func parseUnmerged(_ record: String) -> FileStatus? {
        let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
        guard fields.count == 11 else { return nil }
        let path = String(fields[10])
        return FileStatus(path: path, originalPath: nil, staged: .unmerged, unstaged: .unmerged)
    }
}
