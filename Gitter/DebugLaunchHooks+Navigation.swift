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
    ///   openworktree:<folder>  Open Worktree on the row with that folder name (or that path),
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
    extension DebugLaunchHooks {

        static let navigationCommands: Set<String> = [
            "filter", "sidebar", "worktrees", "worktreemenu", "openworktree", "pills", "watchloads", "firstresponder",
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
                store.openWorktree(worktree)
                _ = await wait({ store.generation != before && store.snapshot != nil && !store.worktrees.isEmpty })
                log("openworktree: root \(store.root?.path ?? "nil") | error: \(store.lastError ?? "nil")")
                logTitles(store)
                log(
                    "openworktree: open recent first: "
                        + "\(NSDocumentController.shared.recentDocumentURLs.first?.path ?? "nil") | lastRepositoryPath: "
                        + "\(UserDefaults.standard.string(forKey: RepositoryStore.lastRepositoryPathKey) ?? "nil")")
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
            default: log("unknown step: \(step)")
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

        private static func logTitles(_ store: RepositoryStore) {
            let window = NSApp.windows.first { $0.isVisible && $0.sheetParent == nil }
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
                log("worktreemenu \(WorktreeWording.folderName(worktree.path)): "
                    + "\(WorktreeWording.openTitle) [\(state(store.openWorktreeBlockedReason(worktree)))] | "
                    + "\(WorktreeWording.revealTitle) [\(state(WorktreeWording.revealBlocked(worktree)))] | "
                    + "\(WorktreeWording.copyPathTitle) [on: \(flatten(worktree.path))]")
            }
            for branch in store.localBranches {
                let icon = store.worktreeHolder(of: branch.name).map(WorktreeWording.holderSymbol) ?? "none"
                log("branchmenu \(branch.name) [icon: \(icon), checkedOutAt: \(branch.checkedOutAt ?? "nil")]: "
                    + "Switch [\(state(store.switchBlockedReason(for: branch.name)))] | "
                    + "Delete… [\(state(store.deleteBlockedReason(for: branch.name)))] | "
                    + "\(RemoteAdminWording.fastForwardTitle(branch.name)) [\(state(store.fastForwardBlockedReason(branch.name)))]")
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
