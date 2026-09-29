#if DEBUG

    import AppKit
    import Foundation
    import GitCore

    /// The discard steps of `GITTER_DEBUG_BRANCH_ACTION` (see `DebugLaunchHooks+Branches` for the
    /// grammar and the waiting):
    ///
    ///   discard:<path>          the unstaged row's "Discard Changes…" / "Move to Trash…": opens
    ///                           the sheet (nothing more). The path is the rest of the step.
    ///   discardstaged:<path>    the staged row's "Discard Staged and Unstaged Changes…".
    ///   discardall              the unstaged header's "Discard All…".
    ///   discardhunk:<n>         hunk n of the diff on screen: "Discard Hunk…", or with
    ///                           `GITTER_DEBUG_SELECT_LINES` those lines of it ("Discard N
    ///                           Lines…"), or "Discard File…" where that is what it offers.
    ///                           Logs `discardhunk: offer <…>` first.
    ///   confirmdiscard          the sheet's destructive button, for the model the sheet shows;
    ///                           does nothing without the sheet.
    ///   undodiscard             the sticky notice's Undo Discard, as its button runs it
    ///                           (`RepositoryStore.perform`, a private pasteboard). Logs the
    ///                           receipts, `undodiscard: <kind> <paths> record: <sha>…`, or
    ///                           `undodiscard: no Undo Discard`.
    ///   discardstale            logs whether the sheet on screen is stale now
    ///                           (`discardSheetIsStale`: every read again, which the live
    ///                           line runs only when its fingerprint moved).
    ///
    /// The opening steps read git before the sheet goes up, in a task of their own; each waits
    /// for the sheet (or a banner) for up to ten seconds. A step that cannot be taken logs why.
    extension DebugLaunchHooks {

        static func discardStep(_ command: String, step: String, store: RepositoryStore) async {
            let rest = String(step.dropFirst(command.count + 1))
            switch command {
            case "discard":
                guard let file = store.unstagedFiles.first(where: { $0.path == rest }) else {
                    log("discard: no unstaged file \(rest)")
                    return
                }
                await awaitingSheet(store) { store.requestDiscardUnstaged([file]) }
            case "discardstaged":
                guard let file = store.stagedFiles.first(where: { $0.path == rest }) else {
                    log("discardstaged: no staged file \(rest)")
                    return
                }
                await awaitingSheet(store) { store.requestDiscardStaged(file) }
            case "discardall":
                if let reason = store.discardAllBlockedReason { log("discardall: blocked: \(reason)") }
                await awaitingSheet(store) { store.requestDiscardAllUnstaged() }
            case "discardhunk":
                guard let file = store.diff.first, let index = Int(rest), file.hunks.indices.contains(index)
                else {
                    log("discardhunk: no hunk \(rest) on screen")
                    return
                }
                let hunk = file.hunks[index]
                let own = Set(hunk.lines.map(\.id))
                let lines = lineIDs().map { $0.intersection(own) }
                let offer = HunkDiscardOffer.offer(
                    for: file, hunk: hunk.id, lines: lines, onUnstagedSide: !store.diffIsStaged)
                log("discardhunk: offer \(offer.map { "\($0) \"\($0.title)\"" } ?? "nil") lines: \(lines.map { $0.sorted() } ?? [])")
                await awaitingSheet(store) { store.requestDiscardHunk(hunk.id, lines: lines, in: file) }
            case "confirmdiscard":
                guard case .discard(let model) = store.activeSheet else {
                    log("confirmdiscard: no discard sheet")
                    return
                }
                store.confirmDiscard(model)
            case "undodiscard":
                let undo = store.stickyNotice?.actions.first {
                    if case .undoDiscard = $0 { true } else { false }
                }
                guard let undo, case .undoDiscard(let receipts) = undo else {
                    log("undodiscard: no Undo Discard")
                    return
                }
                for receipt in receipts { log("undodiscard: \(describe(receipt))") }
                let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.debug-undodiscard"))
                defer { pasteboard.releaseGlobally() }
                store.perform(undo, pasteboard: pasteboard) { _ in }
            case "discardstale":
                guard case .discard(let model) = store.activeSheet else {
                    log("discardstale: no discard sheet")
                    return
                }
                log("discardstale: \(await store.discardSheetIsStale(model))")
            default:
                log("unknown step: \(step)")
            }
        }

        /// Runs `open` and waits for a discard sheet, or a new banner saying why there is none.
        private static func awaitingSheet(_ store: RepositoryStore, _ open: () -> Void) async {
            let before = store.lastError
            open()
            let shown = await wait({
                if case .discard = store.activeSheet { return true }
                return store.lastError != before
            })
            if !shown { log("discard: no sheet after ten seconds") }
        }

        /// A request as the result line shows it: kind, paths, and for lines the count.
        static func describe(_ request: DiscardRequest) -> String {
            switch request {
            case .unstaged(let paths, _): "unstaged\(paths)"
            case .stagedAndUnstaged(let paths, _): "stagedAndUnstaged\(paths)"
            case .lines(let path, _, let count, _): "lines(\(path), \(count))"
            case .untracked(let paths, _): "untracked\(paths)"
            }
        }

        private static func describe(_ receipt: DiscardReceipt) -> String {
            "\(describe(receipt.request)) record: \(receipt.record?.sha ?? "nil") "
                + "head: \(receipt.headAtDiscard.prefix(7)) "
                + "trashed: \(receipt.trashed.sorted { $0.key < $1.key }.map { "\($0.key) -> \($0.value.path)" })"
        }
    }

#endif
