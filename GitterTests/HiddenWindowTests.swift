import AppKit
import Foundation
import GitCoreTestSupport
import Testing

@testable import GitCore
@testable import Gitter

/// The window side of hiding, recorded instead of done (`HiddenWindowEnvironment`, Ruling 3): what
/// was ordered out, brought to the front and closed for real, and every alert with its answer,
/// which the test gives.
@MainActor final class HiddenWindowRecorder {
    private(set) var orderedOut: [NSWindow] = []
    private(set) var fronted: [NSWindow] = []
    private(set) var closed: [NSWindow] = []
    private(set) var alerts: [String] = []
    /// The last alert's answer: what its Show or Close does.
    private(set) var answer: (@MainActor (HiddenWindowEnvironment.Choice) -> Void)?

    var environment: HiddenWindowEnvironment {
        HiddenWindowEnvironment(
            orderOut: { self.orderedOut.append($0) },
            front: { self.fronted.append($0) },
            realClose: { self.closed.append($0) },
            alert: { text, answer in
                self.alerts.append(text)
                self.answer = answer
            })
    }
}

/// E3 Task 5 (spec Design §3): a window whose store is still working — a write on its lane, or a
/// local change running — hides instead of closing; opening its repository again brings that same
/// window back; when the work ends while it is hidden, the window closes for real, or an alert
/// says what it ended with. The window side goes through `HiddenWindowEnvironment`, recorded here;
/// the work is real git, held through `TestBackend`.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct HiddenWindowTests {

    // MARK: - The close decision

    @Test func onlyAWriteOnTheLaneOrAChangeRunningHidesTheWindow() {
        let fetch = RemoteActivity(kind: .fetch, remote: "origin")
        let autoFetch = RemoteActivity(kind: .autoFetch, remote: nil)
        let push = RemoteActivity(kind: .push, remote: "origin")
        #expect(WindowRegistry.closeDecision(remoteActivity: nil, isMutating: false) == .close)
        #expect(WindowRegistry.closeDecision(remoteActivity: fetch, isMutating: false) == .close)
        #expect(WindowRegistry.closeDecision(remoteActivity: autoFetch, isMutating: false) == .close)
        #expect(WindowRegistry.closeDecision(remoteActivity: push, isMutating: false) == .hide)
        #expect(WindowRegistry.closeDecision(remoteActivity: nil, isMutating: true) == .hide)
        #expect(WindowRegistry.closeDecision(remoteActivity: push, isMutating: true) == .hide)
    }

    // MARK: - How the work ended

    @Test func nothingNewToReadClosesTheWindow() {
        let reading = HiddenReading(laneMessages: 2, lastLaneMessage: "an older one")
        #expect(HiddenEnding.decide(repository: "repo", atHide: reading, now: reading) == .close)
    }

    @Test func aNewBannerIsTheAlert() {
        #expect(
            HiddenEnding.decide(
                repository: "repo", atHide: HiddenReading(), now: HiddenReading(error: "Commit failed."))
                == .alert("repo: Commit failed."))
        #expect(
            HiddenEnding.decide(
                repository: "repo", atHide: HiddenReading(error: "An older banner."),
                now: HiddenReading(error: "Commit failed.")) == .alert("repo: Commit failed."))
    }

    @Test func aLaneMessageToReadIsTheAlertInItsOwnWords() {
        #expect(
            HiddenEnding.decide(
                repository: "repo", atHide: HiddenReading(laneMessages: 1),
                now: HiddenReading(error: "The banner.", laneMessages: 2, lastLaneMessage: "The push was rejected."))
                == .alert("repo: The push was rejected."))
    }

    @Test func aBannerAlreadyUpBeforeTheHideIsNotToldAgain() {
        let reading = HiddenReading(error: "Seen already.", laneMessages: 1, lastLaneMessage: "Seen already.")
        #expect(HiddenEnding.decide(repository: "repo", atHide: reading, now: reading) == .close)
    }

    /// I1: a change that fails since the hide in the very words of the banner already up is told:
    /// the failures are counted, not compared by their text.
    @Test func aChangeFailingInTheWordsOfTheBannerUpAtTheHideIsTold() {
        #expect(
            HiddenEnding.decide(
                repository: "repo", atHide: HiddenReading(error: "Commit failed.", mutationFailures: 3),
                now: HiddenReading(error: "Commit failed.", mutationFailures: 4)) == .alert("repo: Commit failed."))
    }

    @Test func withNoRepositoryTheAlertIsTheMessageAlone() {
        #expect(
            HiddenEnding.decide(repository: nil, atHide: HiddenReading(), now: HiddenReading(error: "Failed."))
                == .alert("Failed."))
    }

    // MARK: - How the work ended: an operation that stopped (final review, I1)

    static let mergeStop = OperationPlace.stopped(
        .merge, OperationProgress(operation: .merge, mergedName: "feature"))
    static let rebaseAt2 = OperationPlace.stopped(
        .rebase, OperationProgress(operation: .rebase, step: 2, total: 5, current: CommitRef(sha: "b", subject: "B")))
    static let rebaseAt3 = OperationPlace.stopped(
        .rebase, OperationProgress(operation: .rebase, step: 3, total: 5, current: CommitRef(sha: "c", subject: "C")))

    /// An operation in progress now that was not at the hide — a merge's conflicts, a pick that
    /// stopped — is the alert, in the bar's words.
    @Test func anOperationStoppedSinceTheHideIsTheAlertInTheBarsWords() {
        let now = HiddenReading(
            place: Self.mergeStop, placeSentence: "Merging feature into main. Resolve the conflicts, then commit.")
        #expect(
            HiddenEnding.decide(repository: "repo", atHide: HiddenReading(), now: now)
                == .alert("repo: Merging feature into main. Resolve the conflicts, then commit."))
    }

    /// A Continue that stops again, at another commit, is told; the same place — a stage during
    /// the merge, which changes only the bar's next step — is not.
    @Test func anOperationAtAnotherPlaceIsToldAndAtTheSamePlaceIsNot() {
        let at2 = HiddenReading(place: Self.rebaseAt2, placeSentence: "at 2")
        let at3 = HiddenReading(place: Self.rebaseAt3, placeSentence: "at 3")
        #expect(HiddenEnding.decide(repository: "repo", atHide: at2, now: at3) == .alert("repo: at 3"))
        let resolving = HiddenReading(place: Self.mergeStop, placeSentence: "Resolve the conflicts, then commit.")
        let resolved = HiddenReading(place: Self.mergeStop, placeSentence: "Commit to complete the merge.")
        #expect(HiddenEnding.decide(repository: "repo", atHide: resolving, now: resolved) == .close)
    }

    /// An operation that was in progress at the hide and is gone now — the commit that concluded
    /// a merge, an abort — has nothing to tell.
    @Test func anOperationEndedSinceTheHideClosesTheWindow() {
        let merging = HiddenReading(place: Self.mergeStop, placeSentence: "Merging feature into main.")
        #expect(HiddenEnding.decide(repository: "repo", atHide: merging, now: HiddenReading()) == .close)
    }

    /// A range left halted with no operation is told in its bar's words.
    @Test func aRangeHaltedSinceTheHideIsTheAlert() {
        let halted = HaltedSequence(operation: .cherryPick, notApplied: [CommitRef(sha: "a", subject: "A")], total: 1)
        let now = HiddenReading(place: .halted(halted), placeSentence: "The cherry-pick stopped part-way.")
        #expect(
            HiddenEnding.decide(repository: "repo", atHide: HiddenReading(), now: now)
                == .alert("repo: The cherry-pick stopped part-way."))
    }

    /// The staged revert's notice, up since the hide, is the alert; the same notice up at the hide
    /// was seen. A banner comes first.
    @Test func theStagedRevertsNoticeIsTheAlertAfterAnyBanner() {
        let staged = HiddenReading(stagedRevert: "The revert's changes are staged.")
        #expect(
            HiddenEnding.decide(repository: "repo", atHide: HiddenReading(), now: staged)
                == .alert("repo: The revert's changes are staged."))
        #expect(HiddenEnding.decide(repository: "repo", atHide: staged, now: staged) == .close)
        var both = staged
        both.error = "A banner."
        #expect(
            HiddenEnding.decide(repository: "repo", atHide: HiddenReading(), now: both) == .alert("repo: A banner."))
    }

    // MARK: - The proxy

    /// The proxy answers `windowShouldClose` from the original delegate when it does not hide, and
    /// passes every other delegate call to it (C1: SwiftUI's own delegate implements
    /// `windowShouldClose` and more); the original is held weakly.
    @Test func theProxyForwardsEverythingElseToTheOriginalDelegate() {
        let window = Self.window()
        let original = RecordingDelegate()
        let state = ProxyState()
        let proxy = WindowCloseProxy(original: original, shouldHide: { state.busy }, hide: { state.hides += 1 })

        original.answer = false
        #expect(proxy.windowShouldClose(window) == false, "the original's answer")
        original.answer = true
        #expect(proxy.windowShouldClose(window) == true)
        #expect(original.askedToClose == 2)

        state.busy = true
        #expect(proxy.windowShouldClose(window) == false)
        #expect(state.hides == 1)
        #expect(original.askedToClose == 2, "a hide does not ask the original")

        #expect(proxy.responds(to: #selector(NSWindowDelegate.windowDidResize(_:))))
        #expect(!proxy.responds(to: #selector(NSWindowDelegate.windowDidMiniaturize(_:))))
        let delegate: any NSWindowDelegate = proxy
        delegate.windowDidResize?(Notification(name: NSWindow.didResizeNotification, object: window))
        #expect(original.resized == 1)
    }

    @Test func theProxyKeepsTheOriginalWeaklyAndClosesWithoutOne() {
        let window = Self.window()
        var original: RecordingDelegate? = RecordingDelegate()
        original?.answer = false
        let proxy = WindowCloseProxy(original: original, shouldHide: { false }, hide: {})
        #expect(proxy.windowShouldClose(window) == false)
        original = nil
        #expect(proxy.windowShouldClose(window) == true)
    }

    /// `attach` puts the proxy in as the window's delegate, once, keeping the delegate it found as
    /// the original; a window attached again keeps the same proxy.
    @Test(.timeLimit(.minutes(10))) func attachInstallsTheProxyOnceKeepingTheOriginal() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let test = TestRegistry()
        defer { test.remove() }
        let store = await test.opened(repo)
        let window = Self.window()
        let original = RecordingDelegate()
        original.answer = false
        window.delegate = original

        test.registry.attach(window, to: store)
        let proxy = try #require(window.delegate as? WindowCloseProxy)
        test.registry.attach(window, to: store)
        #expect(window.delegate === proxy)

        #expect(window.delegate?.windowShouldClose?(window) == false, "the original's answer, the store idle")
        #expect(original.askedToClose == 1)
    }

    // MARK: - Close All with a mix (RF3)

    /// RF3: a busy window and an idle one closed together — Close All asks each window in turn —
    /// the busy one hides, the idle one closes; a quit after that brings the hidden one to the
    /// front before asking, so the question has a window.
    @Test(.timeLimit(.minutes(10))) func closeAllHidesTheBusyWindowAndClosesTheIdleOneAndAQuitFrontsTheHidden() async throws {
        let busyRepo = try ScratchRepo("busy")
        defer { busyRepo.remove() }
        _ = try HeldTransport.remoteOneCommitBehind(busyRepo)
        let idleRepo = try ScratchRepo("idle")
        defer { idleRepo.remove() }
        try idleRepo.commit("a.txt", "one\n", "first")
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let backend = TestBackend()
        let busy = test.registry.makeStore(backend: backend)
        await open(busy, busyRepo.url)
        let idle = await test.opened(idleRepo)
        defer { await releaseAndSettle([backend], [busy]) }
        let busyWindow = Self.window()
        let idleWindow = Self.window()
        test.registry.attach(busyWindow, to: busy)
        test.registry.attach(idleWindow, to: idle)
        let gate = backend.hold(.push)
        busy.push()
        #expect(await waitUntil("the push parked") { gate.waiting })

        // AppKit's own user close, as Close All sends it to each window in turn (C1).
        busyWindow.performClose(nil)
        idleWindow.performClose(nil)

        #expect(recorder.orderedOut == [busyWindow])
        #expect(busy.isHidden)
        #expect(!busy.isClosed)
        #expect(!idle.isHidden)
        #expect(idle.isClosed, "the idle window closed, as before E3")
        #expect(test.registry.openRepositoryPaths == [], "both left the list: the closed one and the hidden one")

        // The quit: its question goes on the hidden window, brought to the front first.
        #expect(QuitGuard.decision(test.registry.stores.map(\.remoteActivity)) == .ask(writeAt: 0))
        #expect(QuitGuard.questionWindow(for: busy, in: test.registry) === busyWindow)
        #expect(recorder.fronted == [busyWindow])
        #expect(!busy.isHidden)
        #expect(test.registry.openRepositoryPaths == [shownPath(busyRepo)])

        gate.release()
        await waitUntilIdle(busy)
        #expect(recorder.closed.isEmpty, "a window back on screen is not closed when its work ends")
        #expect(recorder.alerts.isEmpty)
    }

    /// The control: a window that is not hidden and not on screen (never ordered in here; a
    /// minimized window is not visible either, the same `isVisible` branch) is asked about
    /// app-modally, as before, and nothing is brought to the front.
    @Test(.timeLimit(.minutes(10))) func aQuitAboutAWindowNotHiddenAndNotOnScreenFrontsNothing() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let store = await test.opened(repo)
        let window = Self.window()
        test.registry.attach(window, to: store)

        #expect(QuitGuard.questionWindow(for: store, in: test.registry) == nil)
        #expect(recorder.fronted.isEmpty)
        let windowless = test.registry.makeStore()
        #expect(QuitGuard.questionWindow(for: windowless, in: test.registry) == nil)
    }

    // MARK: - Opening it again

    /// A hidden store is live: every open of its repository, by any spelling (E2 RF2), fronts it.
    @Test(.timeLimit(.minutes(10))) func everyOpenOfAHiddenWindowsRepositoryFrontsIt() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        _ = try HeldTransport.remoteOneCommitBehind(repo)
        let link = repo.directory.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo.url)
        let other = try ScratchRepo("other")
        defer { other.remove() }
        try other.commit("a.txt", "one\n", "first")
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let backend = TestBackend()
        let hidden = test.registry.makeStore(backend: backend)
        await open(hidden, repo.url)
        let front = await test.opened(other)
        defer { await releaseAndSettle([backend], [hidden]) }
        let window = Self.window()
        test.registry.attach(window, to: hidden)
        let gate = backend.hold(.push)
        hidden.push()
        #expect(await waitUntil("the push parked") { gate.waiting })
        #expect(window.delegate?.windowShouldClose?(window) == false)
        #expect(hidden.isHidden)

        for spelling in [repo.url, link] {
            for kind in [OpenKind.recentOrFinder, .openPanel, .worktreeNewWindow, .worktreeHere] {
                #expect(test.registry.route(spelling, kind: kind, front: front) == .front(hidden), "\(spelling.path)")
            }
        }
        #expect(recorder.fronted.isEmpty, "route only decides")

        #expect(test.registry.open(link, kind: .recentOrFinder, front: front) == .front(hidden))
        #expect(recorder.fronted == [window])
        #expect(!hidden.isHidden)
        #expect(test.registry.openRepositoryPaths == [shownPath(repo), shownPath(other)], "back at its old place")

        gate.release()
        await waitUntilIdle(hidden)
        #expect(recorder.closed.isEmpty)
        #expect(test.registry.stores.contains { $0 === hidden })
    }

    // MARK: - The work ends while hidden

    /// A push that succeeds while its window is hidden: the window closes for real, with no alert,
    /// and the store leaves the registry.
    @Test(.timeLimit(.minutes(10))) func aPushThatSucceedsWhileHiddenClosesTheWindowForReal() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        let bare = try HeldTransport.remoteOneCommitBehind(repo)
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let (store, backend, window) = await Self.attachedStore(repo, in: test)
        defer { await releaseAndSettle([backend], [store]) }
        let gate = backend.hold(.push)
        store.push()
        #expect(await waitUntil("the push parked") { gate.waiting })

        #expect(window.delegate?.windowShouldClose?(window) == false)
        #expect(store.isHidden)
        #expect(test.registry.window(of: store) === window, "a hidden store keeps its window")
        #expect(test.registry.openRepositoryPaths == [])
        #expect(recorder.closed.isEmpty, "nothing is closed while the push runs")

        gate.release()
        await waitUntil("the real close") { !recorder.closed.isEmpty }
        await waitUntilGone(store, from: test.registry)

        #expect(recorder.closed == [window])
        #expect(recorder.alerts.isEmpty)
        #expect(store.isClosed)
        #expect(!store.isHidden)
        #expect(store.lastError == nil)
        #expect(try repo.git("-C", bare.path, "rev-parse", "main") == repo.git("rev-parse", "main"))
        #expect(test.registry.openRepositoryPaths == [])
    }

    /// A push the server refuses while its window is hidden: the alert says so, and nothing is
    /// closed until its Close.
    @Test(.timeLimit(.minutes(10))) func aPushThatFailsWhileHiddenRaisesTheAlertAndClosesOnlyOnItsClose() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try Self.refusingRemote(repo)
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let (store, backend, window) = await Self.attachedStore(repo, in: test)
        defer { await releaseAndSettle([backend], [store]) }
        let gate = backend.hold(.push)
        store.push()
        #expect(await waitUntil("the push parked") { gate.waiting })
        #expect(window.delegate?.windowShouldClose?(window) == false)

        gate.release()
        await waitUntil("the alert") { !recorder.alerts.isEmpty }

        let told = try #require(store.lastLaneMessageToRead)
        #expect(recorder.alerts == ["repo: \(told)"])
        #expect(store.lastError != nil)
        #expect(recorder.closed.isEmpty, "not closed before the alert's answer")
        #expect(store.isHidden)
        #expect(test.registry.stores.contains { $0 === store })

        let answer = try #require(recorder.answer)
        answer(.close)
        #expect(recorder.closed == [window])
        await waitUntilGone(store, from: test.registry)
        #expect(recorder.alerts.count == 1)
    }

    /// The alert's Show brings the window back, its banner there; nothing is closed.
    @Test(.timeLimit(.minutes(10))) func theAlertsShowBringsTheWindowBackWithItsBanner() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try Self.refusingRemote(repo)
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let (store, backend, window) = await Self.attachedStore(repo, in: test)
        defer { await releaseAndSettle([backend], [store]) }
        let gate = backend.hold(.push)
        store.push()
        #expect(await waitUntil("the push parked") { gate.waiting })
        #expect(window.delegate?.windowShouldClose?(window) == false)
        gate.release()
        await waitUntil("the alert") { !recorder.alerts.isEmpty }

        let answer = try #require(recorder.answer)
        answer(.show)

        #expect(recorder.fronted == [window])
        #expect(!store.isHidden)
        #expect(store.lastError != nil, "the banner is there")
        #expect(test.registry.openRepositoryPaths == [shownPath(repo)])
        #expect(recorder.closed.isEmpty)
        #expect(!store.isClosed)
    }

    /// A local change (a commit) running as the window closes hides it; when the commit ends the
    /// window closes for real and the store is left with nothing running (the B3.1 gap: closed at
    /// once, the commit's ending was dropped and the store stayed mutating).
    @Test(.timeLimit(.minutes(10))) func aCommitThatEndsWhileHiddenClosesTheWindowWithNothingStuck() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        try repo.write("a.txt", "two\n")
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let (store, backend, window) = await Self.attachedStore(repo, in: test)
        defer { await releaseAndSettle([backend], [store]) }
        let gate = backend.hold(.commit)
        store.draft.subject = "second"
        store.commit()
        #expect(await waitUntil("the commit parked") { gate.waiting })
        #expect(store.isMutating)
        #expect(store.remoteActivity == nil)

        #expect(window.delegate?.windowShouldClose?(window) == false)
        #expect(store.isHidden)

        gate.release()
        await waitUntil("the real close") { !recorder.closed.isEmpty }
        await waitUntilGone(store, from: test.registry)

        #expect(!store.isMutating)
        #expect(store.lastError == nil)
        #expect(recorder.alerts.isEmpty)
        #expect(try repo.git("log", "-1", "--format=%s").trimmingCharacters(in: .newlines) == "second")
    }

    /// The control, and what is left of B3.1: a store closed through E2's path (`windowClosed`,
    /// which only the `onDisappear` fallback of a never-attached window still takes for a busy
    /// store) while its commit runs is still left mutating, its ending dropped.
    @Test(.timeLimit(.minutes(10))) func aStoreClosedMidCommitThroughE2sPathIsStillLeftMutating() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        try repo.write("a.txt", "two\n")
        let test = TestRegistry()
        defer { test.remove() }
        let backend = TestBackend()
        let store = test.registry.makeStore(backend: backend)
        await open(store, repo.url)
        // Not `releaseAndSettle`: this store stays mutating by design (the known issue below), so
        // it would never settle; the body waits for the commit's landing itself.
        defer { backend.releaseAll() }
        let gate = backend.hold(.commit)
        store.draft.subject = "second"
        store.commit()
        #expect(await waitUntil("the commit parked") { gate.waiting })

        test.registry.windowClosed(store)
        gate.release()
        await waitUntil("the commit landing") {
            (try? repo.git("log", "-1", "--format=%s").trimmingCharacters(in: .newlines)) == "second"
        }
        // The ending's own turn: anything it would clear is cleared by the next one.
        try await Task.sleep(for: .milliseconds(200))

        withKnownIssue("B3.1: closed at once, a store's local change ends at finishMutation's stale-generation guard") {
            #expect(!store.isMutating)
        }
    }

    // MARK: - A local change that stops while hidden (final review, I1)

    /// A merge that stops on conflicts while its window is hidden says nothing in a banner — the
    /// operation bar does — so the alert tells the bar's sentence, and the window is not closed
    /// before its answer: a repository left mid-merge is never closed on silently.
    @Test(.timeLimit(.minutes(10))) func aMergeThatStopsOnConflictsWhileHiddenRaisesTheAlertWithTheBarsSentence() async throws {
        let repo = try Self.branches(conflicting: true)
        defer { repo.remove() }
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let (store, backend, window) = await Self.attachedStore(repo, in: test)
        defer { await releaseAndSettle([backend], [store]) }
        let gate = backend.hold(.merge)
        store.merge("feature", mode: .fastForwardIfPossible)
        #expect(await waitUntil("the merge parked") { gate.waiting })
        #expect(window.delegate?.windowShouldClose?(window) == false)
        #expect(store.isHidden)

        gate.release()
        await Self.waitForTheEnding(of: store, recorder)

        #expect(store.operationInProgress == .merge)
        #expect(store.lastError == nil, "a merge's conflicts are no banner")
        #expect(recorder.alerts == ["repo: \(store.operationBarSentence)"])
        #expect(store.operationBarSentence.hasPrefix("Merging feature into main."))
        #expect(recorder.closed.isEmpty, "not closed before the alert's answer")
        #expect(store.isHidden)
    }

    /// The control: a merge that goes through cleanly while hidden closes the window for real,
    /// with no alert — its "Merged" notice is not one that must be read.
    @Test(.timeLimit(.minutes(10))) func aCleanMergeWhileHiddenClosesTheWindowWithNoAlert() async throws {
        let repo = try Self.branches(conflicting: false)
        defer { repo.remove() }
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let (store, backend, window) = await Self.attachedStore(repo, in: test)
        defer { await releaseAndSettle([backend], [store]) }
        let gate = backend.hold(.merge)
        store.merge("feature", mode: .fastForwardIfPossible)
        #expect(await waitUntil("the merge parked") { gate.waiting })
        #expect(window.delegate?.windowShouldClose?(window) == false)

        gate.release()
        await Self.waitForTheEnding(of: store, recorder)
        await waitUntilGone(store, from: test.registry)

        #expect(store.operationInProgress == nil)
        #expect(recorder.alerts.isEmpty)
        #expect(recorder.closed == [window])
        #expect(try repo.git("log", "-1", "--format=%s").hasPrefix("Merge branch 'feature'"))
    }

    /// A cherry-pick that stops on a conflict while hidden (`HistoryOutcome.stopped`, "the
    /// operation bar's to say"): the alert tells the bar's sentence.
    @Test(.timeLimit(.minutes(10))) func aCherryPickThatStopsWhileHiddenRaisesTheAlertWithTheBarsSentence() async throws {
        let repo = try Self.branches(conflicting: true)
        defer { repo.remove() }
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let (store, backend, window) = await Self.attachedStore(repo, in: test)
        defer { await releaseAndSettle([backend], [store]) }
        store.requestHistoryAction(.cherryPick, shas: [store.featureTip])
        await waitUntil("the plan's sheet") { store.activeSheet != nil }
        guard case .historyAction(let plan) = try #require(store.activeSheet) else {
            Issue.record("not the plan's sheet: \(String(describing: store.activeSheet))")
            return
        }
        let gate = backend.hold(.run)
        store.confirmHistoryAction(plan)
        #expect(await waitUntil("the pick parked") { gate.waiting })
        #expect(window.delegate?.windowShouldClose?(window) == false)
        #expect(store.isHidden)

        gate.release()
        await Self.waitForTheEnding(of: store, recorder)

        #expect(store.operationInProgress == .cherryPick)
        #expect(recorder.alerts == ["repo: \(store.operationBarSentence)"])
        #expect(store.operationBarSentence.hasPrefix("Cherry-picking "))
        #expect(recorder.closed.isEmpty)
    }

    /// A single revert git could not commit (a `prepare-commit-msg` hook that says no, as an
    /// unsigned one does) leaves the revert staged, its notice up and its message in the draft:
    /// the alert tells the notice, and the window — the draft with it — is not closed before the
    /// answer.
    @Test(.timeLimit(.minutes(10))) func aRevertLeftStagedWhileHiddenRaisesTheAlertWithItsNotice() async throws {
        let repo = try Self.branches(conflicting: false)
        defer { repo.remove() }
        let hook = repo.url.appending(path: ".git/hooks/prepare-commit-msg")
        try "#!/bin/sh\necho 'refused by the test'\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let (store, backend, window) = await Self.attachedStore(repo, in: test)
        defer { await releaseAndSettle([backend], [store]) }
        store.requestHistoryAction(.revert, shas: [store.mainTip])
        await waitUntil("the plan's sheet") { store.activeSheet != nil }
        guard case .historyAction(let plan) = try #require(store.activeSheet) else {
            Issue.record("not the plan's sheet: \(String(describing: store.activeSheet))")
            return
        }
        let gate = backend.hold(.run)
        store.confirmHistoryAction(plan)
        #expect(await waitUntil("the revert parked") { gate.waiting })
        #expect(window.delegate?.windowShouldClose?(window) == false)

        gate.release()
        await Self.waitForTheEnding(of: store, recorder)

        let notice = try #require(store.stickyNotice)
        #expect(store.operationInProgress == nil)
        #expect(recorder.alerts == ["repo: \(notice.text)"])
        #expect(!store.draft.message.isEmpty, "the revert's message is in the draft")
        #expect(recorder.closed.isEmpty)
    }

    // MARK: - RF2: the work ends just as the window comes back

    /// RF2: the hidden window shown again (its `didBecomeKeyNotification`, as SwiftUI's
    /// `openWindow(value:)` shows it, C2), then the push ends: no alert, no real close, the store
    /// no longer hidden and its repository back on the list.
    @Test(.timeLimit(.minutes(10))) func shownAgainBeforeItsPushEndsTheWindowStays() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try Self.refusingRemote(repo)
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let (store, backend, window) = await Self.attachedStore(repo, in: test)
        defer { await releaseAndSettle([backend], [store]) }
        let gate = backend.hold(.push)
        store.push()
        #expect(await waitUntil("the push parked") { gate.waiting })
        #expect(window.delegate?.windowShouldClose?(window) == false)
        #expect(store.isHidden)

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        gate.release()
        await waitUntilIdle(store)

        #expect(!store.isHidden)
        #expect(store.lastError != nil, "the failure is on its banner")
        #expect(recorder.alerts.isEmpty)
        #expect(recorder.closed.isEmpty)
        #expect(test.registry.openRepositoryPaths == [shownPath(repo)])
        #expect(test.registry.stores.contains { $0 === store })
    }

    /// RF2 reversed: the push ends first and the window is closed for real; the open after that
    /// makes a new window.
    @Test(.timeLimit(.minutes(10))) func endedBeforeItIsShownAgainTheOpenMakesANewWindow() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        _ = try HeldTransport.remoteOneCommitBehind(repo)
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let (store, backend, window) = await Self.attachedStore(repo, in: test)
        defer { await releaseAndSettle([backend], [store]) }
        let gate = backend.hold(.push)
        store.push()
        #expect(await waitUntil("the push parked") { gate.waiting })
        #expect(window.delegate?.windowShouldClose?(window) == false)

        gate.release()
        await waitUntilGone(store, from: test.registry)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        #expect(recorder.closed == [window])
        #expect(test.registry.route(repo.url, kind: .recentOrFinder, front: nil) == .newWindow(RepositoryWindow(url: repo.url)))
        #expect(test.registry.openRepositoryPaths == [], "a late signal from the closed window puts nothing back")
    }

    // MARK: - A held quit with two hidden busy stores

    /// Two hidden windows pushing, and a quit: its question fronts the first; under Wait the
    /// second's push is refused by the server while it is still hidden. The failure is told once —
    /// by the hidden ending's alert — and the quit is called off by it without its own windowless
    /// alert: a hidden store counts as having a window in `callingOff(hasWindow:)`
    /// (`QuitGuard.hasWindow`, the poll's own predicate).
    @Test(.timeLimit(.minutes(10))) func underAHeldQuitAHiddenWindowsFailureIsToldOnce() async throws {
        let (test, recorder, stores, gates, backends, repos) = try await Self.twoHiddenPushes()
        defer { for repo in repos { repo.remove() } }
        defer { test.remove() }
        defer { await releaseAndSettle(backends, stores) }
        defer { for store in stores { store.endTerminating() } }
        let lanes = stores.map(\.remoteActivity)
        #expect(QuitGuard.decision(lanes) == .ask(writeAt: 0))
        let messagesBefore = stores.map(\.laneMessagesToRead)
        #expect(QuitGuard.questionWindow(for: stores[0], in: test.registry) != nil)
        #expect(!stores[0].isHidden)
        #expect(stores[1].isHidden)
        let compared = QuitGuard.beginWaiting(
            stores, writesAsked: lanes.map { $0?.isWrite == true }, messagesBefore: messagesBefore)

        gates[1].release()
        await waitUntil("the hidden ending's alert") { !recorder.alerts.isEmpty }

        let calling = try #require(
            QuitGuard.callingOff(stores, before: compared) { QuitGuard.hasWindow($0, in: test.registry) })
        #expect(calling.store === stores[1])
        #expect(calling.windowlessAlert == nil, "not told a second time")
        #expect(recorder.alerts == ["refusing: \(try #require(stores[1].lastLaneMessageToRead))"])
    }

    /// The control: the same failure in a store whose window really closed (E2's windowless
    /// store) is told by the quit's own call-off alert, and no hidden ending alerts.
    @Test(.timeLimit(.minutes(10))) func underAHeldQuitAClosedWindowsFailureIsToldByTheCallOff() async throws {
        let (test, recorder, stores, gates, backends, repos) = try await Self.twoHiddenPushes(closeSecond: true)
        defer { for repo in repos { repo.remove() } }
        defer { test.remove() }
        defer { await releaseAndSettle(backends, stores) }
        defer { for store in stores { store.endTerminating() } }
        let lanes = stores.map(\.remoteActivity)
        let messagesBefore = stores.map(\.laneMessagesToRead)
        let compared = QuitGuard.beginWaiting(
            stores, writesAsked: lanes.map { $0?.isWrite == true }, messagesBefore: messagesBefore)

        gates[1].release()
        await waitUntilLaneFree(stores[1])
        await waitUntil("the closed store's message") { stores[1].laneMessagesToRead != messagesBefore[1] }

        let calling = try #require(
            QuitGuard.callingOff(stores, before: compared) { QuitGuard.hasWindow($0, in: test.registry) })
        #expect(calling.store === stores[1])
        #expect(calling.windowlessAlert != nil)
        #expect(recorder.alerts.isEmpty)
    }

    /// Important 1 (fix round 1): the hidden window's push is refused while the quit's question is
    /// still up, its alert is answered Close — the window closes for real, so the store has no window
    /// any more — and only then is Wait chosen. The failure was told by the alert, so the call-off
    /// says nothing more: told once.
    @Test(.timeLimit(.minutes(10))) func failedThenItsAlertClosedThenWaitIsToldOnce() async throws {
        let (test, recorder, stores, gates, backends, repos) = try await Self.twoHiddenPushes()
        defer { for repo in repos { repo.remove() } }
        defer { test.remove() }
        defer { await releaseAndSettle(backends, stores) }
        defer { for store in stores { store.endTerminating() } }
        let lanes = stores.map(\.remoteActivity)
        let messagesBefore = stores.map(\.laneMessagesToRead)
        #expect(QuitGuard.questionWindow(for: stores[0], in: test.registry) != nil)

        // The question is up: the hidden push is refused, and its alert answered Close.
        gates[1].release()
        await waitUntil("the hidden ending's alert") { !recorder.alerts.isEmpty }
        let answer = try #require(recorder.answer)
        answer(.close)
        await waitUntilGone(stores[1], from: test.registry)
        #expect(test.registry.window(of: stores[1]) == nil)

        // Then Wait.
        let compared = QuitGuard.beginWaiting(
            stores, writesAsked: lanes.map { $0?.isWrite == true }, messagesBefore: messagesBefore)
        let calling = try #require(
            QuitGuard.callingOff(stores, before: compared) { QuitGuard.hasWindow($0, in: test.registry) })
        #expect(calling.store === stores[1], "Gitter stays open, as Wait says")
        #expect(calling.windowlessAlert == nil, "told once, by the alert")
        #expect(recorder.alerts.count == 1)

        // The control: judged by its window alone, as before the fix, the call-off tells it again.
        let byWindowAlone = try #require(
            QuitGuard.callingOff(stores, before: compared) { test.registry.window(of: $0) != nil })
        withKnownIssue("by its window alone, a hidden store whose alert closed it is windowless: told twice") {
            #expect(byWindowAlone.windowlessAlert == nil)
        }
    }

    /// The reverse order: Wait first, then the hidden push is refused (its alert goes up), then the
    /// alert is answered Close. Before and after the answer, the call-off adds no alert of its own.
    @Test(.timeLimit(.minutes(10))) func waitThenFailedThenItsAlertClosedIsToldOnce() async throws {
        let (test, recorder, stores, gates, backends, repos) = try await Self.twoHiddenPushes()
        defer { for repo in repos { repo.remove() } }
        defer { test.remove() }
        defer { await releaseAndSettle(backends, stores) }
        defer { for store in stores { store.endTerminating() } }
        let lanes = stores.map(\.remoteActivity)
        let messagesBefore = stores.map(\.laneMessagesToRead)
        #expect(QuitGuard.questionWindow(for: stores[0], in: test.registry) != nil)
        let compared = QuitGuard.beginWaiting(
            stores, writesAsked: lanes.map { $0?.isWrite == true }, messagesBefore: messagesBefore)

        gates[1].release()
        await waitUntil("the hidden ending's alert") { !recorder.alerts.isEmpty }
        let before = try #require(
            QuitGuard.callingOff(stores, before: compared) { QuitGuard.hasWindow($0, in: test.registry) })
        #expect(before.store === stores[1])
        #expect(before.windowlessAlert == nil)

        let answer = try #require(recorder.answer)

        answer(.close)
        await waitUntilGone(stores[1], from: test.registry)
        let after = try #require(
            QuitGuard.callingOff(stores, before: compared) { QuitGuard.hasWindow($0, in: test.registry) })
        #expect(after.windowlessAlert == nil)
        #expect(recorder.alerts.count == 1)
    }

    /// M3 (final review): Wait's bound passes — a short one here — with both hidden pushes still
    /// running, so each store gets the call-off's banner; the first push then goes through. That
    /// banner was about a wait that has ended, so its window closes for real with no alert. The
    /// second push is refused: its own failure, not the call-off's banner, is the alert.
    @Test(.timeLimit(.minutes(10))) func theCallOffsBannerOnAHiddenWindowGoesWhenItsPushGoesThrough() async throws {
        let (test, recorder, stores, gates, backends, repos) = try await Self.twoHiddenPushes()
        defer { for repo in repos { repo.remove() } }
        defer { test.remove() }
        defer { await releaseAndSettle(backends, stores) }
        let windows = stores.map { test.registry.window(of: $0) }
        let bound = Duration.milliseconds(1)

        QuitGuard.gaveUpWaiting(stores, after: bound)
        let activity = try #require(stores[0].remoteActivity)
        #expect(stores[0].lastError == RemoteWording.quitWaitGaveUp(activity, after: bound))
        #expect(stores[1].lastError != nil)

        gates[0].release()
        await waitUntilLaneFree(stores[0])
        await Self.waitForTheEnding(of: stores[0], recorder)
        #expect(recorder.alerts.isEmpty, "no alert about a push that went through")
        #expect(recorder.closed == [try #require(windows[0])])
        #expect(stores[0].isClosed)

        gates[1].release()
        await waitUntilLaneFree(stores[1])
        await waitUntil("the refused push's ending") { recorder.alerts.count + recorder.closed.count == 2 }
        #expect(recorder.alerts == ["refusing: \(try #require(stores[1].lastLaneMessageToRead))"])
    }

    // MARK: - Hide, show, hide again; the alert after a show; the proxy at the real close

    /// The alert's Close after the window was shown again (Open Recent while the alert was up):
    /// the window is on screen, so it is not closed.
    @Test(.timeLimit(.minutes(10))) func theAlertsCloseAfterTheWindowWasShownAgainClosesNothing() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try Self.refusingRemote(repo)
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let (store, backend, window) = await Self.attachedStore(repo, in: test)
        defer { await releaseAndSettle([backend], [store]) }
        let gate = backend.hold(.push)
        store.push()
        #expect(await waitUntil("the push parked") { gate.waiting })
        #expect(window.delegate?.windowShouldClose?(window) == false)
        gate.release()
        await waitUntil("the alert") { !recorder.alerts.isEmpty }

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(!store.isHidden)
        let answer = try #require(recorder.answer)
        answer(.close)

        #expect(recorder.closed.isEmpty)
        #expect(!store.isClosed)
        #expect(test.registry.window(of: store) === window)
    }

    /// Hidden, shown again, hidden again while the same push runs: only the newest hide watches, so
    /// its refusal is told once and the window is not closed before the answer.
    @Test(.timeLimit(.minutes(10))) func hiddenShownAndHiddenAgainIsWatchedOnce() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try Self.refusingRemote(repo)
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let (store, backend, window) = await Self.attachedStore(repo, in: test)
        defer { await releaseAndSettle([backend], [store]) }
        let gate = backend.hold(.push)
        store.push()
        #expect(await waitUntil("the push parked") { gate.waiting })

        #expect(window.delegate?.windowShouldClose?(window) == false)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(!store.isHidden)
        #expect(window.delegate?.windowShouldClose?(window) == false)
        #expect(store.isHidden)
        #expect(recorder.orderedOut == [window, window])

        gate.release()
        await waitUntil("the alert") { !recorder.alerts.isEmpty }
        await waitUntilLaneFree(store)
        // Every turn that could still run an older watcher.
        for _ in 0..<5 { await Task.yield() }

        #expect(recorder.alerts.count == 1)
        #expect(recorder.closed.isEmpty)
        let answer = try #require(recorder.answer)
        answer(.close)
        #expect(recorder.closed == [window])
    }

    /// The real close lets go of the proxy and gives the window its own delegate back (SwiftUI's,
    /// in the app), on the turn after the close.
    @Test(.timeLimit(.minutes(10))) func theRealCloseGivesTheWindowItsOwnDelegateBack() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        _ = try HeldTransport.remoteOneCommitBehind(repo)
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let backend = TestBackend()
        let store = test.registry.makeStore(backend: backend)
        await open(store, repo.url)
        defer { await releaseAndSettle([backend], [store]) }
        let window = Self.window()
        let original = RecordingDelegate()
        window.delegate = original
        test.registry.attach(window, to: store)
        #expect(window.delegate is WindowCloseProxy)
        #expect(test.registry.hasProxy(on: window))
        let gate = backend.hold(.push)
        store.push()
        #expect(await waitUntil("the push parked") { gate.waiting })
        #expect(window.delegate?.windowShouldClose?(window) == false)

        gate.release()
        await waitUntilGone(store, from: test.registry)
        await waitUntil("the proxy let go") { !test.registry.hasProxy(on: window) }

        #expect(window.delegate === original)
    }

    /// Minor 8: shown again, a hidden window's repository goes back to its place in the list, not
    /// to the end.
    @Test(.timeLimit(.minutes(10))) func shownAgainItsRepositoryTakesItsOldPlaceInTheList() async throws {
        let repo = try ScratchRepo("hidden")
        defer { repo.remove() }
        _ = try HeldTransport.remoteOneCommitBehind(repo)
        let after = try ScratchRepo("after")
        defer { after.remove() }
        try after.commit("a.txt", "one\n", "first")
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let (store, backend, window) = await Self.attachedStore(repo, in: test)
        defer { await releaseAndSettle([backend], [store]) }
        _ = await test.opened(after)
        #expect(test.registry.openRepositoryPaths == [shownPath(repo), shownPath(after)])
        let gate = backend.hold(.push)
        store.push()
        #expect(await waitUntil("the push parked") { gate.waiting })

        #expect(window.delegate?.windowShouldClose?(window) == false)
        #expect(test.registry.openRepositoryPaths == [shownPath(after)])
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        #expect(test.registry.openRepositoryPaths == [shownPath(repo), shownPath(after)])
    }

    // MARK: - The recorder's control

    /// The recorder's checks can fail: before any ending, nothing is recorded as closed or alerted.
    @Test func theRecorderRecordsOnlyWhatItWasAsked() {
        let recorder = HiddenWindowRecorder()
        let window = Self.window()
        recorder.environment.orderOut(window)
        #expect(recorder.orderedOut == [window])
        withKnownIssue("nothing was closed or alerted") {
            #expect(recorder.closed == [window])
            #expect(!recorder.alerts.isEmpty)
        }
    }

    // MARK: - Fixtures

    static func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// A store on `repo` made by `test`'s registry through a fresh `TestBackend`, opened, idle and
    /// attached to a window of its own.
    static func attachedStore(
        _ repo: ScratchRepo, in test: TestRegistry, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> (RepositoryStore, TestBackend, NSWindow) {
        let backend = TestBackend()
        let store = test.registry.makeStore(backend: backend)
        await open(store, repo.url, sourceLocation: sourceLocation)
        let window = window()
        test.registry.attach(window, to: store)
        return (store, backend, window)
    }

    /// `main` and `feature` from a first commit of `a.txt`, each one commit on: `feature` changes
    /// `a.txt` too when `conflicting` (a merge or a pick of it stops on that file), or adds
    /// `f.txt` otherwise (a clean merge). `main` is checked out.
    static func branches(conflicting: Bool) throws -> ScratchRepo {
        let repo = try ScratchRepo()
        try repo.commit("a.txt", "one\n", "first")
        try repo.git("switch", "-c", "feature")
        if conflicting {
            try repo.commit("a.txt", "feature\n", "feature work")
        } else {
            try repo.commit("f.txt", "f\n", "feature work")
        }
        try repo.git("switch", "main")
        try repo.commit("a.txt", "main\n", "main work")
        return repo
    }

    /// Returns once `store`'s change has ended and its hidden ending has run: an alert, or the real
    /// close. Never on the alert alone, so a test that expects one sees the close instead.
    static func waitForTheEnding(
        of store: RepositoryStore, _ recorder: HiddenWindowRecorder,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await waitUntil("the hidden ending", sourceLocation: sourceLocation) {
            !store.isMutating && (!recorder.alerts.isEmpty || !recorder.closed.isEmpty)
        }
    }

    /// `remoteOneCommitBehind`'s repository, its bare remote refusing every push (`pre-receive`).
    static func refusingRemote(_ repo: ScratchRepo) throws {
        let bare = try HeldTransport.remoteOneCommitBehind(repo)
        let hook = bare.appending(path: "hooks/pre-receive")
        try "#!/bin/sh\necho 'refused by the test' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    }

    /// Two stores, "accepting" and "refusing", each pushing on a hold and its window hidden by a
    /// close — or, with `closeSecond`, the second's window closed through E2's path instead.
    static func twoHiddenPushes(closeSecond: Bool = false) async throws -> (
        TestRegistry, HiddenWindowRecorder, [RepositoryStore], [StuckCall], [TestBackend], [ScratchRepo]
    ) {
        let accepting = try ScratchRepo("accepting")
        _ = try HeldTransport.remoteOneCommitBehind(accepting)
        let refusing = try ScratchRepo("refusing")
        try refusingRemote(refusing)
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        var stores: [RepositoryStore] = []
        var gates: [StuckCall] = []
        var backends: [TestBackend] = []
        for repo in [accepting, refusing] {
            let (store, backend, window) = await attachedStore(repo, in: test)
            let gate = backend.hold(.push)
            store.push()
            #expect(await waitUntil("the push parked") { gate.waiting })
            if closeSecond, repo.url == refusing.url {
                test.registry.windowClosed(store)
            } else {
                #expect(window.delegate?.windowShouldClose?(window) == false)
                #expect(store.isHidden)
            }
            stores.append(store)
            gates.append(gate)
            backends.append(backend)
        }
        return (test, recorder, stores, gates, backends, [accepting, refusing])
    }
}

/// What a test's proxy is told to answer, and how often it hid.
@MainActor final class ProxyState {
    var busy = false
    var hides = 0
}

/// A window delegate that answers `windowShouldClose` as told and counts what reaches it.
@MainActor final class RecordingDelegate: NSObject, NSWindowDelegate {
    var answer = true
    private(set) var askedToClose = 0
    private(set) var resized = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        askedToClose += 1
        return answer
    }

    func windowDidResize(_ notification: Notification) {
        resized += 1
    }
}
