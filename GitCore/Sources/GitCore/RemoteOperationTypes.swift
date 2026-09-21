import Foundation

/// The value types `GitRemoteBackend` hands back or throws.
///
/// Split out of `GitRemoteBackend.swift` for length only, exactly as `BranchOperationTypes` is
/// split out of `GitBranchBackend`. `RemoteFailureParser` is what turns git's stderr into a
/// `RemoteOperationError`.

/// A network failure Gitter can describe in its own words, rather than dumping git's stderr.
///
/// **This is not `BranchOperationError`, and the difference matters.** Every case of that type
/// is a refusal: git did nothing, and the UI may say so. Here, only the two cases thrown
/// *before git runs* (`.noRemote` for a name Gitter will not pass on, and `.noUpstream`) carry
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
    /// with no remote configured at all. Thrown **before git runs**, so it is the one case here
    /// besides `.noUpstream` that really does mean nothing changed. See `GitRemoteBackend.fetch`
    /// for what each refused name would otherwise have meant to git.
    case noRemote
    /// The branch has no upstream, so there is nothing for the operation to work against. Not
    /// thrown by `fetch`, which does not need one; it is here for the operations in the tasks
    /// that follow, which do.
    case noUpstream
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
    /// Whether the branch's upstream is now what `setUpstream: true` asked for, or `nil` when
    /// there is nothing to report: the push did not ask for one, or the server refused it, in
    /// which case git had no occasion to write one.
    ///
    /// **`-u` is best-effort in git, and Gitter reads it back.** Measured on git 2.54 with
    /// `.git/config` made unwritable: the push succeeds and exits **0**, the branch appears on
    /// the server, the `branch '…' set up to track '…'.` notice is simply absent, and the
    /// failure is two `error:` lines on stderr that `remoteMessages` does not carry because
    /// they are not the server's. A caller that trusted `-u` would show a published branch with
    /// an upstream it does not have — so the upstream is read back out of
    /// `branch.<name>.remote` / `branch.<name>.merge` and reported here.
    ///
    /// `false` means "not confirmed" rather than "definitely not written": it is also what a
    /// read-back that could not be run answers, because in both cases Gitter cannot say the
    /// branch is tracking what it was asked to track.
    public let upstreamWasSet: Bool?
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
        outcome: PushOutcome, remoteMessages: [String], upstreamWasSet: Bool? = nil,
        errorLines: [String] = []
    ) {
        self.outcome = outcome
        self.remoteMessages = remoteMessages
        self.upstreamWasSet = upstreamWasSet
        self.errorLines = errorLines
    }
}

/// Why Gitter will not push a branch even though git might.
public enum PushTargetRefusal: Equatable, Sendable {
    /// `%(push:remotename)` named a remote that is not configured. Measured (row k): git prints
    /// whatever `branch.<name>.pushRemote` says, configured or not, and only fails at the far
    /// end with `fatal: '<name>' does not appear to be a git repository`. Naming the bad name
    /// here is more use than showing the user that sentence.
    case unknownRemote(String)
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
/// 2. A `pushRemote` that is not in `remotes` → `.refused(.unknownRemote)`. First, because a
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
        guard remotes.contains(where: { $0.name == pushRemote }) else {
            return .refused(.unknownRemote(pushRemote))
        }
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
}
