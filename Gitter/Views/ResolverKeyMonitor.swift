import AppKit
import SwiftUI

/// Focus mode's keys that no single view owns, as a local key monitor while this view is in a
/// window:
/// - **Escape as Done** (`ResolverShell.escapeIsDone`). It lets the key through to a text view
///   being edited (the Result, a field editor), to a sheet and to other windows. A text view that
///   only shows text (Ours, Theirs, a read-only Result) is not being edited: Escape there is Done.
///   In the editable Result, Escape leaves the text (`ResolverTextView.cancelOperation`), and the
///   next one is Done.
/// - **⌘Z and ⇧⌘Z as the store's undo and redo** (`ResolverShell.undoKey`), wherever focus mode's
///   keys are — the sidebar, a column, the Result — so choices and typing undo alike (spec). A text
///   field being edited (a sheet's, a search field's) keeps its own undo.
struct ResolverKeyMonitor: NSViewRepresentable {
    let done: @MainActor () -> Void
    let undo: @MainActor () -> Void
    let redo: @MainActor () -> Void

    func makeNSView(context: Context) -> MonitorView {
        MonitorView(done: done, undo: undo, redo: redo)
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.done = done
        view.undo = undo
        view.redo = redo
    }

    final class MonitorView: NSView {
        var done: @MainActor () -> Void
        var undo: @MainActor () -> Void
        var redo: @MainActor () -> Void
        private var monitor: Any?

        init(done: @escaping @MainActor () -> Void, undo: @escaping @MainActor () -> Void, redo: @escaping @MainActor () -> Void) {
            self.done = done
            self.undo = undo
            self.redo = redo
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
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }

        /// Whether the key was focus mode's, done here.
        func handle(_ event: NSEvent) -> Bool {
            guard let window else { return false }
            let flags = event.modifierFlags
            let modifiers = flags.intersection([.command, .option, .control, .shift])
            let ownWindow = event.window === window
            let sheetUp = window.attachedSheet != nil
            let responder = window.firstResponder
            let editing = (responder as? NSText)?.isEditable ?? false
            if ResolverShell.escapeIsDone(
                isEscape: event.keyCode == 53, modified: !modifiers.isEmpty, ownWindow: ownWindow, sheetUp: sheetUp,
                editingText: editing)
            {
                done()
                return true
            }
            let key = ResolverShell.undoKey(
                key: event.charactersIgnoringModifiers ?? "", command: flags.contains(.command),
                shift: flags.contains(.shift), otherModifiers: !flags.intersection([.option, .control]).isEmpty,
                ownWindow: ownWindow, sheetUp: sheetUp, editingOtherText: editing && !(responder is ResolverTextView))
            switch key {
            case .undo?: undo()
            case .redo?: redo()
            case nil: return false
            }
            return true
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}
