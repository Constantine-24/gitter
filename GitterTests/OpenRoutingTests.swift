import AppKit
import Foundation
import Testing

@testable import Gitter

/// E2 Task 4: every open goes through `WindowRegistry.route` / `open`.
///
/// - A repository a window already shows comes to the front, whatever asked: Open Repository…,
///   Open Recent or a Finder open, a worktree's Open in New Window — compared by resolved path (RF2).
/// - Open Repository… uses the front window when it shows nothing, and a new window otherwise.
/// - Open Recent and a Finder open, and Open in New Window, always make a new window.
/// - A new window asked for before the first window has taken the launch waits for it
///   (`pendingOpen`, Ruling 9): the launch opens it first.
///
/// Every registry here is a scratch one (`TestRegistry`), on real repositories (`ScratchRepo`).
/// Its `openWindow` is a recorder, so no test opens a real window.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct OpenRoutingTests {
    static let kinds: [OpenKind] = [.openPanel, .recentOrFinder, .worktreeNewWindow]

    /// Records each window the registry asks for, instead of opening one.
    final class WindowRecorder {
        var asked: [RepositoryWindow?] = []
    }

    /// A registry whose launch is over (the first window took its pending open) and whose new
    /// windows are recorded.
    static func launchedRegistry() -> (TestRegistry, WindowRecorder) {
        let test = TestRegistry()
        let recorder = WindowRecorder()
        test.registry.openWindow = { recorder.asked.append($0) }
        _ = test.registry.takePendingOpen()
        return (test, recorder)
    }

    // MARK: - route

    @Test(.timeLimit(.minutes(10))) func aRepositoryShownInSomeWindowComesToTheFrontForEveryKind() async throws {
        let shown = try ScratchRepo("shown")
        defer { shown.remove() }
        try shown.commit("a.txt", "one\n", "first")
        let other = try ScratchRepo("other")
        defer { other.remove() }
        try other.commit("a.txt", "one\n", "first")
        let (test, _) = Self.launchedRegistry()
        defer { test.remove() }
        let showing = await test.opened(shown)
        let elsewhere = await test.opened(other)
        let empty = test.registry.makeStore()

        for kind in Self.kinds {
            for front in [nil, empty, elsewhere, showing] as [RepositoryStore?] {
                #expect(test.registry.route(shown.url, kind: kind, front: front) == .front(showing), "\(kind)")
            }
        }
    }

    @Test(.timeLimit(.minutes(10))) func openRepositoryUsesAnEmptyFrontWindowAndOtherwiseANewOne() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let other = try ScratchRepo("other")
        defer { other.remove() }
        try other.commit("a.txt", "one\n", "first")
        let (test, _) = Self.launchedRegistry()
        defer { test.remove() }
        let empty = test.registry.makeStore()
        let showing = await test.opened(other)

        #expect(test.registry.route(repo.url, kind: .openPanel, front: empty) == .useFront(empty))
        #expect(
            test.registry.route(repo.url, kind: .openPanel, front: showing) == .newWindow(RepositoryWindow(url: repo.url)))
        #expect(test.registry.route(repo.url, kind: .openPanel, front: nil) == .newWindow(RepositoryWindow(url: repo.url)))
    }

    /// Open Recent, a Finder open and Open in New Window never take over the front window, even
    /// an empty one.
    @Test(.timeLimit(.minutes(10))) func recentFinderAndWorktreeOpensMakeANewWindowEvenOverAnEmptyFront() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let (test, _) = Self.launchedRegistry()
        defer { test.remove() }
        let empty = test.registry.makeStore()

        for kind in [OpenKind.recentOrFinder, .worktreeNewWindow] {
            #expect(test.registry.route(repo.url, kind: kind, front: empty) == .newWindow(RepositoryWindow(url: repo.url)))
            #expect(test.registry.route(repo.url, kind: kind, front: nil) == .newWindow(RepositoryWindow(url: repo.url)))
        }
    }

    /// RF2: a link to a shown repository, a trailing slash and a `..` path are that repository.
    @Test(.timeLimit(.minutes(10))) func anySpellingOfAShownRepositoryComesToTheFront() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let link = repo.directory.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo.url)
        let (test, _) = Self.launchedRegistry()
        defer { test.remove() }
        let showing = await test.opened(repo)
        let empty = test.registry.makeStore()

        for spelling in [link, URL(fileURLWithPath: repo.url.path + "/"), repo.url.appending(path: "sub/..")] {
            for kind in Self.kinds {
                #expect(test.registry.route(spelling, kind: kind, front: empty) == .front(showing), "\(spelling.path)")
            }
        }
    }

    /// A closed window's repository is shown nowhere: it opens again in a window of its own.
    @Test(.timeLimit(.minutes(10))) func aClosedWindowsRepositoryIsNotFronted() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let (test, _) = Self.launchedRegistry()
        defer { test.remove() }
        let closing = await test.opened(repo)
        test.registry.windowClosed(closing)

        #expect(
            test.registry.route(repo.url, kind: .recentOrFinder, front: nil) == .newWindow(RepositoryWindow(url: repo.url)))
    }

    // MARK: - open

    @Test(.timeLimit(.minutes(10))) func openActsOnTheRouteItTook() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let other = try ScratchRepo("other")
        defer { other.remove() }
        try other.commit("a.txt", "one\n", "first")
        let (test, recorder) = Self.launchedRegistry()
        defer { test.remove() }
        let showing = await test.opened(other)

        // A new window, asked for with its repository; nothing opens in the front window.
        #expect(test.registry.open(repo.url, kind: .recentOrFinder, front: showing) == .newWindow(RepositoryWindow(url: repo.url)))
        #expect(recorder.asked == [RepositoryWindow(url: repo.url)])
        #expect(showing.root.map(RepositoryWindow.init(url:)) == RepositoryWindow(url: other.url))

        // The empty front window takes Open Repository…'s choice itself.
        let empty = test.registry.makeStore()
        #expect(test.registry.open(repo.url, kind: .openPanel, front: empty) == .useFront(empty))
        await waitUntilIdle(empty)
        #expect(empty.root.map(RepositoryWindow.init(url:)) == RepositoryWindow(url: repo.url))
        #expect(recorder.asked.count == 1)

        // Shown now: brought to the front — its window, made key and ordered in — and nothing
        // else opens.
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 200, height: 100), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        test.registry.attach(window, to: empty)
        #expect(!window.isVisible)
        #expect(test.registry.open(repo.url, kind: .recentOrFinder, front: showing) == .front(empty))
        #expect(window.isVisible)
        #expect(recorder.asked.count == 1)
        #expect(showing.root.map(RepositoryWindow.init(url:)) == RepositoryWindow(url: other.url))
    }

    /// Ruling 9 kept: an open that needs a new window before the first window has taken the
    /// launch is held for it (`pendingOpen`) rather than opened beside it; afterwards it opens a
    /// window of its own.
    @Test(.timeLimit(.minutes(10))) func aNewWindowAskedForBeforeTheLaunchWaitsForIt() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        let test = TestRegistry()
        defer { test.remove() }
        let recorder = WindowRecorder()
        test.registry.openWindow = { recorder.asked.append($0) }

        #expect(test.registry.open(repo.url, kind: .recentOrFinder, front: nil) == .newWindow(RepositoryWindow(url: repo.url)))
        #expect(recorder.asked.isEmpty)
        #expect(test.registry.pendingOpen == repo.url)

        #expect(test.registry.takePendingOpen() == repo.url)
        #expect(test.registry.pendingOpen == nil)
        #expect(test.registry.takePendingOpen() == nil)

        test.registry.open(repo.url, kind: .recentOrFinder, front: nil)
        #expect(recorder.asked == [RepositoryWindow(url: repo.url)])
        #expect(test.registry.pendingOpen == nil)
    }

    /// The control for `launchedRegistry`: its recorder sees a new window only because the
    /// helper took the launch's pending open. A registry whose launch is still to come holds the
    /// open instead, so the same check fails there.
    @Test(.timeLimit(.minutes(10))) func theRecorderSeesANewWindowOnlyOnceTheLaunchIsTaken() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        let (launched, seen) = Self.launchedRegistry()
        defer { launched.remove() }
        launched.registry.open(repo.url, kind: .recentOrFinder, front: nil)
        #expect(seen.asked == [RepositoryWindow(url: repo.url)])

        let unlaunched = TestRegistry()
        defer { unlaunched.remove() }
        let unseen = WindowRecorder()
        unlaunched.registry.openWindow = { unseen.asked.append($0) }
        unlaunched.registry.open(repo.url, kind: .recentOrFinder, front: nil)
        withKnownIssue("before the launch the open is held, not handed to the recorder") {
            #expect(unseen.asked == [RepositoryWindow(url: repo.url)])
        }
    }

    // MARK: - store(of:)

    @Test(.timeLimit(.minutes(10))) func aWindowsStoreIsFoundFromTheWindow() async throws {
        let (test, _) = Self.launchedRegistry()
        defer { test.remove() }
        let one = test.registry.makeStore()
        let two = test.registry.makeStore()
        func window() -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered,
                defer: true)
            window.isReleasedWhenClosed = false
            return window
        }
        let first = window()
        let second = window()
        let stranger = window()
        test.registry.attach(first, to: one)
        test.registry.attach(second, to: two)

        #expect(test.registry.store(of: first) === one)
        #expect(test.registry.store(of: second) === two)
        #expect(test.registry.store(of: stranger) == nil)
        #expect(test.registry.store(of: nil) == nil)

        test.registry.windowClosed(two)
        #expect(test.registry.store(of: second) == nil)
    }
}
