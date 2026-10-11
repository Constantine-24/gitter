import AppKit
import SwiftUI

/// Gives the `NSSplitView` behind the enclosing `HSplitView` an autosave name, so AppKit keeps
/// where the user left its divider in the defaults and puts it back at the next launch.
/// `HSplitView` has no such option, and without one the divider went back to the middle at
/// every launch (measured, window polish Task 2).
struct SplitViewAutosave: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView { Finder(name: name) }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// The split view `view` sits in: its nearest `NSSplitView` ancestor, or nil.
    static func enclosingSplitView(of view: NSView) -> NSSplitView? {
        sequence(first: view, next: \.superview).dropFirst().lazy.compactMap { $0 as? NSSplitView }.first
    }

    /// The split view to name for `view`: the nearest enclosing one, if it has no autosave name yet.
    /// A named one is left alone: should `HSplitView` stop being built on an `NSSplitView`, the
    /// nearest would be the sidebar's, which SwiftUI has named (fix round 1, M1).
    static func splitToName(above view: NSView) -> NSSplitView? {
        guard let split = enclosingSplitView(of: view), (split.autosaveName ?? "").isEmpty else { return nil }
        return split
    }

    private final class Finder: NSView {
        let name: String

        init(name: String) {
            self.name = name
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            SplitViewAutosave.splitToName(above: self)?.autosaveName = name
        }
    }
}
