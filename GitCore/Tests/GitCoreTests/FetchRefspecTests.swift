import Foundation
import Testing

@testable import GitCore

/// `FetchRefspec` — which configured `remote.<name>.fetch` values a Gitter fetch refuses.
///
/// Every row was measured on git 2.54 against a local bare repository, a `topic` branch on the
/// server one commit ahead of a *diverged* local `topic` that was not checked out (the final
/// review's `frqa/ia` shape). The rule is one sentence: **a destination not under
/// `refs/remotes/` is refused**; no destination at all (a bare source, an empty right-hand
/// side, a negative refspec) writes only `FETCH_HEAD` and is not.
@Suite struct FetchRefspecTests {
    /// Each wrote, or would write, outside `refs/remotes/`.
    @Test(arguments: [
        // `topic@{0}: fetch …: forced-update`, the local commit left on no ref (measured).
        "+refs/heads/*:refs/heads/*",
        // Non-forced: git rejects the non-fast-forward (`! [rejected] topic -> topic`), but a
        // fast-forward of a local branch the user did not ask to move is still a write there.
        "refs/heads/topic:refs/heads/topic",
        // Replaces a local annotated tag of the same name.
        "+refs/tags/*:refs/tags/*",
        // `git remote add --mirror=fetch` writes exactly this.
        "+refs/*:refs/*",
        // A short destination is DWIMed into `refs/heads/`: measured, `+topic:x/y` created
        // `refs/heads/x/y`.
        "+topic:x/y",
        "topic:topic",
        // Not a spelling git would DWIM into `refs/remotes/`: refused rather than guessed.
        "+refs/heads/*:remotes/origin/*",
        "+refs/heads/*:REFS/remotes/origin/*",
        // Several colons cannot occur in a valid refspec; git splits at the last one, and so
        // does this — `refs/heads/b` is not under `refs/remotes/`.
        "+refs/remotes/a:refs/remotes/x:refs/heads/b",
        // A leading space is not trimmed: git would reject the refspec, and refusing costs
        // nothing.
        " +refs/heads/*:refs/heads/*",
    ])
    func refusesADestinationOutsideRemoteTracking(refspec: String) {
        #expect(FetchRefspec.writesOutsideRemoteTracking(refspec))
        #expect(FetchRefspec.firstUnsafe(["+refs/heads/*:refs/remotes/origin/*", refspec]) == refspec)
    }

    @Test(arguments: [
        // The default `git clone` writes.
        "+refs/heads/*:refs/remotes/origin/*",
        "refs/heads/main:refs/remotes/origin/main",
        // Into another remote's namespace is still remote-tracking.
        "+refs/heads/*:refs/remotes/fork/*",
        // Negative: no destination. (`^a:b` is `fatal: invalid refspec` before anything is
        // contacted — measured — so it cannot write anything either.)
        "^refs/heads/topic",
        // A bare source: measured, `FETCH_HEAD` only, no ref moved.
        "refs/heads/topic",
        // An empty destination: the same, measured.
        "refs/heads/topic:",
        "",
    ])
    func acceptsARefspecThatWritesOnlyRemoteTrackingRefsOrFetchHead(refspec: String) {
        #expect(!FetchRefspec.writesOutsideRemoteTracking(refspec))
    }

    @Test func firstUnsafeIsNilForTheDefaultAndNamesTheFirstOffender() {
        #expect(FetchRefspec.firstUnsafe([]) == nil)
        #expect(FetchRefspec.firstUnsafe(["+refs/heads/*:refs/remotes/origin/*", "^refs/heads/x"]) == nil)
        #expect(
            FetchRefspec.firstUnsafe([
                "+refs/heads/*:refs/remotes/origin/*", "+refs/tags/*:refs/tags/*",
                "+refs/heads/*:refs/heads/*",
            ]) == "+refs/tags/*:refs/tags/*")
    }
}
