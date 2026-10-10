import Foundation

/// The value types `GitRemoteBackend` hands back or throws.
///
/// Split out of `GitRemoteBackend.swift` for length only, exactly as `BranchOperationTypes` is
/// split out of `GitBranchBackend`. `RemoteFailureParser` is what turns git's stderr into a
/// `RemoteOperationError`.

/// A network failure Gitter can describe in its own words, rather than dumping git's stderr.
///
/// **This is not `BranchOperationError`, and the difference matters.** Every case of that type
/// is a refusal: git did nothing, and the UI may say so. Here, only the cases thrown *before
/// git runs* (`.noRemote` for a name Gitter will not pass on, `.invalidLease`,
/// and `.unsafeFetchRefspec` for a *named* remote — see its own comment for `--all`) carry
/// that guarantee. The rest are reports of a failure that happened somewhere in the middle of a
/// transfer, and a fetch that failed **may still have updated refs** — measured on git 2.54:
/// `git fetch --all` with one good remote and one unreachable one exits 1 with the good
/// remote's refs already moved. Nothing built on this type may render a throw as "nothing
/// changed"; the caller re-reads the repository.
///
/// The wordings each case is recognised from are in `RemoteFailureParser`, with the measurement
/// that produced them. Anything git says that the parser does not recognise stays
/// `GitError.commandFailed`, in git's own words.
///
/// **No payload here carries a credential.** A remote URL can have one written into it
/// (`https://<user>:<token>@host/repo.git`), and git quotes that URL back when it fails; every
/// payload below has been through `RemoteFailureParser.redactingCredentials`. Anything that
/// builds a sentence out of raw stderr instead of out of one of these cases must call it too.
public enum RemoteOperationError: Error, Equatable, Sendable {
    /// The server wants a credential and git could not ask for one: `ProcessRunner` sets
    /// `GIT_TERMINAL_PROMPT=0` and gives git `/dev/null` for stdin, so an HTTPS remote with no
    /// credential helper fails here instead of hanging on a prompt nobody can answer. The URL
    /// is git's, quoted out of its message, so the UI can name the remote the user must set up.
    case authenticationNeeded(url: String)
    /// A credential *was* offered and the server refused it: a rejected HTTPS password/token,
    /// or an ssh key the server will not accept (which is also where a key whose passphrase
    /// cannot be asked for ends up — with no tty and no askpass there is no third outcome).
    /// The URL is whatever git named: an HTTPS URL, or an ssh address like `git@github.com`.
    case authenticationFailed(url: String)
    /// The server's host key is not in `known_hosts`, or does not match what is. Gitter cannot
    /// fix this — accepting a host key is a decision that belongs in a terminal, where the
    /// fingerprint can be checked — so the UI says so and offers no "trust it" button.
    case hostKeyNotTrusted
    /// Nothing answered: an unresolvable host name, a refused connection, a timed-out one. The
    /// payload is the **host** when git or ssh named one, and otherwise git's own line, because
    /// half a sentence is worse than the whole of git's.
    case unreachable(String)
    /// There is no repository at the other end, or the server will not admit there is one. Both
    /// readings are deliberate: a private repository on a host that does not know the user
    /// answers exactly as a misspelled one does, and Gitter cannot tell them apart. An unknown
    /// *remote name* also lands here — see `RemoteFailureParser` for why git's wording for that
    /// cannot be told from a configured remote whose path holds no repository.
    case repositoryNotFound
    /// There is no remote to work with: a name Gitter will not hand to git (empty, whitespace,
    /// beginning with `-`, or `.`), or — for the store, later in this milestone — a repository
    /// with no remote configured at all. Thrown **before git runs**, so it really does mean
    /// nothing changed. See `GitRemoteBackend.fetch` for what each refused name would otherwise
    /// have meant to git.
    case noRemote
    /// The remote is configured but git has no URL for what was asked — none at all, or (for a
    /// fetch or a read of the remote's refs) only a push URL. git would use the remote's **name
    /// as a path** (fix round 1, I1, measured: a nested checkout called `vendor` was fetched
    /// from, and a branch in it deleted by a push). Thrown before any fetch, push or `ls-remote`
    /// runs; the payload is the remote's name.
    case noURL(String)
    /// The name is not a configured remote (`git remote -v` does not list it) — removed or
    /// renamed since the caller read the remotes. git would read it as a **path** (Ruling 11,
    /// measured: a tag push to an unconfigured `vendor` beside a nested repository `vendor/`
    /// returned `.pushed` and changed that repository). Thrown before any fetch, push or
    /// `ls-remote` runs; the payload is the name.
    case noSuchRemote(String)
    /// An expected tip handed to `forcePush` or `deleteRemoteBranch` — the lease, or
    /// `forcePush`'s `expectedLocalTip`, the refspec's source side — is not a full object
    /// name — 40 or 64 **lower-case** hexadecimal characters, and not all zeros. Thrown
    /// **before git runs**, so it is the third case here that really does mean nothing changed.
    /// The payload is the value that was refused; an object name is not a credential.
    ///
    /// **Every other shape is a lease that cannot do its job, and git accepts most of them.**
    /// Measured on git 2.54, with the remote branch genuinely ahead:
    ///
    /// | expected value | what git does |
    /// |---|---|
    /// | `211f4ff` (abbreviated) | `error: cannot parse expected object name`, exit 129 |
    /// | a 40-hex name in UPPER CASE | **accepted**: the push is forced |
    /// | `refs/heads/main`, `HEAD`, `origin/main` | **accepted**, resolved *locally* as a revision |
    /// | empty | **accepted**; means "the ref must not exist" |
    /// | forty zeros | **accepted**; means the same |
    ///
    /// The three that are accepted are why this exists. A value git resolves as a revision is a
    /// lease on a **local** name that moves: measured,
    /// `--force-with-lease=refs/heads/main:refs/remotes/origin/main` forced the push, which is
    /// the bare `--force-with-lease` hole reached by another road. The all-zero name is a lease
    /// that can never refuse: measured, with the branch absent from the server it exits 0 and
    /// pushes `[new branch]`. And an upper-case name is a spelling of a sha the sheet never
    /// showed — git prints object names in lower case, so that is what the sheet held.
    case invalidLease(String)
    /// A fetch from `remote` was not run because one of its configured refspecs
    /// (`remote.<name>.fetch`) writes outside `refs/remotes/` — `refspec` is the first such, as
    /// configured. See `FetchRefspec` for what one did and the rule that decides.
    ///
    /// **Whether anything changed depends on which fetch it was, and the payload does not
    /// say.** For a named remote it is thrown **before git runs**: nothing was contacted and
    /// nothing changed (proved in `UnsafeFetchRefspecTests` by an upload-pack wrapper that never
    /// fired). For `--all` it is thrown **after** every other remote was fetched on its own, so
    /// their remote-tracking refs may well have moved — the same "re-read, never infer" rule as
    /// every other case here, and the reason the UI words it as "did not fetch `<remote>`" and
    /// never as "nothing changed". Neither payload is a credential: a remote name and a
    /// refspec are configuration, not a URL.
    case unsafeFetchRefspec(remote: String, refspec: String)
}

/// Why the server refused a ref. Each case is git's own `--porcelain` summary, read back from
/// stdout — never guessed from the exit code, which is 1 for every one of them alike.
public enum PushRejection: Equatable, Sendable {
    /// `[rejected] (fetch first)` — the remote branch has commits this repository has never
    /// fetched. Fetch, then merge or rebase; or force-push behind a lease.
    case fetchFirst
    /// `[rejected] (non-fast-forward)` — the same divergence, seen *after* a fetch: the local
    /// branch is not a descendant of the remote-tracking ref. git uses a different word for it,
    /// and both mean "this push would discard commits on the server".
    case nonFastForward
    /// `[rejected] (stale info)` — a `--force-with-lease` whose expected object name is not
    /// what the server holds. The remote branch moved between the sheet and the confirm, and
    /// **nothing on the server changed**: this is the stale-confirmation rule enforced by the
    /// server rather than by a re-read.
    case staleLease
    /// `[remote rejected] (<reason>)` — a hook or a hosting service said no. The payload is the
    /// reason git printed inside the parentheses, which is the server's own text and therefore
    /// redacted; the server's fuller explanation arrives beside it as `remoteMessages`.
    case remoteRejected(String)
    /// A result line for our ref that this version of Gitter cannot read, kept whole (and
    /// redacted). Inventing an outcome for a shape nobody has seen is the one answer that could
    /// lose work, so the line itself is carried up for the user to read.
    case other(String)
}

/// What a push did, read from the `--porcelain` result line for the refspec that was asked for.
///
/// **A rejection is an outcome, not an error** — the same choice `MergeOutcome.conflicts`
/// makes. The server did something (it said no), which is a different fact from "git could not
/// be run" or "the host could not be reached", and stretching the error type to cover it would
/// lose that difference. `GitRemoteBackend.push` therefore returns for every row of git's push
/// table and throws only when there is no result line at all.
public enum PushOutcome: Equatable, Sendable {
    /// `=` / `[up to date]` — the server already had this commit on that ref.
    case upToDate
    /// `*` / `[new branch]` — the ref did not exist on the server and now does.
    case created
    /// ` ` (a space) / `<from>..<to>` — a fast-forward. The two shas are git's **abbreviated**
    /// ones, exactly as it printed them; nothing here expands them.
    case pushed(from: String, to: String)
    /// `+` / `<from>...<to> (forced update)` — a non-fast-forward that a lease permitted.
    case forced(from: String, to: String)
    /// `-` / `[deleted]` — the ref is gone from the server.
    case deleted
    /// `!` — the server refused this ref. See `PushRejection`.
    case rejected(PushRejection)
}

/// A push's outcome together with everything the server said while it happened.
///
/// **Why the messages are not an associated value of `.rejected`.** They arrive the same way
/// whatever the outcome — stderr lines prefixed `remote:` — and they matter just as much on a
/// *success*: a hosting service's "create a pull request" URL is printed by a `post-receive`
/// hook after the push has gone through, and Gitter shows it as a notice. Hanging them off the
/// one failing case would have meant the caller reading them two different ways depending on
/// how the push went, and `PushOutcome` would have stopped being comparable with a plain `==`.
/// One place, read the same way every time.
public struct PushResult: Equatable, Sendable {
    public let outcome: PushOutcome
    /// The server's own words, in order, with git's `remote:` prefix and the padding spaces it
    /// erases the previous line with both removed, and credentials redacted. Empty for a server
    /// that said nothing — which is every server without a hook. Blank lines the server printed
    /// are kept as empty strings: they are its layout, and dropping them would join two
    /// paragraphs of somebody else's text together.
    ///
    /// **It is somebody else's text, and unbounded.** A hook may print any number of lines and
    /// any bytes at all: measured on git 2.54, an ANSI colour escape (`\u{1B}[31m`), a tab and
    /// a BEL all arrive intact, and only a NUL is lost (git cuts the line there). Whatever
    /// renders this shows it as plain text — escapes and control characters stripped, length
    /// capped — never as anything a terminal or a formatter would interpret.
    public let remoteMessages: [String]
    /// What became of the upstream `setUpstream: true` asked for. See `UpstreamResult`.
    public let upstream: UpstreamResult
    /// git's own `error:` lines from stderr, whole and redacted — the ones that are *not* the
    /// server talking. See `PushPorcelainParser.errorLines`.
    ///
    /// This is where a failure that leaves the outcome a success ends up: the unwritable
    /// upstream above, and anything else git reports about this end after the push itself went
    /// through. It also carries git's `error: failed to push some refs to …` summary on a
    /// rejection, which is a true sentence the caller has usually already said better; whether
    /// to show it beside an outcome that explains itself is the caller's decision.
    public let errorLines: [String]

    public init(
        outcome: PushOutcome, remoteMessages: [String], upstream: UpstreamResult = .notRequested,
        errorLines: [String] = []
    ) {
        self.outcome = outcome
        self.remoteMessages = remoteMessages
        self.upstream = upstream
        self.errorLines = errorLines
    }
}

/// What became of the upstream a `setUpstream: true` push asked git to write.
///
/// **`-u` is best-effort in git, and Gitter reads it back.** Measured on git 2.54 with
/// `.git/config` made unwritable: the push succeeds and exits **0**, the branch appears on the
/// server, the `branch '…' set up to track '…'.` notice is simply absent, and the explanation
/// is two `error:` lines on stderr that `remoteMessages` does not carry because they are not
/// the server's. A caller that trusted `-u` would show a published branch with an upstream it
/// does not have — so the configuration is read back out of `branch.<name>.remote` /
/// `branch.<name>.merge` and answered here.
///
/// **Four cases and not three, because the read-back can fail too.** This was `Bool?`, where
/// `false` meant both "git did not write it" and "the read-back could not be run", documented
/// as "not confirmed". The two need opposite sentences — one says *the branch is not tracking
/// what you asked for*, the other says *it may well be and this could not be checked* — and
/// the second can occur with the upstream **correctly written**, which makes a `false` there a
/// false statement about the repository. Measured: a client-side `reference-transaction` hook
/// that leaves `.git/config` unparseable makes `git config --get` exit 128 after `-u` has
/// already succeeded (`anUpstreamThatCannotBeReadBackIsUnknownAndNotUnset`).
public enum UpstreamResult: Equatable, Sendable {
    /// Nothing to report. Either `setUpstream` was false, or the server refused the push — in
    /// which case git had no occasion to write an upstream and the words belong to the
    /// refusal. Both lease methods always answer this: neither asks for an upstream.
    case notRequested
    /// Read back, and the branch is tracking exactly what the push asked for.
    case set
    /// Read back, and it is **not**. The push itself may well have succeeded; this is the
    /// notice beside it, and git's own words for why are in `errorLines`.
    case notSet
    /// The read-back could not be run at all, so nothing is known either way. Never word this
    /// as "the upstream was not set": say that it could not be checked.
    case unknown
}

/// Why Gitter will not push a branch even though git might.
public enum PushTargetRefusal: Equatable, Sendable {
    /// `%(push:remotename)` named a remote that is not configured. Measured (row k): git prints
    /// whatever `branch.<name>.pushRemote` says, configured or not, and only fails at the far
    /// end with `fatal: '<name>' does not appear to be a git repository`. Naming the bad name
    /// here is more use than showing the user that sentence.
    case unknownRemote(String)
    /// `%(push:remotename)` named a configured remote that has no URL to push to (fix round 1,
    /// I1): git would use its name as a path.
    case noURL(String)
    /// The branch and its upstream have different names on the same remote, and no explicit
    /// refspec settles which one a push means. The payload is the upstream as git spells it
    /// (`origin/main`). See `PushTarget` for why this is refused rather than resolved.
    case upstreamNameDiffers(upstream: String)
}

/// Where a push of a branch goes — the one place that decides, for the store, the toolbar and
/// every sheet alike.
///
/// **Where a branch pushes is not where it fetches from.** `branch.<name>.pushRemote` and
/// `remote.pushDefault` send a push to a different repository than the one the branch tracks,
/// and `remote.pushDefault` gives a push target to a branch with no upstream at all. So the
/// remote is `Branch.pushRemote` (`%(push:remotename)`) and never `upstreamRemote`, and the ref
/// is `Branch.pushRef` (`%(push:remoteref)`) when git filled it in and otherwise the branch's
/// own name — never `upstreamRef`, which under an override belongs to another server entirely.
///
/// Measured on git 2.54.0 (Apple Git-157); the rows are the design document's push-target table
/// and each one has a test of its own in `PushTargetTests`.
///
/// **The rules, in the order they are applied.**
/// 1. No `pushRemote` → `.unpublished`. git would fall back to the implicit default remote
///    here (measured row m: with `push.default=current` a bare `git push` of an upstreamless
///    branch publishes to `origin`), and Gitter deliberately does not follow that fallback:
///    Publish names the remote out loud instead. A branch whose upstream is another *local*
///    branch lands here too, because git reports `.` as its push remote and `.` is not a remote.
/// 2. A `pushRemote` that is not in `remotes` → `.refused(.unknownRemote)`; one with no URL to
///    push to (`Remote.canPush`) → `.refused(.noURL)`. First, because a
///    destination on a remote that does not exist is not a destination whatever else is set.
/// 3. `pushRef` non-nil → `.push(pushRemote, pushRef)`. That field is filled in by exactly one
///    configuration, `remote.<name>.push` (measured row h), and honouring it is the difference
///    between pushing where the user's own `git push` goes and pushing somewhere else.
/// 4. `pushRemote == upstreamRemote`, no `pushRef`, and an `upstreamRef` naming another branch
///    → `.refused(.upstreamNameDiffers)`. Measured row g: git's default `push.default=simple`
///    refuses this outright (`fatal: The upstream branch of your current branch does not match
///    the name of your current branch.`) and Gitter refuses too, because either answer would
///    surprise — pushing to `<remote>/<branch>` creates a branch nobody asked for while the
///    badge goes on counting against the upstream, and pushing to the upstream's name publishes
///    onto a branch called something else.
/// 5. Otherwise `.push(pushRemote, "refs/heads/<branch>")`.
///
/// **This is the first of two checks, not the only one.** Whatever ref comes out of here is
/// handed to `GitRemoteBackend.push`, which refuses a destination that is not a full
/// `refs/heads/…` name — no `:`, no leading `-` or `+` — before git is launched
/// (`requirePushDestination` in `CLIGitBackend+Push`). That backstop is why rule 3 can honour
/// `%(push:remoteref)` as git reports it without this function having to validate a field git
/// filled in: a value that would make a refspec nobody chose is refused on the way out, by the
/// one place that knows how the refspec is spelled.
///
/// **A known limit of rule 4.** `push.default` is not among the fields `for-each-ref` reports —
/// measured: rows (g) under `simple`, `upstream` and `current` print byte-identical fields
/// while a bare `git push` refuses, pushes to the upstream's name and pushes to the branch's
/// name respectively. Gitter cannot see which is configured, so it refuses all three and says
/// to push once from a terminal with an explicit destination. A user who has set
/// `push.default=upstream` or `current` is therefore refused where their own git would not be.
/// Deferred in `docs/BACKLOG.md`; reading `push.default` is a separate config read and a
/// separate decision.
public enum PushTarget: Equatable, Sendable {
    case push(remote: String, ref: String)
    /// There is nowhere to push yet: the button reads "Publish" and the sheet names the remote.
    /// **Not** the same as "has no upstream" — measured rows (b), (c), (e) and (f) give the two
    /// answers in both combinations.
    case unpublished
    case refused(PushTargetRefusal)

    /// Pure and total: it reads only the fields `RefParser` filled in and answers for every
    /// input, including a remote-tracking branch (which has no push fields, so `.unpublished`)
    /// and an empty remote list.
    public static func resolve(_ branch: Branch, remotes: [Remote]) -> PushTarget {
        guard let pushRemote = branch.pushRemote else { return .unpublished }
        guard let entry = remotes.first(where: { $0.name == pushRemote }) else {
            return .refused(.unknownRemote(pushRemote))
        }
        // A remote with no URL (listed since B2 Task 3) is no destination: a push to it uses its
        // name as a path (fix round 1, I1).
        guard entry.canPush else { return .refused(.noURL(pushRemote)) }
        if let pushRef = branch.pushRef { return .push(remote: pushRemote, ref: pushRef) }

        let ownRef = "refs/heads/" + branch.name
        if pushRemote == branch.upstreamRemote, let upstreamRef = branch.upstreamRef,
            upstreamRef != ownRef {
            // `upstream` is `%(upstream:short)` — "origin/main", the spelling the user sees in
            // git's own messages. It is always there when `upstreamRef` is, but the fallback
            // keeps this total rather than resting on that.
            return .refused(.upstreamNameDiffers(upstream: branch.upstream ?? upstreamRef))
        }
        return .push(remote: pushRemote, ref: ownRef)
    }

    /// The count a "Push" button may draw beside itself, or nil to draw none.
    ///
    /// `Branch.tracking` is measured against the **upstream**; a push goes wherever `resolve`
    /// says. The two are the same ref only when the push goes to exactly the upstream's remote
    /// and ref, so that is the only time the ahead count says what a push would send. Measured
    /// in Task 9's review: with `branch.main.pushRemote=fork` (rows b/c) the toolbar read
    /// "Push ↑1" while `git push --dry-run` answered "Everything up-to-date" — the count was
    /// against `origin/main` and the push went to `fork`. Nil too for a refused target (a
    /// disabled Push must not advertise commits it will not send), an unpublished branch, a
    /// local upstream, a `[gone]` upstream, and nothing ahead.
    ///
    /// **The same remote name is not the same repository.** The count is against a
    /// remote-tracking ref that a fetch from the remote's *fetch* URL keeps; a push goes to its
    /// *push* URL. Measured in Task 9's second review: `git remote set-url --push origin
    /// fork2.git` on a branch level with `fork2` read "Push ↑1" while `git push --dry-run` said
    /// "Everything up-to-date". So the count also needs `pushURL == fetchURL`, both present — a
    /// remote missing either cannot be shown to push where it fetches from. (Only the first
    /// push URL is compared; a remote with several pushes to all of them.)
    public static func aheadCountToDisplay(for branch: Branch, remotes: [Remote]) -> Int? {
        guard !branch.tracksLocalBranch,
            case .counts(let ahead, _) = branch.tracking, ahead > 0,
            case .push(let remote, let ref) = resolve(branch, remotes: remotes),
            remote == branch.upstreamRemote, ref == branch.upstreamRef,
            pushesWhereItFetches(remote, remotes: remotes)
        else { return nil }
        return ahead
    }

    /// Whether `remote` pushes to the URL it fetches from: both known, and equal. False for a
    /// remote not in `remotes`.
    public static func pushesWhereItFetches(_ remote: String, remotes: [Remote]) -> Bool {
        guard let entry = remotes.first(where: { $0.name == remote }),
            let fetchURL = entry.fetchURL, let pushURL = entry.pushURL
        else { return false }
        return fetchURL == pushURL
    }
}


/// Whether a click on the toolbar's Stop is a decision to stop.
///
/// The Stop button appears the moment a network action starts, in the same toolbar item as the
/// button that started it. A click that lands within the double-click interval of the start is
/// the second half of that first click — Task 9's review reproduced a double-click on Fetch
/// cancelling the fetch it had just begun — so it is dropped. The system interval can be set up
/// to 5 s; Stop never ignores a click for longer than `longestGuard`. ⌘. and the menu's Stop are
/// deliberate and do not come through here.
public enum StopClick {
    /// The cap on the guard, in seconds — about the default double-click interval (0.5 s).
    public static let longestGuard: TimeInterval = 0.6

    public static func isDeliberate(
        startedAt: Date, now: Date, doubleClickInterval: TimeInterval
    ) -> Bool {
        now.timeIntervalSince(startedAt) >= min(doubleClickInterval, longestGuard)
    }
}

/// What `rebase(onto:at:)` — or, since B1, `rebase(_:at:)` with a `RebasePlan` — did, read back
/// from the repository afterwards — from `operationInProgress` and from where HEAD ended up —
/// never from git's exit code or its prose.
///
/// Four cases where the design document had three. **`.fastForwarded` was added in Task 7**
/// because git words two different things the same way: measured on git 2.54, a branch with
/// nothing of its own that is behind its upstream is *moved* by `git rebase` to the upstream's
/// tip — "Successfully rebased and updated refs/heads/main." — without a single commit being
/// rewritten. Calling that `.rebased` would have the store tell the user their commits were
/// rewritten when none were.
///
/// `.conflicts` is an outcome, not an error, exactly as it is for `MergeOutcome`: the rebase
/// has stopped in the existing `.rebase` operation, with the existing note and Abort sheet.
public enum RebaseOutcome: Equatable, Sendable {
    /// HEAD did not move: git said "Current branch <b> is up to date." and wrote nothing.
    ///
    /// **"The upstream is already underneath" does not guarantee this.** Measured: a branch
    /// whose own commits above the upstream include a merge commit is *flattened* by a plain
    /// rebase — the merge dropped, the commits under it replayed — so HEAD moves and the answer
    /// is `.rebased`. Only HEAD standing still is read as "up to date".
    case upToDate
    /// HEAD moved forward to exactly the upstream's tip, and the old HEAD is an ancestor of it:
    /// nothing was rewritten and nothing is off the branch.
    case fastForwarded
    /// HEAD moved anywhere else. The branch's own commits are new objects now; the old tip is in
    /// `ORIG_HEAD` and the reflog.
    ///
    /// **It can have rewritten zero commits and still be this.** A local commit whose change the
    /// upstream already carries is dropped ("skipped previously applied commit"), and when every
    /// local commit is, HEAD lands on the upstream's tip just as a fast-forward's does. The old
    /// tip is then *not* an ancestor of the new one — a commit left the branch — which is why
    /// the ancestry, and not the landing place alone, decides `.fastForwarded`.
    case rebased
    /// The rebase **stopped** part-way — usually on a conflict, but not only: `rebase-merge/`
    /// (or, under `rebase.backend=apply`, `rebase-apply/`) is in place, the snapshot reports
    /// `RepositoryOperation.rebase`, HEAD is **detached** on the last commit that applied, and
    /// the branch itself has not moved yet. `abort(.rebase)` puts the branch and the index back.
    ///
    /// The name says "conflicts" because that is the common case, but the meaning is "a rebase
    /// is in progress after the call" and nothing more. Measured stops with **no unmerged
    /// entry**: a commit that cannot be signed (`commit.gpgSign=true`, `gpg.program` failing),
    /// and an untracked file in the way of a commit replayed part-way (git prints the
    /// "would be overwritten" refusal text, but it prints it mid-rebase). A caller must not
    /// promise the user a conflict to resolve; it can promise a rebase to continue or abort.
    case conflicts
}

/// What a pull does after its fetch, decided from the branch's tracking alone — the design
/// document's "Pull, as the store performs it" table.
///
/// **The tracking must be the one read after the fetch.** Before it, `behind` is whatever the
/// last fetch saw, and "nothing to do" could be a statement about yesterday.
public enum PullPlan: Equatable, Sendable {
    /// Nothing to bring in: level, or ahead only. A pull never pushes.
    case nothingToDo
    /// Behind only: `merge(upstream, .fastForwardIfPossible)`, with every existing refusal.
    case fastForward
    /// Both sides have commits the other lacks: the pull sheet, Merge or Rebase, with these
    /// counts.
    case askHowToIntegrate(ahead: Int, behind: Int)
    /// The branch has no upstream (Pull is disabled with a reason).
    case noUpstream
    /// The upstream is configured but its remote-tracking ref is gone.
    case upstreamGone

    /// Pure and total. A **negative** count is read as 0: git never prints one, but
    /// `Tracking.parse` reads the number with `Int(_:)`, which would accept `-1`, and "nothing
    /// on that side" is the reading that never asks the user to integrate commits that do not
    /// exist.
    public static func decide(_ tracking: Tracking) -> PullPlan {
        switch tracking {
        case .none:
            return .noUpstream
        case .gone:
            return .upstreamGone
        case .counts(let rawAhead, let rawBehind):
            let ahead = max(0, rawAhead)
            let behind = max(0, rawBehind)
            if behind == 0 { return .nothingToDo }
            if ahead == 0 { return .fastForward }
            return .askHowToIntegrate(ahead: ahead, behind: behind)
        }
    }

    /// The count a "Pull" button may draw beside itself, or nil to draw none: the behind count
    /// against a **remote** upstream. A pull fetches the upstream's remote and integrates the
    /// upstream, so — unlike a push — the count is right even when the branch pushes elsewhere.
    /// Nil for a local upstream (the badge carries that, naming the branch), `.gone`, `.none`,
    /// and nothing behind.
    public static func behindCountToDisplay(for branch: Branch) -> Int? {
        guard !branch.tracksLocalBranch, branch.upstreamRemote != nil,
            case .counts(_, let behind) = branch.tracking, behind > 0
        else { return nil }
        return behind
    }
}
