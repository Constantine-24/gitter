#if DEBUG

    import AppKit
    import Foundation
    import GitCore
    import Synchronization

    /// The resolver's steps of `GITTER_DEBUG_BRANCH_ACTION` (see `DebugLaunchHooks+Branches` for
    /// the grammar and the waiting):
    ///
    ///   select:<path>           selects the working copy's file (the unstaged row of a conflicted
    ///                           one, the staged row of a resolved one) and waits for the
    ///                           resolver's read; logs `resolver: …`.
    ///   take:ours|theirs:<path> Take Ours / Take Theirs (or the whole-file kind's own title).
    ///   deletefile:<path>       Delete the File. (`delete:` is the branch step.)
    ///   keep:<path>             Keep Their / Our Version.
    ///   confirmreplace          the Replace sheet's destructive button, for what the sheet shows.
    ///   markresolved:<path>     Mark Resolved.
    ///   confirmmarkers          the Mark Resolved sheet's destructive button.
    ///   reopen:<path>           selects the resolved file, waits for `canReopen`, and opens
    ///                           Reopen Conflict… (nothing more); logs `reopen: not offered` when
    ///                           it is not.
    ///   confirmreopen           the Reopen sheet's destructive button.
    ///   conflictreadfails:on|off  makes the resolver's read of a conflicted file throw while it
    ///                           is on (the store checks `conflictReadFails` before asking the
    ///                           backend), so the failed state shows; `off` stops it. Logs the
    ///                           setting. Try Again, or `select:`, then reads for real.
    ///   tryagain                the failed state's Try Again (`loadConflict()`); waits for the
    ///                           document or the failure, and logs `resolver: …`.
    ///   resolver                logs the resolver's state without doing anything.
    ///   resolver:open[:<path>]  focus mode on that file (or the first with conflicts), as the
    ///                           card's or the operation bar's Resolve Conflicts… does; waits for
    ///                           its read (and draft) and the sidebar's summaries, and logs
    ///                           `focus: …` with the window number `screencapture -l` needs.
    ///   resolver:done           Done; logs `focus: …`.
    ///   resolver:state          logs `focus: …` without doing anything.
    ///   noticeshow              the sticky notice's Show Copy, as its button runs it.
    ///   cancelsheet             what a sheet's Cancel does (`activeSheet = nil`): a sheet up
    ///                           keeps `quit` from quitting.
    ///
    /// Each write step goes through the store's own entry point, which does nothing where the
    /// resolver offers no such button; the step logs the offer first, so a refusal is visible.
    extension DebugLaunchHooks {

        static let conflictCommands: Set<String> = [
            "select", "take", "deletefile", "keep", "confirmreplace", "markresolved",
            "confirmmarkers", "reopen", "confirmreopen", "resolver", "noticeshow", "cancelsheet",
            "conflictreadfails", "tryagain",
        ]

        private static let readFails = Mutex(false)

        /// Whether the resolver's read of a conflict throws (`conflictreadfails:`).
        static var conflictReadFails: Bool { readFails.withLock { $0 } }

        /// What the failing read throws.
        struct ConflictReadFailed: Error, LocalizedError {
            var errorDescription: String? { "the harness made this read fail" }
        }

        static func conflictStep(_ command: String, step: String, store: RepositoryStore) async {
            let rest = String(step.dropFirst(command.count + 1))
            switch command {
            case "select":
                await select(rest, store: store)
            case "take":
                let parts = rest.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let side: ConflictSide = parts[0] == "ours" ? .ours : parts[0] == "theirs" ? .theirs : nil
                else {
                    log("take: expected ours|theirs:<path>")
                    return
                }
                guard await select(parts[1], store: store) else { return }
                logOffer(side == .ours ? .takeOurs : .takeTheirs, store)
                store.takeSide(side)
            case "deletefile":
                guard await select(rest, store: store) else { return }
                logOffer(.delete, store)
                store.deleteConflictedFile()
            case "keep":
                guard await select(rest, store: store) else { return }
                logOffer(.keep, store)
                store.keepConflictedFile()
            case "confirmreplace":
                guard case .replaceHandEdited(let snapshot, let pending) = store.activeSheet else {
                    log("confirmreplace: no replace sheet")
                    return
                }
                store.confirmReplaceHandEdited(snapshot, pending)
            case "markresolved":
                guard await select(rest, store: store) else { return }
                logOffer(.markResolved, store)
                store.markSelectedResolved()
            case "confirmmarkers":
                guard case .markResolved(let snapshot, _) = store.activeSheet else {
                    log("confirmmarkers: no mark resolved sheet")
                    return
                }
                store.confirmMarkResolved(snapshot)
            case "reopen":
                guard store.snapshot?.status.files.contains(where: { $0.path == rest }) == true else {
                    log("reopen: no file \(rest)")
                    return
                }
                store.select(rest, staged: true)
                guard await wait({ store.reopenablePath == rest }, what: "reopen \(rest): the offer") else {
                    log("reopen: not offered for \(rest)")
                    return
                }
                store.requestReopen(rest)
                let shown = await wait({ if case .reopen(rest, _, _, _)? = store.activeSheet { true } else { false } }, what: "reopen \(rest): its sheet")
                if !shown {
                    log("reopen: no sheet for \(rest) | blocked: \(store.conflictActionBlockedReason ?? "nil")")
                }
            case "confirmreopen":
                guard case .reopen(let path, _, _, _) = store.activeSheet else {
                    log("confirmreopen: no reopen sheet")
                    return
                }
                store.confirmReopen(path)
            case "conflictreadfails":
                guard rest == "on" || rest == "off" else {
                    log("conflictreadfails: expected on|off")
                    return
                }
                readFails.withLock { $0 = rest == "on" }
                log("conflictreadfails: \(rest)")
            case "tryagain":
                guard store.conflictLoadFailure != nil else {
                    log("tryagain: no failed read")
                    return
                }
                store.loadConflict()
                await store.conflictTask?.value
                logResolver(store)
            case "resolver":
                await resolverStep(rest, store: store)
            case "cancelsheet":
                store.activeSheet = nil
            case "noticeshow":
                let show = store.stickyNotice?.actions.first {
                    if case .showStash = $0 { true } else { false }
                }
                guard let show, case .showStash(let stash) = show else {
                    log("noticeshow: no Show Copy")
                    return
                }
                log("noticeshow: \(stash.sha) \"\(stash.message)\"")
                let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.debug-noticeshow"))
                defer { pasteboard.releaseGlobally() }
                store.perform(show, pasteboard: pasteboard) { _ in }
                _ = await wait({ store.stashContents != nil }, what: "noticeshow: the stash's contents")
                log("noticeshow: selection \(store.selection)")
            default:
                log("unknown step: \(step)")
            }
        }

        /// Selects `path` in the working copy and waits for the resolver's read; false (and a
        /// log line) when there is no such conflicted file.
        @discardableResult
        private static func select(_ path: String, store: RepositoryStore) async -> Bool {
            guard let file = store.snapshot?.status.files.first(where: { $0.path == path }) else {
                log("select: no file \(path)")
                return false
            }
            let conflicted = file.conflict != nil
            if store.selectedPath != path || (conflicted && store.stagedView) {
                store.select(path, staged: !conflicted && file.unstaged == nil)
            }
            if conflicted {
                guard await wait({ store.selectedConflict != nil || store.conflictLoadFailure?.path == path }, what: "select \(path): its resolver") else {
                    log("select: no resolver for \(path) after ten seconds | error: \(store.lastError ?? "nil")")
                    return false
                }
            } else {
                _ = await wait({ store.reopenablePath == path }, seconds: 3, what: "select \(path): the reopen offer")
            }
            logResolver(store)
            return true
        }

        private static func logOffer(_ action: ResolverAction, _ store: RepositoryStore) {
            guard let document = store.selectedConflict else {
                log("offer \(action): no resolver on screen")
                return
            }
            let offered = ResolverOffer.actions(for: document).contains(action)
            log("offer \(action): \(offered ? "offered" : "NOT offered") \"\(ConflictWording.title(action, document.snapshot.file))\" "
                + "blocked: \(store.conflictActionBlockedReason ?? "nil")")
        }

        static func logResolver(_ store: RepositoryStore) {
            guard let document = store.selectedConflict else {
                if let failure = store.conflictLoadFailure {
                    log("resolver: failed to read \(failure.path) | \(ConflictWording.loadFailed(failure.message))")
                    return
                }
                log("resolver: none | selected: \(store.selectedPath ?? "nil") reopenable: \(store.reopenablePath ?? "nil")")
                return
            }
            let file = document.snapshot.file
            let shown: String =
                switch document.presentation {
                case .blocks: "blocks(\(ResolverShell.conflictCount(of: document) ?? 0))"
                case .wholeFile(let reason): "wholeFile(\(reason))"
                case .submodule: "submodule"
                }
            let sides = store.conflictSides
            log("resolver: \(file.path) \(ConflictWording.badge(file.kind)) \"\(ConflictWording.kind(file, sides: sides))\" "
                + "| \(shown) | matches: \(document.matchesGitsConflict) "
                + "| hash: \(document.snapshot.worktreeHash?.prefix(12) ?? "nil") "
                + "| sides: \(sides.ours) / \(sides.theirs) "
                + "| actions: \(ResolverOffer.actions(for: document).map { ConflictWording.title($0, file) })")
        }

        /// `resolver`, `resolver:open[:<path>]`, `resolver:done` and `resolver:state`. The path may
        /// hold colons.
        private static func resolverStep(_ rest: String, store: RepositoryStore) async {
            switch rest {
            case "":
                logResolver(store)
            case "done":
                store.closeResolver()
                logFocus(store)
            case "state":
                logFocus(store)
            case let open where open == "open" || open.hasPrefix("open:"):
                let path = open == "open" ? nil : String(open.dropFirst("open:".count))
                store.openResolver(at: path)
                guard let focused = store.resolverFocus?.path else {
                    log("focus: not opened on \(path ?? "the first file") | conflicted: \(store.resolverFiles.map(\.path))")
                    return
                }
                _ = await wait({
                    store.resolverDrafts[focused] != nil || store.conflictLoadFailure?.path == focused
                        || (store.selectedConflict.map { ResolverShell.conflictCount(of: $0) == nil } ?? false)
                }, what: "resolver:open \(focused): its read")
                await store.resolverSummaryTask?.value
                logFocus(store)
            default:
                log("resolver: expected open[:<path>], done or state, got \(rest)")
            }
        }

        /// Focus mode as the shell shows it: the file, its position, the sidebar's rows and
        /// footer, the bars, Resolve File, and the window's number for a window-only screenshot.
        static func logFocus(_ store: RepositoryStore) {
            guard let focus = store.resolverFocus else {
                log("focus: none | card: \(store.selectedFileIsUnmerged) selected: \(store.selectedPath ?? "nil") "
                    + "| window: \(AppModel.windows.window(of: store)?.windowNumber ?? 0)")
                return
            }
            let draft = store.focusedDraft
            let rows = ResolverShell.rows(
                files: store.resolverFiles, resolved: store.resolvedThisSession, drafts: store.resolverDrafts,
                summaries: store.resolverSummaries.mapValues(\.summary))
            let centre = ResolverShell.centre(
                path: focus.path, draft: draft, document: store.selectedConflict, failure: store.conflictLoadFailure,
                allResolved: store.resolverAllResolved)
            let bars = draft.map {
                ResolverShell.bars($0, matchesGitsConflict: store.selectedConflict?.matchesGitsConflict ?? true, keptEditing: false)
            } ?? []
            log("focus: \(focus.path) chunk: \(focus.currentChunk.map(String.init) ?? "nil") "
                + "| \(ResolverShell.position(draft, current: focus.currentChunk) ?? "no position") | centre: \(centre) "
                + "| rows: \(rows.map { "\($0.path)=\(ConflictWording.sidebarStatus($0.status) ?? "-")" }) "
                + "| footer: \(ResolverShell.footerLine(store.operationInProgress, allResolved: store.resolverAllResolved, ended: store.resolverEndedShown != nil) ?? "-") "
                + "| bars: \(bars) | resolve file: \(ResolverShell.resolveFileEnabled(draft, blocked: store.conflictActionBlockedReason)) "
                + "| abort: \(ResolverShell.showsAbort(store.operationInProgress) ? "\(store.abortState)" : "none") "
                + "| window: \(AppModel.windows.window(of: store)?.windowNumber ?? 0)")
        }

        static func describeConflictSheet(_ sheet: BranchSheet?) -> String? {
            switch sheet {
            case .replaceHandEdited(let snapshot, let pending)?:
                "replaceHandEdited(\(snapshot.file.path), \(pending), hash: \(snapshot.worktreeHash?.prefix(12) ?? "nil"))"
            case .markResolved(let snapshot, let markers)?:
                "markResolved(\(snapshot.file.path), markers: \(markers))"
            case .resolveWithMarkers(let snapshot, let pending)?:
                "resolveWithMarkers(\(snapshot.file.path), \(pending))"
            case .takeForFiles(let plan)?:
                "takeForFiles(\(plan.side), files: \(plan.files.map(\.file.path)), copies: \(plan.copies), "
                    + "skipped: \(plan.skipped.map { "\($0.path) (\($0.reason))" }))"
            case .reopen(let path, let hash, let comesBack, let sides)?:
                "reopen(\(path), hash: \(hash?.prefix(12) ?? "nil"), comesBack: \(comesBack), "
                    + "sides: \(sides.ours) / \(sides.theirs), body: \(ConflictWording.reopenBody(path, comesBack, sides)))"
            default: nil
            }
        }
    }

#endif
