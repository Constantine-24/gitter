import AppKit
import SwiftUI

/// Escape as Done (`ResolverShell.escapeIsDone`): a local key monitor while this view is in a
/// window, which lets the key through to a text view being edited (the Result, a field editor),
/// to a sheet and to other windows. A text view that only shows text (Ours, Theirs, a read-only
/// Result) is not being edited: Escape there is Done. In the editable Result, Escape leaves the
/// text (`ResolverTextView.cancelOperation`), and the next one is Done.
struct EscapeMonitor: NSViewRepresentable {
    let done: @MainActor () -> Void

    func makeNSView(context: Context) -> MonitorView {
        MonitorView(done: done)
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.done = done
    }

    final class MonitorView: NSView {
        var done: @MainActor () -> Void
        private var monitor: Any?

        init(done: @escaping @MainActor () -> Void) {
            self.done = done
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Local monitors run on the main thread.
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.window else { return false }
                    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                    let isDone = ResolverShell.escapeIsDone(
                        isEscape: event.keyCode == 53, modified: !modifiers.isEmpty, ownWindow: event.window === window,
                        sheetUp: window.attachedSheet != nil, editingText: (window.firstResponder as? NSText)?.isEditable ?? false)
                    if isDone { self.done() }
                    return isDone
                }
                return handled ? nil : event
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}
