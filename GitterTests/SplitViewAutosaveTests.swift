import AppKit
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
/// a split view given one writes its frames into the defaults.
private final class NamedSplitView: NSSplitView {
    static let sidebarName = "main-AppWindow-1, SidebarNavigationSplitView"

    override var autosaveName: NSSplitView.AutosaveName? {
        get { Self.sidebarName }
        set {}
    }
}
