import Foundation

public protocol GitBackend: Sendable {
    /// The repository as History shows it, its history read `historyDepth` commits deep
    /// (`HistoryDepth`); `snapshot(at:)` reads one page.
    func snapshot(at root: URL, historyDepth: Int) async throws -> RepoSnapshot
    /// `sha`'s 0-based row in History's order (`rev-list --exclude=refs/stash --all
    /// --topo-order`), or nil when no branch, tag or HEAD reaches it. `sha` is a full object id,
    /// refused otherwise (`BranchOperationError.invalidName`) before git runs.
    func historyRow(of sha: String, at root: URL) async throws -> Int?
    /// The commit `sha` names, read as History reads its commits; nil for an id git doesn't know
    /// as an object (`bad object`). `sha` is a full object id, refused otherwise before git runs;
    /// a 64-hex id in a SHA-1 repository throws (git: unknown revision).
    func commit(_ sha: String, at root: URL) async throws -> Commit?
    /// Diff for one working-copy path. staged=true → index vs HEAD; false → worktree vs index.
    /// For untracked files (staged=false) returns the whole file as added lines.
    func workingCopyDiff(at root: URL, path: String, staged: Bool) async throws -> [FileDiff]
    /// Files changed by a commit (vs its first parent). Uses ChangeKind for `staged`; `unstaged` is nil.
    func commitFiles(at root: URL, sha: String) async throws -> [FileStatus]
    /// Diff of one commit vs its first parent, optionally limited to a path.
    func commitDiff(at root: URL, sha: String, path: String?) async throws -> [FileDiff]
}

extension GitBackend {
    /// The first page of history (`HistoryDepth.page`).
    public func snapshot(at root: URL) async throws -> RepoSnapshot {
        try await snapshot(at: root, historyDepth: HistoryDepth.page)
    }
}
