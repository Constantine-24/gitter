import Foundation

/// A worktree's lock (`git worktree lock`): `reason` is what the user wrote, verbatim — it can
/// hold newlines and control characters (R13) — or nil when none was given (`lock --reason ""`
/// reads the same as no reason).
public struct WorktreeLock: Sendable, Hashable {
    public let reason: String?

    public init(reason: String?) {
        self.reason = reason
    }
}

/// One record of `git worktree list --porcelain -z` (R13), plus the branch an operation in that
/// worktree holds (R14).
public struct Worktree: Sendable, Hashable, Identifiable {
    public var id: String { path }
    /// The absolute path exactly as `list` printed it — git's real path (`/private/var/…`, never
    /// `/var/…`), with any space, newline or non-ASCII character as it is. This is what `remove`
    /// is given (R23), and what identifies the worktree.
    public let path: String
    /// The commit its HEAD holds, a full id; nil for a bare main repository, which has none.
    public let head: String?
    /// The branch checked out there, a full `refs/heads/…` name; nil when HEAD is detached —
    /// which it also is while a rebase or a bisect runs there (`operationBranches`).
    public let branch: String?
    /// The main worktree: always `list`'s first record. It cannot be removed.
    public let isMain: Bool
    /// A bare main repository (`bare`): no working files, no HEAD.
    public let isBare: Bool
    /// Locked (`locked[ <reason>]`); nil when not.
    public let lock: WorktreeLock?
    /// Why git calls it prunable (`prunable <reason>`) — its folder, or the `.git` file in it, is
    /// gone; nil when it is there. A locked missing worktree has no such line (R25).
    public let missingReason: String?
    /// The branches an operation in this worktree holds, full `refs/heads/…` names, read from its
    /// state files by the one reader git's own rule needs (`CLIGitBackend.branchesHeld(in:)`, B2's
    /// `worktreeUsing`): the branch a rebase started from (`rebase-merge/head-name`, or
    /// `rebase-apply/head-name` when it is not an `am`), the one a bisect started from
    /// (`BISECT_START`), then every branch a `rebase --update-refs` will move
    /// (`rebase-merge/update-refs`). `list` shows such a worktree as detached and
    /// `%(worktreepath)` leaves those branches empty, yet git refuses to delete, rename or check
    /// any of them out anywhere else (R14). Empty when none.
    public let operationBranches: [String]

    /// The first of `operationBranches` — the branch the rebase or bisect itself started from,
    /// when there is one — or nil.
    public var operationBranch: String? { operationBranches.first }

    /// Whether its folder is gone (`missingReason` set).
    public var isMissing: Bool { missingReason != nil }

    public init(
        path: String, head: String?, branch: String?, isMain: Bool, isBare: Bool, lock: WorktreeLock?,
        missingReason: String?, operationBranches: [String] = []
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isMain = isMain
        self.isBare = isBare
        self.lock = lock
        self.missingReason = missingReason
        self.operationBranches = operationBranches
    }

    /// A copy holding `operationBranches`.
    func with(operationBranches: [String]) -> Worktree {
        Worktree(
            path: path, head: head, branch: branch, isMain: isMain, isBare: isBare, lock: lock,
            missingReason: missingReason, operationBranches: operationBranches)
    }
}

/// What `git status` says about a worktree's files (R15): entries, not lines of a diff. Any of
/// them makes git's own `remove` refuse (R20).
public struct WorktreeChanges: Sendable, Hashable {
    /// Entries with a staged change (the index side of a `1` or `2` record).
    public let staged: Int
    /// Entries with an unstaged change to a tracked file (the worktree side).
    public let unstaged: Int
    /// Untracked entries, as `--untracked-files=normal` lists them — an untracked folder is one.
    public let untracked: Int
    /// Unmerged entries (`u` records).
    public let conflicted: Int

    public var isClean: Bool { staged + unstaged + untracked + conflicted == 0 }

    public init(staged: Int, unstaged: Int, untracked: Int, conflicted: Int) {
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.conflicted = conflicted
    }

    public static let none = WorktreeChanges(staged: 0, unstaged: 0, untracked: 0, conflicted: 0)
}

/// The ignored entries `git worktree remove` deletes without asking (R21), as `status
/// --ignored=matching` lists them: an ignored folder is one entry (`build/`) and goes with
/// everything in it, an ignored file inside a folder that is not is another (`sub/deep/x.log`).
///
/// Every entry is kept (B3 Task 5 fix round 1, I1): the check made again before git runs compares
/// them all, so an ignored file swapped for another of the same count is a change, never a file
/// deleted that the sheet did not name. Equality is the entries'.
public struct IgnoredSummary: Sendable, Hashable {
    /// Every entry `status` listed, in git's order.
    public let entries: [String]

    public init(entries: [String]) {
        self.entries = entries
    }

    /// How many entries `status` listed.
    public var count: Int { entries.count }

    /// Their distinct first path components, in git's order (`build/`, `sub/`, `top.log` — a
    /// folder keeps its `/`), at most `topLevelLimit`.
    public var topLevel: [String] {
        var top: [String] = []
        for path in entries {
            let name = path.firstIndex(of: "/").map { String(path[...$0]) } ?? path
            if !top.contains(name) { top.append(name) }
            if top.count == Self.topLevelLimit { break }
        }
        return top
    }

    public static let none = IgnoredSummary(entries: [])

    /// How many names `topLevel` holds at most.
    public static let topLevelLimit = 10
}

/// Paths as git matches worktree paths (R23), for GitCore's own checks and the app's live folder
/// check alike (B3 Task 5 fix round 1, I2: one rule, not two copies).
public enum WorktreePaths {
    /// `path` as git compares it: `..` and `.` taken out, then the deepest part that exists resolved
    /// with `realpath(3)` (`/var` → `/private/var`, links followed) and the rest put back. A path
    /// none of which can be resolved is returned as it is.
    public static func resolved(_ path: String) -> String {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var rest: [String] = []
        while true {
            if let real = realpath(url.path, nil) {
                defer { free(real) }
                let head = String(cString: real)
                return rest.isEmpty ? head : (head == "/" ? "" : head) + "/" + rest.joined(separator: "/")
            }
            guard url.path != "/", !url.path.isEmpty else { return path }
            rest.insert(url.lastPathComponent, at: 0)
            url.deleteLastPathComponent()
        }
    }

    /// The same file system object by git's rule: equal, or equal once both are resolved.
    public static func same(_ a: String, _ b: String) -> Bool {
        a == b || resolved(a) == resolved(b)
    }

    /// `path` is `folder` or inside it; both already resolved.
    public static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
}

/// Why Gitter will not remove a worktree. Each is decided by Gitter's own check, before git
/// runs: git's `remove` refuses only some of these (R20) and deletes the rest silently (R21).
public enum WorktreeRemovalRefusal: Error, Sendable, Hashable {
    /// The main worktree.
    case isMain
    /// The worktree this window has open: git would remove it from under the app (R20).
    case isOpenHere
    /// Locked, with the lock's reason. Only an unlock in a terminal lifts it; Gitter does not.
    case locked(reason: String?)
    /// An operation is part-way through there — `rebase`, `am`, `merge`, `cherry-pick`,
    /// `revert`, `bisect` or `sequencer` (a cherry-pick or revert range between steps). git
    /// removes the worktree and the operation's state with it (R20).
    case operationInProgress(String)
    /// Staged, unstaged, untracked or conflicted entries.
    case changes(WorktreeChanges)
    /// Index entries marked assume-unchanged (`ls-files -v` tags them in lower case): an edit
    /// to one is invisible to `status` and to git's own check, and `remove` deletes it (R21).
    /// Paths as the index holds them, at most `pathLimit`.
    case assumeUnchanged([String])
    /// Skip-worktree entries (`S`/`s`) whose file is present: an edit to it is invisible in the
    /// same way. Paths, at most `pathLimit`.
    case skipWorktreePresent([String])
    /// `.git` entries anywhere in the worktree but its own — compared ignoring case, a folder or a
    /// file: a repository nested in an ignored folder, or a `.git` folder `status` skips, which
    /// `remove` deletes, history and all (R21; fix round 1, I1). Paths of their parent folders,
    /// relative to the worktree, at most `pathLimit`.
    case nestedRepository([String])
    /// The worktree holds more entries than Gitter walks (`WorktreeWalkLimit`), or the walk took
    /// too long: a repository inside it could not be ruled out.
    case tooLargeToCheck
    /// A folder or state file Gitter must read to make the check could not be read (B3 Task 2,
    /// carried note 4: unreadable is never "nothing there"). The path, as Gitter tried it.
    case unreadable(String)

    /// How many paths a refusal names at most.
    public static let pathLimit = 20
}

/// Everything the Remove Worktree sheet shows, read by `GitWorktreeBackend.removalCheck` and
/// read again, whole, by `removeWorktree` before git runs.
public struct WorktreeRemoval: Sendable, Hashable {
    /// The worktree, as `list` printed it when the check was made.
    public let worktree: Worktree
    /// Its changes; nil for a missing worktree, whose folder there is nothing in — and for the
    /// main one, which is refused before anything is read.
    public let changes: WorktreeChanges?
    /// What `remove` will delete without asking.
    public let ignored: IgnoredSummary
    /// For a detached worktree, the commits only its HEAD holds: removing it deletes its HEAD
    /// reflog, so they are unreachable afterwards (R22). Counted as B2's union is, against every
    /// branch, tag and remote-tracking ref and every **other** worktree's HEAD. `holders` is
    /// `[worktree.path]` when there are any — the key a kept branch is asked for under.
    /// `.none` for a worktree on a branch: the branch is never deleted.
    public let stranded: StrandedCommits
    /// Why it is not removed; empty when it may be.
    public let refusals: [WorktreeRemovalRefusal]

    public init(
        worktree: Worktree, changes: WorktreeChanges?, ignored: IgnoredSummary, stranded: StrandedCommits,
        refusals: [WorktreeRemovalRefusal]
    ) {
        self.worktree = worktree
        self.changes = changes
        self.ignored = ignored
        self.stranded = stranded
        self.refusals = refusals
    }
}

/// How far the nested-repository walk goes before it gives up and refuses (`.tooLargeToCheck`).
/// Internal: the protocol's check always uses `standard`; tests lower it.
struct WorktreeWalkLimit: Sendable, Hashable {
    /// Entries visited, across every ignored folder.
    let entries: Int
    /// Seconds since the walk began.
    let seconds: Double

    /// Ruling 5: 500 000 entries or 3 s, whichever comes first (the plan's 20 000 / 2 s refused
    /// most worktrees with a `node_modules/` or `.build/`). Measured (B3 Task 2): about 250 000
    /// entries a second on an APFS SSD.
    static let standard = WorktreeWalkLimit(entries: 500_000, seconds: 3)
}

/// Why Add Worktree was refused. Each is thrown before git runs.
public enum AddWorktreeRefusal: Error, Sendable, Hashable {
    /// No local branch `refs/heads/<name>` — a remote-only name, a tag, a typo — or one that is
    /// a symbolic ref. git would create a tracking branch for a remote-only name, or detach at
    /// whatever else the name resolves to (R17).
    case noSuchBranch(String)
    /// The branch is checked out in the worktree at `path`.
    case branchInUse(path: String)
    /// A rebase or a bisect in the worktree at `path` holds the branch (R14).
    case branchHeldByOperation(path: String)
    /// Something is at the path already — a file, a link, or a folder that is not empty.
    case pathExists(String)
    /// The path is inside a listed worktree (or is one): git accepts it, and the new worktree
    /// would show there as untracked (R16).
    case pathInsideWorktree(String)
    /// The path does not begin with `/`: git resolves a relative one against its own working
    /// directory, not the repository (R16).
    case pathNotAbsolute(String)
}

/// What Add Worktree did, read back from `list` whatever git's exit code was (R19).
public enum AddWorktreeResult: Sendable, Hashable {
    /// Listed at the path, on the branch asked for, and git exited 0.
    case added(Worktree)
    /// Listed at the path, on the branch asked for — but git exited non-zero, as it does when a
    /// `post-checkout` hook fails after the worktree is complete (R19). git's own words.
    case addedWithError(Worktree, gitsWords: String)
    /// Not what was asked for: a worktree listed at the path on another branch or detached, or
    /// (nil) git exited 0 and nothing is listed there. git's own words, possibly empty.
    case unexpected(Worktree?, gitsWords: String)
}

/// A removal that stopped part-way or whose outcome is not known. Not a refusal of the sheet's
/// state as such, except `changedSinceShown`, which is thrown with nothing written.
public enum WorktreeRemovalPartial: Error, Sendable, Hashable {
    /// The check made again just before git would run differs from the sheet's — HEAD, branch,
    /// lock, changes, ignored count, stranded count or refusals — or the worktree is no longer
    /// listed. Nothing was created or removed.
    case changedSinceShown
    /// The kept branches `kept` were created, and then the removal could not go on (git could not
    /// be started, or a later kept branch failed): nothing was removed, and `kept` stay.
    case keptBranchesThenStopped(kept: [String], gitsWords: String)
    /// git refused the removal and the worktree is still listed: git's own words. The kept
    /// branches, created before git ran, stay. git checks as it deletes, so files may be gone —
    /// read the worktree back.
    case refusedByGit(gitsWords: String, keptBranches: [String])
    /// git took the worktree out of `list` but did not finish: it exited non-zero, or its folder
    /// is still there (B3 Task 2 fix round 1, I3). Measured: `failed to delete '…': Directory not
    /// empty` / `Permission denied` / `Not a directory`, exit 255, after the administrative entry,
    /// the `.git` file and some files were already deleted. git's own words; the kept branches stay.
    case removedWithLeftovers(gitsWords: String, keptBranches: [String])
    /// Cancelled while git was removing, or the list could not be read back afterwards: whether
    /// the worktree is gone is **not known**. The kept branches stay.
    case outcomeUnknown(keptBranches: [String])
}
