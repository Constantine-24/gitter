import Foundation

/// A refusal git made that Gitter can describe precisely, rather than dumping stderr.
///
/// Every case here is a refusal: git did nothing. That is the point of the whole type — the
/// UI can say "these files would be overwritten, commit or move them first" and the user
/// knows their work is still exactly where they left it. Anything git says that
/// `BranchRefusalParser` does not recognise stays `GitError.commandFailed`.
public enum BranchOperationError: Error, Sendable, Equatable {
    /// Files the operation would have written over: `tracked` are files with local changes
    /// (staged or not) that differ between here and there, `untracked` are files git does not
    /// know about that the checkout would have clobbered.
    ///
    /// One case rather than two because **git can refuse over both at once** — verified on
    /// git 2.54, a single `git switch` prints the "Your local changes…" block and then the
    /// "The following untracked working tree files…" block. Reporting only the first would
    /// have the user fix that file, retry, and be refused all over again. Either list may be
    /// empty; never both. Both hold every file git named, in git's order — truncating for
    /// display is the UI's job.
    case wouldOverwrite(tracked: [String], untracked: [String])
    /// git refuses to switch branches part-way through something. Carries the operation as a
    /// phrase that completes "while …": `merging`, `cherry-picking`, `reverting`, `rebasing`,
    /// `applying patches`.
    case operationInProgress(String)
    /// The name is not a valid branch name — either git's `check-ref-format` said so, or it is
    /// empty or starts with `-` (which git would read as an option), which Gitter rejects
    /// before git ever runs.
    case invalidName(String)
    /// A branch of that name is already there. Creating, renaming or copying onto it would
    /// overwrite the other branch, so git refuses and so does Gitter.
    case branchExists(String)
    /// The current branch cannot be deleted. (Raised by a later task in this milestone.)
    case cannotDeleteCurrent(String)
}

/// Branch-level operations: naming, creating, switching, detaching, tracking and renaming.
///
/// These are the first Gitter operations that write working-tree files, so the contract is
/// deliberately narrow:
///
/// - **No force flag is ever passed.** Not `--force`, `-f`, `--discard-changes`, `-B`, `-C`,
///   nor `--merge` on a switch. When a local change stands in the way, git refuses, nothing
///   changes, and the refusal arrives as a `BranchOperationError` naming the files. A test
///   (`ForceFlagScannerTests`) fails the build if such a flag ever appears in `GitCore`.
/// - **Branch names and revisions are not pathspecs.** `literalPathspec` is never applied to
///   them; instead a name that is empty or begins with `-` is rejected before git runs, and
///   revisions and start points are passed after `--end-of-options` on the commands that
///   accept it, so a ref really named `--force` could never be read as a flag.
///
///   That leading-`-` rule is a blanket one, and it does cost something: a ref literally
///   named `--force` or `-x` *can* exist — `git update-ref refs/heads/--force <sha>` makes
///   one — and such a branch is deliberately unreachable from Gitter. It still appears in the
///   sidebar; only operating on it is refused, with `.invalidName`. Reaching it would mean
///   trusting `--end-of-options` in the one position (`switch -c <name>`) where it
///   demonstrably does not work, which is not a trade worth making for a ref nobody creates
///   by accident.
///
/// `GitBackend` (reads) and `GitWorkingCopyBackend` (index and commit writes) stay separate
/// for the same reason they always were: either half can be faked on its own.
public protocol GitBranchBackend: Sendable {
    /// Whether `name` would be accepted as a local branch name.
    ///
    /// Rejected without running git: empty or whitespace-only names, names beginning with `-`,
    /// and four shapes `check-ref-format --branch` *accepts* while meaning something other
    /// than what the user typed (all verified on git 2.54):
    ///
    /// - `refs/…` and `heads/…` — `git branch refs/heads/x` creates
    ///   `refs/heads/refs/heads/x`, and `git branch heads/y` creates `refs/heads/heads/y`.
    /// - anything containing `@{` — `check-ref-format --branch` *expands* branch shorthand, so
    ///   `@{-1}` reports valid and resolves to the previously checked-out branch's name.
    /// - exactly `@` — accepted by git, and a branch nobody can refer to without confusion.
    ///
    /// Everything else is `git check-ref-format --branch <name>` (exit 0 → valid, 128 → not),
    /// so what a name may *contain* stays git's judgement and cannot drift from it: the
    /// control characters, `..`, `~`, `^`, `:`, `?`, `*`, `[`, trailing `.lock`, `HEAD` and
    /// the rest are never re-implemented here.
    ///
    /// This is a name-quality gate for the UI. The backend's own argv safety — rejecting a
    /// leading `-` before any name reaches git — is separate and unconditional.
    func validateBranchName(_ name: String, at root: URL) async throws -> Bool

    /// `git branch --end-of-options <name> [<start>]`, or `git switch -c <name>
    /// [--end-of-options <start>]` when `switchTo`.
    ///
    /// Without `switchTo` this writes one ref and touches nothing else — not HEAD, not the
    /// index, not a single file. With it, a dirty worktree is carried onto the new branch
    /// (there is nothing to conflict with: the new branch starts where HEAD already is, unless
    /// `startPoint` says otherwise, in which case git applies its usual refusal rules).
    ///
    /// Throws `.branchExists` if `name` is taken and `.invalidName` if git (or Gitter) rejects
    /// the name.
    func createBranch(_ name: String, startPoint: String?, switchTo: Bool, at root: URL) async throws

    /// `git switch --no-guess --end-of-options <branch>`.
    ///
    /// `--no-guess` matters: without it, switching to a name that exists only as
    /// `origin/<name>` silently *creates* a local tracking branch. Gitter has an explicit
    /// action for that (`trackRemoteBranch`) and this one must never do it by accident.
    ///
    /// Non-conflicting local changes ride along, which is git's default and Gitter's answer to
    /// "do I have to stash first?". A conflicting change or an untracked file in the way throws
    /// `.wouldOverwrite` (which carries both lists, since git can refuse over both at once),
    /// and a merge/rebase/cherry-pick/revert/am in progress throws `.operationInProgress` — in
    /// every case git changed nothing.
    func switchTo(branch: String, at root: URL) async throws

    /// `git switch --detach --end-of-options <revision>`: check out a commit or tag without
    /// being on a branch. Same refusal rules as `switchTo`.
    func checkoutDetached(_ revision: String, at root: URL) async throws

    /// Check out `origin/feat/x` as a local `feat/x` tracking it.
    ///
    /// The remote name is the first path component and the local branch name is everything
    /// after it, so `origin/feat/x` becomes `feat/x` — not `x`.
    ///
    /// A remote whose own name contains a slash is not special-cased: `my/remote/feature`
    /// (a real shape — `git remote add my/remote …` puts its refs under
    /// `refs/remotes/my/remote/`) yields a local branch called `remote/feature`, keeping a
    /// fragment of the remote's name. The upstream is still set correctly, because git
    /// resolves the full string for `--track`. Untangling it would mean listing the remotes to
    /// find the longest matching prefix; nobody names remotes that way, and the failure is
    /// cosmetic and immediately visible, so this stays as it is. It is tested, not accidental.
    ///
    /// When a local branch of that
    /// name already exists this is a plain switch to it: its tip is not moved and no upstream
    /// is set, because silently retargeting an existing branch is exactly the kind of surprise
    /// this milestone is about avoiding.
    func trackRemoteBranch(_ remoteBranch: String, at root: URL) async throws

    /// `git branch -m --end-of-options <old> <new>`. Renaming the current branch is fine: HEAD
    /// follows it and the worktree is untouched. Throws `.branchExists` when `new` is taken.
    func renameBranch(_ old: String, to new: String, at root: URL) async throws
}
