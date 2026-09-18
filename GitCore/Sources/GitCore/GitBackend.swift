import Foundation

public protocol GitBackend: Sendable {
    func snapshot(at root: URL) async throws -> RepoSnapshot
    /// Diff for one working-copy path. staged=true → index vs HEAD; false → worktree vs index.
    /// For untracked files (staged=false) returns the whole file as added lines.
    func workingCopyDiff(at root: URL, path: String, staged: Bool) async throws -> [FileDiff]
    /// Files changed by a commit (vs its first parent). Uses ChangeKind for `staged`; `unstaged` is nil.
    func commitFiles(at root: URL, sha: String) async throws -> [FileStatus]
    /// Diff of one commit vs its first parent, optionally limited to a path.
    func commitDiff(at root: URL, sha: String, path: String?) async throws -> [FileDiff]
}
