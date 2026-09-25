#if DEBUG

    import AppKit
    import Foundation
    import GitCore

    /// Driving the branch actions and sheets from the environment, for the same reason as the
    /// rest of these hooks: the sidebar's context menus are AppKit menus that in-process clicks
    /// cannot open, so without this there is no way to reach `switchTo`, `merge` or a
    /// confirmation sheet from a script.
    ///
    ///   GITTER_DEBUG_BRANCH_ACTION=<step>[;<step>…]
    ///
    ///     switch:<branch>              track:<remote>/<branch>      detach:<revision>
    ///     create:<name>[:<start>]      createswitch:<name>[:<start>]
    ///     rename:<old>:<new>           delete:<branch>              forcedelete:<branch>
    ///     merge:<branch>:<ff|noff|squash>
    ///     abort                        confirmleave
    ///     sheet:new | sheet:rename:<b> | sheet:merge:<b> | sheet:delete:<b> | sheet:abort
    ///     sheet:pull
    ///     wait:<seconds>
    ///
    ///   The network lane (`RepositoryStore+Remotes`, `+RemoteSheets`):
    ///
    ///     fetch[:<remote>]             pull          pull:merge      pull:rebase
    ///     push                         publish:<remote>
    ///     forcepush                    confirmforcepush
    ///     deleteremote:<remote>/<b>    confirmdeleteremote
    ///     cancel                       start:<step>  idle
    ///     stageall                     commit:<subject>     snapshot:<name>
    ///     open:<path>                  menu:<title>        views[:<class>]     badges
    ///     autofetchfailed:<reason>
    ///
    /// Steps run in order, each waiting for the mutation the one before it started — and, for a
    /// step that starts network work, for the lane to free as well, for up to 120 seconds.
    /// `start:<step>` runs a step **without** waiting for its lane, which is how the steps after
    /// it run *during* a slow fetch: `start:fetch;stageall;commit:x;wait:2;cancel`. A step taken
    /// while the lane was already busy waits only for the mutation slot, so a second network
    /// action is refused and logged at once instead of waiting out the first. `cancel` and
    /// `idle` wait for the lane to free, so their line shows what the work said at the end.
    ///
    /// `pull:merge` and `pull:rebase` pull and then answer the pull sheet, if one opened, with
    /// that mode; `sheet:pull` opens the sheet from the tracking already on screen without
    /// fetching or acting. `publish:<remote>` pushes and answers the publish sheet with that
    /// remote if one opened (with a single remote there is none). `forcepush` opens the force
    /// push sheet, which it can only do after a rejected `push`; `deleteremote:` only opens its
    /// sheet. The two `confirm…` steps answer those sheets, and do nothing without them. `abort`,
    /// `forcedelete` and `confirmleave` answer a confirmation, which is why several steps in one
    /// launch matter: those sheets cannot be reached any other way.
    ///
    /// `wait:<seconds>` does nothing but hold the sheet on screen, and it exists for one kind of
    /// check that cannot be made any other way: what the app does when the repository changes
    /// **underneath a confirmation that is already up**. The script opens the sheet, waits here
    /// while a terminal moves a branch, and the clicks in `GITTER_DEBUG_CLICK` — which run once,
    /// after the **last** step — then answer a warning that has gone out of date. (Clicks after
    /// *every* step is what this comment used to claim; `DebugLaunchHooks.run` posts them once,
    /// when `runBranchActions` has returned.) A wait is clamped to 0…120 seconds: a typo in the
    /// number should not leave a launched app sitting there for an hour with nothing to quit it.
    ///
    /// `delete:` and `forcedelete:` **act** — they run `git branch -d`/`-D`. Every `sheet:` step
    /// only opens a sheet; `sheet:delete:<b>` in particular reads the warning's numbers instead
    /// of letting `-d` refuse, so it cannot delete a branch git considers merged.
    ///
    /// After every step one line goes to stderr. `head` and `selection` ride along because the
    /// store's own answer to "where are we now" cannot be read from git, and "the selection
    /// returns to the working copy" is part of what these actions promise:
    ///
    ///   BRANCH_ACTION result: <sheet or nil> | notice: <…> | error: <…> | head: <…> |
    ///   selection: <…>
    extension DebugLaunchHooks {

        static var branchActionSpec: String? {
            ProcessInfo.processInfo.environment["GITTER_DEBUG_BRANCH_ACTION"]
        }

        static func runBranchActions(_ spec: String, store: RepositoryStore) async {
            for step in spec.split(separator: ";") {
                log("step: \(step)")
                let text = String(step)
                let laneWasBusy = store.remoteActivity != nil
                let started = text.hasPrefix("start:")
                await perform(started ? String(text.dropFirst("start:".count)) : text, store: store)
                // `mutate` and the lane are both claimed synchronously, so by now `isMutating` or
                // `remoteActivity` is already set for anything that runs git; a step that only
                // opens a sheet sets neither and this returns at once.
                if started || text.hasPrefix("wait:") {
                    // Nothing to wait for: the point is to carry on while it runs.
                } else if laneWasBusy && text != "cancel" && text != "idle" {
                    _ = await wait({ !store.isMutating })
                } else {
                    _ = await wait(
                        { store.remoteActivity == nil && !store.isMutating }, seconds: 120)
                }
                logResult(store)
            }
        }

        private static func logResult(_ store: RepositoryStore) {
            let lane = store.remoteActivity.map {
                "\($0.kind)(\($0.remote ?? "all"), progress: \($0.progress ?? "nil"))"
            }
            log(
                "result: \(describe(store.activeSheet, store)) | notice: \(flat(store.notice)) "
                    + "| error: \(flat(store.lastError)) "
                    + "| head: \(store.headLabel) | selection: \(store.selection)")
            log(
                "lane: \(lane ?? "nil") | forcePushOffered: \(store.bannerOffersForcePush) "
                    + "| reasons: fetch=\(store.fetchBlockedReason ?? "nil"); "
                    + "pull=\(store.pullBlockedReason ?? "nil"); "
                    + "push=\(store.pushBlockedReason ?? "nil") "
                    + "| pushTitle: \(store.pushButtonTitle) | tracking: \(store.currentTracking) "
                    + "| pushCount: \(store.pushAheadCount.map(String.init) ?? "nil") "
                    + "| pullCount: \(store.pullBehindCount.map(String.init) ?? "nil") "
                    + "| pushHelp: \(store.pushHelp) "
                    + "| pullMode: \(store.rememberedPullMode.rawValue) "
                    + "| loads: \(store.snapshotLoadCount)")
        }

        private static func flat(_ text: String?) -> String {
            text?.replacingOccurrences(of: "\n", with: " \u{23CE} ") ?? "nil"
        }

        // MARK: - One step

        private static func perform(_ step: String, store: RepositoryStore) async {
            // `maxSplits` so a branch name may contain a colon-free remainder only where the
            // grammar says so: `merge:<b>:<mode>` has exactly three fields, `rename` three,
            // `create` two or three.
            let fields = step.split(separator: ":").map(String.init)
            guard let command = fields.first else { return }
            let first = fields.count > 1 ? fields[1] : nil
            let second = fields.count > 2 ? fields[2] : nil

            switch command {
            case "switch": first.map { store.switchTo(branch: $0) }
            // A remote branch is spelled `origin/x`, which has no colon, so re-joining is only
            // needed for the ones that take two names.
            case "track": first.map { store.track(remoteBranch: $0) }
            case "detach": first.map { store.detach(at: $0) }
            case "create":
                first.map {
                    store.createBranch(named: $0, startPoint: second, switchTo: false)
                }
            case "createswitch":
                first.map {
                    store.createBranch(named: $0, startPoint: second, switchTo: true)
                }
            case "rename":
                if let first, let second { store.rename(first, to: second) }
            case "delete": first.map { store.requestDelete($0) }
            case "forcedelete":
                // The warning first, then its answer — the same two steps a user takes, and the
                // only way in: `confirmForceDelete` refuses without a matching sheet on screen.
                // A branch `-d` deletes cleanly never reaches the second half, which is right.
                if let first {
                    store.requestDelete(first)
                    _ = await wait({ !store.isMutating })
                    // Reached for unconditionally, on purpose: the store's own guard is the only
                    // thing that may stop it. For a branch `-d` deleted cleanly no warning was
                    // ever shown, and a `confirmForceDelete` that ran anyway would be visible —
                    // it would put "There is no branch named …" in the banner.
                    store.confirmForceDelete(first)
                    _ = await wait({ !store.isMutating })
                }
            case "merge":
                if let first, let mode = mergeMode(second) { store.merge(first, mode: mode) }
            case "abort":
                // The sheet first, then its answer: the same two steps a user takes, and the
                // only way to exercise `confirmAbort`'s "which operation" argument honestly.
                store.requestAbort()
                if case .abort(let operation) = store.activeSheet {
                    store.confirmAbort(operation)
                }
            case "confirmleave": store.confirmLeaveDetached()
            case "wait":
                // Seconds, not milliseconds: what this is for is giving a shell time to change
                // the repository, and a step measured in milliseconds could not. Clamped, so a
                // mistyped number cannot park the app past the end of the check.
                try? await Task.sleep(
                    for: .seconds(min(max(Double(first ?? "") ?? 1, 0), 120)))
            case "sheet": await sheet(first, second, store: store)
            case "fetch": store.fetch(remote: first)
            case "pull":
                if first == nil {
                    store.pull()
                } else if let mode = first.flatMap(PullMode.init(rawValue:)) {
                    // The pull, then the sheet's answer — the two steps a user takes. Answered
                    // unconditionally: `confirmPull` does nothing without its sheet on screen.
                    store.pull()
                    _ = await wait(
                        { store.remoteActivity == nil && !store.isMutating }, seconds: 120)
                    store.confirmPull(mode)
                }
            case "push": store.push()
            case "publish":
                store.push()
                _ = await wait({ store.remoteActivity == nil && !store.isMutating }, seconds: 120)
                first.map { store.confirmPublish(to: $0) }
            case "forcepush": store.requestForcePush()
            case "confirmforcepush": store.confirmForcePush()
            case "deleteremote": first.map { store.requestDeleteRemoteBranch($0) }
            case "confirmdeleteremote": store.confirmDeleteRemoteBranch()
            case "cancel": store.cancelRemoteActivity()
            // Nothing but the wait below: the lane to free, after a `start:`.
            case "idle": break
            case "snapshot":
                // Past the banners' insertion animation, so they are drawn at full opacity.
                try? await Task.sleep(for: .milliseconds(800))
                first.map { snapshot(named: $0) }
            // "Open Repository…" mid-script, e.g. while a push is on the lane. The path is the
            // rest of the step, colons and all.
            case "open":
                let path = step.dropFirst("open:".count)
                if !path.isEmpty { store.open(URL(fileURLWithPath: String(path))) }
            case "autofetchfailed":
                store.debugSetLastAutoFetchFailure(String(step.dropFirst("autofetchfailed:".count)))
            case "menu": first.map { dumpMenu(titled: $0) }
            case "views": dumpViews(matching: first)
            case "badges":
                // What each sidebar row's badge draws, says and reads out — the same function
                // the row calls. The snapshot cannot show the sidebar (see `snapshot(named:)`).
                for branch in store.localBranches {
                    let text = TrackingBadge.text(
                        for: branch.tracking, tracksLocalBranch: branch.tracksLocalBranch,
                        upstream: branch.upstream)
                    let help = RemoteWording.trackingHelp(
                        branch.tracking, upstream: branch.upstream,
                        tracksLocalBranch: branch.tracksLocalBranch)
                    let spoken = RemoteWording.trackingAccessibility(
                        branch.tracking, upstream: branch.upstream,
                        tracksLocalBranch: branch.tracksLocalBranch)
                    log(
                        "badge \(branch.name): \(text ?? "(none)") | help: \(help ?? "nil") "
                            + "| voiceover: \(spoken ?? "nil")")
                }
            case "stageall": store.stageAll()
            case "commit":
                // The composer's own path: the subject goes into the draft, then `commit()`.
                store.draft.subject = first ?? "commit"
                store.commit()
            default: log("unknown step: \(step)")
            }
        }

        private static func sheet(_ which: String?, _ name: String?, store: RepositoryStore)
            async
        {
            switch which {
            case "new": store.requestNewBranch()
            case "rename": name.map { store.requestRename($0) }
            case "merge": name.map { store.requestMerge($0) }
            // `previewDeleteWarning`, never `requestDelete`: this step says it opens a sheet, and
            // `requestDelete` runs `git branch -d`, which would silently delete a merged branch.
            // It reads the count in its own task and takes no mutation lock, so wait for the
            // sheet itself rather than for `isMutating`.
            case "delete":
                // Cleared first so the wait below cannot be satisfied by a sheet an earlier step
                // left up, which would print the previous step's answer for this one.
                store.activeSheet = nil
                name.map { store.previewDeleteWarning($0) }
                _ = await wait({ store.activeSheet != nil })
            case "abort": store.requestAbort()
            // From the tracking on screen, with no fetch and no merge: this step opens a sheet.
            case "pull": store.previewPullSheet()
            default: log("unknown sheet: \(which ?? "")")
            }
        }

        /// Renders the main window — and the sheet attached to it, drawn centred over its top
        /// edge the way AppKit presents it — into `<GITTER_DEBUG_SNAPSHOT_DIR>/<name>.png`.
        ///
        /// Drawn by the app itself rather than captured from the screen: a window on a Space
        /// nobody is looking at captures as blank, and a screen capture would take whatever
        /// else is on the display with it. The frame view's **layer tree** is rendered
        /// (`CALayer.render(in:)`, see `image(of:)`) — not `cacheDisplay`, which leaves out the
        /// SwiftUI overlays the banners are drawn in — and that needs neither Screen Recording
        /// nor the window to be visible. It does not draw `NSVisualEffectView` materials, so
        /// the sidebar comes out blank: faithful for banners and sheets, not for the whole
        /// window. (Measured in Task 9: rendering the sidebar's own layer does not help either —
        /// its text layers hold vibrancy-tinted contents, `CATintedImage`, which
        /// `render(in:)` skips. The `badges` step logs what its rows draw instead.)
        private static func snapshot(named name: String) {
            guard let dir = ProcessInfo.processInfo.environment["GITTER_DEBUG_SNAPSHOT_DIR"],
                let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }),
                let main = image(of: window)
            else {
                log("snapshot failed: \(name)")
                return
            }
            let size = main.size
            let composed = NSImage(size: size, flipped: false) { _ in
                main.draw(in: NSRect(origin: .zero, size: size))
                if let sheet = window.attachedSheet, let drawn = image(of: sheet) {
                    let origin = NSPoint(
                        x: (size.width - drawn.size.width) / 2,
                        y: size.height - drawn.size.height - 60)
                    drawn.draw(in: NSRect(origin: origin, size: drawn.size))
                }
                return true
            }
            guard let tiff = composed.tiffRepresentation,
                let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { return }
            let url = URL(fileURLWithPath: dir).appending(path: name + ".png")
            do {
                try png.write(to: url)
                log("snapshot: \(url.lastPathComponent)")
            } catch {
                log("snapshot failed: \(error)")
            }
        }

        /// Logs the main window's view tree — class, depth, frame in content-area coordinates
        /// (the toolbar's y is negative) — for views whose class name contains `filter`.
        ///
        /// This is how a `GITTER_DEBUG_CLICK` is aimed at a toolbar button: each SwiftUI toolbar
        /// item is a `ToolbarItemHostingView`, and the centre of its frame is the click point.
        /// (The in-process accessibility tree was tried first and exposes only the window and
        /// its title-bar buttons, not SwiftUI's elements, when no assistive client is running.)
        private static func dumpViews(matching filter: String?) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }),
                let frameView = window.contentView?.superview
            else { return }
            let content = window.contentLayoutRect
            var stack: [(NSView, Int)] = [(frameView, 0)]
            while let (view, depth) = stack.popLast() {
                let name = String(describing: Swift.type(of: view))
                if filter.map({ name.contains($0) }) ?? true {
                    let r = view.convert(view.bounds, to: nil)
                    log(
                        "view: \(String(repeating: " ", count: depth))\(name) "
                            + "x=\(Int(r.minX - content.minX)) y=\(Int(content.maxY - r.maxY)) "
                            + "w=\(Int(r.width)) h=\(Int(r.height))\(view.isHidden ? " hidden" : "")")
                }
                for child in view.subviews.reversed() { stack.append((child, depth + 1)) }
            }
        }

        private static func image(of window: NSWindow) -> NSImage? {
            // The frame view, so the toolbar and title bar are in the picture too. Its layer
            // tree is rendered rather than `cacheDisplay`, which leaves out SwiftUI overlays —
            // the banners, which are most of what these pictures are for.
            guard let view = window.contentView?.superview ?? window.contentView else {
                return nil
            }
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let scale = window.backingScaleFactor
            let size = view.bounds.size
            guard let layer = view.layer,
                let context = CGContext(
                    data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.scaleBy(x: scale, y: scale)
            (layer.presentation() ?? layer).render(in: context)
            guard let cgImage = context.makeImage() else { return nil }
            return NSImage(cgImage: cgImage, size: size)
        }

        /// Logs every item of the main menu's `<title>` menu — title, shortcut, enabled — after
        /// `update()`, which runs the same validation opening it would. A script cannot open a
        /// menu (a posted click on the menu bar does not reach it), so this is how a check
        /// reads which commands exist, what they are bound to and which are live right now.
        private static func dumpMenu(titled title: String) {
            guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == title })?.submenu
            else {
                log("menu: no \"\(title)\" menu")
                return
            }
            // SwiftUI refreshes a command menu's items when it is about to open, through the
            // delegate; `update()` alone reads whatever was there when the app launched.
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            for item in menu.items {
                if item.isSeparatorItem {
                    log("menu \(title): ---")
                    continue
                }
                let mask = item.keyEquivalentModifierMask
                let shortcut =
                    (mask.contains(.control) ? "⌃" : "") + (mask.contains(.option) ? "⌥" : "")
                    + (mask.contains(.shift) ? "⇧" : "") + (mask.contains(.command) ? "⌘" : "")
                    + item.keyEquivalent.uppercased()
                log("menu \(title): \(item.title) [\(shortcut)] enabled=\(item.isEnabled)")
            }
        }

        private static func mergeMode(_ name: String?) -> MergeMode? {
            switch name {
            case "ff": .fastForwardIfPossible
            case "noff": .alwaysMergeCommit
            case "squash": .squash
            default: nil
            }
        }

        // MARK: - Reporting

        /// Every field a shell might want to assert on, including the ones that make a
        /// confirmation meaningful (the unmerged count and tip, the stranded-commit count).
        private static func describe(_ sheet: BranchSheet?, _ store: RepositoryStore) -> String {
            switch sheet {
            case nil: "nil"
            case .newBranch(let startPoint, let label):
                "newBranch(startPoint: \(startPoint ?? "HEAD"), label: \(label))"
            case .rename(let name): "rename(\(name))"
            case .merge(let name): "merge(\(name))"
            case .deleteUnmerged(let name, let count, let tip):
                "deleteUnmerged(\(name), uniqueCommits: \(count), tip: \(tip.prefix(7)))"
            // The files matter more than the operation's name: they are what the sheet promises
            // to list, and what a rebase takes and the other five keep differs between them.
            case .abort(let operation):
                "abort(\(operation), reverts: \(store.filesRevertedByAbort.map(\.path)), "
                    + "unstagedToo: \(store.abortAlsoDiscardsUnstagedEdits), "
                    + "rewinds: \(store.abortRewindsCommits))"
            case .leaveDetached(let count, let sha, let action):
                "leaveDetached(unreferencedCommits: \(count), head: \(sha.prefix(7)), "
                    + "then: \(action))"
            case .pullDiverged(let ahead, let behind, let upstream):
                "pullDiverged(ahead: \(ahead), behind: \(behind), upstream: \(upstream))"
            case .publish(let branch): "publish(\(branch))"
            // Shas in full: they are the leases, and the shell compares them with git's.
            case .forcePush(
                let branch, let localTip, let remote, let remoteRef, let tip, let discarded,
                let total):
                "forcePush(\(branch) -> \(remote) \(remoteRef), localTip: \(localTip), "
                    + "remoteTip: \(tip), total: \(total), "
                    + "discarded: \(discarded.map { "\($0.sha.prefix(7)) \($0.summary) <\($0.authorName)>" }))"
            case .deleteRemoteBranch(let remote, let branch, let tip, let onlyThere):
                "deleteRemoteBranch(\(remote) \(branch), tip: \(tip), onlyThere: \(onlyThere))"
            }
        }

        private static func log(_ message: String) {
            FileHandle.standardError.write(Data("BRANCH_ACTION \(message)\n".utf8))
        }
    }

#endif
