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
