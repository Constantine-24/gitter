import Foundation

/// The two reads a jump to a commit History has not loaded needs (H1): where the commit is in
/// History's order, so the store knows how deep to read, and the commit itself, so the detail
/// can show it before that read lands. See `GitBackend` for the contract.
extension CLIGitBackend {

    /// One `rev-list` over the walk History's own read makes (`commitLog`: `--exclude` before
    /// `--all`, so the stash is not walked), one id per line, searched for `sha`.
    ///
    /// The whole output is read and then searched, not streamed with a stop at the match: the
    /// streaming seam (`runStreaming`) hands back stdout only when git has finished — it reports
    /// stderr as it arrives, not stdout — and stopping early would mean changing it. 100,001 ids
    /// are about 4 MB and git writes them in under 0.1 s (measured, H1). The search compares
    /// bytes, so no `String` is made per line. The id is never passed to git, but is still
    /// refused unless it is a full object id: a short one could match no line or, read as a
    /// prefix, the wrong one.
    public func historyRow(of sha: String, at root: URL) async throws -> Int? {
        guard Self.isFullObjectID(sha) else { throw BranchOperationError.invalidName(sha) }
        let data = try await run(["rev-list", "--exclude=refs/stash", "--all", "--topo-order"], cwd: root)
        return Self.row(of: Array(sha.utf8), in: data)
    }

    /// The 0-based index of the line equal to `id` in `rev-list`'s newline-terminated output.
    static func row(of id: [UInt8], in data: Data) -> Int? {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int? in
            let newline = UInt8(ascii: "\n")
            var row = 0
            var start = 0
            while start < bytes.count {
                var end = start
                while end < bytes.count, bytes[end] != newline { end += 1 }
                if end - start == id.count, id.withUnsafeBytes({ idBytes in
                    memcmp(bytes.baseAddress! + start, idBytes.baseAddress!, id.count) == 0
                }) {
                    return row
                }
                row += 1
                start = end + 1
            }
            return nil
        }
    }

    /// `log -1 --no-walk` of the one id, in History's own format and through History's own
    /// parser, so the commit equals the one a deep enough snapshot would list. git answers an id
    /// that names no object with `fatal: bad object <id>`, exit 128 (git 2.54, measured): that is
    /// nil. Any other failure is thrown.
    public func commit(_ sha: String, at root: URL) async throws -> Commit? {
        guard Self.isFullObjectID(sha) else { throw BranchOperationError.invalidName(sha) }
        do {
            let data = try await run(
                ["log", "-1", "--no-walk", "--format=\(Self.logFormat)", "-z", "--end-of-options", sha], cwd: root)
            return LogParser.parse(data).first
        } catch let GitError.commandFailed(128, stderr) where stderr.contains("bad object \(sha)") {
            return nil
        }
    }
}
