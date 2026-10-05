import Foundation

/// Parses `git worktree list --porcelain -z` (B3 R13) into `Worktree`s, in git's order — the main
/// worktree first, then the linked ones sorted by path bytes.
///
/// Each attribute is `key[ value]` ending in a NUL, and a record ends with one more NUL (an empty
/// field). `-z` is what makes this exact: without it a newline in a path is printed raw and splits
/// the record, while a lock reason is C-quoted. With it both are raw, so a path or a lock reason
/// is taken verbatim — newlines, tabs and control characters included. A NUL cannot be in either.
///
/// Keys measured on git 2.54: `worktree <abs path>`, `HEAD <id>`, `branch refs/heads/<b>`,
/// `detached`, `bare`, `locked[ <reason>]` (`lock --reason ""` prints a bare `locked`) and
/// `prunable <reason>`. Anything else is skipped, so a key a later git adds is ignored rather than
/// misread; a record with no `worktree` line is dropped. `operationBranch` is not in the output:
/// `GitWorktreeBackend.worktrees` reads it from the state files.
public enum WorktreeListParser {
    public static func parse(_ data: Data) -> [Worktree] {
        var result: [Worktree] = []
        var fields: [String] = []
        for field in data.split(separator: 0, omittingEmptySubsequences: false) {
            if field.isEmpty {
                if let worktree = record(fields, isFirst: result.isEmpty) { result.append(worktree) }
                fields = []
            } else {
                fields.append(String(decoding: field, as: UTF8.self))
            }
        }
        if let worktree = record(fields, isFirst: result.isEmpty) { result.append(worktree) }
        return result
    }

    private static func record(_ fields: [String], isFirst: Bool) -> Worktree? {
        var path: String?
        var head: String?
        var branch: String?
        var bare = false
        var lock: WorktreeLock?
        var missing: String?
        for field in fields {
            let key = field.prefix { $0 != " " }
            let value = field.count > key.count ? String(field.dropFirst(key.count + 1)) : nil
            switch key {
            case "worktree": path = value
            case "HEAD": head = value
            case "branch": branch = value
            case "bare": bare = true
            case "locked": lock = WorktreeLock(reason: value.flatMap { $0.isEmpty ? nil : $0 })
            case "prunable": missing = value ?? ""
            default: continue
            }
        }
        guard let path, !path.isEmpty else { return nil }
        return Worktree(
            path: path, head: head, branch: branch, isMain: isFirst, isBare: bare, lock: lock,
            missingReason: missing)
    }
}
