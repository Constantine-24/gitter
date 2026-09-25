import Foundation

/// Which configured fetch refspecs a Gitter fetch refuses to run under.
///
/// **A fetch is only a read of the server while every refspec it uses writes into
/// `refs/remotes/`.** The refspecs are the user's configuration (`remote.<name>.fetch`), not
/// Gitter's vector, and they decide where fetched refs land. Measured on git 2.54 in the final
/// review (`frqa/ia`): with `remote.origin.fetch=+refs/heads/*:refs/heads/*` — which is also
/// part of what `git remote add --mirror=fetch` writes, as `+refs/*:refs/*` — every Gitter
/// fetch, the automatic one every ten minutes included, force-updated local branches
/// (`topic@{0}: fetch --progress --no-prune --all: forced-update`, the local commit left on no
/// ref). git protects only the checked-out branch, and only when the server has it too.
/// `+refs/tags/*:refs/tags/*` replaces local tags the same way.
///
/// **The rule: a refspec with a destination that does not begin `refs/remotes/` is unsafe.**
/// Parsed the way git parses one — an optional leading `+`, then `<src>:<dst>` split at the
/// **last** `:` — and measured for each shape that is *not* refused:
///
/// | refspec | what `git fetch <remote>` wrote |
/// |---|---|
/// | `+refs/heads/*:refs/remotes/origin/*` | remote-tracking refs only |
/// | `refs/heads/topic` (a bare source) | `FETCH_HEAD` only; no ref moved |
/// | `refs/heads/topic:` (an empty destination) | `FETCH_HEAD` only; no ref moved |
/// | `^refs/heads/topic` (negative) | nothing of its own: it only removes matches |
///
/// A negative refspec with a destination (`^a:b`) is `fatal: invalid refspec` before anything
/// is contacted (measured), so it is let through for git to refuse. Everything else with a
/// destination outside `refs/remotes/` is refused — a DWIMed short destination included:
/// measured, `+topic:x/y` created `refs/heads/x/y`. Nothing is trimmed and nothing is
/// case-folded, so every spelling this does not recognise as remote-tracking is refused; the
/// cost of that is only ever a refusal git would not have made.
public enum FetchRefspec {
    private static let remoteTracking = "refs/remotes/"

    /// Whether a fetch through `refspec` could write a ref outside `refs/remotes/`.
    public static func writesOutsideRemoteTracking(_ refspec: String) -> Bool {
        if refspec.hasPrefix("^") { return false }
        let body = refspec.hasPrefix("+") ? refspec.dropFirst() : Substring(refspec)
        guard let colon = body.lastIndex(of: ":") else { return false }
        let destination = body[body.index(after: colon)...]
        if destination.isEmpty { return false }
        return !destination.hasPrefix(remoteTracking)
    }

    /// The first refspec in `refspecs` that `writesOutsideRemoteTracking`, in configuration
    /// order, or nil when a fetch through all of them is a read of the server.
    public static func firstUnsafe(_ refspecs: [String]) -> String? {
        refspecs.first(where: writesOutsideRemoteTracking)
    }
}
