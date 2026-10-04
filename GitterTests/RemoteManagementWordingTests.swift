import Foundation
import GitCore
import Testing

@testable import Gitter

/// B2 Task 5: Add Remote…, Edit URL…, Rename… and Remove… — every sentence their sheets, notices
/// and banners put on screen (`RemoteAdminWording`), the URLs shown in them (redacted for display
/// only, carried note 1), what the Edit URL form writes, and the reasons a disabled item shows.
/// Above all the half-done and unknown outcomes, which must never read as "nothing happened"
/// (carried note 4). Pure: no store, no git.
@Suite struct RemoteManagementWordingTests {
    static let id1 = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
    static let id2 = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"
    static let origin = Remote(name: "origin", fetchURL: "/srv/o.git", pushURL: "/srv/o.git")
    static let nourl = Remote(name: "vendor", fetchURL: nil, pushURL: nil)
    static let pushOnly = Remote(name: "po", fetchURL: nil, pushURL: "/srv/po.git")

    static func gate(
        _ remotes: [Remote] = [origin], activity: RemoteActivity? = nil, isMutating: Bool = false,
        hasRepository: Bool = true
    ) -> RemoteWording.Gate {
        RemoteWording.Gate(
            hasRepository: hasRepository, activity: activity, isMutating: isMutating,
            operation: nil, isDetached: true, branch: nil, remotes: remotes)
    }

    // MARK: - Titles and menu reasons

    @Test func theTitlesNameWhatTheyActOn() {
        #expect(RemoteAdminWording.addRemoteTitle == "Add Remote…")
        #expect(RemoteAdminWording.editURLTitle == "Edit URL…")
        #expect(RemoteAdminWording.renameRemoteTitle == "Rename…")
        #expect(RemoteAdminWording.removeRemoteTitle == "Remove…")
        #expect(RemoteAdminWording.addRemoteSheetTitle == "Add Remote")
        #expect(RemoteAdminWording.editURLSheetTitle("origin") == "Edit URL of \"origin\"")
        #expect(RemoteAdminWording.renameRemoteSheetTitle("origin") == "Rename Remote \"origin\"")
        #expect(RemoteAdminWording.removeRemoteSheetTitle("origin") == "Remove Remote \"origin\"")
    }

    /// Add and Edit URL are configuration writes through `mutate`: only a running change stops
    /// them. A busy lane does not — they touch no remote-tracking ref.
    @Test func addAndEditURLWaitOnlyForARunningChange() {
        let lane = RemoteActivity(kind: .fetch, remote: "origin", progress: nil)
        #expect(RemoteAdminWording.addRemoteBlocked(Self.gate()) == nil)
        #expect(RemoteAdminWording.addRemoteBlocked(Self.gate([])) == nil)
        #expect(RemoteAdminWording.addRemoteBlocked(Self.gate(activity: lane)) == nil)
        #expect(RemoteAdminWording.addRemoteBlocked(Self.gate(isMutating: true)) == RemoteWording.mutationBusy)
        #expect(RemoteAdminWording.addRemoteBlocked(Self.gate(hasRepository: false)) == RemoteWording.noRepository)
        #expect(RemoteAdminWording.editURLBlocked(Self.gate(activity: lane)) == nil)
        #expect(RemoteAdminWording.editURLBlocked(Self.gate(isMutating: true)) == RemoteWording.mutationBusy)
        #expect(RemoteAdminWording.editURLBlocked(Self.gate(hasRepository: false)) == RemoteWording.noRepository)
    }

    /// Rename and Remove run on the lane (R21, R23: never beside a fetch), holding the slot.
    @Test func renameAndRemoveWaitForTheLaneAndForARunningChange() {
        let lane = RemoteActivity(kind: .fetch, remote: "origin", progress: nil)
        for blocked in [RemoteAdminWording.renameRemoteBlocked, RemoteAdminWording.removeRemoteBlocked] {
            #expect(blocked(Self.gate()) == nil)
            // A remote with no URL can be renamed and removed: neither contacts it.
            #expect(blocked(Self.gate([Self.nourl])) == nil)
            #expect(blocked(Self.gate(activity: lane)) == RemoteWording.laneBusy(lane))
            #expect(blocked(Self.gate(isMutating: true)) == RemoteWording.mutationBusy)
            #expect(blocked(Self.gate(hasRepository: false)) == RemoteWording.noRepository)
        }
    }

    // MARK: - Remotes with no URL in the sidebar

    @Test func aRemoteWithNoURLIsMarkedAndPointsAtEditURL() {
        #expect(RemoteAdminWording.remoteBadge(Self.origin) == nil)
        #expect(RemoteAdminWording.remoteHelp(Self.origin) == nil)
        #expect(RemoteAdminWording.remoteBadge(Self.nourl) == "no URL")
        #expect(
            RemoteAdminWording.remoteHelp(Self.nourl)
                == "\"vendor\" has no URL, so nothing can be fetched from it or pushed to it. Give it one with Edit URL….")
        #expect(RemoteAdminWording.remoteBadge(Self.pushOnly) == "push URL only")
        #expect(
            RemoteAdminWording.remoteHelp(Self.pushOnly)
                == "\"po\" has only a push URL, so nothing can be fetched from it. Give it one with Edit URL….")
    }

    // MARK: - URLs shown, redacted for display only (carried note 1)

    @Test(arguments: [
        ("https://alice:s3cret@example.invalid/o/r.git", "https://example.invalid/o/r.git"),
        ("https://ghp_tok@example.invalid/o/r.git", "https://example.invalid/o/r.git"),
        // An ssh login is no secret, and without it the address names another account.
        ("git@example.invalid:o/r.git", "git@example.invalid:o/r.git"),
        ("ssh://git@example.invalid:2222/o/r.git", "ssh://git@example.invalid:2222/o/r.git"),
        ("/srv/repos/o.git", "/srv/repos/o.git"),
        ("file:///srv/repos/o.git", "file:///srv/repos/o.git"),
        // Strip before redacting: a control inside the userinfo must not shield the password.
        ("https://u:\u{0B}secret@example.invalid/r.git", "https://example.invalid/r.git"),
    ])
    func aURLIsShownWithoutItsCredential(url: String, shown: String) {
        #expect(RemoteAdminWording.displayURL(url) == shown)
    }

    /// Fix round 1, I4: a configured URL is redacted by its structure, not as prose — RFC 3986's
    /// sub-delims (`'`, `(`, `)`, …) are legal in a userinfo, and a prose redactor stops at them.
    /// Everything up to the authority's LAST `@` goes (the authority ends at the first `/`, `?`
    /// or `#`); scp-like, everything up to the last `@` of the host part.
    static let structuralCases: [(url: String, shown: String)] = [
        ("https://u:p'ss@example.invalid/x.git", "https://example.invalid/x.git"),
        ("https://u:p(ss)@example.invalid/x.git", "https://example.invalid/x.git"),
        ("https://u:p ss@example.invalid/x.git", "https://example.invalid/x.git"),
        ("https://u:p\"ss@example.invalid/x.git", "https://example.invalid/x.git"),
        ("https://u:p@ss@example.invalid/x.git", "https://example.invalid/x.git"),
        ("https://u:p%40ss@example.invalid/x.git", "https://example.invalid/x.git"),
        ("https://(tok)@example.invalid/x.git", "https://example.invalid/x.git"),
        ("ssh://u:p(ss)@example.invalid/x.git", "ssh://example.invalid/x.git"),
        ("https://u:p@[::1]:8443/x.git", "https://[::1]:8443/x.git"),
        // scp-like: a password, sub-delims and `@` in it, before the host.
        ("u:p(ss)@example.invalid:o/x.git", "example.invalid:o/x.git"),
        ("u:p@ss@example.invalid:o/x.git", "example.invalid:o/x.git"),
        ("u:p'ss@example.invalid:/abs/x.git", "example.invalid:/abs/x.git"),
        // Nothing to hide: unchanged.
        ("https://example.invalid/x.git", "https://example.invalid/x.git"),
        ("https://example.invalid/x.git?ref=a@b", "https://example.invalid/x.git?ref=a@b"),
        ("https://example.invalid/a@b/x.git", "https://example.invalid/a@b/x.git"),
        ("git@example.invalid:team@2024/x.git", "git@example.invalid:team@2024/x.git"),
        ("file:///srv/a(b)@c.git", "file:///srv/a(b)@c.git"),
        ("/srv/a:b@c.git", "/srv/a:b@c.git"),
        ("../rel/a:b@c.git", "../rel/a:b@c.git"),
    ]

    @Test(arguments: structuralCases)
    func aConfiguredURLIsRedactedByItsStructure(url: String, shown: String) {
        #expect(RemoteAdminWording.displayURL(url) == shown)
        #expect(!RemoteAdminWording.displayURL(url).contains("p(ss)"))
        #expect(RemoteAdminWording.hidesCredential(url) == (url != shown))
    }

    /// I4: the notices and banners built from a URL hide such a password too.
    @Test func noticesAndBannersHideAPasswordWithSubDelims() {
        let secret = "https://u:p(ss)@example.invalid/x.git"
        let texts = [
            RemoteAdminWording.remoteAdded("up", url: secret),
            RemoteAdminWording.urlsChanged("up", fetch: secret, push: .set(secret)),
            RemoteAdminWording.connectsTo(RemoteURLs(fetch: ["/x"], push: [], effectiveFetch: secret)) ?? "",
            RemoteAdminWording.addRemoteFailure(
                RemoteAdminPartial.urlsChangedThenFailed(
                    remote: "up", now: RemoteURLs(fetch: [secret], push: [secret], effectiveFetch: nil),
                    gitsWords: "fatal: x"), name: "up"),
            RemoteAdminWording.editURLFailure(
                RemoteAdminPartial.urlsChangedThenFailed(
                    remote: "up", now: RemoteURLs(fetch: [secret], push: [], effectiveFetch: nil), gitsWords: "fatal: x"),
                remote: "up"),
        ]
        for text in texts {
            #expect(!text.contains("p(ss)"), "\(text)")
            #expect(!text.contains("u:"), "\(text)")
        }
    }

    /// The field starts with the configured URL as written — unless that would show a
    /// credential: then it starts empty, and an empty field keeps the configured URL.
    @Test func theURLFieldNeverShowsACredential() {
        #expect(RemoteAdminWording.urlFieldStart("https://example.invalid/o/r.git") == "https://example.invalid/o/r.git")
        #expect(RemoteAdminWording.urlFieldStart("git@example.invalid:o/r.git") == "git@example.invalid:o/r.git")
        #expect(RemoteAdminWording.urlFieldStart("https://alice:s3cret@example.invalid/r.git") == "")
        #expect(RemoteAdminWording.urlFieldStart(nil) == "")
        #expect(RemoteAdminWording.hidesCredential("https://alice:s3cret@example.invalid/r.git"))
        #expect(!RemoteAdminWording.hidesCredential("git@example.invalid:o/r.git"))
        let secret = "https://alice:s3cret@example.invalid/r.git"
        #expect(RemoteAdminWording.urlToWrite(field: "", configured: secret) == secret)
        #expect(RemoteAdminWording.urlToWrite(field: "  /srv/new.git \n", configured: secret) == "/srv/new.git")
        // No credential to keep: an empty field is an empty URL, which the form refuses.
        #expect(RemoteAdminWording.urlToWrite(field: "", configured: "/srv/o.git") == "")
        #expect(RemoteAdminWording.urlToWrite(field: "", configured: nil) == "")
        #expect(
            RemoteAdminWording.credentialKept
                == "It holds a credential, which is not shown. Leave the field empty to keep it as it is.")
    }

    /// The push URL is tri-state (`PushURLChange`): left alone, set, or cleared.
    @Test func thePushChoiceBecomesAPushURLChange() {
        // Pushing to the fetch URL, as now: nothing to write.
        #expect(RemoteAdminWording.pushChange(ownPushURL: false, field: "", configured: []) == .unchanged)
        // Pushing to the fetch URL instead of its own: the push URL is cleared.
        #expect(RemoteAdminWording.pushChange(ownPushURL: false, field: "/p.git", configured: ["/p.git"]) == .clear)
        #expect(RemoteAdminWording.pushChange(ownPushURL: true, field: "/p.git", configured: ["/p.git"]) == .unchanged)
        #expect(RemoteAdminWording.pushChange(ownPushURL: true, field: " /q.git ", configured: ["/p.git"]) == .set("/q.git"))
        #expect(RemoteAdminWording.pushChange(ownPushURL: true, field: "/q.git", configured: []) == .set("/q.git"))
        // A credential kept by an empty field is no change.
        let secret = "https://u:p@example.invalid/r.git"
        #expect(RemoteAdminWording.pushChange(ownPushURL: true, field: "", configured: [secret]) == .unchanged)
        // Several push URLs are shown read-only and never written (`.severalURLs`).
        #expect(RemoteAdminWording.pushChange(ownPushURL: true, field: "/q.git", configured: ["/a", "/b"]) == .unchanged)
        #expect(RemoteAdminWording.pushChange(ownPushURL: false, field: "", configured: ["/a", "/b"]) == .unchanged)
    }

    @Test func saveIsOnlyOfferedForAChange() {
        let urls = RemoteURLs(fetch: ["/o.git"], push: [], effectiveFetch: "/o.git")
        #expect(!RemoteAdminWording.editURLWrites(urls, fetch: "/o.git", push: .unchanged))
        #expect(RemoteAdminWording.editURLWrites(urls, fetch: "/n.git", push: .unchanged))
        #expect(RemoteAdminWording.editURLWrites(urls, fetch: "/o.git", push: .set("/p.git")))
        let none = RemoteURLs(fetch: [], push: [], effectiveFetch: nil)
        #expect(RemoteAdminWording.editURLWrites(none, fetch: "/o.git", push: .unchanged))
    }

    /// The form's own check mirrors what GitCore refuses (`RemoteAdminRefusal.unsafeURL`); GitCore
    /// stays the authority.
    @Test func aURLGitterWillNotWriteIsNamedBeforeTheClick() {
        #expect(RemoteAdminWording.urlProblem("/srv/o.git") == nil)
        #expect(RemoteAdminWording.urlProblem("https://example.invalid/o.git") == nil)
        #expect(RemoteAdminWording.urlProblem("  ") == "Enter a URL.")
        #expect(
            RemoteAdminWording.urlProblem("-oProxyCommand=x")
                == "A URL can't begin with \"-\": git would read it as an option.")
        #expect(
            RemoteAdminWording.urlProblem("EXT::sh -c x")
                == "Gitter won't write an ext:: URL: git would run it as a command.")
        #expect(RemoteAdminWording.urlProblem("/a\u{07}b") == "A URL can't hold a control character.")
    }

    /// R20: `remote -v` shows the rewritten URL; the sheet shows the configured one and says where
    /// git really connects only beside it, redacted.
    @Test func theInsteadOfRewriteIsOnlyAnInformationLine() {
        let same = RemoteURLs(fetch: ["/o.git"], push: [], effectiveFetch: "/o.git")
        #expect(RemoteAdminWording.connectsTo(same) == nil)
        let rewritten = RemoteURLs(
            fetch: ["https://example.invalid/o/r.git"], push: [], effectiveFetch: "git@example.invalid:o/r.git")
        #expect(
            RemoteAdminWording.connectsTo(rewritten)
                == "git connects to git@example.invalid:o/r.git: a url.<base>.insteadOf rule rewrites it. "
                + "Saving keeps the URL as you typed it.")
        let secret = RemoteURLs(
            fetch: ["https://example.invalid/r.git"], push: [], effectiveFetch: "https://u:tok@mirror.invalid/r.git")
        #expect(RemoteAdminWording.connectsTo(secret)?.contains("tok") == false)
        #expect(RemoteAdminWording.connectsTo(RemoteURLs(fetch: [], push: [], effectiveFetch: nil)) == nil)
    }

    /// R22: several `url` values cannot be set with a plain `set-url`; they are shown as written.
    @Test func severalURLsAreShownReadOnlyWithTheReason() {
        let one = RemoteURLs(fetch: ["/o.git"], push: ["/p.git"], effectiveFetch: "/o.git")
        #expect(RemoteAdminWording.severalFetchURLs(one, remote: "origin") == nil)
        #expect(RemoteAdminWording.severalPushURLs(one, remote: "origin") == nil)
        let many = RemoteURLs(fetch: ["/a.git", "/b.git"], push: ["/p.git", "/q.git"], effectiveFetch: "/a.git")
        #expect(
            RemoteAdminWording.severalFetchURLs(many, remote: "origin")
                == "\"origin\" has 2 fetch URLs; git fetches from the first. Gitter changes the URL only of a "
                + "remote with one, so they are shown as written. Change them in a terminal with git remote set-url.")
        #expect(
            RemoteAdminWording.severalPushURLs(many, remote: "origin")
                == "\"origin\" has 2 push URLs, and git pushes to each. They are shown as written and left as they are.")
    }

    @Test func remoteNameProblemsAreWorded() {
        #expect(RemoteAdminWording.remoteNameProblem(.empty) == "Enter a name for the remote.")
        #expect(RemoteAdminWording.remoteNameProblem(.invalid) == "That is not a valid remote name.")
        #expect(
            RemoteAdminWording.remoteNameProblem(.reserved)
                == "\"HEAD\" and \"@\" already mean something to git. Choose another name.")
        #expect(
            RemoteAdminWording.remoteNameProblem(.exists)
                == "A remote with that name already exists (names are compared ignoring case).")
        #expect(
            RemoteAdminWording.remoteNameProblem(.nested("origin"))
                == "It would share a folder of remote-tracking branches with \"origin\": one name is inside the other.")
    }

    // MARK: - Notices

    @Test func theNoticesNameTheURLsRedacted() {
        #expect(
            RemoteAdminWording.remoteAdded("up", url: "https://u:tok@example.invalid/r.git")
                == "Added the remote \"up\" (https://example.invalid/r.git).")
        #expect(
            RemoteAdminWording.urlsChanged("origin", fetch: "https://u:tok@example.invalid/r.git", push: .unchanged)
                == "\"origin\" now fetches from https://example.invalid/r.git.")
        #expect(
            RemoteAdminWording.urlsChanged("origin", fetch: "/o.git", push: .set("/p.git"))
                == "\"origin\" now fetches from /o.git and pushes to /p.git.")
        #expect(
            RemoteAdminWording.urlsChanged("origin", fetch: "/o.git", push: .clear)
                == "\"origin\" now fetches from /o.git and pushes to the same URL.")
        #expect(RemoteAdminWording.remoteRenamed("origin", to: "upstream") == "Renamed the remote \"origin\" to \"upstream\".")
    }

    // MARK: - Add and Edit URL failures

    @Test func addFailuresSayWhatWasLeft() {
        #expect(
            RemoteAdminWording.addRemoteFailure(RemoteAdminRefusal.nameProblem(.exists), name: "origin")
                == "Couldn't add \"origin\": a remote with that name already exists (names are compared ignoring case). "
                + "Nothing was added.")
        #expect(
            RemoteAdminWording.addRemoteFailure(RemoteAdminRefusal.unsafeURL, name: "up")
                == "Couldn't add \"up\": Gitter won't write that URL — it is empty, begins with \"-\", is an ext:: "
                + "command, or holds a control character. Nothing was added.")
        // Written part of it, then failed: what the configuration holds now, never "nothing".
        let now = RemoteURLs(fetch: ["https://u:tok@example.invalid/r.git"], push: [], effectiveFetch: nil)
        let partial = RemoteAdminWording.addRemoteFailure(
            RemoteAdminPartial.urlsChangedThenFailed(remote: "up", now: now, gitsWords: "error: could not lock config file"),
            name: "up")
        #expect(
            partial
                == "Adding \"up\" failed part-way (error: could not lock config file). \"up\" is configured now, "
                + "with the fetch URL https://example.invalid/r.git and no push URL. Remove it, or edit its URL.")
        #expect(!partial.contains("tok"))
        let gone = RemoteAdminWording.addRemoteFailure(
            RemoteAdminPartial.urlsChangedThenFailed(remote: "up", now: nil, gitsWords: "fatal: x"), name: "up")
        #expect(
            gone
                == "Adding \"up\" failed part-way (fatal: x). Its configuration changed, but \"up\" is not a "
                + "configured remote. Check with: git config --get-regexp '^remote\\.'")
        #expect(
            RemoteAdminWording.addRemoteFailure(RemoteAdminPartial.urlsOutcomeUnknown(remote: "up"), name: "up")
                == "Stopped while git was adding \"up\": whether it was added is not known. Refresh to see.")
    }

    @Test func editURLFailuresSayWhatWasLeft() {
        #expect(
            RemoteAdminWording.editURLFailure(RemoteAdminRefusal.severalURLs, remote: "origin")
                == "\"origin\" has more than one URL of that kind now, and git can't set one of several. Nothing was "
                + "changed. Change them in a terminal with git remote set-url.")
        #expect(
            RemoteAdminWording.editURLFailure(RemoteAdminRefusal.noSuchRemote("origin"), remote: "origin")
                == RemoteAdminWording.remoteGone("origin"))
        #expect(
            RemoteAdminWording.editURLFailure(RemoteAdminRefusal.unsafeURL, remote: "origin")
                == "Couldn't change the URL of \"origin\": Gitter won't write that URL — it is empty, begins with "
                + "\"-\", is an ext:: command, or holds a control character. Nothing was changed.")
        let now = RemoteURLs(fetch: ["/new.git"], push: ["https://u:tok@example.invalid/p.git"], effectiveFetch: "/new.git")
        #expect(
            RemoteAdminWording.editURLFailure(
                RemoteAdminPartial.urlsChangedThenFailed(remote: "origin", now: now, gitsWords: "fatal: lock"),
                remote: "origin")
                == "Changing the URL of \"origin\" failed part-way (fatal: lock). It has the fetch URL /new.git "
                + "and the push URL https://example.invalid/p.git now. Edit its URL again.")
        #expect(
            RemoteAdminWording.editURLFailure(RemoteAdminPartial.urlsOutcomeUnknown(remote: "origin"), remote: "origin")
                == "Stopped while git was changing the URL of \"origin\": which URLs it has now is not known. "
                + "Refresh to see.")
        #expect(
            RemoteAdminWording.urlsChangedWhileShown("origin")
                == "The URLs of \"origin\" changed since you opened this — review again. Nothing was changed.")
    }

    // MARK: - Rename

    @Test func renameRefusalsSayNothingChanged() {
        #expect(
            RemoteAdminWording.renameRemoteFailure(RemoteAdminRefusal.nameProblem(.nested("up")), old: "origin", new: "up/x")
                == "Couldn't rename \"origin\" to \"up/x\": it would share a folder of remote-tracking branches with "
                + "\"up\": one name is inside the other. Nothing was changed.")
        #expect(
            RemoteAdminWording.renameRemoteFailure(RemoteAdminRefusal.noSuchRemote("origin"), old: "origin", new: "up")
                == RemoteAdminWording.remoteGone("origin"))
        #expect(
            RemoteAdminWording.renameRemoteFailure(RemoteOperationError.noSuchRemote("origin"), old: "origin", new: "up")
                == RemoteAdminWording.remoteGone("origin"))
        #expect(
            RemoteAdminWording.renameRemoteFailure(
                RemoteAdminPartial.renameOutcomeUnknown(old: "origin", new: "up"), old: "origin", new: "up")
                == "Stopped while git was renaming \"origin\" to \"up\": what its settings and remote-tracking "
                + "branches hold now is not known. Refresh, and check with: git remote -v")
    }

    /// R21: a held ref lock leaves the section renamed and everything else where it was. The
    /// banner names what git left, and — when renaming back restores exactly the state before —
    /// how to undo it.
    @Test func aHalfDoneRenameNamesWhatGitLeftAndHowToFinish() {
        let left = RenameLeftover(
            old: "origin", new: "up", configured: ["up"],
            refspecsStillOld: ["+refs/heads/*:refs/remotes/origin/*"],
            configStillNamingOld: ["branch.main.remote", "remote.pushdefault"],
            refsUnderOld: ["refs/remotes/origin/main", "refs/remotes/origin/topic"], refsUnderNew: [],
            gitsWords: "error: renaming remote references failed: cannot lock ref 'refs/remotes/origin/main'")
        let text = RemoteAdminWording.renameRemoteFailure(
            RemoteAdminPartial.renameHalfDone(left: left), old: "origin", new: "up")
        #expect(
            text
                == [
                    "Renaming \"origin\" to \"up\" stopped part-way (error: renaming remote references failed: cannot "
                        + "lock ref 'refs/remotes/origin/main').",
                    "The remote is called \"up\" now.",
                    "Its fetch refspec still writes under refs/remotes/origin/: +refs/heads/*:refs/remotes/origin/*.",
                    "2 remote-tracking branches are still under \"origin/\".",
                    "These settings still name \"origin\", which is not configured, so those branches have no upstream "
                        + "or push remote now: branch.main.remote, remote.pushdefault.",
                    "To undo it, rename \"up\" back to \"origin\" (Rename… on \"up\"), then try again.",
                ].joined(separator: "\n"))
        // Refs already under the new name: renaming back is not an exact undo, so it is not offered.
        let moved = RenameLeftover(
            old: "origin", new: "up", configured: ["up"], refspecsStillOld: [], configStillNamingOld: [],
            refsUnderOld: ["refs/remotes/origin/a"], refsUnderNew: ["refs/remotes/up/b"], gitsWords: "fatal: x")
        let other = RemoteAdminWording.renameRemoteFailure(
            RemoteAdminPartial.renameHalfDone(left: moved), old: "origin", new: "up")
        #expect(
            other
                == [
                    "Renaming \"origin\" to \"up\" stopped part-way (fatal: x).",
                    "The remote is called \"up\" now.",
                    "1 remote-tracking branch is still under \"origin/\".",
                    "1 remote-tracking branch is under \"up/\".",
                    "Finish it in a terminal; compare git remote -v and git for-each-ref refs/remotes/.",
                ].joined(separator: "\n"))
        #expect(!other.contains("rename \"up\" back"))
    }

    // MARK: - Remove

    static let impact = RemovalImpact(
        remote: "origin",
        refs: [
            RefTip(ref: "refs/remotes/origin/gone1", id: id1), RefTip(ref: "refs/remotes/origin/main", id: id2),
        ],
        stranded: StrandedCommits(count: 1, commits: [CommitRef(sha: id1, subject: "G1")], holders: ["refs/remotes/origin/gone1"]),
        upstreamOf: ["main", "topic"],
        pushRedirects: [
            PushRedirect(branch: "onfork", nowPushesTo: "fork"), PushRedirect(branch: "solo", nowPushesTo: nil),
            PushRedirect(branch: "loc", nowPushesTo: "."), PushRedirect(branch: "glob", nowPushesTo: "origin"),
        ],
        leftBehind: ["refs/remotes/origin/handmade"])

    @Test func theRemoveSheetSaysEverythingItDeletesAndChanges() {
        #expect(
            RemoteAdminWording.removeIntro(Self.impact)
                == "Removing \"origin\" deletes its settings and these 2 remote-tracking branches here; nothing on "
                + "the server changes.")
        let bare = RemovalImpact(
            remote: "x", refs: [], stranded: .none, upstreamOf: [], pushRedirects: [], leftBehind: [])
        #expect(
            RemoteAdminWording.removeIntro(bare)
                == "Removing \"x\" deletes its settings here. It has no remote-tracking branches; nothing on the "
                + "server changes.")
        #expect(
            RemoteAdminWording.removeUpstreams(Self.impact)
                == "These branches track \"origin\" and will be left with no upstream: \"main\", \"topic\".")
        #expect(RemoteAdminWording.removeUpstreams(bare) == nil)
        #expect(
            RemoteAdminWording.removePushRedirects(Self.impact)
                == [
                    "\"onfork\" pushes to \"origin\" now, and will push to \"fork\" instead.",
                    "\"solo\" pushes to \"origin\" now, and will have nowhere to push: Push will offer Publish….",
                    "\"loc\" pushes to \"origin\" now, and will push into this repository (its upstream is a local branch).",
                    "\"glob\" pushes to \"origin\" through a setting outside this repository's configuration, which "
                        + "git leaves: it will go on pushing to \"origin\", which will no longer exist.",
                ])
        #expect(
            RemoteAdminWording.removeLeftBehind(Self.impact)
                == "These are not mapped by the fetch refspecs of \"origin\", so git leaves them; they will show "
                + "under Other: origin/handmade.")
        #expect(RemoteAdminWording.removeLeftBehind(bare) == nil)
    }

    /// Promise 3: every deleted ref with its full id — the only way back — and everything else
    /// the removal changed.
    @Test func theRemoveNoticeIsTheOnlyRecordOfTheRefs() {
        let text = RemoteAdminWording.remoteRemoved(Self.impact, keptBranches: ["gone1"])
        let expected: [String] = [
                    "Removed the remote \"origin\". This is the only record of the 2 remote-tracking branches deleted "
                        + "with it:",
                    "refs/remotes/origin/gone1 \(Self.id1)",
                    "refs/remotes/origin/main \(Self.id2)",
                    "Kept as a local branch: \"gone1\".",
                    "Left with no upstream: \"main\", \"topic\".",
                    "Pushing elsewhere now: \"onfork\" to \"fork\"; \"solo\" nowhere (Push will offer Publish…); "
                        + "\"loc\" into this repository; \"glob\" still to \"origin\", which no longer exists.",
                    "Left behind, under Other: origin/handmade.",
                    "To bring one back, give its line above to git update-ref, e.g.: git update-ref "
                        + "refs/remotes/origin/gone1 \(Self.id1)",
                ]
        #expect(text == expected.joined(separator: "\n"))
        Self.expectEverySuggestedCommandNamesFullRefs(text)
        // The example is never `<remote>/HEAD`, which update-ref would turn into an ordinary ref.
        let withHEAD = RemovalImpact(
            remote: "origin", refs: [RefTip(ref: "refs/remotes/origin/HEAD", id: Self.id2)] + Self.impact.refs,
            stranded: .none, upstreamOf: [], pushRedirects: [], leftBehind: [])
        #expect(
            RemoteAdminWording.remoteRemoved(withHEAD, keptBranches: []).hasSuffix(
                "e.g.: git update-ref refs/remotes/origin/gone1 \(Self.id1)"))
        let bare = RemovalImpact(
            remote: "x", refs: [], stranded: .none, upstreamOf: [], pushRedirects: [], leftBehind: [])
        #expect(RemoteAdminWording.remoteRemoved(bare, keptBranches: []) == "Removed the remote \"x\".")
    }

    @Test func removeRefusalsSayNothingWasRemoved() {
        #expect(
            RemoteAdminWording.removeRemoteFailure(RemoteAdminRefusal.impactChanged, remote: "origin")
                == "What removing \"origin\" would delete or change is not what the sheet showed: it changed since "
                + "you opened this — review again. Nothing was removed.")
        #expect(
            RemoteAdminWording.removeRemoteFailure(RemoteAdminRefusal.noSuchRemote("origin"), remote: "origin")
                == RemoteAdminWording.remoteGone("origin"))
        #expect(
            RemoteAdminWording.removeRemoteFailure(RemoteAdminRefusal.branchExists("gone1"), remote: "origin")
                == "Couldn't keep \"gone1\": a branch, tag or remote has that name now. Nothing was removed.")
        #expect(
            RemoteAdminWording.removeRemoteFailure(
                RemoteAdminPartial.keptBranchesThenStopped(kept: ["a"], failedName: "b", gitsWords: "fatal: x"),
                remote: "origin")
                == "Created the kept branch \"a\", then couldn't create \"b\": fatal: x. Nothing was removed; "
                + "\"a\" stays.")
        #expect(
            RemoteAdminWording.removeRemoteFailure(CancellationError(), remote: "origin")
                == "Stopped the removal of \"origin\" before anything was created or removed.")
    }

    /// Carried note 6: cancelled while a kept branch was being created is UNKNOWN, never
    /// "couldn't create".
    @Test func aCancelledKeptBranchIsOfUnknownOutcome() {
        let text = RemoteAdminWording.removeRemoteFailure(
            RemoteAdminPartial.keptBranchesCancelled(kept: ["a"], unknown: "b"), remote: "origin")
        #expect(
            text
                == "Stopped while creating the kept branch \"b\": it may or may not have been created — check the "
                + "branch list. Nothing was removed; \"a\" was created before it and stays.")
        #expect(!text.contains("couldn't"))
    }

    /// R23: a held lock leaves the remote and its refs, with every branch setting naming it
    /// already unset. The banner says so, names the refs it did delete with their ids, and how
    /// to finish.
    @Test func aHalfDoneRemovalNamesWhatGitLeftAndHowToFinish() {
        let left = RemovalLeftover(
            remote: "origin", stillConfigured: true,
            refsLeft: [RefTip(ref: "refs/remotes/origin/gone1", id: Self.id1)],
            refsDeleted: [RefTip(ref: "refs/remotes/origin/main", id: Self.id2)],
            configRemoved: ["branch.main.remote", "branch.main.merge"], keptBranches: ["gone1"],
            gitsWords: "error: could not delete references: Unable to create '/r/.git/packed-refs.lock': File exists.")
        let text = RemoteAdminWording.removeRemoteFailure(RemoteAdminPartial.removeHalfDone(left: left), remote: "origin")
        #expect(
            text
                == [
                    "Removing \"origin\" stopped part-way (error: could not delete references: Unable to create "
                        + "'/r/.git/packed-refs.lock': File exists.). \"origin\" is still configured.",
                    "git had already removed these settings: branch.main.remote, branch.main.merge — those branches "
                        + "have no upstream or push remote of this name now.",
                    "Still there, at the ids they hold now:",
                    "refs/remotes/origin/gone1 \(Self.id1)",
                    "Deleted — the only record of what they held:",
                    "refs/remotes/origin/main \(Self.id2)",
                    "Kept as a local branch before git ran: \"gone1\". It stays.",
                    "Remove \"origin\" again to finish (Remove… on \"origin\").",
                ].joined(separator: "\n"))
        let gone = RemovalLeftover(
            remote: "origin", stillConfigured: false, refsLeft: [RefTip(ref: "refs/remotes/origin/a", id: Self.id1)],
            refsDeleted: [], configRemoved: [], keptBranches: [], gitsWords: "fatal: x")
        #expect(
            RemoteAdminWording.removeRemoteFailure(RemoteAdminPartial.removeHalfDone(left: gone), remote: "origin")
                == [
                    "Removing \"origin\" stopped part-way (fatal: x). \"origin\" is no longer configured.",
                    "Still there, at the ids they hold now:",
                    "refs/remotes/origin/a \(Self.id1)",
                    "Delete what is left in a terminal, each only while it holds that id:",
                    "git update-ref -d refs/remotes/origin/a \(Self.id1)",
                ].joined(separator: "\n"))
        for leftover in [left, gone] {
            Self.expectEverySuggestedCommandNamesFullRefs(
                RemoteAdminWording.removeRemoteFailure(RemoteAdminPartial.removeHalfDone(left: leftover), remote: "origin"))
        }
    }

    /// I6: a removal of unknown outcome names every ref the sheet showed with its id — if they
    /// are gone, those ids are the only way back (R7).
    @Test func anUnknownRemovalNamesEveryRefWithItsId() {
        let text = RemoteAdminWording.removeRemoteFailure(
            RemoteAdminPartial.removeOutcomeUnknown(remote: "origin", keptBranches: ["gone1"]), remote: "origin",
            refs: Self.impact.refs)
        #expect(
            text
                == [
                    "Stopped while git was removing \"origin\": whether the remote, its remote-tracking branches and "
                        + "the branch settings naming it are still there is not known. Refresh to see. The kept branch "
                        + "\"gone1\" was created before git ran and stays.",
                    "If they are gone, they held:",
                    "refs/remotes/origin/gone1 \(Self.id1)",
                    "refs/remotes/origin/main \(Self.id2)",
                ].joined(separator: "\n"))
    }

    /// I5: `git update-ref` with a short name writes `.git/origin/main` (measured): every
    /// suggested `git update-ref` names a full `refs/…` ref.
    static func expectEverySuggestedCommandNamesFullRefs(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        var rest = Substring(text)
        var found = 0
        while let range = rest.range(of: "git update-ref ") {
            var after = rest[range.upperBound...]
            if after.hasPrefix("-d ") { after = after.dropFirst(3) }
            #expect(after.hasPrefix("refs/"), "\(after.prefix(40))", sourceLocation: sourceLocation)
            found += 1
            rest = after
        }
        #expect(found > 0 || !text.contains("update-ref"), sourceLocation: sourceLocation)
    }

    @Test func theButtonsSayWhatTheyDo() {
        #expect(RemoteAdminWording.removeButton == "Remove")
        #expect(RemoteAdminWording.renameButton == "Rename")
        #expect(RemoteAdminWording.addButton == "Add Remote")
        #expect(RemoteAdminWording.fetchAfterAdding == "Fetch from it after adding")
        #expect(RemoteAdminWording.saveURLButton == "Save")
    }

    // MARK: - The lane

    @Test func renameAndRemoveAreNamedOnTheLane() {
        let rename = RemoteActivity(kind: .renameRemote, remote: "origin", progress: nil)
        let remove = RemoteActivity(kind: .removeRemote, remote: "origin", progress: nil)
        #expect(!rename.isWrite && !remove.isWrite)
        #expect(RemoteWording.describe(rename) == "the rename of \"origin\"")
        #expect(RemoteWording.describe(remove) == "the removal of \"origin\"")
        #expect(RemoteWording.inProgressTitle(rename) == "Renaming \"origin\"…")
        #expect(RemoteWording.inProgressTitle(remove) == "Removing \"origin\"…")
    }
}
