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
    ///     autofetchfailed:<reason>     copyurls
    ///     quit                         alert               alertbutton:<title>
    ///     quitevent                    alertsnapshot:<name>         activate
    ///     menuitem:<menu>:<title>      panelsnapshot:<name>
    ///     notice                       openlink
    ///     newwindow:<path>             inwindow:<n>                 closewindow
    ///
    ///   The stash (`RepositoryStore+Stash`, `DebugLaunchHooks+Stash`):
    ///
    ///     stash:<msg>[:u]              stashpaths:<p,p>:<msg>
    ///     apply:<n>                    pop:<n>
    ///     dropstash:<n>                confirmdropstash
    ///     stashes                      selectstash:<n>[:<path>]     sheet:stash
    ///     noticepop                    stashcontinue[:merge|:rebase]
    ///
    ///   Discard (`RepositoryStore+Discard`, `DebugLaunchHooks+Discard`):
    ///
    ///     discard:<path>               discardstaged:<path>         discardall
    ///     discardhunk:<n>              confirmdiscard               undodiscard
    ///     discardstale
    ///
    ///   The resolver (`RepositoryStore+Conflicts`, `DebugLaunchHooks+Conflicts`):
    ///
    ///     select:<path>                blocks:<path>:<O|T|B|b…>     resolve
    ///     take:ours|theirs:<path>      deletefile:<path>            keep:<path>
    ///     confirmreplace               markresolved:<path>          confirmmarkers
    ///     reopen:<path>                confirmreopen                resolver
    ///     noticeshow                   cancelsheet
    ///
    ///   The operation bar and the composer (`RepositoryStore+Continue`,
    ///   `DebugLaunchHooks+Continue`):
    ///
    ///     bar                          message:<text>               continue
    ///     confirmempty                 confirmothers                skip
    ///     confirmskip                  stageall                     confirmstageall
    ///     commitdraft                  usemessage                   keepmessage
    ///
    ///   The history actions (`RepositoryStore+History`, `DebugLaunchHooks+History`):
    ///
    ///     selectcommits:<rev,…>        historymenu                  pick
    ///     revert                       rebaseonto:<rev>             confirmhistory
    ///     confirmrebase
    ///
    ///   Tags (`RepositoryStore+Tags`, `DebugLaunchHooks+History`):
    ///
    ///     newtag:<name>:<rev>[:<msg>]  deletetag:<name>             confirmdeletetag
    ///     restoretag[:<name>]          pushtag:<name>:<remote>      deleteremotetag:<name>:<remote>
    ///     confirmdeleteremotetag       tags
    ///
    ///   Remotes housekeeping (`RepositoryStore+RemoteAdmin`, `DebugLaunchHooks+RemoteAdmin`):
    ///
    ///     prune:<remote>               confirmprune[:none|:<ref>=<name>,…]
    ///     cleanup                      confirmcleanup[:<b,…>]       pushbranch:<b>
    ///     confirmpublish:<remote>      ffbranch:<b>                 upstream:<b>
    ///     setupstream:<b>:<ref>
    ///     unsetupstream:<b>            adminmenu
    ///     prefill:<key>=<value>|clear  addremote                    confirmaddremote:<n>=<url>[=nofetch]
    ///     editurl:<remote>             confirmediturl[:<key>=<value>|…]
    ///     renameremote:<remote>        confirmrenameremote:<new>
    ///     removeremote:<remote>        confirmremoveremote[:none|:<ref>=<name>,…]
    ///
    ///   Navigation (`SidebarFilter`, `RepositoryStore+Worktrees`, `DebugLaunchHooks+Navigation`):
    ///
    ///     filter:<text>                sidebar                      worktrees
    ///     worktreemenu                 openworktree:<folder>        pills
    ///     watchloads:<seconds>         firstresponder               reloadtiming
    ///     comparewith:<ref>            compare:<a>:<b>              comparesheet[:<a>[:<b>]]
    ///     comparefilter:<text>         confirmcompare:<a>:<b>       comparestate
    ///     compareselect:<id|changes>   comparepath:<path>           compareswap
    ///     comparerefresh               comparedone                  comparemenu
    ///     comparecopy:<id>             sidebarclick:<branch>        reload
    ///     loadolder                    reveal:<branch|tag|id>
    ///     addworktree[:<b>]            folderproblem:<path>         confirmaddworktree:<kind>:…:<path>
    ///     removeworktree:<folder>      removeworktreestart:<folder> removeallmissing
    ///     worktreesheet                confirmremoveworktree[:none|:<name>]  noticeopen
    ///
    ///   The window's layout (`DebugLaunchHooks+Layout`):
    ///
    ///     split                        togglesidebar                resize:<w>x<h>
    ///     divider:<x>                  sidebarwidth:<x>
    ///
    ///   The target window's sheet, through its own controls (`HarnessControls`,
    ///   `DebugLaunchHooks+Controls`; the value is split from the label at the first `=`):
    ///
    ///     controls                     press:<label>                tick:<label>[=on|off]
    ///     fill:<label>=<text>          choose:<label>=<option>
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
    /// `copyurls` takes every configured remote's "Copy …" items (`RemoteMenu.copyItems`, what
    /// the menu draws), copies each through `Clipboard.copy` — the menu's own call — onto a
    /// private named pasteboard rather than the general one, reads it back and logs
    /// `copy <remote> "<title>": <raw address> -> <pasteboard>`. The raw address is printed so
    /// the redaction can be checked against it; point this only at scratch remotes.
    ///
    /// `quit` asks the app to quit the way Quit Gitter (⌘Q) does, through `QuitFlow`: every sheet
    /// is closed, and once none is attached the terminate is performed from the run loop
    /// (`perform(_:with:afterDelay: 0)`) — not from a main-queue block, where a held quit would
    /// starve every MainActor job — so that the steps after it still run while `QuitGuard` holds
    /// the quit (`.terminateLater`): `start:push;wait:1;quit;wait:1;alert;alertbutton:Wait`. With
    /// a quit already under way it is ignored, and says so (`QUIT … ignored`). `quitevent` quits the
    /// way the Dock, a logout or a shutdown does: it sends the quit Apple Event to the app's own
    /// Apple Event Mach port from a background thread and logs the reply it gets back,
    /// `quit event reply: <keyErrorNumber>` — −128 once a quit is called off, 0 when it goes ahead —
    /// or `quit event send failed: <error>` (`DebugLaunchHooks+Quit`); the steps after it go on
    /// without waiting for the reply: `start:push;wait:1;quitevent;wait:1;alert;alertbutton:Don't
    /// Quit`. A step the launch guard refuses ends the script and quits the way `quit` does.
    /// `alertbutton:<title>` clicks that button of an alert on screen (`performClick`, the
    /// button's own action — the alert's completion handler runs as it would for a pointer).
    /// `menuitem:<menu>:<title>` fires a main menu item through `NSMenu.performActionForItem(at:)`,
    /// which is what choosing it does —
    /// how "Fetch Automatically" is toggled — and `menu:<title>` then shows its state, and which
    /// window's store the menus act on (the front one's, `menu <title>: front window: …`). Both
    /// make the app frontmost first when none of its windows is key (`bringToFront`). None of
    /// the three waits for a step's work to finish, nor does `quitevent`. `alert` logs every text
    /// and button (with its key equivalent) of each sheet on screen, and of the app-modal alert
    /// if one is up (`app-modal …`, `ModalAlert`'s): the snapshot draws an alert's frame and its
    /// tinted buttons but not its text, which is drawn with vibrancy (the sidebar's problem,
    /// below). `alertbutton:` looks in the app-modal alert first. `alertsnapshot:<name>` draws
    /// the app-modal alert's own window (`cacheDisplay`, which draws an alert's text) into the
    /// snapshot folder, as `snapshot:` renders the target's (E3 Task 5). For the app-modal alert,
    /// `alert` also logs how it is presented — whether the app is active, the panel key, and its
    /// default button cell — and the hidden ending's alert logs its buttons' key equivalents as it
    /// is built (`alert built: …`). `activate` makes Gitter the active app (`NSApp.activate()`), as
    /// a click on it would, and logs whether it is and which window is key (final review M1).
    ///
    /// `notice` logs both notice slots — each one's text, links and button titles:
    /// `notice transient: <…> | links: [...] | actions: [...]` and the same for `sticky`.
    /// `openlink` runs the sticky notice's Open button through `RepositoryStore.perform` with an
    /// opener that only logs `openlink: <url>` — the harness never starts a browser — and a
    /// private pasteboard; with no Open on screen it logs `openlink: no link`.
    ///
    /// `stashcontinue` is the error banner's Stash and Continue (`RepositoryStore
    /// .stashAndContinue`): with nothing offered it logs `stashcontinue: not offered` and does
    /// nothing. It waits for the stash **and** the retry it starts. `:merge` / `:rebase` then
    /// answer the pull sheet a retried pull may end in, like `pull:<mode>`. The `lane` line
    /// carries `stashContinue: <message> -u:<bool> blocked: <reason>` or `nil`.
    ///
    /// The automatic fetch prints its own lines, `AUTOFETCH …`, one per tick and one per ending;
    /// `QUIT …` lines say what quitting decided.
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

        /// Runs the steps in order, each on the target window's store (`target`, `inwindow:`).
        /// False when the launch guard refused a step: the rest were not run, and the app is
        /// quitting (`QuitFlow`, reason `.launchRefusal`).
        @discardableResult
        static func runBranchActions(_ spec: String) async -> Bool {
            for step in spec.split(separator: ";") {
                let text = String(step)
                let started = text.hasPrefix("start:")
                let command = started ? String(text.dropFirst("start:".count)) : text
                // An `open:` step, or a failed reload, can leave another repository on screen; a
                // `newwindow:` or `inwindow:` the launcher did not provide for is refused too.
                guard let acting = target else { return refuse("refused: no target window", step: step) }
                if let refusal = guardRefusal(acting) ?? windowStepRefusal(command) {
                    return refuse(refusal, step: step)
                }
                // The worktree state is read after a snapshot lands, in its own task (B3 final
                // review, I2): a step acts on, and logs, the state that snapshot's read gives.
                _ = await wait({ !acting.isReadingWorktreeState }, seconds: 60, what: "step \(step): the worktree state read")
                log("step: \(step)")
                // An automatic fetch does not count: the user's network actions stop it and go
                // ahead (`beginRemote`), so a step taken during one waits for its own lane.
                let laneWasBusy = acting.blockingRemoteActivity != nil
                await perform(command, store: acting)
                // The wait and the result line are the target's — the new one after `inwindow:`.
                let store = target ?? acting
                // `mutate` and the lane are both claimed synchronously, so by now `isMutating` or
                // `remoteActivity` is already set for anything that runs git; a step that only
                // opens a sheet sets neither and this returns at once.
                if started || text.hasPrefix("wait:") || text == "quit" || text == "quitevent"
                    || text == "alert" || text.hasPrefix("alertbutton:") || text.hasPrefix("menuitem:")
                    || text == "closewindow" || text == "activate"
                {
                    // Nothing to wait for: the point is to carry on while it runs.
                } else if laneWasBusy && text != "cancel" && text != "idle" {
                    _ = await wait({ !store.isMutating }, what: "step \(step): the mutation, the lane being busy")
                } else {
                    // The lane as the user's actions see it (S11): an automatic fetch blocks
                    // nothing, so a step does not wait out one that started meanwhile.
                    _ = await wait(
                        { store.blockingRemoteActivity == nil && !store.isMutating }, seconds: 120,
                        what: "step \(step): the lane and the mutation to finish")
                }
                logResult(store)
            }
            return true
        }

        /// Logs a launch-guard refusal of `step` and quits (`.launchRefusal`); false, for the loop.
        private static func refuse(_ refusal: String, step: Substring) -> Bool {
            log("launch guard: \(refusal); step \(step) and the rest not run")
            QuitFlow.request(.launchRefusal)
            return false
        }

        private static func logResult(_ store: RepositoryStore) {
            let lane = store.remoteActivity.map {
                "\($0.kind)(\($0.remote ?? "all"), progress: \($0.progress ?? "nil"))"
            }
            log(
                "result: \(describe(store.activeSheet, store)) | notice: \(flat(store.notice?.text)) "
                    + "| error: \(flat(store.lastError)) "
                    + "| head: \(store.headLabel) | selection: \(store.selection)")
            log(
                "lane: \(lane ?? "nil") | forcePushOffered: \(store.bannerOffersForcePush) "
                    + "| stashContinue: \(describeStashContinue(store)) "
                    + "| reasons: fetch=\(store.fetchBlockedReason ?? "nil"); "
                    + "pull=\(store.pullBlockedReason ?? "nil"); "
                    + "push=\(store.pushBlockedReason ?? "nil") "
                    + "| pushTitle: \(store.pushButtonTitle) | tracking: \(store.currentTracking) "
                    + "| pushCount: \(store.pushAheadCount.map(String.init) ?? "nil") "
                    + "| pullCount: \(store.pullBehindCount.map(String.init) ?? "nil") "
                    + "| pushHelp: \(store.pushHelp) "
                    + "| pullMode: \(store.rememberedPullMode.rawValue) "
                    + "| loads: \(store.snapshotLoadCount) "
                    + "| autoFetch: \(store.autoFetchScheduler.isEnabled ? "on" : "off"), "
                    + "failure: \(store.lastAutoFetchFailure ?? "nil") "
                    + "| stores: \(RepositoryStore.storesBuilt), registered: \(RepositoryStore.storesRegistered)")
        }

        private static func describeStashContinue(_ store: RepositoryStore) -> String {
            guard let offer = store.offeredStashAndContinue else { return "nil" }
            return "\(offer.message) -u:\(offer.includeUntracked) "
                + "blocked: \(store.stashAndContinueBlockedReason ?? "nil")"
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
                    _ = await wait({ !store.isMutating }, what: "forcedelete \(first): the delete")
                    // Reached for unconditionally, on purpose: the store's own guard is the only
                    // thing that may stop it. For a branch `-d` deleted cleanly no warning was
                    // ever shown, and a `confirmForceDelete` that ran anyway would be visible —
                    // it would put "There is no branch named …" in the banner.
                    store.confirmForceDelete(first)
                    _ = await wait({ !store.isMutating }, what: "forcedelete \(first): the confirmed delete")
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
                        { store.remoteActivity == nil && !store.isMutating }, seconds: 120, what: "pull:\(mode.rawValue): the pull before its sheet")
                    store.confirmPull(mode)
                }
            case "push": store.push()
            case "publish":
                store.push()
                _ = await wait({ store.remoteActivity == nil && !store.isMutating }, seconds: 120, what: "publish: the push before its sheet")
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
                first.map { snapshot(named: $0, store: store) }
            case "alertsnapshot":
                // The app-modal alert's own window, nothing else on screen (E3 Task 5).
                try? await Task.sleep(for: .milliseconds(300))
                if let first, let modal = NSApp.modalWindow {
                    write(cachedImage(of: modal), named: first)
                } else {
                    log("snapshot failed: \(first ?? "") (no app-modal alert)")
                }
            case "panelsnapshot":
                // A panel of its own that is neither a sheet nor an app-modal alert — the About
                // panel, after `menuitem:Gitter:About Gitter` (P1 Task 2) — its words read off the
                // panel, then its own window, nothing else on screen.
                try? await Task.sleep(for: .milliseconds(300))
                let panel = NSApp.windows.first {
                    $0 is NSPanel && $0.isVisible && $0.sheetParent == nil && $0 !== NSApp.modalWindow
                }
                if let first, let panel {
                    logControls(in: panel.contentView, window: "panel \(type(of: panel))")
                    write(cachedImage(of: panel), named: first)
                } else {
                    log("snapshot failed: \(first ?? "") (no panel)")
                }
            // "Open Repository…" mid-script, e.g. while a push is on the lane. The path is the
            // rest of the step, colons and all. Once this window shows another repository, the
            // launch guard refuses every step after this one, unless that repository is one
            // GITTER_DEBUG_ALSO_OPEN lists (the guard then accepts it as a window's own).
            case "open":
                let path = step.dropFirst("open:".count)
                if !path.isEmpty { store.open(URL(fileURLWithPath: String(path))) }
            case "autofetchfailed":
                store.debugSetLastAutoFetchFailure(String(step.dropFirst("autofetchfailed:".count)))
            case "menu": if let first { await dumpMenu(titled: first) }
            case "views": dumpViews(matching: first, store: store)
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
            case "copyurls": copyURLs(store: store)
            case "quit":
                // The app's one quit path, as Quit Gitter takes it: it closes every sheet, waits
                // until none is attached — AppKit refuses a quit while one is (M1.4) — and then
                // terminates from the run loop (`QuitFlow.Environment.live`).
                QuitFlow.request(.harness)
            case "quitevent": sendQuitEvent()
            case "alert":
                for window in NSApp.windows where window.sheetParent != nil && window.isVisible {
                    logControls(in: window.contentView, window: "\(type(of: window))")
                }
                // An app-modal alert (`ModalAlert`): a window of its own, no sheet's parent.
                if let modal = NSApp.modalWindow, modal.sheetParent == nil {
                    logControls(in: modal.contentView, window: "app-modal \(type(of: modal))")
                    // How it is presented (final review M1): AppKit draws and honours a default
                    // button only in a key window.
                    log(
                        "alert app-modal \(type(of: modal)) state: app active: \(NSApp.isActive) | panel key: "
                            + "\(modal.isKeyWindow) | default button cell: \(modal.defaultButtonCell?.title ?? "none") "
                            + "| key window: \(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "none")")
                }
            case "activate":
                // Makes Gitter the active app, as a click on it would (final review M1's proof).
                NSApp.activate()
                try? await Task.sleep(for: .milliseconds(500))
                log(
                    "activate: app active: \(NSApp.isActive) | key window: "
                        + "\(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "none")")
            case "alertbutton":
                let title = String(step.dropFirst("alertbutton:".count))
                // The app-modal alert's first: a hidden repository window may draw a button of
                // the same title (a sheet's Close), and it comes earlier in `NSApp.windows`.
                let windows = [NSApp.modalWindow].compactMap { $0 } + NSApp.windows
                let button = windows.lazy.compactMap { findButton(title, in: $0.contentView) }
                    .first
                if let button {
                    button.performClick(nil)
                } else {
                    log("alertbutton: no button \"\(title)\" on screen")
                }
            case "menuitem":
                if let first, let second { await fireMenuItem(second, inMenu: first) }
            case "notice":
                log("notice transient: \(describe(store.notice))")
                log("notice sticky: \(describe(store.stickyNotice))")
            case "openlink": openLink(store: store)
            case "stash", "stashpaths", "apply", "pop", "dropstash", "confirmdropstash", "stashes",
                "selectstash", "noticepop":
                await stashStep(command, step: step, store: store)
            case "discard", "discardstaged", "discardall", "discardhunk", "confirmdiscard", "undodiscard",
                "discardstale":
                await discardStep(command, step: step, store: store)
            case let conflict where conflictCommands.contains(conflict):
                await conflictStep(command, step: step, store: store)
            case let bar where continueCommands.contains(bar):
                await continueStep(command, step: step, store: store)
            case let history where historyCommands.contains(history):
                await historyStep(command, step: step, store: store)
            case let admin where remoteAdminCommands.contains(admin):
                await remoteAdminStep(command, step: step, store: store)
            case let navigation where navigationCommands.contains(navigation):
                await navigationStep(command, step: step, store: store)
            case let control where controlCommands.contains(control):
                await controlStep(command, step: step, store: store)
            case let layout where layoutCommands.contains(layout):
                await layoutStep(command, rest: String(step.dropFirst(command.count + 1)), store: store)
            case "stashcontinue":
                guard store.offeredStashAndContinue != nil else {
                    log("stashcontinue: not offered")
                    return
                }
                store.stashAndContinue()
                // The stash, then the retry it starts in the same main-actor run: the slot is
                // claimed again before the wait below can see it free (a retried pull runs no
                // fetch, so it never takes the lane).
                _ = await wait({ store.remoteActivity == nil && !store.isMutating }, seconds: 120, what: "stashcontinue: the stash and its retry")
                if let mode = first.flatMap(PullMode.init(rawValue:)) {
                    // Does nothing without its sheet on screen.
                    store.confirmPull(mode)
                }
            case "commit":
                // The composer's own path: the subject goes into the draft, then `commit()`.
                store.draft.subject = first ?? "commit"
                store.commit()
            default: log("unknown step: \(step)")
            }
        }

        /// The hidden ending's alert as `HiddenWindowEnvironment.live` built it, before it is raised:
        /// each button's key equivalent then, whether the app is active, and the Dock attention
        /// request made for an inactive app (its number; `none` when active) (final review M1).
        static func logAlertBuilt(_ alert: NSAlert, attention: Int?) {
            let buttons = alert.buttons.map { button in
                let key = button.keyEquivalent
                    .replacingOccurrences(of: "\r", with: "Return")
                    .replacingOccurrences(of: "\u{1b}", with: "Escape")
                return "\(button.title) [key: \(key.isEmpty ? "none" : key)]"
            }
            log(
                "alert built: \(alert.messageText) | buttons: \(buttons.joined(separator: ", ")) "
                    + "| app active: \(NSApp.isActive) | attention request: \(attention.map(String.init) ?? "none")")
        }

        private static func logControls(in view: NSView?, window: String) {
            guard let view else { return }
            if let button = view as? NSButton, !button.title.isEmpty {
                let key = button.keyEquivalent
                    .replacingOccurrences(of: "\r", with: "Return")
                    .replacingOccurrences(of: "\u{1b}", with: "Escape")
                log("alert \(window) button: \(button.title) [key: \(key.isEmpty ? "none" : key)]")
            } else if let text = view as? NSTextField, !text.stringValue.isEmpty {
                log("alert \(window) text: \(text.stringValue)")
            }
            for child in view.subviews { logControls(in: child, window: window) }
        }

        private static func findButton(_ title: String, in view: NSView?) -> NSButton? {
            guard let view else { return nil }
            if let button = view as? NSButton, button.title == title { return button }
            for child in view.subviews {
                if let found = findButton(title, in: child) { return found }
            }
            return nil
        }

        private static func fireMenuItem(_ title: String, inMenu menuTitle: String) async {
            guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == menuTitle })?.submenu
            else {
                log("menuitem: no \"\(menuTitle)\" menu")
                return
            }
            await bringToFront()
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
                log("menuitem: no \"\(title)\" in \"\(menuTitle)\"")
                return
            }
            menu.performActionForItem(at: index)
        }

        private static func copyURLs(store: RepositoryStore) {
            let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.debug-copyurls"))
            defer { pasteboard.releaseGlobally() }
            for remote in store.snapshot?.refs.remotes ?? [] {
                for item in RemoteMenu.copyItems(for: remote) {
                    let raw =
                        item.title == RemoteWording.copyPushURLTitle
                        ? remote.pushURL : remote.fetchURL
                    guard let text = item.text else {
                        log("copy \(remote.name) \"\(item.title)\": (disabled)")
                        continue
                    }
                    Clipboard.copy(text, to: pasteboard)
                    let back = pasteboard.string(forType: .string) ?? "(empty)"
                    log("copy \(remote.name) \"\(item.title)\": \(raw ?? "nil") -> \(back)")
                }
            }
        }

        private static func describe(_ notice: Notice?) -> String {
            guard let notice else { return "nil" }
            return "\(flat(notice.text)) | links: \(notice.links.map(\.absoluteString)) "
                + "| actions: \(notice.actions.map(NoticeWording.title)) | tone: \(notice.tone) | keep: \(notice.keep)"
        }

        /// The sticky banner's Open, as its button runs it, except that the opener only logs.
        private static func openLink(store: RepositoryStore) {
            let open = store.stickyNotice?.actions.first {
                if case .openLink = $0 { true } else { false }
            }
            guard let open else {
                log("openlink: no link")
                return
            }
            let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.debug-openlink"))
            defer { pasteboard.releaseGlobally() }
            var opened = false
            store.perform(open, pasteboard: pasteboard) { url in
                opened = true
                log("openlink: \(url.absoluteString)")
            }
            if !opened { log("openlink: refused") }
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
                _ = await wait({ store.activeSheet != nil }, what: "sheet:delete: its sheet")
            case "abort": store.requestAbort()
            // From the tracking on screen, with no fetch and no merge: this step opens a sheet.
            case "pull": store.previewPullSheet()
            case "stash": store.requestStash()
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
        private static func snapshot(named name: String, store: RepositoryStore) {
            guard ProcessInfo.processInfo.environment["GITTER_DEBUG_SNAPSHOT_DIR"] != nil,
                let window = window(of: store),
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
            write(composed, named: name)
        }

        /// `image` as `<GITTER_DEBUG_SNAPSHOT_DIR>/<name>.png`, logged.
        private static func write(_ image: NSImage?, named name: String) {
            guard let dir = ProcessInfo.processInfo.environment["GITTER_DEBUG_SNAPSHOT_DIR"], let composed = image
            else {
                log("snapshot failed: \(name)")
                return
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
        private static func dumpViews(matching filter: String?, store: RepositoryStore) {
            guard let window = window(of: store),
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

        /// An AppKit-only window (an `NSAlert`'s panel) drawn through `cacheDisplay`, which draws
        /// its text and buttons — the layer render (`image(of:)`) leaves out what is drawn with
        /// vibrancy, which in an alert is all of it but the icon (measured, E3 Task 5).
        private static func cachedImage(of window: NSWindow) -> NSImage? {
            guard let view = window.contentView?.superview ?? window.contentView,
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(rep)
            return image
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
        private static func dumpMenu(titled title: String) async {
            guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == title })?.submenu
            else {
                log("menu: no \"\(title)\" menu")
                return
            }
            await bringToFront()
            // The menus act on the front window's store (`@FocusedValue`), not on the target.
            let front = AppModel.windows.store(of: NSApp.keyWindow)
            log(
                "menu \(title): front window: "
                    + (front.map { "store \($0.debugSerial) \($0.root?.lastPathComponent ?? "(empty)")" } ?? "none")
                    + (front?.activeSheet != nil ? ", sheet up" : ""))
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
                let state = item.state == .on ? " state=on" : ""
                log("menu \(title): \(item.title) [\(shortcut)] enabled=\(item.isEnabled)\(state)")
            }
        }

        /// Makes the app frontmost when no window of it is key, and waits for one to be. The menus
        /// act on the front window's store (`@FocusedValue`, E2 Task 4), and an app launched from a
        /// shell is never frontmost — no window is key, so every repository item would read off.
        /// The click hooks do the same (`runEvents`). The window made key is AppKit's choice: the
        /// one last made key, which `newwindow:` and a fronted window change.
        private static func bringToFront() async {
            guard NSApp.keyWindow == nil else { return }
            NSApp.activate()
            _ = await wait({ NSApp.keyWindow != nil }, seconds: 5, what: "a key window, for the menus")
            // The commands are re-read on the key window's change (M3.3): one turn for that.
            try? await Task.sleep(for: .milliseconds(200))
        }

        /// The commits in full: the shell compares them with `git rev-list sequencer/head..HEAD`.
        private static func describe(_ rewind: AbortRewind) -> String {
            switch rewind {
            case .none: "none"
            case .patches: "patches"
            case .unknown: "unknown"
            case .commits(let made): "commits(\(made.map { "\($0.sha) \($0.subject)" }))"
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
                    + "rewinds: \(describe(store.abortRewind)), "
                    + "history: \(operation.abortHistory(store.abortRewind)))"
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
            case .stash(let paths): "stash(selectedPaths: \(paths))"
            // The full sha and the position: what the confirm hands to GitCore's verified drop.
            case .dropStash(let stash):
                "dropStash(stash@{\(stash.index)} \(stash.sha) \"\(stash.message)\")"
            // What the sheet asks and names: the requests GitCore gets, each row's loss, where
            // the copy goes, and the destructive button's title.
            case .discard(let model):
                "discard(\(model.requests.map(describe)), title: \(model.title), "
                    + "rows: \(model.rows.map { "\($0.name): \($0.loses)\($0.preview.isEmpty ? "" : " \($0.preview)")" }), "
                    + "destination: \(model.destination), button: \(model.confirmTitle))"
            case .replaceHandEdited, .markResolved, .reopen:
                describeConflictSheet(sheet) ?? "?"
            case .continueEmpty, .continueOthers, .skip, .stageAll:
                describeContinueSheet(sheet) ?? "?"
            case .historyAction, .rebaseOnto:
                describeHistorySheet(sheet) ?? "?"
            case .newTag, .deleteTag, .deleteRemoteTag:
                describeTagSheet(sheet, store) ?? "?"
            case .prune, .cleanUpGone, .upstream, .addRemote, .editRemoteURL, .renameRemote, .removeRemote:
                describeRemoteAdminSheet(sheet) ?? "?"
            case .compareBranches(let a, let b):
                "compareBranches(a: \(a ?? "nil"), b: \(b ?? "nil"))"
            case .addWorktree, .checkingWorktreeRemoval, .removeWorktree, .removeMissingWorktrees:
                describeWorktreeSheet(sheet) ?? "?"
            }
        }

        // internal (not private): used by DebugLaunchHooks+Stash.swift
        static func log(_ message: String) {
            FileHandle.standardError.write(Data("BRANCH_ACTION \(message)\n".utf8))
        }
    }

#endif
