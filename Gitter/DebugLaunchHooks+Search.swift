#if DEBUG

    import Foundation
    import GitCore

    /// F1's steps of `GITTER_DEBUG_BRANCH_ACTION`: commit search, driven through the store the bar
    /// and the menu call. Each step ends with one line, except where noted below:
    ///
    ///   `search: mode <m> | query "<q>" | status <s> | rows <n> | cut <b> | stale <b> |
    ///   first <short ids, up to 5> | selection <sha|nil>`
    ///
    /// (`mode` is `message`, `file` or `code`; `status` is `idle`, `searching`, `done`, `stopped` or
    /// `failed: …`; `selection` is the selected commit's full id.) A step the window refuses logs
    /// `search: blocked: <reason>` and changes nothing. With search closed (after `searchleave` or
    /// `searchshow`, or `searchstate` before any search) the line is `search: closed | selection
    /// <sha|nil>`.
    ///
    ///   search:<mode>:<query>  opens search, sets the mode and the query (a colon in the query is
    ///                          part of it), waits for the search to land, then logs. A second line,
    ///                          `search timing: <n> ms`, says how long the search took from
    ///                          the step's start to landing, the `searchDebounce` wait included.
    ///   searchselect:<n>       selects the n-th result (0-based) as the results list does
    ///                          (`selectRows`) and logs the detail's header id (`searchselect:
    ///                          detail <sha|nil>`), then the line above; with no such result it
    ///                          logs only `search: searchselect <n>: no such result`.
    ///   searchshow             Show in History on the selected result, then the line above (the
    ///                          closed form); with no commit selected it logs only
    ///                          `search: searchshow: no commit selected`.
    ///   searchstop             Stop, then the line above; with no search running (Stop acts only
    ///                          then) it first logs `search: searchstop: nothing running`.
    ///   searchagain            Search Again, waits, then the line above.
    ///   searchleave            Close Search (Esc), then the line above.
    ///   searchstate            only the line above.
    extension DebugLaunchHooks {

        static let searchCommands: Set<String> = [
            "search", "searchselect", "searchshow", "searchstop", "searchagain", "searchleave", "searchstate",
        ]

        static func searchStep(_ command: String, rest: String, store: RepositoryStore) async {
            if command != "searchstate", let reason = store.searchBlockedReason {
                return log("search: blocked: \(reason)")
            }
            switch command {
            case "search":
                let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2, let mode = searchMode(parts[0]) else {
                    return log("search: needs <message|file|code>:<query>")
                }
                let started = ContinuousClock.now
                store.openSearch()
                store.setSearchMode(mode)
                store.setSearchQuery(parts[1])
                await store.searchTask?.value
                log("search timing: \(Self.milliseconds(since: started)) ms")
                await settleSearch(store)
            case "searchselect":
                guard let n = Int(rest), let commits = store.commitSearch?.result?.commits, commits.indices.contains(n) else {
                    return log("search: searchselect \(rest): no such result")
                }
                // As the results list selects: `selectRows`, which notes the pick for leaving.
                store.selectRows([.commit(commits[n].sha)], shown: commits.map { .commit($0.sha) })
                await store.detailTask?.value
                await store.diffTask?.value
                try? await Task.sleep(for: .milliseconds(300))
                log("searchselect: detail \(store.commitForDetail(commits[n].sha)?.sha ?? "nil")")
            case "searchshow":
                guard case .commit(let sha) = store.selection else {
                    return log("search: searchshow: no commit selected")
                }
                store.showInHistory(sha)
                await store.detailTask?.value
                try? await Task.sleep(for: .milliseconds(300))
            case "searchstop":
                // Stop acts only on a search that runs; `search:` waits for its search to land.
                if store.commitSearch?.status != .searching { log("search: searchstop: nothing running") }
                store.stopSearch()
            case "searchagain":
                store.searchAgain()
                await settleSearch(store)
            case "searchleave":
                store.leaveSearch()
                await store.detailTask?.value
                try? await Task.sleep(for: .milliseconds(300))
            default:
                break
            }
            logSearch(store)
        }

        private static func searchMode(_ name: String) -> CommitSearchMode? {
            switch name {
            case "message": .messageAuthorOrID
            case "file": .file
            case "code": .code
            default: nil
            }
        }

        private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
            let elapsed = ContinuousClock.now - start
            return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        }

        /// The search's task, then the detail's, then a frame so the column has drawn.
        private static func settleSearch(_ store: RepositoryStore) async {
            await store.searchTask?.value
            await store.detailTask?.value
            try? await Task.sleep(for: .milliseconds(300))
        }

        private static func logSearch(_ store: RepositoryStore) {
            guard let state = store.commitSearch else {
                return log("search: closed | selection \(selectionSha(store))")
            }
            let mode: String =
                switch state.mode {
                case .messageAuthorOrID: "message"
                case .file: "file"
                case .code: "code"
                }
            let status: String =
                switch state.status {
                case .idle: "idle"
                case .searching: "searching"
                case .done: "done"
                case .stopped: "stopped"
                case .failed(let words): "failed: \(flatten(words))"
                }
            let commits = state.result?.commits ?? []
            log(
                "search: mode \(mode) | query \"\(state.query)\" | status \(status) | rows \(commits.count) "
                    + "| cut \(state.result?.isCut ?? false) | stale \(state.isStale) "
                    + "| first \(commits.prefix(5).map(\.shortSha).joined(separator: ",")) "
                    + "| selection \(selectionSha(store))")
        }

        private static func selectionSha(_ store: RepositoryStore) -> String {
            if case .commit(let sha) = store.selection { return sha }
            return "nil"
        }
    }

#endif
