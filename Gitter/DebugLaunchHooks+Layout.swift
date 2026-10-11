#if DEBUG

    import AppKit
    import Foundation

    /// The window's layout steps of `GITTER_DEBUG_BRANCH_ACTION` (see `DebugLaunchHooks+Branches`
    /// for the grammar). The harness cannot drag, and the sidebar's toolbar button goes into the
    /// toolbar's overflow menu on a narrow window, where a click cannot reach it; these do what the
    /// pointer would, through the same AppKit calls:
    ///
    ///   split            the window's width, the sidebar's width (and whether it is collapsed),
    ///                    the commit list's and the detail's panes and the divider between them,
    ///                    in `views` coordinates (x from the content area's left edge).
    ///   togglesidebar    the sidebar's show/hide, as the toolbar button sends it
    ///                    (`NSSplitViewController.toggleSidebar(_:)`), then `split`.
    ///   resize:<w>x<h>   the window resized, as `GITTER_DEBUG_WINDOW` does at launch, then `split`.
    ///   divider:<x>      the commit list / detail divider moved to x, as a drag moves it
    ///                    (`NSSplitView.setPosition(_:ofDividerAt:)`, which the split view's
    ///                    delegate constrains to the panes' minimums), then `split`.
    extension DebugLaunchHooks {

        static let layoutCommands: Set<String> = ["split", "togglesidebar", "resize", "divider"]

        static func layoutStep(_ command: String, rest: String, store: RepositoryStore) async {
            guard let window = window(of: store) else {
                log("\(command): no window")
                return
            }
            switch command {
            case "togglesidebar":
                guard let controller = sidebarController(in: window) else {
                    log("togglesidebar: no sidebar split")
                    return
                }
                controller.toggleSidebar(nil)
            case "resize": resize(to: rest)
            case "divider":
                guard let x = Double(rest), let split = contentSplit(in: window) else {
                    log("divider: no commit list / detail split, or no x in \(rest)")
                    return
                }
                let local = split.convert(NSPoint(x: x + window.contentLayoutRect.minX, y: 0), from: nil).x
                split.setPosition(local, ofDividerAt: 0)
            default: break
            }
            // A drawn frame, so the lines say what the window settled on.
            if command != "split" { try? await Task.sleep(for: .milliseconds(600)) }
            logSplit(window)
        }

        private static func logSplit(_ window: NSWindow) {
            let content = window.contentLayoutRect
            func span(_ view: NSView) -> String {
                let r = view.convert(view.bounds, to: nil)
                return "x=\(Int(r.minX - content.minX))..\(Int(r.maxX - content.minX)) "
                    + "y=\(Int(content.maxY - r.maxY)) w=\(Int(r.width)) h=\(Int(r.height))"
            }
            var line = "split: window w=\(Int(window.frame.width))"
            if let item = sidebarController(in: window)?.splitViewItems.first {
                line += " | sidebar \(item.isCollapsed ? "collapsed" : "shown") \(span(item.viewController.view))"
            }
            if let split = contentSplit(in: window), split.arrangedSubviews.count == 2 {
                let panes = split.arrangedSubviews
                let divider = panes[0].convert(panes[0].bounds, to: nil).maxX - content.minX
                line += " | commit list \(span(panes[0])) | detail \(span(panes[1])) | divider x=\(Int(divider))"
                line += " | autosave \(split.autosaveName ?? "nil")"
            } else {
                line += " | no commit list / detail split"
            }
            log(line)
        }

        /// The navigation split's controller: the one whose first item is a sidebar.
        private static func sidebarController(in window: NSWindow) -> NSSplitViewController? {
            splitViews(in: window).lazy.compactMap { $0.delegate as? NSSplitViewController }
                .first { $0.splitViewItems.first?.behavior == .sidebar }
        }

        /// The side-by-side split that is not the sidebar's: the commit list and the detail.
        private static func contentSplit(in window: NSWindow) -> NSSplitView? {
            let sidebar = sidebarController(in: window)?.splitView
            return splitViews(in: window).first { $0.isVertical && $0 !== sidebar }
        }

        private static func splitViews(in window: NSWindow) -> [NSSplitView] {
            var found: [NSSplitView] = []
            var stack = [window.contentView].compactMap { $0 }
            while let view = stack.popLast() {
                if let split = view as? NSSplitView { found.append(split) }
                stack.append(contentsOf: view.subviews.reversed())
            }
            return found
        }
    }

#endif
