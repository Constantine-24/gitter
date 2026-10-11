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
            guard let split = SplitViewAutosave.enclosingSplitView(of: self), split.autosaveName != name else { return }
            split.autosaveName = name
        }
    }
}
