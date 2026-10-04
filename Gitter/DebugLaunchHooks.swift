#if DEBUG

    import AppKit
    import Foundation
    import GitCore

    /// Launch-time hooks that drive the UI from environment variables.
    ///
    /// They exist for verification only. The screenshot environment has Screen Recording but
    /// not Accessibility, so nothing can click: without these, a diff can never be put on
    /// screen and `applyHunk`/`applyLines` can never be reached from a real launch. Compiled
    /// out of Release entirely, and read only once, at startup.
    ///
    ///   GITTER_DEBUG_SELECT_PATH=<path>     select that file in the working copy
    ///   GITTER_DEBUG_STAGED=1               select it on the staged side instead
    ///   GITTER_DEBUG_SELECT_COMMIT=<rev>    select a commit ("HEAD" = the newest one) and,
    ///                                       with no SELECT_PATH, its first file
    ///   GITTER_DEBUG_SELECT_LINES=3,4       pre-select those line ids in the first hunk
    ///   GITTER_DEBUG_APPLY=hunk:0 | lines   then stage/unstage that hunk, or those lines
    ///   GITTER_DEBUG_WINDOW=1400x1400       resize the window, past the screen if asked
    ///   GITTER_DEBUG_OPEN=<path>            the fixture: opened first, as "Open Repository…"
    ///                                       does, and the only repository a hook acts on
    ///   GITTER_DEBUG_APPEARANCE=light|dark  force the window's appearance
    ///   GITTER_DEBUG_THEN=<steps>           branch-action steps to run after the clicks and
    ///                                       keys, e.g. `idle;snapshot:after-click` — what a
    ///                                       click on a toolbar button did
    ///
    /// **The launch guard** (`DebugLaunchGuard`, B2 Ruling 15): with any `GITTER_DEBUG_*`
    /// variable set, the last repository is not reopened and no automatic fetch starts (unless
    /// `GITTER_DEBUG_AUTOFETCH` asks for one); the fixture is opened first, and nothing that acts
    /// — a selection, staging, a click, a key, a step — runs unless the repository on screen is
    /// that fixture. Each refusal is logged as `BRANCH_ACTION launch guard: refused: …`.
    ///
    /// `DebugLaunchHooks+Events` adds the ones that click and type;
    /// `DebugLaunchHooks+Branches` the ones that run branch actions and open their sheets;
    /// `DebugLaunchHooks+Stash` and `DebugLaunchHooks+Discard` the stash and discard steps of
    /// that same step list (its header lists every step).
    @MainActor
    enum DebugLaunchHooks {

        /// Handed to `DiffView` the first time a diff arrives, then dropped: the view owns the
        /// selection, and this is the only way in without making that state public.
        private static var pendingLineIDs: Set<DiffLine.ID>?

        static func preselectLines(in diffs: [FileDiff], selection: inout DiffLineSelection) {
            guard let ids = pendingLineIDs, let hunk = diffs.first?.hunks.first else { return }
            pendingLineIDs = nil
            for line in hunk.lines where ids.contains(line.id) {
                selection.toggle(line, in: hunk)
            }
        }

        static func run(store: RepositoryStore) {
            RepositoryStore.logStores("the window's store is store \(store.debugSerial)")
            let env = ProcessInfo.processInfo.environment
            let path = env["GITTER_DEBUG_SELECT_PATH"]
            let commit = env["GITTER_DEBUG_SELECT_COMMIT"]
            let window = env["GITTER_DEBUG_WINDOW"]
            let openPath = env["GITTER_DEBUG_OPEN"]
            let appearance = env["GITTER_DEBUG_APPEARANCE"]
            let branchAction = branchActionSpec
            let then = env["GITTER_DEBUG_THEN"]
            guard
                path != nil || commit != nil || window != nil || openPath != nil
                    || appearance != nil || branchAction != nil || wantsEvents || then != nil
            else { return }

            pendingLineIDs = lineIDs()
            if let appearance { self.appearance(appearance) }

            Task {
                if let window { resize(to: window) }
                // The launch guard: nothing was reopened, so the fixture is the first repository
                // on screen — and nothing below acts on any other one, or with none open.
                // An empty GITTER_DEBUG_OPEN opens nothing, as an unset one (final review M4).
                if let fixture = DebugLaunchGuard.fixtureToOpen(env) { store.open(URL(fileURLWithPath: fixture)) }
                guard await wait({ store.snapshot != nil }) else {
                    log("launch guard: \(guardRefusal(store) ?? "refused: no snapshot loaded")")
                    return
                }
                if let refusal = guardRefusal(store) {
                    log("launch guard: \(refusal)")
                    return
                }

                if let commit {
                    let sha = commit == "HEAD" ? store.snapshot?.commits.first?.sha : commit
                    guard let sha else { return }
                    store.select(.commit(sha))
                    _ = await wait({ !store.detailFiles.isEmpty })
                    store.selectPath(path ?? store.detailFiles.first?.path)
                } else if let path {
                    // Written before a path is selected, so its `didSet` cannot fire a diff
                    // load for the side we are about to leave.
                    store.stagedView = env["GITTER_DEBUG_STAGED"] == "1"
                    store.selectPath(path)
                }

                if let apply = env["GITTER_DEBUG_APPLY"], await wait({ !store.diff.isEmpty }) {
                    self.apply(apply, store: store)
                }
                // Before the clicks, so a sheet one of them opens is on screen for them (and for
                // a screenshot). Each step checks the guard again (`runBranchActions`).
                if let branchAction {
                    guard await wait({ store.snapshot != nil }) else { return }
                    await runBranchActions(branchAction, store: store)
                }
                // Last, so a click lands on a list that has finished loading its rows.
                if wantsEvents {
                    if let refusal = guardRefusal(store) {
                        log("launch guard: \(refusal); no clicks or keys")
                        return
                    }
                    await runEvents()
                }
                if let then {
                    guard await wait({ store.snapshot != nil }) else { return }
                    await runBranchActions(then, store: store)
                }
            }
        }

        /// Why a hook must not act on the repository on screen now, or nil (`DebugLaunchGuard`).
        // internal (not private): used by DebugLaunchHooks+Branches.swift before every step
        static func guardRefusal(_ store: RepositoryStore) -> String? {
            DebugLaunchGuard.stepRefusal(root: store.root, ProcessInfo.processInfo.environment)
        }

        /// Makes the window `<width>x<height>`, anchored at its current top-left corner.
        ///
        /// The window SwiftUI opens by itself is shorter than the screen, and the diff sits in
        /// the bottom third of it; asking for the screen's full height is what gets a whole
        /// diff into one frame. (Anything beyond the screen is clipped away by the compositor,
        /// so asking for more than that buys nothing.)
        private static func resize(to spec: String) {
            let parts = spec.split(separator: "x").compactMap { Double($0) }
            guard parts.count == 2, let window = NSApp.windows.first(where: \.isVisible) else {
                return
            }
            let top = window.frame.maxY
            window.setFrame(
                NSRect(x: window.frame.minX, y: top - parts[1], width: parts[0], height: parts[1]),
                display: true)
        }

        /// Pins the whole app to one appearance, so a screenshot pass can shoot light and dark
    /// without touching the machine's global setting.
    private static func appearance(_ name: String) {
        NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
    }

    /// Runs the real staging path exactly as the buttons do, so the end-to-end check goes
        /// through `PatchBuilder` and `git apply --cached` and not through a shortcut.
        private static func apply(_ command: String, store: RepositoryStore) {
            guard let file = store.diff.first else { return }

            if command == "lines" {
                // `pendingLineIDs` is usually gone by now — the view consumed it when the diff
                // arrived — but the environment still says which lines were meant.
                guard let hunk = file.hunks.first, let ids = lineIDs() else { return }
                store.applyLines(ids, of: hunk, in: file)
            } else if let index = command.split(separator: ":").last.flatMap({ Int($0) }),
                command.hasPrefix("hunk:"), file.hunks.indices.contains(index)
            {
                store.applyHunk(file.hunks[index], in: file)
            }
        }

        // internal (not private): used by DebugLaunchHooks+Discard.swift's `discardhunk:`
        static func lineIDs() -> Set<DiffLine.ID>? {
            ProcessInfo.processInfo.environment["GITTER_DEBUG_SELECT_LINES"].map { list in
                Set(
                    list.split(separator: ",")
                        .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
            }
        }

        /// Polls `condition` for up to ten seconds, or `seconds` — the network steps wait up to
        /// 120, since a slow transfer is exactly what some of them are there to drive. Loading is spread over several independent
        /// tasks in the store with nothing to await from outside, so polling is the honest
        /// way to say "once it is on screen".
        // internal (not private): used by DebugLaunchHooks+Branches.swift, which waits the same
        // way for each step's mutation to finish
        static func wait(_ condition: @MainActor () -> Bool, seconds: Int = 10) async -> Bool {
            for _ in 0..<(seconds * 10) {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return condition()
        }
    }

#endif
