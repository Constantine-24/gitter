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
@MainActor final class WindowCloseProxy: NSObject, NSWindowDelegate {
    /// Read from `responds(to:)` and `forwardingTarget(for:)`, which NSObject declares
    /// nonisolated; AppKit sends a window's delegate messages on the main thread, and nothing
    /// writes this after `init`.
    nonisolated(unsafe) private(set) weak var original: (any NSWindowDelegate)?
    private let shouldHide: @MainActor () -> Bool
    private let hide: @MainActor () -> Void

    init(
        original: (any NSWindowDelegate)?, shouldHide: @escaping @MainActor () -> Bool,
        hide: @escaping @MainActor () -> Void
    ) {
        self.original = original
        self.shouldHide = shouldHide
        self.hide = hide
    }

    /// Hides instead (`hide`, and false) when `shouldHide` says so; otherwise the original's
    /// answer, or true with none.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if shouldHide() {
            hide()
            return false
        }
        return original?.windowShouldClose?(sender) ?? true
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
