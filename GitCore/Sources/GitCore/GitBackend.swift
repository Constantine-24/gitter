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
    /// `CancellationError` (every read goes through the streaming runner, which kills git).
    ///
    /// Every vector starts `log --exclude=refs/stash --all --topo-order --no-show-signature
    /// --no-notes --encoding=UTF-8 --root` (`--exclude` before `--all`: after it, stashes leak
    /// in). The walk's order is not date order (a commit dated before its parent still sits where
    /// the walk puts it), so results are never merged from two reads by date. Measured (git 2.54,
    /// scratch repositories):
    /// - `i18n.logOutputEncoding=ISO-8859-1` turns `%an`, `%s` and `%B` into Latin-1 bytes, so
    ///   "café" matched nothing; `--encoding=UTF-8` overrides it. `log.showRoot=false` stops `-S`
    ///   from searching a root commit; `--root` overrides it.
    /// - Every read runs with `GIT_NO_LAZY_FETCH=1`: in a partial clone (`--filter=blob:none`) a
    ///   Code search otherwise fetched every missing blob it diffed from the promisor. With it,
    ///   git fails at once (`warning: lazy fetching disabled; …`, `fatal: could not fetch <id>
    ///   from promisor remote`, exit 128), thrown as `CommitSearchError.contentsNotDownloaded`;
    ///   Message and File read no blobs and still search.
    /// - Message, Author or ID reads every commit with its full message (`%B`) and matches in the
    ///   app (`CommitSearchMatcher`): `--grep` and `--author` combine by AND, `--author` sees the
    ///   mailmapped name where History shows `%an`, and `rev-parse` resolves a branch named like
    ///   an id before the commit.
    /// - File is `--full-history --diff-merges=separate --name-only --no-renames --no-follow --
    ///   ':(glob,icase)**/*<q>*' ':(glob,icase)**/*<q>*/**'` (`\`, `*`, `?`, `[` and `]` in the
    ///   query escaped): a fragment, a folder (`docs/`) or `Views/Sidebar`, unchanged by
    ///   `GIT_GLOB_PATHSPECS` and `GIT_NOGLOB_PATHSPECS`. git folds ASCII case only, its own
    ///   tables whatever the locale. Default simplification (no `--full-history`) follows only a
    ///   merge's parent whose files it kept, so the commits of a side branch whose change a merge
    ///   dropped vanish once that branch is deleted (a `-s ours` merge, a conflict resolved to
    ///   ours, a change undone before merging, a fix also cherry-picked). `--full-history` lists
    ///   them, but also a merge that equals one parent on the path; `--diff-merges=separate`
    ///   prints a merge once per parent it differs from (and `log.diffMerges` would change `-m`),
    ///   so a merge is kept only when it differs from every parent — the evil merge, not the
    ///   clean one (Ruling P19). The matches are ordered by one `rev-list --exclude=refs/stash
    ///   --all --topo-order`, read beside the log: default simplification reordered the walk, and
    ///   `--full-history`'s own order, though History's in 400 random small histories, is not proved.
    ///   A query with an interior empty, `.` or `..` segment between slashes is collapsed by git
    ///   into a looser pattern (`a//b` and `a/./b` match as `a/b`; `docs/../` matches every
    ///   path), and one with a NUL cannot be launched: both return an empty result, git not run.
    /// - Code is `--no-textconv --no-ext-diff --find-renames -i -S<query>`: `-S` is literal; `-i`
    ///   folds ASCII case only because the runner sets `LC_ALL=C` (under a UTF-8 locale git folds
    ///   `É` with `é`); a `diff=` textconv driver would otherwise change the searched text;
    ///   `diff.renames=false` would make a pure rename show the moved text as added; and a merge's
    ///   own changes are not searched (no `-m`). No `-n`: a rare match walks everything.
    func searchCommits(_ search: CommitSearch, limit: Int, at root: URL) async throws -> CommitSearchResult
}

extension GitBackend {
    /// The first page of history (`HistoryDepth.page`).
    public func snapshot(at root: URL) async throws -> RepoSnapshot {
        try await snapshot(at: root, historyDepth: HistoryDepth.page)
    }
}
