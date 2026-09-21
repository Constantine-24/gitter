#if DEBUG

    import AppKit
    import Foundation

    /// Mouse clicks, key presses and a responder dump, for the same verification runs.
    ///
    /// `osascript` and `CGEvent.post` both need Accessibility, which the screenshot environment
    /// does not grant, so nothing outside the process can click. Events built here are posted
    /// onto the app's *own* queue, which needs no permission at all.
    ///
    /// They go through `NSApp.postEvent` rather than `sendEvent`: `NSTableView` runs its own
    /// tracking loop on mouse-down and pulls the matching mouse-up out of the queue itself, so a
    /// synchronous send would spin in that loop with no up-event to find.
    ///
    ///   GITTER_DEBUG_CLICK="x,y[:2|:shift|:right][;…]"  click those points (see `point(from:)`),
    ///                                            or `type=text` to type in the middle of it
    ///   GITTER_DEBUG_KEYS=space,return,cmd+return,tab   then press those keys
    ///   GITTER_DEBUG_TYPE=text                   then type that text, character by character
    ///   GITTER_DEBUG_DUMP_RESPONDER=1            print the responder chain to stderr after
    ///                                            every click and key, and once more at the
    ///                                            end — or that many times, 200 ms apart
    extension DebugLaunchHooks {

        /// The variable names, in one place: `wantsEvents` and `runEvents` have to agree about
        /// them, and a typo in either would silently do nothing.
        private enum Variable {
            static let click = "GITTER_DEBUG_CLICK"
            static let keys = "GITTER_DEBUG_KEYS"
            static let typing = "GITTER_DEBUG_TYPE"
            static let dump = "GITTER_DEBUG_DUMP_RESPONDER"
            static let all = [click, keys, typing, dump]
        }

        /// Whether any of the event variables is set, and `run` therefore has work to do even
        /// without a selection to make.
        static var wantsEvents: Bool {
            let env = ProcessInfo.processInfo.environment
            return Variable.all.contains { env[$0] != nil }
        }

        /// Clicks, then keys, then typing, then the dump — in that order, because each step is
        /// usually the setup for the next (click a row, press space, see where focus went).
        static func runEvents() async {
            let env = ProcessInfo.processInfo.environment
            guard let window = NSApp.windows.first(where: \.isVisible) else { return }
            // Launched from a shell the app is not frontmost, and an inactive window is never
            // key: its selection draws in the unemphasized grey no matter who is first
            // responder, which is exactly the thing under investigation here.
            NSApp.activate()
            // `activate()` returns long before the window is key, and a click that lands first
            // is the *inactive*-window case, which AppKit treats differently.
            for _ in 0..<50 {
                if window.isKeyWindow || window.attachedSheet != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(300))

            let dump = env[Variable.dump]
            for spec in env[Variable.click, default: ""].split(separator: ";") {
                // `type=…` as a step, not only the `GITTER_DEBUG_TYPE` variable, because what
                // typing is usually for is what happens *after* it — untick a box, press a
                // button — and that needs the two ordered against each other. `type=` with
                // nothing after it types nothing, rather than typing the word.
                if spec.hasPrefix(typeStep) {
                    for character in spec.dropFirst(typeStep.count) {
                        type(character, in: target(of: window))
                    }
                } else {
                    click(String(spec), in: target(of: window))
                }
                try? await Task.sleep(for: .milliseconds(400))
                if dump != nil { dumpResponders(of: target(of: window), after: "\(spec)") }
            }
            for name in env[Variable.keys, default: ""].split(separator: ",") {
                press(String(name), in: target(of: window))
                try? await Task.sleep(for: .milliseconds(400))
                if dump != nil { dumpResponders(of: target(of: window), after: "key \(name)") }
            }
            for character in env[Variable.typing, default: ""] {
                type(character, in: target(of: window))
                try? await Task.sleep(for: .milliseconds(120))
            }
            // A count rather than a flag: focus can be handed back a moment later (a reload
            // that rebuilds the list would do it), and one dump cannot tell a never-focused
            // list from a list that lost focus again.
            if let dump {
                for _ in 0..<max(1, Int(dump) ?? 1) {
                    dumpResponders(of: target(of: window), after: "settled")
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }

        /// The window an event must be aimed at: the sheet on screen, if there is one.
        ///
        /// A sheet is its own `NSWindow`. Events posted with the *parent's* window number are
        /// delivered to a window a sheet has made modal, so they land on nothing — which is
        /// exactly what a click on the merge sheet's radio buttons did until this existed
        /// (the radio never moved; verified by screenshot, twice). Re-read before every step
        /// rather than captured once, because a step can open or close a sheet.
        ///
        /// Coordinates in a click step are therefore relative to whichever window is in front:
        /// the sheet's own content area while one is up, the main window's otherwise.
        private static func target(of window: NSWindow) -> NSWindow {
            window.attachedSheet ?? window
        }

        /// The prefix that turns a click-script step into a typing step.
        private static let typeStep = "type="

        // MARK: - Clicking

        /// `x,y` in points from the top-left of the window's *content* area, optionally
        /// `:2` for a double click or `:shift` for a shift-click.
        ///
        /// A screenshot pixel converts with the numbers `dumpResponders` prints: divide by the
        /// backing scale for points from the window's top-left, then subtract the content
        /// area's own offset (`frame.height - contentLayoutRect.maxY` from the top).
        private static func click(_ spec: String, in window: NSWindow) {
            let parts = spec.split(separator: ":")
            guard let location = point(from: parts.first.map(String.init) ?? "", in: window) else {
                return
            }
            let modifiers: NSEvent.ModifierFlags = parts.contains("shift") ? .shift : []
            // `:right` is what opens a context menu: a right-click is the only way to reach the
            // sidebar's and the commit list's menus, and nothing outside the process may click.
            // AppKit turns a right mouse-down into `menu(for:)` and pops the menu up itself.
            if parts.contains("right") {
                send(rightClick: location, in: window)
                return
            }
            send(click: 1, at: location, modifiers: modifiers, in: window)
            // AppKit reads a double click off `clickCount`, and it only ever sees a 2 after it
            // has seen a 1 — so the second pair follows the first rather than replacing it.
            if parts.contains("2") {
                send(click: 2, at: location, modifiers: modifiers, in: window)
            }
        }

        private static func point(from pair: String, in window: NSWindow) -> NSPoint? {
            let numbers = pair.split(separator: ",").compactMap { Double($0) }
            guard numbers.count == 2 else { return nil }
            let content = window.contentLayoutRect
            return NSPoint(x: content.minX + numbers[0], y: content.maxY - numbers[1])
        }

        private static func send(
            click count: Int, at location: NSPoint, modifiers: NSEvent.ModifierFlags,
            in window: NSWindow
        ) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard
                    let event = NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                        clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)
                else { continue }
                NSApp.postEvent(event, atStart: false)
            }
        }

        /// A right mouse-down/up pair, which is what an `NSView` turns into a context menu.
        ///
        /// **It does not open one here, and that is a recorded result rather than a bug to fix
        /// later.** Tried both ways on macOS 26 (Task 8): down alone and the down/up pair, on a
        /// sidebar row where a *left* click posted the same way demonstrably selects the row —
        /// no menu appeared either time, and the responder dump printed straight away, so no
        /// menu tracking loop was ever entered. A posted right-click is delivered, but SwiftUI's
        /// `.contextMenu` is not reached by it. Kept so the next attempt starts from what has
        /// already been ruled out; the menus themselves still need a real pointer.
        private static func send(rightClick location: NSPoint, in window: NSWindow) {
            for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                guard
                    let event = NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                        clickCount: 1, pressure: type == .rightMouseDown ? 1 : 0)
                else { continue }
                NSApp.postEvent(event, atStart: false)
            }
        }

        // MARK: - Keys

        /// A key name, optionally prefixed with `cmd+`, `shift+`, `opt+` or `ctrl+`.
        private static func press(_ name: String, in window: NSWindow) {
            var modifiers: NSEvent.ModifierFlags = []
            var key = name
            while let plus = key.firstIndex(of: "+") {
                switch key[key.startIndex..<plus] {
                case "cmd": modifiers.insert(.command)
                case "shift": modifiers.insert(.shift)
                case "opt": modifiers.insert(.option)
                case "ctrl": modifiers.insert(.control)
                default: break
                }
                key = String(key[key.index(after: plus)...])
            }
            guard let (code, characters) = keys[key] else { return }
            send(characters, code: code, modifiers: modifiers, in: window)
        }

        private static let keys: [String: (code: UInt16, characters: String)] = [
            "space": (49, " "), "return": (36, "\r"), "tab": (48, "\t"),
            "escape": (53, "\u{1b}"), "down": (125, "\u{f701}"), "up": (126, "\u{f700}"),
        ]

        /// One character of `GITTER_DEBUG_TYPE`. The key code is what a keyboard would report
        /// for the physical key; a text field inserts what `characters` says regardless, and
        /// that is all this is for.
        private static func type(_ character: Character, in window: NSWindow) {
            send(String(character), code: 0, modifiers: [], in: window)
        }

        private static func send(
            _ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags,
            in window: NSWindow
        ) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard
                    let event = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: characters,
                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
                else { continue }
                NSApp.postEvent(event, atStart: false)
            }
        }

        // MARK: - Responder dump

        /// Prints, to stderr, who would receive a key press and where the window is on screen.
        ///
        /// Both halves matter for the selection colour: AppKit draws the emphasized (accent)
        /// highlight only when the table is the first responder of a key window, and the
        /// geometry is what turns a screenshot pixel back into a click point.
        private static func dumpResponders(of window: NSWindow, after step: String) {
            var lines = [
                "RESPONDER after \(step): key=\(window.isKeyWindow) "
                    + "main=\(window.isMainWindow) active=\(NSApp.isActive)",
                "RESPONDER frame=\(window.frame) content=\(window.contentLayoutRect) "
                    + "scale=\(window.backingScaleFactor)",
            ]
            var responder = window.firstResponder
            var depth = 0
            while let current = responder, depth < 24 {
                lines.append("RESPONDER [\(depth)] \(Swift.type(of: current))")
                responder = current.nextResponder
                depth += 1
            }
            FileHandle.standardError.write(Data(lines.joined(separator: "\n").utf8))
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }

#endif
