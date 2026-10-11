import AppKit
import SwiftUI
import Testing

@testable import Gitter

/// Window polish Task 2: the commit list / detail divider is kept across launches by giving the
/// `NSSplitView` behind the `HSplitView` an autosave name (`SplitViewAutosave`). The name must go
/// to the split the view sits in — the nearest one — and not to the sidebar's around it, whose
/// autosave SwiftUI already owns. No autosave name is set here: a split view with one saves its
/// frames into the defaults.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct SplitViewAutosaveTests {

    /// outer split > pane > inner split > pane > leaf, as the window nests the HSplitView's split
    /// inside the navigation split.
    private func nested() -> (outer: NSSplitView, inner: NSSplitView, leaf: NSView) {
        let outer = NSSplitView()
        let outerPane = NSView()
        outer.addSubview(outerPane)
        let inner = NSSplitView()
        outerPane.addSubview(inner)
        let innerPane = NSView()
        inner.addSubview(innerPane)
        let leaf = NSView()
        innerPane.addSubview(leaf)
        return (outer, inner, leaf)
    }

    @Test func theNearestSplitViewAboveTheViewIsTheOne() {
        let (_, inner, leaf) = nested()
        #expect(SplitViewAutosave.enclosingSplitView(of: leaf) === inner)
    }

    @Test func aSplitViewItselfIsNotItsOwnEnclosingOne() {
        let (outer, inner, _) = nested()
        #expect(SplitViewAutosave.enclosingSplitView(of: inner) === outer)
    }

    @Test func aViewInNoSplitViewHasNone() {
        let parent = NSView()
        let child = NSView()
        parent.addSubview(child)
        #expect(SplitViewAutosave.enclosingSplitView(of: child) == nil)
        #expect(SplitViewAutosave.enclosingSplitView(of: parent) == nil)
    }

    // MARK: - No name under the test host (final fix wave, G1)

    /// A split view with an autosave name writes its frames to `UserDefaults.standard`, which under
    /// the test host is the user's real domain: three tests that build a real window failed
    /// `.leavesTheRealDefaultsAlone` on `NSSplitView Subview Frames CommitListDetail`.
    @Test func underTheTestHostNoNameIsGiven() {
        #expect(TestHost.isRunningTests)
        #expect(SplitViewAutosave.autosaveName("CommitListDetail", isRunningTests: true) == nil)
        #expect(SplitViewAutosave.autosaveName("CommitListDetail", isRunningTests: false) == "CommitListDetail")
    }

    /// Control: the check fails when it expects a name under the test host.
    @Test func theCheckFailsForANameUnderTheTestHost() {
        withKnownIssue("no name is given under the test host") {
            #expect(SplitViewAutosave.autosaveName("CommitListDetail", isRunningTests: true) == "CommitListDetail")
        }
    }

    /// The view itself, hosted in a window inside a split view that records the names it is given
    /// and keeps none (so nothing reaches the defaults): under the test host it gives none.
    @Test(.timeLimit(.minutes(10))) func aWindowUnderTheTestHostNamesNoSplitView() async {
        let hosted = HostedInSplit(SplitViewAutosave(name: "CommitListDetail"))
        #expect(await hosted.finderIsInTheWindow())
        #expect(hosted.split.namesGiven.isEmpty)
        hosted.close()
    }

    /// Control: the same window, told it is not under the test host, gives the name — the check
    /// above sees a name when one is given.
    @Test(.timeLimit(.minutes(10))) func theCheckFailsWhenTheViewGivesAName() async {
        let hosted = HostedInSplit(SplitViewAutosave(name: "CommitListDetail", isRunningTests: false))
        #expect(await hosted.finderIsInTheWindow())
        withKnownIssue("the view outside the test host names its split view") {
            #expect(hosted.split.namesGiven.isEmpty)
        }
        hosted.close()
    }

    // MARK: - Only an unnamed split view is named (fix round 1, M1)

    /// The split view the finder names: the nearest one, when it has no autosave name yet. Should
    /// `HSplitView` stop being built on an `NSSplitView`, the nearest is the sidebar's, which
    /// SwiftUI has already named — and it must keep that name.
    @Test func anUnnamedNearestSplitViewIsTheOneToName() {
        let (_, inner, leaf) = nested()
        #expect(SplitViewAutosave.splitToName(above: leaf) === inner)
    }

    @Test func aSplitViewThatAlreadyHasANameIsNotRenamed() {
        let (named, leaf) = inNamedSplitView()
        #expect(named.autosaveName == NamedSplitView.sidebarName)
        #expect(SplitViewAutosave.splitToName(above: leaf) == nil)
    }

    /// Control: the check fails when it expects the named split view to be the one to name.
    @Test func theCheckFailsForTheNamedSplitView() {
        let (named, leaf) = inNamedSplitView()
        withKnownIssue("a named split view is not renamed") {
            #expect(SplitViewAutosave.splitToName(above: leaf) === named)
        }
    }

    /// named split > pane > leaf: the window as it would be with no split view of the HSplitView's own.
    private func inNamedSplitView() -> (NamedSplitView, NSView) {
        let named = NamedSplitView()
        let pane = NSView()
        named.addSubview(pane)
        let leaf = NSView()
        pane.addSubview(leaf)
        return (named, leaf)
    }

    /// Control: the check fails when it expects the outer split, the sidebar's in the window.
    @Test func theCheckFailsForTheOuterSplitView() {
        let (outer, _, leaf) = nested()
        withKnownIssue("the outer split view is not the nearest") {
            #expect(SplitViewAutosave.enclosingSplitView(of: leaf) === outer)
        }
    }
}

/// A split view that reads as already named, as the navigation split's is, without setting a name:
/// a split view given one writes its frames into the defaults. Never put in a window or laid out: its
/// getter's name would let AppKit's save path write `NSSplitView Subview Frames` for it.
private final class NamedSplitView: NSSplitView {
    static let sidebarName = "main-AppWindow-1, SidebarNavigationSplitView"

    override var autosaveName: NSSplitView.AutosaveName? {
        get { Self.sidebarName }
        set {}
    }
}

/// A split view that records the autosave names it is given and keeps none: AppKit's setter is never
/// called, and the getter always reads nil, since AppKit's save path reads the getter and a name there
/// would make a layout of this view write its frames into `UserDefaults.standard` — the real domain
/// under the test host (the final re-review measured it).
private final class RecordingSplitView: NSSplitView {
    private(set) var namesGiven: [String] = []

    override var autosaveName: NSSplitView.AutosaveName? {
        get { nil }
        set { if let newValue { namesGiven.append(newValue) } }
    }
}

/// `view` in an `NSHostingView` in a pane of a `RecordingSplitView`, in a window that is never shown.
@MainActor private final class HostedInSplit {
    let split = RecordingSplitView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let window: NSWindow
    private let hosting: NSView

    init(_ view: SplitViewAutosave) {
        let pane = NSView(frame: split.bounds)
        split.addSubview(pane)
        hosting = NSHostingView(rootView: view)
        hosting.frame = pane.bounds
        pane.addSubview(hosting)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = split
        split.layoutSubtreeIfNeeded()
    }

    /// Waits until the representable's own view is in the window — its `viewDidMoveToWindow` has run.
    func finderIsInTheWindow() async -> Bool {
        await waitUntil("the autosave view in the window") { [hosting, window] in
            var stack = [hosting]
            while let view = stack.popLast() {
                if String(describing: type(of: view)).contains("Finder"), view.window === window { return true }
                stack.append(contentsOf: view.subviews)
            }
            hosting.layoutSubtreeIfNeeded()
            return false
        }
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}
