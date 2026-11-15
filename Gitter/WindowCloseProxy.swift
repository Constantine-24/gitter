import AppKit

/// A repository window's delegate, put in front of SwiftUI's own (`WindowRegistry.attach`, E3
/// Task 5): it answers `windowShouldClose` itself and forwards every other selector to the
/// original (`responds(to:)`, `forwardingTarget(for:)`).
///
/// Measured (C1): SwiftUI's delegate, `AppKitWindowController`, implements `windowShouldClose:`
/// itself, so a close the proxy does not turn into a hide is answered by it, not by a plain true.
/// Every user close reaches it — the close button, ⌘W, File › Close, `performClose`,
/// `sendAction`, and Close All, which asks each window in turn — while `window.close()` bypasses
/// it, which is how the app's own real close gets through. With a sheet up AppKit asks no
/// delegate at all (C5). SwiftUI never put its own delegate back, and resize, focus,
/// `@FocusedValue` and sheets kept working with the proxy in.
///
/// The original is held weakly, as the probe did; the window holds its delegate weakly too, so the
/// registry keeps the proxy alive, keyed by window.
///
/// **Ask, then close** (Task 7): a window whose store holds drafts with changes is not closed at
/// once. `askFirst` puts the question up and answers true; the close is refused, and on Discard
/// and Close the question's answer calls the continuation it was handed, which closes the window
/// as the close would have — hidden if it has got busy since, else the original's answer — through
/// `window.close()`, which asks no delegate. A window that hides asks nothing: its drafts stay in
/// the hidden store, and its final close asks (`WindowRegistry`).
@MainActor final class WindowCloseProxy: NSObject, NSWindowDelegate {
    /// Read from `responds(to:)` and `forwardingTarget(for:)`, which NSObject declares
    /// nonisolated; AppKit sends a window's delegate messages on the main thread, and nothing
    /// writes this after `init`.
    nonisolated(unsafe) private(set) weak var original: (any NSWindowDelegate)?
    private let shouldHide: @MainActor () -> Bool
    private let hide: @MainActor () -> Void
    private let askFirst: @MainActor (_ close: @escaping @MainActor () -> Void) -> Bool

    init(
        original: (any NSWindowDelegate)?, shouldHide: @escaping @MainActor () -> Bool,
        hide: @escaping @MainActor () -> Void,
        askFirst: @escaping @MainActor (_ close: @escaping @MainActor () -> Void) -> Bool = { _ in false }
    ) {
        self.original = original
        self.shouldHide = shouldHide
        self.hide = hide
        self.askFirst = askFirst
    }

    /// Hides instead (`hide`, and false) when `shouldHide` says so; asks first (false) when
    /// `askFirst` puts a question up; otherwise the original's answer, or true with none.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if shouldHide() {
            hide()
            return false
        }
        let asked = askFirst { [weak self, weak sender] in
            guard let self, let sender else { return }
            self.closeAfterAsking(sender)
        }
        if asked { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    /// The question's Discard and Close: the close goes on as it would have, without asking again.
    private func closeAfterAsking(_ sender: NSWindow) {
        if shouldHide() {
            hide()
            return
        }
        guard original?.windowShouldClose?(sender) ?? true else { return }
        sender.close()
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) { return true }
        return (original as? NSObject)?.responds(to: selector) ?? false
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if let original = original as? NSObject, original.responds(to: selector) { return original }
        return super.forwardingTarget(for: selector)
    }
}
