#if DEBUG

    import Foundation
    import GitCore

    /// B2 Task 4's steps of `GITTER_DEBUG_BRANCH_ACTION` (see `DebugLaunchHooks+Branches` for the
    /// grammar and the waiting):
    ///
    ///   prune:<remote>         Prune <remote>…: the list on the lane, then the sheet — logged
    ///                          with every ref and full id, the stranded count and commits, the
    ///                          holders, the default keep boxes with their names and verdicts,
    ///                          and `<remote>/HEAD`'s target — or the notice or banner.
    ///   confirmprune[:<keep>]  the prune sheet's button. With no <keep> the boxes as the sheet
    ///                          ticks them by default; `:none` keeps nothing; otherwise
    ///                          `<ref>=<name>,…` (each ref in full). The sticky notice is logged.
    ///   cleanup                Clean Up Gone Branches…: the sheet's rows (detail, ticked by
    ///                          default, where checked out, the unmerged warning) or the notice.
    ///   confirmcleanup[:<b,…>] the sheet's button with the default ticks, or with those names.
    ///   pushbranch:<b>         Push / Publish… / Re-publish of <b> from its menu.
    ///   confirmpublish:<remote> the publish sheet's button with that remote (`confirmPublish`).
    ///   ffbranch:<b>           Fast-Forward <b>.
    ///   upstream:<b>           Set / Change Upstream… of <b>: the sheet and its choices.
    ///   setupstream:<b>:<ref>  the sheet, then its button with <ref> (a full ref name).
    ///   unsetupstream:<b>      Unset Upstream.
    ///   adminmenu              every local branch's and remote's items as their menus build
    ///                          them, with the reasons the disabled ones show, each remote's
    ///                          sidebar badge and tooltip, and the menu bar's Remotes menu — the
    ///                          sidebar cannot be snapshotted.
    ///
    /// B2 Task 5's, remote management (`rest` is everything after the first colon, so a URL may
    /// hold colons; never a `;`):
    ///
    ///   prefill:<key>=<value>  what the next remote sheet's fields start with (`sheetPrefill`:
    ///                          `name`, `url`, `fetch`, `push`, `own` = 0|1) — the harness cannot
    ///                          type into a sheet (carried note 9). `prefill:clear` empties it.
    ///   addremote              Add Remote…: the sheet.
    ///   confirmaddremote:<name>=<url>[=nofetch]  its button (fetching after, unless `nofetch`).
    ///   editurl:<remote>       Edit URL…: the read, then the sheet — logged with each configured
    ///                          URL as shown, the fields' starting text, the "git connects to"
    ///                          line and the several-URLs notes.
    ///   confirmediturl[:<key>=<value>|…]  its Save with the fields as `prefill` keys say (the
    ///                          rest as the sheet starts them), through the sheet's own
    ///                          `urlToWrite` / `pushChange`.
    ///   renameremote:<remote>  Rename…: the sheet. `confirmrenameremote:<new>` its button.
    ///   removeremote:<remote>  Remove…: the impact's read, then the sheet — logged with every ref
    ///                          and full id, the stranded count, the keep defaults, and each
    ///                          sentence about upstreams, push redirects and refs left behind.
    ///   confirmremoveremote[:<keep>]  its button, `<keep>` as for `confirmprune`.
    ///
    /// Each goes through the store's own entry point; the result line after it shows the sheet,
    /// the notice and the banner.
    extension DebugLaunchHooks {

        static let remoteAdminCommands: Set<String> = [
            "prune", "confirmprune", "cleanup", "confirmcleanup", "pushbranch", "confirmpublish", "ffbranch",
            "upstream", "setupstream", "unsetupstream", "adminmenu", "prefill", "addremote", "confirmaddremote",
            "editurl", "confirmediturl", "renameremote", "confirmrenameremote", "removeremote", "confirmremoveremote",
        ]

        /// What the next remote sheet's fields start with (`prefill:`), read in the sheets' own
        /// `init` under `#if DEBUG`.
        static var sheetPrefill: [String: String] = [:]

        static func remoteAdminStep(_ command: String, step: String, store: RepositoryStore) async {
            let rest = step.count > command.count ? String(step.dropFirst(command.count + 1)) : ""
            switch command {
            case "prune":
                store.requestPrune(rest)
                _ = await wait({ store.remoteActivity == nil }, seconds: 120, what: "prune \(rest): the dry run")
                await logPruneSheet(store)
            case "confirmprune":
                guard case .prune(let plan) = store.activeSheet else {
                    log("confirmprune: no prune sheet")
                    return
                }
                let keeping: [String: String]
                switch rest {
                case "": keeping = await defaultKeeping(plan, store)
                case "none": keeping = [:]
                default: keeping = keepPairs(rest)
                }
                log("confirmprune: keeping \(keeping.sorted { $0.key < $1.key })")
                store.confirmPrune(plan, keeping: keeping)
                _ = await wait({ store.remoteActivity == nil && !store.isMutating }, seconds: 120, what: "confirmprune: the prune")
                log("notice sticky: \(store.stickyNotice?.text.replacingOccurrences(of: "\n", with: " \u{23CE} ") ?? "nil")")
            case "cleanup":
                store.requestCleanUpGoneBranches()
                _ = await wait({ !store.isMutating }, what: "cleanup: the gone branches' read")
                logCleanUpSheet(store)
            case "confirmcleanup":
                guard case .cleanUpGone(let branches) = store.activeSheet else {
                    log("confirmcleanup: no clean-up sheet")
                    return
                }
                let names = rest.isEmpty ? nil : Set(rest.split(separator: ",").map(String.init))
                let chosen = branches.filter { names?.contains($0.name) ?? RemoteAdminWording.defaultTicked($0) }
                log("confirmcleanup: \(chosen.map(\.name))")
                store.confirmCleanUp(chosen)
                _ = await wait({ !store.isMutating }, what: "confirmcleanup: the deletes")
                log("notice sticky: \(store.stickyNotice?.text.replacingOccurrences(of: "\n", with: " \u{23CE} ") ?? "nil")")
            case "pushbranch": store.pushBranch(rest)
            case "confirmpublish": store.confirmPublish(to: rest)
            case "ffbranch": store.fastForwardBranch(rest)
            case "upstream":
                store.requestSetUpstream(rest)
                logUpstreamSheet(store)
            case "setupstream":
                let fields = rest.split(separator: ":", maxSplits: 1).map(String.init)
                guard fields.count == 2 else { return }
                store.requestSetUpstream(fields[0])
                logUpstreamSheet(store)
                store.confirmSetUpstream(fields[0], to: fields[1])
            case "unsetupstream": store.unsetUpstream(rest)
            case "adminmenu": logAdminMenus(store)
            case "prefill":
                if rest == "clear" {
                    sheetPrefill = [:]
                } else if let (key, value) = pair(rest) {
                    sheetPrefill[key] = value
                }
                log("prefill: \(sheetPrefill.sorted { $0.key < $1.key })")
            default: await remoteManagementStep(command, rest: rest, store: store)
            }
        }

        /// `<key>=<value>`, split at the first `=`.
        private static func pair(_ text: some StringProtocol) -> (String, String)? {
            let parts = String(text).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }

        /// `<ref>=<name>,…`, as `confirmprune` and `confirmremoveremote` take it.
        private static func keepPairs(_ text: String) -> [String: String] {
            Dictionary(text.split(separator: ",").compactMap { pair($0) }, uniquingKeysWith: { first, _ in first })
        }

        private static func remoteManagementStep(_ command: String, rest: String, store: RepositoryStore) async {
            switch command {
            case "addremote":
                store.requestAddRemote()
            case "confirmaddremote":
                let fields = rest.split(separator: "=", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 2 else { return }
                store.confirmAddRemote(name: fields[0], url: fields[1], fetchAfter: fields.count < 3 || fields[2] != "nofetch")
                _ = await wait({ !store.isMutating }, what: "confirmaddremote: the add")
                _ = await wait({ store.remoteActivity == nil }, seconds: 120, what: "confirmaddremote: the fetch after it")
            case "editurl":
                store.requestEditURL(rest)
                _ = await wait({ !store.isMutating }, what: "editurl \(rest): the read for its sheet")
                logEditURLSheet(store)
            case "confirmediturl":
                guard case .editRemoteURL(let urls, let remote) = store.activeSheet else {
                    log("confirmediturl: no Edit URL sheet")
                    return
                }
                var fields = rest.split(separator: "|").compactMap { pair($0) }.reduce(into: [String: String]()) {
                    $0[$1.0] = $1.1
                }
                fields["fetch"] = fields["fetch"] ?? RemoteAdminWording.urlFieldStart(urls.fetch.first)
                fields["push"] =
                    fields["push"] ?? (urls.push.count == 1 ? RemoteAdminWording.urlFieldStart(urls.push.first) : "")
                let own = fields["own"].map { $0 == "1" } ?? !urls.push.isEmpty
                let fetch = RemoteAdminWording.urlToWrite(field: fields["fetch"] ?? "", configured: urls.fetch.first)
                let push = RemoteAdminWording.pushChange(ownPushURL: own, field: fields["push"] ?? "", configured: urls.push)
                log("confirmediturl: fetch=\(RemoteAdminWording.displayURL(fetch)) push=\(describe(push)) "
                    + "writes=\(RemoteAdminWording.editURLWrites(urls, fetch: fetch, push: push)) "
                    + "problem=\(RemoteAdminWording.urlProblem(fetch) ?? "nil")")
                store.confirmEditURL(remote, fetch: fetch, push: push)
                _ = await wait({ !store.isMutating }, what: "confirmediturl: the write")
            case "renameremote":
                store.requestRenameRemote(rest)
                if case .renameRemote(let remote) = store.activeSheet {
                    log("rename sheet: \(RemoteAdminWording.renameRemoteSheetTitle(remote)) | "
                        + RemoteAdminWording.renameRemoteIntro(remote))
                }
            case "confirmrenameremote":
                guard case .renameRemote(let remote) = store.activeSheet else {
                    log("confirmrenameremote: no Rename sheet")
                    return
                }
                let problem = await store.remoteNameProblem(rest)
                log("confirmrenameremote: \(remote) → \(rest), verdict=\(problem.map(RemoteAdminWording.remoteNameProblem) ?? "ok")")
                store.confirmRenameRemote(remote, to: rest)
                _ = await wait({ store.remoteActivity == nil && !store.isMutating }, seconds: 120, what: "confirmrenameremote: the rename")
            case "removeremote":
                store.requestRemoveRemote(rest)
                _ = await wait({ !store.isMutating }, what: "removeremote \(rest): the read for its sheet")
                await logRemoveSheet(store)
            case "confirmremoveremote":
                guard case .removeRemote(let impact) = store.activeSheet else {
                    log("confirmremoveremote: no Remove sheet")
                    return
                }
                let keeping: [String: String]
                switch rest {
                case "":
                    let defaults = await store.removeKeepDefaults(impact)
                    keeping = defaults.names.filter { defaults.ticked.contains($0.key) }
                case "none": keeping = [:]
                default: keeping = keepPairs(rest)
                }
                log("confirmremoveremote: keeping \(keeping.sorted { $0.key < $1.key })")
                store.confirmRemoveRemote(impact, keeping: keeping)
                _ = await wait({ store.remoteActivity == nil && !store.isMutating }, seconds: 120, what: "confirmremoveremote: the removal")
                log("notice sticky: \(store.stickyNotice?.text.replacingOccurrences(of: "\n", with: " \u{23CE} ") ?? "nil")")
            default: log("unknown step: \(command):\(rest)")
            }
        }

        private static func describe(_ change: PushURLChange) -> String {
            switch change {
            case .unchanged: "unchanged"
            case .set(let url): "set(\(RemoteAdminWording.displayURL(url)))"
            case .clear: "clear"
            }
        }

        private static func logEditURLSheet(_ store: RepositoryStore) {
            guard case .editRemoteURL(let urls, let remote) = store.activeSheet else { return }
            log("editurl sheet: \(RemoteAdminWording.editURLSheetTitle(remote)) "
                + "| fetch: \(urls.fetch.map(RemoteAdminWording.displayURL)) "
                + "| push: \(urls.push.map(RemoteAdminWording.displayURL)) "
                + "| fetch field starts: \"\(RemoteAdminWording.urlFieldStart(urls.fetch.first))\" "
                + "| hides credential: \(urls.fetch.first.map(RemoteAdminWording.hidesCredential) ?? false) "
                + "| connects: \(RemoteAdminWording.connectsTo(urls) ?? "nil") "
                + "| several fetch: \(RemoteAdminWording.severalFetchURLs(urls, remote: remote) ?? "nil") "
                + "| several push: \(RemoteAdminWording.severalPushURLs(urls, remote: remote) ?? "nil")")
        }

        private static func logRemoveSheet(_ store: RepositoryStore) async {
            guard case .removeRemote(let impact) = store.activeSheet else { return }
            let defaults = await store.removeKeepDefaults(impact)
            log("remove sheet: \(RemoteAdminWording.removeIntro(impact))")
            for tip in impact.refs { log("remove ref: \(tip.ref) \(tip.id)") }
            log("remove stranded: \(RemoteAdminWording.stranded(impact.stranded)) count=\(impact.stranded.count) "
                + "holders=\(impact.stranded.holders)")
            for ref in impact.stranded.holders {
                log("remove keep: \(ref) ticked=\(defaults.ticked.contains(ref)) name=\(defaults.names[ref] ?? "")")
            }
            log("remove upstreams: \(RemoteAdminWording.removeUpstreams(impact) ?? "nil")")
            for line in RemoteAdminWording.removePushRedirects(impact) { log("remove push: \(line)") }
            log("remove left behind: \(RemoteAdminWording.removeLeftBehind(impact) ?? "nil")")
        }

        /// What the sheet ticks by default: the holders `pruneKeepDefaults` ticks, with its names.
        private static func defaultKeeping(_ plan: PrunePlan, _ store: RepositoryStore) async -> [String: String] {
            let defaults = await store.pruneKeepDefaults(plan)
            return defaults.names.filter { defaults.ticked.contains($0.key) }
        }

        private static func logPruneSheet(_ store: RepositoryStore) async {
            guard case .prune(let plan) = store.activeSheet else { return }
            let defaults = await store.pruneKeepDefaults(plan)
            let head = await store.remoteHEADTarget(plan.remote)
            log("prune sheet: \(RemoteAdminWording.pruneSheetIntro(plan))")
            for tip in plan.refs { log("prune ref: \(tip.ref) \(tip.id)") }
            log("prune stranded: \(RemoteAdminWording.stranded(plan.stranded)) count=\(plan.stranded.count) "
                + "holders=\(plan.stranded.holders) more=\(RemoteAdminWording.strandedMore(plan.stranded) ?? "nil")")
            for commit in plan.stranded.commits { log("prune commit: \(commit.sha) \(commit.subject)") }
            for ref in plan.stranded.holders {
                let name = defaults.names[ref] ?? ""
                let problem = await store.keepNameProblem(name, duplicate: false)
                log("prune keep: \(ref) ticked=\(defaults.ticked.contains(ref)) name=\(name) "
                    + "verdict=\(problem ?? "ok")")
            }
            let dangling = RemoteAdminWording.prunesHEADTarget(target: head, refs: plan.refs)
            log("prune HEAD: \(head ?? "nil") | line: "
                + "\(dangling ? RemoteAdminWording.danglingHEAD(remote: plan.remote, target: head ?? "") : "nil")")
        }

        private static func logCleanUpSheet(_ store: RepositoryStore) {
            guard case .cleanUpGone(let branches) = store.activeSheet else { return }
            log("cleanup sheet: \(RemoteAdminWording.cleanUpIntro(branches.count))")
            for gone in branches {
                log("cleanup row: \(gone.name) tip=\(gone.tip) | \(RemoteAdminWording.goneRowDetail(gone)) "
                    + "| ticked=\(RemoteAdminWording.defaultTicked(gone)) "
                    + "| checkedOut=\(RemoteAdminWording.checkedOut(gone) ?? "nil") "
                    + "| warning=\(RemoteAdminWording.unmergedWarning(gone) ?? "nil")")
            }
        }

        private static func logUpstreamSheet(_ store: RepositoryStore) {
            guard case .upstream(let branch, let current) = store.activeSheet, let refs = store.snapshot?.refs else {
                return
            }
            let remote = refs.remotes.flatMap { remote in refs.branches(of: remote).map { "refs/remotes/" + $0.name } }
            let local = refs.localBranches.filter { $0.name != branch }.map { "refs/heads/" + $0.name }
            log("upstream sheet: \(RemoteAdminWording.upstreamSheetTitle(branch, current: current)) "
                + "| \(RemoteAdminWording.upstreamNow(current)) | choices: \(remote + local)")
        }

        private static func logAdminMenus(_ store: RepositoryStore) {
            let remotes = store.snapshot?.refs.remotes ?? []
            for branch in store.localBranches {
                let items = [
                    (RemoteAdminWording.pushBranchTitle(branch, remotes: remotes), store.pushBranchBlockedReason(branch.name)),
                    (RemoteAdminWording.fastForwardTitle(branch.name), store.fastForwardBlockedReason(branch.name)),
                    (RemoteAdminWording.upstreamTitle(branch), store.upstreamBlockedReason),
                ] + (branch.upstream == nil
                    ? [] : [(RemoteAdminWording.unsetUpstreamTitle, store.unsetUpstreamBlockedReason(branch.name))])
                log("adminmenu \(branch.name): "
                    + items.map { "\($0.0) [\($0.1.map { "off: \($0)" } ?? "on")]" }.joined(separator: " | "))
            }
            func state(_ reason: String?) -> String { reason.map { "off: \($0)" } ?? "on" }
            for remote in remotes {
                log("adminmenu remote \(remote.name): \(RemoteAdminWording.pruneTitle(remote.name)) "
                    + "[\(state(store.pruneBlockedReason(remote)))] | \(RemoteAdminWording.editURLTitle) "
                    + "[\(state(store.editURLBlockedReason))] | \(RemoteAdminWording.renameRemoteTitle) "
                    + "[\(state(store.renameRemoteBlockedReason))] | \(RemoteAdminWording.removeRemoteTitle) "
                    + "[\(state(store.removeRemoteBlockedReason))] | sidebar badge: "
                    + "\(RemoteAdminWording.remoteBadge(remote) ?? "nil"), help: \(RemoteAdminWording.remoteHelp(remote) ?? "nil")")
            }
            log("adminmenu Remotes: \(RemoteAdminWording.addRemoteTitle) [\(state(store.addRemoteBlockedReason))] | "
                + "prune \(RemoteAdminWording.prunableRemotes(remotes)) "
                + "[\(store.pruneMenuBlockedReason.map { "off: \($0)" } ?? "on")] | "
                + "\(RemoteAdminWording.cleanUpTitle) [\(store.cleanUpBlockedReason.map { "off: \($0)" } ?? "on")]")
        }

        /// The new sheets in the result line.
        static func describeRemoteAdminSheet(_ sheet: BranchSheet?) -> String? {
            switch sheet {
            case .prune(let plan):
                "prune(\(plan.remote), refs: \(plan.refs.map { "\($0.ref)@\($0.id.prefix(7))" }), "
                    + "stranded: \(plan.stranded.count), holders: \(plan.stranded.holders))"
            case .cleanUpGone(let branches):
                "cleanUpGone(\(branches.map { "\($0.name)@\($0.tip.prefix(7)) only:\($0.uniqueCommits)" }))"
            case .upstream(let branch, let current):
                "upstream(\(branch), current: \(current ?? "nil"))"
            case .addRemote:
                "addRemote(prefill: \(sheetPrefill.sorted { $0.key < $1.key }))"
            case .editRemoteURL(let urls, let remote):
                "editRemoteURL(\(remote), fetch: \(urls.fetch.map(RemoteAdminWording.displayURL)), "
                    + "push: \(urls.push.map(RemoteAdminWording.displayURL)), "
                    + "effective: \(urls.effectiveFetch.map(RemoteAdminWording.displayURL) ?? "nil"))"
            case .renameRemote(let remote):
                "renameRemote(\(remote))"
            case .removeRemote(let impact):
                "removeRemote(\(impact.remote), refs: \(impact.refs.map { "\($0.ref)@\($0.id.prefix(7))" }), "
                    + "stranded: \(impact.stranded.count), upstreamOf: \(impact.upstreamOf), "
                    + "redirects: \(impact.pushRedirects.map { "\($0.branch)→\($0.nowPushesTo ?? "nil")" }), "
                    + "leftBehind: \(impact.leftBehind))"
            default: nil
            }
        }
    }

#endif
