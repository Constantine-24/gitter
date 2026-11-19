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
    /// The sidebar's Recent input: the branches HEAD was switched to, and each local branch's tip
    /// date. Two reads: `reflog show -n 2000 --no-show-signature --format=%gs HEAD --` and
    /// `for-each-ref --format=%(refname)%00%(committerdate:unix) --end-of-options refs/heads`.
    /// Measured (git 2.54, scratch repositories):
    /// - `switch`, `checkout`, `switch -c` and a switch back from a detached HEAD each record
    ///   `checkout: moving from <A> to <B>`; `<B>` is the text after the last ` to `. A detached
    ///   switch records the revision as written (`HEAD~0`, a sha). `branch -m` does not rewrite
    ///   earlier entries. Rebase lines are not counted.
    /// - The `--` is required: a file named `HEAD` in the worktree makes the read exit 128,
    ///   "ambiguous argument".
    /// - Each linked worktree has its own HEAD reflog; the read is of the worktree at `root`.
    /// - When HEAD does not resolve — unborn (an empty repository, or after `switch --orphan`)
    ///   or its branch ref missing — the reflog read exits 128 with `fatal: bad revision 'HEAD'`:
    ///   read as no switches, and the tip dates are still read. Any other failure throws; a
    ///   detached HEAD naming a missing object, for one, exits 128 with `fatal: bad object HEAD`.
    /// - `--no-show-signature` keeps `log.showSignature` from adding gpg output to the text.
    func branchActivity(at root: URL) async throws -> BranchActivity
    /// Commit search (F1): the commits `search` finds among everything History shows (every ref
    /// except `refs/stash`), in History's order, at most `limit` of them; `isCut` says there were
    /// more. An empty query returns an empty result without running git. A cancelled task throws
    /// `CancellationError` (the read goes through `runStreaming`, which kills git).
    ///
    /// Every vector starts `log --exclude=refs/stash --all --topo-order --no-show-signature
    /// --no-notes -z` (`--exclude` before `--all`: after it, stashes leak in). One read per
    /// search, never two merged: the walk's order is not date order (a commit dated before its
    /// parent still sits where the walk puts it). Measured (git 2.54, scratch repositories):
    /// - Message, Author or ID reads every commit with its full message (`%B`) and matches in the
    ///   app (`CommitSearchMatcher`): `--grep` and `--author` combine by AND, `--author` sees the
    ///   mailmapped name where History shows `%an`, and `rev-parse` resolves a branch named like
    ///   an id before the commit.
    /// - File is `--no-follow -- ':(glob,icase)**/*<q>*' ':(glob,icase)**/*<q>*/**'` (`\`, `*`, `?`,
    ///   `[` and `]` in the query escaped): a fragment, a folder (`docs/`) or `Views/Sidebar`,
    ///   unchanged by `GIT_GLOB_PATHSPECS` and `GIT_NOGLOB_PATHSPECS`. git folds ASCII case only
    ///   (`LC_ALL=C`). A merge is listed only when it changed the path against every parent
    ///   (default history simplification), and that simplification can reorder the walk (a
    ///   `-s ours` merge), so the matches are put in History's order by one `rev-list --exclude=
    ///   refs/stash --all --topo-order`. A query with an interior empty, `.` or `..` segment
    ///   between slashes (`a//b`, `docs/../`) is normalised by git into a pattern matching every
    ///   path, and one with a NUL cannot be launched: both return an empty result, git not run.
    /// - Code is `--no-textconv --no-ext-diff --find-renames -i -S<query>`: `-S` is literal, `-i` folds ASCII
    ///   case, a `diff=` textconv driver would otherwise change the searched text, `diff.renames=false` would make a pure rename show the moved text as added, and a merge's
    ///   own changes are not searched (no `-m`). No `-n`: a rare match walks everything.
    func searchCommits(_ search: CommitSearch, limit: Int, at root: URL) async throws -> CommitSearchResult
}

extension GitBackend {
    /// The first page of history (`HistoryDepth.page`).
    public func snapshot(at root: URL) async throws -> RepoSnapshot {
        try await snapshot(at: root, historyDepth: HistoryDepth.page)
    }
}
