import Foundation

/// A refusal git made that Gitter can describe precisely, rather than dumping stderr.
///
/// Every case here is a refusal: git did nothing. That is the point of the whole type — the
/// UI can say "these files would be overwritten, commit or move them first" and the user
/// knows their work is still exactly where they left it. Anything git says that
/// `BranchRefusalParser` does not recognise stays `GitError.commandFailed`.
public enum BranchOperationError: Error, Sendable, Equatable {
    /// Tracked files with local changes (staged or not) that differ between here and there.
    /// Every file git named, in git's order; truncating the list for display is the UI's job.
    case wouldOverwrite(files: [String])
    /// Untracked files that the checkout would have written over.
    case untrackedWouldBeOverwritten(files: [String])
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
/// `GitBackend` (reads) and `GitWorkingCopyBackend` (index and commit writes) stay separate
/// for the same reason they always were: either half can be faked on its own.
public protocol GitBranchBackend: Sendable {
    /// Whether `name` would be accepted as a local branch name.
    ///
    /// Empty, whitespace-only and leading-`-` names are rejected without running git; the rest
    /// is `git check-ref-format --branch <name>` (exit 0 → valid, 128 → not), so Gitter's idea
    /// of a valid name is git's own and cannot drift from it.
    ///
    /// One quirk this inherits from git: `check-ref-format --branch` also *expands* branch
    /// shorthand, so `@{-1}` reports valid and resolves to the previously checked-out branch.
    /// Creating a branch from such a name produces a differently-named branch — surprising,
    /// but not destructive, and the New Branch sheet shows the user what they typed.
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
    /// "do I have to stash first?". A conflicting change throws `.wouldOverwrite`, an untracked
    /// file in the way throws `.untrackedWouldBeOverwritten`, and a merge/rebase/cherry-pick/
    /// revert/am in progress throws `.operationInProgress` — in every case git changed nothing.
    func switchTo(branch: String, at root: URL) async throws

    /// `git switch --detach --end-of-options <revision>`: check out a commit or tag without
    /// being on a branch. Same refusal rules as `switchTo`.
    func checkoutDetached(_ revision: String, at root: URL) async throws

    /// Check out `origin/feat/x` as a local `feat/x` tracking it.
    ///
    /// The remote name is the first path component and the local branch name is everything
    /// after it, so `origin/feat/x` becomes `feat/x` — not `x`. When a local branch of that
    /// name already exists this is a plain switch to it: its tip is not moved and no upstream
    /// is set, because silently retargeting an existing branch is exactly the kind of surprise
    /// this milestone is about avoiding.
    func trackRemoteBranch(_ remoteBranch: String, at root: URL) async throws

    /// `git branch -m --end-of-options <old> <new>`. Renaming the current branch is fine: HEAD
    /// follows it and the worktree is untouched. Throws `.branchExists` when `new` is taken.
    func renameBranch(_ old: String, to new: String, at root: URL) async throws
}
