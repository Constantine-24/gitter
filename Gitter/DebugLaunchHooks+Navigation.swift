#if DEBUG

    import AppKit
    import Foundation
    import GitCore

    /// B3 Task 3's steps of `GITTER_DEBUG_BRANCH_ACTION` (see `DebugLaunchHooks+Branches` for the
    /// grammar and the waiting). The sidebar cannot be snapshotted (it is drawn with vibrancy, as
    /// B2 found), so what it shows is logged from the same functions its rows call:
    ///
    ///   filter:<text>          the sidebar filter's text, as typing it would set it (`filter:`
    ///                          empties it), then the `sidebar` lines.
    ///   sidebar                every section the sidebar draws with its rows after the filter —
    ///                          each remote group with whether it is expanded, "No matches" — and
    ///                          the count VoiceOver announces.
    ///   worktrees              every worktree row: folder, branch line, each mark's text and
    ///                          tooltip, the changes read; this window's path, whether it is a
    ///                          linked worktree, the main folder, the store's title and the
    ///                          window's own.
    ///   worktreemenu           each worktree's menu items with the reasons the disabled ones
    ///                          show, and every local branch's held icon and its Switch, Delete and
    ///                          Fast-Forward with their reasons.
    ///   openworktree:<folder>  Open Worktree on the row with that folder name (or that path) —
    ///                          or, when another window shows it, `shown already, fronted: …` —
    ///                          then — once its first snapshot is in — the root, the titles, Open
    ///                          Recent's first entry and `lastRepositoryPath`. The launch guard
    ///                          refuses every step after it: another repository is open.
    ///   pills                  every commit row's "worktree:" pills with their tooltips.
    ///   watchloads:<seconds>   for that long, one line per finished snapshot load: the count,
    ///                          HEAD, the files and the staged ones, the stashes and every local
    ///                          branch's tip — what a terminal's change in a linked worktree made
    ///                          the app show (RF5).
    ///   firstresponder         the class of the key window's first responder (after ⌘F, through
    ///                          `menuitem:Edit:Filter Sidebar`).
    ///   reloadtiming           a snapshot load, timed (B3 final review, I2): when `refresh()`
    ///                          returned with the snapshot written, whether the worktree state was
    ///                          then still the one before, and when its own read landed.
    ///
    /// B3 Task 4's compare steps. Each waits for the comparison's read and the detail it selects
    /// (files, then the diff of a selected file) before it logs, since none of them claims the
    /// mutation slot the step list waits for:
    ///
    ///   comparewith:<full ref>     the branch menu's "Compare with "<current>"" on that branch,
    ///                              then the `comparestate` lines.
    ///   compare:<ref A>:<ref B>    `compare` with two full refs, then `comparestate`.
    ///   comparesheet[:<a>[:<b>]]   Compare Branches… (the Repository menu's when bare), then its
    ///                              presets and every picker option with a filter `cafe`-style
    ///                              query applied by `comparefilter:<text>`.
    ///   confirmcompare:<a>:<b>     the sheet's Compare with those two refs (`confirmCompareBranches`).
    ///   comparestate               the bar (title, help, the moved line, which of Swap, Refresh
    ///                              and Done it shows), the changes row, each group with its count,
    ///                              listed ids and "…not listed" line, the header's lines, the
    ///                              selection, the files and the diff's files.
    ///   compareselect:<id|changes> a commit of the comparison (or the changes row), as a click.
    ///   comparepath:<path>         a file of the changes, then the diff's files and hunks.
    ///   compareswap / comparerefresh / comparedone
    ///                              Swap, Refresh and Done, then `comparestate`.
    ///   comparemenu                every local and remote branch's two compare items with the
    ///                              reasons their menus show, and Compare Branches…'s reason.
    ///   comparecopy:<id>           Copy Commit ID onto a private pasteboard, read back.
    ///   sidebarclick:<branch>      a sidebar branch row's click (`selectFromSidebar`).
    ///   reload                     a snapshot load (what the watcher would start), then
    ///                              `comparestate`.
    ///
    /// B3 Task 5's worktree sheets. The harness cannot type into or click inside a sheet, so the
    /// confirms are driven through the store's own `confirm…`, which refuses without its sheet on
    /// screen — each step opens the sheet first, as a user does:
    ///
    ///   addworktree[:<branch>]       Add Worktree… (preset to that local branch), then what the
    ///                                sheet offers: the free branches, start points, remote
    ///                                branches, the default folder and its live check.
    ///   folderproblem:<path>         the folder field's live check for that text.
    ///   confirmaddworktree:existing:<b>:<path> | :new:<name>:<start>:<path> |
    ///     :tracking:<name>:<remote ref>:<path>
    ///                                the sheet's Add with that choice (<start>: a full ref or a
    ///                                full id; the path is the rest, colons and all), then the
    ///                                notice or banner and the worktree list.
    ///   removeworktree:<folder|path> Remove Worktree… on that row: the check, then the sheet's
    ///                                every line — or the banner.
    ///   removeworktreestart:<folder|path>  the same, without waiting for the check: the progress
    ///                                state is on screen for a snapshot.
    ///   removeallmissing             Remove All Missing…: the checks, then the sheet's lines.
    ///   worktreesheet                the worktree sheet on screen, as it is now.
    ///   confirmremoveworktree[:none|:<name>]  the Remove sheet's button with the keep boxes as
    ///                                they start (every holder ticked, the suggested names), none
    ///                                ticked, or the one holder kept as <name>; then the notice or
    ///                                banner and the worktree list. Also answers Remove All
    ///                                Missing… (default or `none`).
    ///   noticeopen                   the sticky notice's Open (`openWorktree`), then the root and
    ///                                the titles. The launch guard refuses every step after it.
    ///
    /// E2 Task 4's windows. Every step acts on the **target** store (`target`), which starts as
    /// the first window's; its guard is checked against the fixture and `GITTER_DEBUG_ALSO_OPEN`:
    ///
    ///   newwindow:<path>             opens `<path>` as Open Recent or a Finder open does
    ///                                (`WindowRegistry.open`, `.recentOrFinder`, no front window):
    ///                                a window of its own, or the one showing it brought to the
    ///                                front; then waits for its first snapshot and lists every
    ///                                registered store. Refused, and the app quits, unless `<path>`
    ///                                is one of `GITTER_DEBUG_ALSO_OPEN`'s. The target stays.
    ///   inwindow:<n>                 makes the n-th registered store (1-based, in the order made)
    ///                                the target. Refused, and the app quits, for no such store.
    ///                                The menus still act on the front window (`menu:` says which).
    extension DebugLaunchHooks {

        static let navigationCommands: Set<String> = Set([
            "filter", "sidebar", "worktrees", "worktreemenu", "openworktree", "pills", "watchloads", "firstresponder",
            "reloadtiming", "newwindow", "inwindow",
        ]).union(compareCommands).union(worktreeSheetCommands)

        private static let worktreeSheetCommands: Set<String> = [
            "addworktree", "folderproblem", "confirmaddworktree", "removeworktree", "removeworktreestart",
            "removeallmissing", "worktreesheet", "confirmremoveworktree", "noticeopen",
        ]

        private static let compareCommands: Set<String> = [
            "comparewith", "compare", "comparesheet", "comparefilter", "confirmcompare", "comparestate", "compareselect",
            "comparepath", "compareswap", "comparerefresh", "comparedone", "comparemenu", "comparecopy",
            "sidebarclick", "reload",
        ]

        static func navigationStep(_ command: String, step: String, store: RepositoryStore) async {
            let rest = step.count > command.count ? String(step.dropFirst(command.count + 1)) : ""
            switch command {
            case "filter":
                store.sidebarFilter = rest
                // A frame, so the field and the list have drawn the new text.
                try? await Task.sleep(for: .milliseconds(300))
                logSidebar(store)
            case "sidebar": logSidebar(store)
            case "worktrees": logWorktrees(store)
            case "worktreemenu": logWorktreeMenus(store)
            case "openworktree":
                guard
                    let worktree = store.worktrees.first(where: {
                        WorktreeWording.folderName($0.path) == rest || $0.path == rest
                    })
                else {
                    log("openworktree: no worktree \(rest)")
                    return
                }
                let before = store.generation
                // Routed (Ruling 11): a worktree another window shows brings that one to the front.
                if case .front(let shown) = store.openWorktree(worktree) {
                    log("openworktree: shown already, fronted: \(describeStore(shown))")
                    return
                }
                _ = await wait({ store.generation != before && store.snapshot != nil && !store.worktrees.isEmpty }, what: "openworktree: the worktree's first snapshot")
                log("openworktree: root \(store.root?.path ?? "nil") | error: \(store.lastError ?? "nil")")
                logTitles(store)
                log(
                    "openworktree: open recent first: "
                        + "\(NSDocumentController.shared.recentDocumentURLs.first?.path ?? "nil") | lastRepositoryPath: "
                        + "\(store.defaults.string(forKey: RepositoryStore.lastRepositoryPathKey) ?? "nil")")
            case "pills":
                let heads = store.detachedWorktreeHeads
                for commit in store.snapshot?.commits ?? [] {
                    guard let worktrees = heads[commit.sha] else { continue }
                    for worktree in worktrees {
                        log("pill \(commit.shortSha) \(flatten(commit.summary)): \(WorktreeWording.pillText(worktree)) "
                            + "| help: \(WorktreeWording.pillHelp(worktree))")
                    }
                }
                log("pills: \(heads.count) commits, \(heads.values.reduce(0) { $0 + $1.count }) worktrees")
            case "watchloads":
                await watchLoads(store, seconds: min(max(Double(rest) ?? 10, 1), 120))
            case "firstresponder":
                let responder = NSApp.keyWindow?.firstResponder
                log("firstresponder: \(responder.map { String(describing: type(of: $0)) } ?? "nil")")
            case "reloadtiming":
                await reloadTiming(store)
            case "newwindow": await newWindow(rest)
            case "inwindow":
                // `windowStepRefusal` has checked the number before the step ran.
                guard let n = Int(rest), AppModel.windows.stores.indices.contains(n - 1) else { return }
                let chosen = AppModel.windows.stores[n - 1]
                target = chosen
                log("inwindow: \(n) -> \(describeStore(chosen))")
            case let compare where compareCommands.contains(compare):
                await compareStep(command, rest: rest, store: store)
            case let sheet where worktreeSheetCommands.contains(sheet):
                await worktreeSheetStep(command, rest: rest, store: store)
            default: log("unknown step: \(step)")
            }
        }

        // MARK: - Add and Remove Worktree (Task 5)

        private static func worktreeSheetStep(_ command: String, rest: String, store: RepositoryStore) async {
            switch command {
            case "addworktree":
                store.requestAddWorktree(branch: rest.isEmpty ? nil : rest)
                await logAddSheet(store)
            case "folderproblem":
                log("folderproblem \"\(rest)\" -> \"\(WorktreeWording.normalizedFolder(rest))\": "
                    + "\(await store.worktreeFolderProblem(rest) ?? "ok")")
            case "confirmaddworktree":
                guard let (choice, path) = addChoice(rest, store) else {
                    return log("confirmaddworktree: cannot read \(rest)")
                }
                log("confirmaddworktree: \(choice) at \(flatten(path)) | sheet: \(describeWorktreeSheet(store.activeSheet) ?? "none")")
                store.confirmAddWorktree(choice, path: path)
                _ = await wait({ !store.isMutating && !store.isReadingWorktreeState }, seconds: 60, what: "confirmaddworktree: the add and the worktree read")
                logOutcome(store)
            case "removeworktree", "removeworktreestart":
                guard let worktree = worktree(rest, store) else { return log("\(command): no worktree \(rest)") }
                store.requestRemoveWorktree(worktree)
                if command == "removeworktree" { await store.worktreeCheckTask?.value }
                await logWorktreeSheet(store)
            case "removeallmissing":
                store.requestRemoveAllMissing()
                await store.worktreeCheckTask?.value
                await logWorktreeSheet(store)
            case "worktreesheet":
                await logWorktreeSheet(store)
            case "confirmremoveworktree":
                await confirmRemove(rest, store)
            case "noticeopen":
                let open = store.stickyNotice?.actions.first { if case .openWorktree = $0 { true } else { false } }
                guard let open else { return log("noticeopen: no Open on the sticky notice") }
                log("noticeopen: \(open) [\(NoticeWording.title(open))]")
                let before = store.generation
                store.perform(open)
                _ = await wait({ store.generation != before && store.snapshot != nil && !store.worktrees.isEmpty }, what: "noticeopen: the opened worktree's first snapshot")
                log("noticeopen: root \(store.root?.path ?? "nil") | error: \(store.lastError.map(flatten) ?? "nil")")
                logTitles(store)
            default: log("unknown step: \(command)")
            }
        }

        private static func worktree(_ name: String, _ store: RepositoryStore) -> Worktree? {
            store.worktrees.first { WorktreeWording.folderName($0.path) == name || $0.path == name }
        }

        /// `existing:<b>:<path>`, `new:<name>:<start>:<path>`, `tracking:<name>:<remote ref>:<path>`.
        private static func addChoice(_ spec: String, _ store: RepositoryStore) -> (AddWorktreeChoice, String)? {
            let parts = spec.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            func tip(_ ref: String) -> RefTip? {
                store.worktreeStartPoints.first { $0.ref == ref }
                    ?? (ref.count == 40 && ref.allSatisfy(\.isHexDigit) ? RefTip(ref: ref, id: ref) : nil)
            }
            switch parts.first {
            case "existing":
                let rest = spec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard rest.count == 3 else { return nil }
                return (.existing(rest[1]), rest[2])
            case "new":
                guard parts.count == 4, let start = tip(parts[2]) else { return nil }
                return (.newBranch(name: parts[1], start: start), parts[3])
            case "tracking":
                guard parts.count == 4, let remote = store.worktreeRemoteTips.first(where: { $0.ref == parts[2] }) else { return nil }
                return (.tracking(name: parts[1], remote: remote), parts[3])
            default:
                return nil
            }
        }

        private static func confirmRemove(_ rest: String, _ store: RepositoryStore) async {
            let removals: [WorktreeRemoval]
            switch store.activeSheet {
            case .removeWorktree(let removal): removals = [removal]
            case .removeMissingWorktrees(let all): removals = all
            default: return log("confirmremoveworktree: no Remove sheet | sheet: \(describeWorktreeSheet(store.activeSheet) ?? "none")")
            }
            let holders = RepositoryStore.keepHolders(removals)
            let defaults = store.worktreeKeepDefaults(holders)
            var keeping: [String: String] = [:]
            switch rest {
            case "": keeping = defaults.names.filter { defaults.ticked.contains($0.key) }
            case "none": keeping = [:]
            default: if let holder = holders.first { keeping = [holder.ref: rest] }
            }
            let problems = await store.keepNameProblems(keeping)
            log("confirmremoveworktree: keeping \(keeping.sorted { $0.key < $1.key }) | name problems: \(problems)")
            guard problems.isEmpty else { return log("confirmremoveworktree: not confirmed — a name has a problem") }
            if case .removeWorktree(let removal) = store.activeSheet {
                store.confirmRemoveWorktree(removal, keeping: keeping)
            } else {
                store.confirmRemoveMissingWorktrees(removals, keeping: keeping)
            }
            _ = await wait({ !store.isMutating && !store.isReadingWorktreeState }, seconds: 60, what: "confirmremoveworktree: the removal and the worktree read")
            logOutcome(store)
        }

        /// The notices and banner after a write, and the worktrees git lists now.
        /// `reloadtiming`: `refresh()` returns once its snapshot is written; the worktree state's
        /// read, started then, lands later in its own task. Polled every 5 ms.
        private static func reloadTiming(_ store: RepositoryStore) async {
            let clock = ContinuousClock()
            let writes = store.worktreeStateWrites
            let loads = store.snapshotLoadCount
            let start = clock.now
            await store.refresh()
            let snapshotAt = clock.now - start
            let stateWasPrevious = store.worktreeStateWrites == writes
            let reading = store.isReadingWorktreeState
            while store.worktreeStateWrites == writes || store.isReadingWorktreeState, clock.now - start < .seconds(60) {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let stateAt = clock.now - start
            func ms(_ duration: Duration) -> Int { Int(duration / .milliseconds(1)) }
            log("reloadtiming: \(store.snapshotLoadCount - loads) snapshot load landed after \(ms(snapshotAt)) ms | the "
                + "worktree state then: \(stateWasPrevious ? "the previous one" : "already new"), its read in flight: "
                + "\(reading) | the worktree state landed after \(ms(stateAt)) ms | worktrees: \(store.worktrees.count), "
                + "changes read: \(store.worktreeChanges.count), unknown: \(store.worktreeState.unknownChanges.count)")
        }

        private static func logOutcome(_ store: RepositoryStore) {
            let sticky = store.stickyNotice
            log("outcome notice: \(store.notice.map { flatten($0.text) } ?? "nil")")
            log("outcome sticky: \(sticky.map { flatten($0.text) } ?? "nil") | actions: "
                + "\(sticky?.actions.map { "\(NoticeWording.title($0)) \($0)" } ?? [])")
            log("outcome error: \(store.lastError.map(flatten) ?? "nil")")
            log("outcome worktrees: \(store.worktrees.map { "\(flatten($0.path)) [\(WorktreeWording.branchLine($0))]" })")
        }

        private static func logAddSheet(_ store: RepositoryStore) async {
            guard case .addWorktree(let preset) = store.activeSheet else {
                return log("addworktree: no sheet | error: \(store.lastError.map(flatten) ?? "nil")")
            }
            let free = store.freeWorktreeBranches
            let branch = preset.flatMap { free.contains($0) ? $0 : nil } ?? free.first ?? ""
            let folder = store.defaultWorktreeFolder(for: branch)
            log("addworktree: \(WorktreeWording.addSheetTitle) | preset: \(preset ?? "nil") | kinds: "
                + "\(AddWorktreeKind.allCases.map(WorktreeWording.kindTitle))")
            log("addworktree existing: \(free.isEmpty ? WorktreeWording.noFreeBranches : free.joined(separator: ", "))")
            log("addworktree starts: \(store.worktreeStartPoints.map(WorktreeWording.startLabel).joined(separator: ", "))")
            log("addworktree remotes: \(store.worktreeRemoteTips.map { "\(WorktreeWording.startLabel($0)) -> \(store.trackingName(for: $0))" })")
            log("addworktree folder for \(branch): \(flatten(folder)) | check: \(await store.worktreeFolderProblem(folder) ?? "ok")")
        }

        private static func logWorktreeSheet(_ store: RepositoryStore) async {
            log("worktreesheet: \(describeWorktreeSheet(store.activeSheet) ?? "none") | error: \(store.lastError.map(flatten) ?? "nil") "
                + "| notice: \(store.notice.map { flatten($0.text) } ?? "nil")")
            let removals: [WorktreeRemoval]
            switch store.activeSheet {
            case .checkingWorktreeRemoval(let worktrees, let all):
                log("worktreesheet checking: \(all ? WorktreeWording.checkingMissing : WorktreeWording.checking) "
                    + "\(worktrees.map { flatten($0.path) })")
                return
            case .removeWorktree(let removal): removals = [removal]
            case .removeMissingWorktrees(let all):
                removals = all
                log("worktreesheet \(WorktreeWording.removeMissingSheetTitle): \(WorktreeWording.removeMissingIntro(all.count)) "
                    + "| button: \(all.contains { $0.refusals.isEmpty } ? WorktreeWording.removeMissingButton(all.filter { $0.refusals.isEmpty }.count) : "none: " + WorktreeWording.noneRemovable)")
            default: return
            }
            for removal in removals {
                let name = WorktreeWording.folderName(removal.worktree.path)
                log("worktreesheet \(name): \(WorktreeWording.removeSheetTitle(removal.worktree)) | head \(removal.worktree.head ?? "nil") "
                    + "| branch \(removal.worktree.branch ?? "nil") | changes: \(removal.changes.map { "\($0)" } ?? "nil")")
                log("worktreesheet \(name) intro: \(WorktreeWording.removeIntro(removal))")
                log("worktreesheet \(name) stays: \(WorktreeWording.branchStays(removal) ?? "-") | stranded: "
                    + "\(WorktreeWording.strandedLine(removal) ?? "-") \(removal.stranded.commits.map { "\($0.sha.prefix(7)) \($0.subject)" })")
                log("worktreesheet \(name) ignored: \(WorktreeWording.ignoredLine(removal.ignored) ?? "-") (count \(removal.ignored.count))")
                log("worktreesheet \(name) refusals (\(removal.refusals.count)): \(removal.refusals.map(WorktreeWording.refusal)) "
                    + "| button: \(removal.refusals.isEmpty ? WorktreeWording.removeButton : "none")")
            }
            let holders = RepositoryStore.keepHolders(removals)
            let defaults = store.worktreeKeepDefaults(holders)
            let problems = await store.keepNameProblems(defaults.names)
            let boxes = holders.map { tip -> String in
                let ticked = defaults.ticked.contains(tip.ref) ? "ticked" : "unticked"
                return "\(WorktreeWording.keepLabel(tip.ref)) \(defaults.names[tip.ref] ?? "") [\(ticked)] at "
                    + "\(tip.id.prefix(7)) \(problems[tip.ref] ?? "ok")"
            }
            log("worktreesheet keep: \(boxes)")
        }

        static func describeWorktreeSheet(_ sheet: BranchSheet?) -> String? {
            switch sheet {
            case .addWorktree(let branch): "addWorktree(preset: \(branch ?? "nil"))"
            case .checkingWorktreeRemoval(let worktrees, let all):
                "checkingWorktreeRemoval(\(worktrees.map { flatten($0.path) }), allMissing: \(all))"
            case .removeWorktree(let r):
                "removeWorktree(\(flatten(r.worktree.path)), refusals: \(r.refusals.count), ignored: \(r.ignored.count), "
                    + "stranded: \(r.stranded.count))"
            case .removeMissingWorktrees(let all):
                "removeMissingWorktrees(\(all.map { "\(flatten($0.worktree.path)) refusals: \($0.refusals.count) stranded: \($0.stranded.count)" }))"
            default: nil
            }
        }

        // MARK: - Compare (Task 4)

        private static func compareStep(_ command: String, rest: String, store: RepositoryStore) async {
            let parts = rest.split(separator: ":", maxSplits: 1).map(String.init)
            switch command {
            case "comparewith":
                store.compareWithCurrent(rest)
                await settleCompare(store)
                logCompare(store)
            case "compare":
                guard parts.count == 2 else { return log("compare: needs <ref A>:<ref B>") }
                store.compare(parts[0], parts[1])
                await settleCompare(store)
                logCompare(store)
            case "comparesheet":
                store.requestCompareBranches(a: parts.first, b: parts.count > 1 ? parts[1] : nil)
                logCompareSheet(store, query: "")
            case "comparefilter":
                logCompareSheet(store, query: rest)
            case "confirmcompare":
                guard parts.count == 2 else { return log("confirmcompare: needs <ref A>:<ref B>") }
                store.confirmCompareBranches(parts[0], parts[1])
                await settleCompare(store)
                log("confirmcompare: sheet \(store.activeSheet.map { "\($0)" } ?? "nil")")
                logCompare(store)
            case "comparestate":
                logCompare(store)
            case "compareselect":
                let selection: Selection =
                    rest == "changes" ? .comparisonChanges
                    : .commit(
                        (store.comparison.map { $0.commitsOnlyB + $0.commitsOnlyA } ?? [])
                            .first { $0.sha.hasPrefix(rest) }?.sha ?? rest)
                store.select(selection)
                await settleDetail(store)
                logCompare(store)
            case "comparepath":
                store.selectPath(rest)
                await settleDetail(store)
                logCompareDiff(store)
            case "compareswap":
                store.swapComparison()
                await settleCompare(store)
                logCompare(store)
            case "comparerefresh":
                store.refreshComparison()
                await settleCompare(store)
                logCompare(store)
            case "comparedone":
                store.endComparison()
                await settleDetail(store)
                logCompare(store)
            case "comparemenu":
                logCompareMenus(store)
            case "comparecopy":
                let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.penzin.Gitter.harness"))
                let sha =
                    (store.comparison.map { $0.commitsOnlyB + $0.commitsOnlyA } ?? []).first { $0.sha.hasPrefix(rest) }?.sha
                guard let sha else { return log("comparecopy: no commit \(rest) in the comparison") }
                // The menu item's own call, onto a private pasteboard.
                Clipboard.copy(sha, to: pasteboard)
                log("comparecopy \(CompareWording.copyCommitIDTitle): \(pasteboard.string(forType: .string) ?? "nil")")
                pasteboard.releaseGlobally()
            case "sidebarclick":
                guard let branch = store.localBranches.first(where: { $0.name == rest }) else {
                    return log("sidebarclick: no branch \(rest)")
                }
                store.selectFromSidebar(.commit(branch.sha))
                await settleDetail(store)
                logCompare(store)
            case "reload":
                await store.refresh()
                await settleDetail(store)
                logCompare(store)
            default: log("unknown step: \(command)")
            }
        }

        /// The comparison's read, then the detail it selected.
        private static func settleCompare(_ store: RepositoryStore) async {
            await store.compareTask?.value
            await settleDetail(store)
        }

        private static func settleDetail(_ store: RepositoryStore) async {
            await store.detailTask?.value
            await store.diffTask?.value
            // A frame, so the column has drawn what the store now says.
            try? await Task.sleep(for: .milliseconds(300))
        }

        private static func logCompare(_ store: RepositoryStore) {
            guard let c = store.comparison else {
                log("compare: none | selection: \(store.selection) | error: \(store.lastError.map(flatten) ?? "nil") "
                    + "| history rows shown: \(store.snapshot?.commits.count ?? 0)")
                return
            }
            let staleness = store.comparisonStaleness
            let buttons =
                [staleness?.offersSwap != false ? CompareWording.swapTitle : nil,
                 staleness?.offersRefresh == true ? CompareWording.refreshTitle : nil, CompareWording.doneTitle]
                .compactMap { $0 }
            log("compare bar: \(CompareWording.barTitle(c)) | a \(c.a.ref) \(c.a.id) | b \(c.b.ref) \(c.b.id) "
                + "| buttons: \(buttons) | moved: \(store.comparisonMoved) | line: \(staleness.flatMap(CompareWording.staleLine) ?? "nil")")
            log("compare help: \(CompareWording.barHelp(c))")
            log("compare row: \(CompareWording.changesRow(c, fileCount: store.comparisonFiles?.count) ?? CompareWording.noHistoryRow(c))")
            for (ref, count, commits) in [(c.b.ref, c.onlyB, c.commitsOnlyB), (c.a.ref, c.onlyA, c.commitsOnlyA)] {
                let shown = commits.prefix(12).map { "\($0.shortSha) \(flatten($0.summary))" }.joined(separator: ", ")
                log("compare group \(CompareWording.onlyOn(ref, count: count)): listed \(commits.count) "
                    + "| first: [\(shown)\(commits.count > 12 ? ", …" : "")] "
                    + "| \(CompareWording.notListed(total: count, listed: commits.count) ?? "all listed") "
                    + "| ids: \(commits.map(\.sha).joined(separator: ","))")
            }
            log("compare header: \(CompareWording.headerTitle(c)) | \(CompareWording.baseLine(c)) | \(CompareWording.countsLine(c)) "
                + "| \(CompareWording.filesLine(c, fileCount: store.comparisonFiles?.count) ?? "-") | bases: \(c.mergeBases)")
            let files = store.detailFiles.map { "\(letter($0.staged)) \($0.path)\($0.originalPath.map { " <- \($0)" } ?? "")" }
            log("compare selection: \(store.selection) | detail files (\(files.count)): \(files.joined(separator: ", ")) "
                + "| comparisonFiles: \(store.comparisonFiles.map { "\($0.count)" } ?? "nil") | path: \(store.selectedPath ?? "nil") "
                + "| diff files: \(store.diff.count) | error: \(store.lastError.map(flatten) ?? "nil") "
                + "| header commit: \(selectedCommitLine(store))")
        }

        private static func selectedCommitLine(_ store: RepositoryStore) -> String {
            guard case .commit(let sha) = store.selection else { return "-" }
            return store.commitForDetail(sha).map { "\($0.shortSha) \(flatten($0.summary))" } ?? "not found (\(sha.prefix(7)))"
        }

        private static func letter(_ kind: ChangeKind?) -> String {
            switch kind {
            case .modified: "M"
            case .added: "A"
            case .deleted: "D"
            case .renamed: "R"
            case .copied: "C"
            case .typeChanged: "T"
            default: "?"
            }
        }

        private static func logCompareDiff(_ store: RepositoryStore) {
            log("compare diff: path \(store.selectedPath ?? "nil") | files \(store.diff.count) | error: \(store.lastError.map(flatten) ?? "nil")")
            for file in store.diff {
                let lines = file.hunks.flatMap(\.lines)
                log("compare diff file \(file.displayPath): hunks \(file.hunks.count) | lines \(lines.count) "
                    + "| first: \(lines.prefix(4).map { flatten($0.text) })")
            }
        }

        private static func logCompareSheet(_ store: RepositoryStore, query: String) {
            guard case .compareBranches(let a, let b) = store.activeSheet else {
                return log("comparesheet: no sheet | error: \(store.lastError.map(flatten) ?? "nil")")
            }
            let options = CompareWording.pickerOptions(store.snapshot?.refs ?? .empty, query: query)
            log("comparesheet: \(CompareWording.sheetTitle) | a: \(a ?? "nil") | b: \(b ?? "nil") "
                + "| blocked: \(CompareWording.sheetBlocked(a: a, b: b) ?? "nil") "
                + "| \(CompareWording.chosen(a)) / \(CompareWording.chosen(b))")
            log("comparesheet options for \"\(query)\" (\(options.count)): \(options.isEmpty ? SidebarFilter.noMatches : options.joined(separator: ", "))")
        }

        private static func logCompareMenus(_ store: RepositoryStore) {
            func state(_ reason: String?) -> String { reason.map { "off: \($0)" } ?? "on" }
            let title = CompareWording.compareWithTitle(current: store.currentBranch)
            let branches = store.compareBranchesBlockedReason
            for ref in store.localBranches.map({ "refs/heads/" + $0.name }) + store.remoteBranches.map({ "refs/remotes/" + $0.name }) {
                log("comparemenu \(ref): \(title) [\(state(store.compareWithCurrentBlockedReason(ref)))] "
                    + "| \(CompareWording.compareBranchesTitle) [\(state(branches))]")
            }
        }

        private static func flatten(_ text: String) -> String {
            text.replacingOccurrences(of: "\n", with: " \u{23CE} ")
        }

        private static func logSidebar(_ store: RepositoryStore) {
            let refs = store.snapshot?.refs ?? .empty
            let rows = SidebarFilter.rows(refs, deletedTags: store.deletedTags.receipts, query: store.sidebarFilter)
            log("sidebar filter: \"\(store.sidebarFilter)\" | filtering: \(rows.isFiltering) | matches: \(rows.matchCount) "
                + "| voiceover: \(rows.isFiltering ? SidebarFilter.announcement(matches: rows.matchCount) : "(none)")")
            if rows.showsBranches {
                log("sidebar Branches: \(rows.branchesHaveNoMatches ? SidebarFilter.noMatches : rows.localBranches.map(\.name).joined(separator: ", "))")
            }
            if WorktreeWording.showsSection(store.worktrees) {
                log("sidebar Worktrees (not filtered): \(store.worktrees.map { WorktreeWording.folderName($0.path) }.joined(separator: ", "))")
            }
            log("sidebar Stashes (not filtered): \(store.snapshot?.stashes.count ?? 0)")
            if rows.showsRemotes {
                if rows.remotesHaveNoMatches { log("sidebar Remotes: \(SidebarFilter.noMatches)") }
                for group in rows.remoteGroups {
                    // The view's own expansion is @State; while filtering it is forced open.
                    let expanded = rows.isFiltering ? "expanded (filtering)" : "the user's own expansion"
                    log("sidebar Remotes \(group.remote.name) [\(expanded)]: \(group.branches.map(\.name).joined(separator: ", "))")
                }
                if !rows.otherBranches.isEmpty {
                    log("sidebar Remotes Other: \(rows.otherBranches.map(\.name).joined(separator: ", "))")
                }
            }
            if rows.showsTags {
                log("sidebar Tags: \(rows.tagsHaveNoMatches ? SidebarFilter.noMatches : (rows.tags.map(\.name) + rows.deletedTags.map { "\($0.name) (deleted)" }).joined(separator: ", "))")
            }
        }

        // MARK: - Windows (E2 Task 4)

        /// Why a `newwindow:` or `inwindow:` step must not run, or nil; nil for every other step.
        // internal (not private): used by DebugLaunchHooks+Branches.swift before every step
        static func windowStepRefusal(_ step: String) -> String? {
            if step.hasPrefix("newwindow:") {
                return DebugLaunchGuard.newWindowRefusal(
                    String(step.dropFirst("newwindow:".count)), ProcessInfo.processInfo.environment)
            }
            if step.hasPrefix("inwindow:") {
                let rest = step.dropFirst("inwindow:".count)
                let count = AppModel.windows.stores.count
                guard let n = Int(rest), n >= 1, n <= count else {
                    return "refused: \(step) names no window (\(count) registered)"
                }
            }
            return nil
        }

        /// The window showing `store`, for what a step draws or reads of one (`snapshot:`, `views`,
        /// the titles): the target's own window, not whichever is first on screen.
        static func window(of store: RepositoryStore) -> NSWindow? {
            AppModel.windows.window(of: store)
        }

        private static func newWindow(_ path: String) async {
            let url = URL(fileURLWithPath: path)
            let registry = AppModel.windows
            let route = registry.open(url, kind: .recentOrFinder, front: nil)
            switch route {
            case .front(let store): log("newwindow: \(path) -> shown already, fronted: \(describeStore(store))")
            case .useFront(let store): log("newwindow: \(path) -> opened in the front window: \(describeStore(store))")
            case .refused(let store): log("newwindow: \(path) -> not a repository, refused in: \(describeStore(store))")
            case .newWindow(let value): log("newwindow: \(path) -> a new window for \(value.path)")
            }
            _ = await wait(
                {
                    guard let shown = registry.store(showing: url) else { return false }
                    return shown.snapshot != nil && !shown.isMutating && !shown.isReadingWorktreeState
                }, seconds: 30, what: "newwindow: the window's first snapshot")
            for (index, store) in registry.stores.enumerated() {
                log("newwindow: window \(index + 1): \(describeStore(store))")
            }
        }

        private static func describeStore(_ store: RepositoryStore) -> String {
            "store \(store.debugSerial) \(store.root?.path ?? "(empty)")"
                + (store.isClosed ? " (closed)" : "") + (store === target ? " [target]" : "")
                + (window(of: store)?.isKeyWindow == true || window(of: store)?.attachedSheet?.isKeyWindow == true
                    ? " [key]" : "")
        }

        private static func logTitles(_ store: RepositoryStore) {
            let window = window(of: store)
            log("title: store \"\(store.windowTitle)\" | window \"\(window?.title ?? "nil")\" #\(window?.windowNumber ?? 0) | linked: \(store.isLinkedWorktree) "
                + "| main: \(store.mainWorktreeName ?? "nil") | open path: \(store.worktreeState.openPath ?? "nil")")
        }

        private static func logWorktrees(_ store: RepositoryStore) {
            log("worktrees: \(store.worktrees.count) | section shown: \(WorktreeWording.showsSection(store.worktrees)) "
                + "| changes read: \(store.worktreeChanges.count) | unknown: \(store.worktreeState.unknownChanges.count)")
            for worktree in store.worktrees {
                let marks = store.marks(worktree)
                log("worktree \(WorktreeWording.folderName(worktree.path)) | \(WorktreeWording.branchLine(worktree)) "
                    + "| head \(worktree.head?.prefix(7) ?? "nil") | marks: "
                    + "[\(marks.map(WorktreeWording.markText).joined(separator: "; "))] | changes: \(store.changesReading(worktree))")
                log("worktree \(WorktreeWording.folderName(worktree.path)) help: \(flatten(WorktreeWording.rowHelp(worktree, marks: marks)))")
                log("worktree \(WorktreeWording.folderName(worktree.path)) voiceover: \(WorktreeWording.rowAccessibility(worktree, marks: marks))")
            }
            logTitles(store)
        }

        private static func logWorktreeMenus(_ store: RepositoryStore) {
            func state(_ reason: String?) -> String { reason.map { "off: \($0)" } ?? "on" }
            for worktree in store.worktrees {
                let newWindow =
                    WorktreeWording.offersOpenInNewWindow(worktree, isOpenHere: store.isOpenHere(worktree))
                    ? "\(WorktreeWording.openInNewWindowTitle) [\(state(WorktreeWording.openInNewWindowBlocked(worktree)))] | "
                    : ""
                log("worktreemenu \(WorktreeWording.folderName(worktree.path)): "
                    + "\(WorktreeWording.openTitle) [\(state(store.openWorktreeBlockedReason(worktree)))] | "
                    + newWindow
                    + "\(WorktreeWording.revealTitle) [\(state(WorktreeWording.revealBlocked(worktree)))] | "
                    + "\(WorktreeWording.copyPathTitle) [on: \(flatten(worktree.path))] | "
                    + "\(WorktreeWording.removeTitle) [\(state(store.removeWorktreeBlockedReason(worktree)))]"
                    + (worktree.isMissing ? " | \(WorktreeWording.removeAllMissingTitle) [on]" : "")
                    + " | \(WorktreeWording.addTitle) [\(state(store.addWorktreeBlockedReason))]")
            }
            log("worktreemenu header: \(WorktreeWording.addTitle) [\(state(store.addWorktreeBlockedReason))] | "
                + "\(WorktreeWording.removeAllMissingTitle) [\(state(store.removeAllMissingBlockedReason))]")
            for branch in store.localBranches {
                let icon = store.worktreeHolder(of: branch.name).map(WorktreeWording.holderSymbol) ?? "none"
                log("branchmenu \(branch.name) [icon: \(icon), checkedOutAt: \(branch.checkedOutAt ?? "nil")]: "
                    + "Switch [\(state(store.switchBlockedReason(for: branch.name)))] | "
                    + "Delete… [\(state(store.deleteBlockedReason(for: branch.name)))] | "
                    + "\(RemoteAdminWording.fastForwardTitle(branch.name)) [\(state(store.fastForwardBlockedReason(branch.name)))] | "
                    + "\(WorktreeWording.newWorktreeTitle(branch.name)) [\(state(store.newWorktreeBlockedReason(branch.name)))]")
            }
        }

        private static func watchLoads(_ store: RepositoryStore, seconds: Double) async {
            var seen = store.snapshotLoadCount
            let end = Date.now.addingTimeInterval(seconds)
            log("watchloads: watching \(Int(seconds)) s from load \(seen)")
            while Date.now < end {
                try? await Task.sleep(for: .milliseconds(50))
                guard store.snapshotLoadCount != seen, !store.isLoading else { continue }
                seen = store.snapshotLoadCount
                let files = store.snapshot?.status.files ?? []
                let tips = store.localBranches.map { "\($0.name)=\($0.sha.prefix(7))" }.joined(separator: ",")
                let time = Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3)))
                log("load \(seen) at \(time): head \(store.headLabel) \(store.headSha?.prefix(7) ?? "nil") | files \(files.count) "
                    + "staged \(files.filter { $0.staged != nil }.count) | stashes \(store.snapshot?.stashes.count ?? 0) | \(tips)")
            }
            log("watchloads: done at load \(store.snapshotLoadCount)")
        }
    }

#endif
