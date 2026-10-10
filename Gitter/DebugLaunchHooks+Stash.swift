#if DEBUG

    import AppKit
    import Foundation
    import GitCore

    /// The stash steps of `GITTER_DEBUG_BRANCH_ACTION` (see `DebugLaunchHooks+Branches` for the
    /// grammar and the waiting):
    ///
    ///   stash:<msg>[:u]          Stash Changes… with every change (`:u` ticks Include untracked
    ///                            files): the sheet, then its Stash — the two steps a user takes.
    ///                            An empty `<msg>` is git's own default.
    ///   stashpaths:<p,p>:<msg>   the same sheet as if those files were selected, answered with
    ///                            "Selected files". The message is the rest of the step.
    ///   apply:<n>  pop:<n>       the context menu's Apply / Pop on the entry at position n.
    ///   dropstash:<n>            opens Drop Stash… for the entry at position n (nothing more).
    ///   confirmdropstash         the drop sheet's Drop Stash, for the entry the sheet names; does
    ///                            nothing without the sheet.
    ///   stashes                  logs the list: `stash@{n} <sha> <kind> branch: … untracked: …
    ///                            message: …`.
    ///   selectstash:<n>[:<path>] shows the entry in the detail pane, and that file's diff.
    ///   sheet:stash              opens Stash Changes… without answering it.
    ///   noticepop                the sticky notice's Pop Stash, as its button runs it
    ///                            (`RepositoryStore.perform`, a private pasteboard). Logs the
    ///                            entry the notice holds, `noticepop: <sha> stash@{<n>}`, or
    ///                            `noticepop: no Pop Stash`.
    ///
    /// A step that cannot be taken — no entry at n, a blocked action — logs why and does nothing.
    extension DebugLaunchHooks {

        static func stashStep(_ command: String, step: String, store: RepositoryStore) async {
            let rest = String(step.dropFirst(command.count + 1))
            switch command {
            case "stash":
                let untracked = rest.hasSuffix(":u") || rest == "u"
                let message = rest == "u" ? "" : untracked ? String(rest.dropLast(2)) : rest
                store.requestStash()
                guard case .stash = store.activeSheet else {
                    log("stash: not offered: \(store.stashBlockedReason ?? "nil")")
                    return
                }
                store.confirmStash(message: message, includeUntracked: untracked, onlySelected: false)
            case "stashpaths":
                let parts = rest.split(separator: ":", maxSplits: 1).map(String.init)
                let paths = (parts.first ?? "").split(separator: ",").map(String.init)
                store.debugRequestStash(paths: paths)
                guard case .stash = store.activeSheet else {
                    log("stashpaths: not offered: \(store.stashBlockedReason ?? "nil")")
                    return
                }
                store.confirmStash(
                    message: parts.count > 1 ? parts[1] : "", includeUntracked: false,
                    onlySelected: true)
            case "apply", "pop", "dropstash":
                guard let stash = entry(rest, store) else { return }
                if let reason = store.stashActionBlockedReason {
                    log("\(command): blocked: \(reason)")
                }
                switch command {
                case "apply": store.applyStash(stash)
                case "pop": store.popStash(stash)
                default: store.requestDropStash(stash)
                }
            case "confirmdropstash":
                guard case .dropStash(let stash) = store.activeSheet else {
                    log("confirmdropstash: no drop sheet")
                    return
                }
                store.confirmDropStash(stash)
            case "stashes":
                if store.stashes.isEmpty { log("stashes: (none)") }
                for stash in store.stashes {
                    log(
                        "stash@{\(stash.index)} \(stash.sha) \(stash.kind) "
                            + "branch: \(stash.branch ?? "nil") untracked: \(stash.hasUntrackedPart) "
                            + "message: \(stash.message)")
                }
            case "selectstash":
                let parts = rest.split(separator: ":", maxSplits: 1).map(String.init)
                guard let stash = entry(parts.first ?? "", store) else { return }
                store.select(.stash(stash.sha))
                _ = await wait({ store.stashContents != nil }, what: "selectstash: the stash's contents")
                if parts.count > 1 {
                    store.selectPath(parts[1])
                    _ = await wait({ !store.diff.isEmpty }, what: "selectstash: the diff")
                }
                let contents = store.stashContents
                log(
                    "selectstash: tracked: \(contents?.tracked.map(\.displayPath) ?? []) "
                        + "untracked: \(contents?.untracked.map(\.displayPath) ?? []) "
                        + "diff: \(store.diff.map(\.displayPath)) "
                        + "canStage: \(store.diff.contains { store.canPartiallyStage($0) })")
            case "noticepop":
                let pop = store.stickyNotice?.actions.first {
                    if case .popStash = $0 { true } else { false }
                }
                guard let pop, case .popStash(let offered) = pop else {
                    log("noticepop: no Pop Stash")
                    return
                }
                log("noticepop: \(offered.sha) stash@{\(offered.index)}")
                let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.debug-noticepop"))
                defer { pasteboard.releaseGlobally() }
                store.perform(pop, pasteboard: pasteboard) { _ in }
            default:
                log("unknown step: \(step)")
            }
        }

        private static func entry(_ position: String, _ store: RepositoryStore) -> Stash? {
            guard let index = Int(position), store.stashes.indices.contains(index) else {
                log("no stash at position \(position)")
                return nil
            }
            return store.stashes[index]
        }
    }

#endif
