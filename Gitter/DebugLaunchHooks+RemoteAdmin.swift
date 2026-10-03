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
    ///                          them, with the reasons the disabled ones show, and the menu
    ///                          bar's Remotes menu — the sidebar cannot be snapshotted.
    ///
    /// Each goes through the store's own entry point; the result line after it shows the sheet,
    /// the notice and the banner.
    extension DebugLaunchHooks {

        static let remoteAdminCommands: Set<String> = [
            "prune", "confirmprune", "cleanup", "confirmcleanup", "pushbranch", "confirmpublish", "ffbranch",
            "upstream", "setupstream", "unsetupstream", "adminmenu",
        ]

        static func remoteAdminStep(_ command: String, step: String, store: RepositoryStore) async {
            let rest = step.count > command.count ? String(step.dropFirst(command.count + 1)) : ""
            switch command {
            case "prune":
                store.requestPrune(rest)
                _ = await wait({ store.remoteActivity == nil }, seconds: 120)
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
                default:
                    keeping = Dictionary(
                        rest.split(separator: ",").compactMap { pair -> (String, String)? in
                            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                            return parts.count == 2 ? (parts[0], parts[1]) : nil
                        }, uniquingKeysWith: { first, _ in first })
                }
                log("confirmprune: keeping \(keeping.sorted { $0.key < $1.key })")
                store.confirmPrune(plan, keeping: keeping)
                _ = await wait({ store.remoteActivity == nil && !store.isMutating }, seconds: 120)
                log("notice sticky: \(store.stickyNotice?.text.replacingOccurrences(of: "\n", with: " \u{23CE} ") ?? "nil")")
            case "cleanup":
                store.requestCleanUpGoneBranches()
                _ = await wait({ !store.isMutating })
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
                _ = await wait({ !store.isMutating })
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
            default: log("unknown step: \(step)")
            }
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
            for remote in remotes {
                log("adminmenu remote \(remote.name): \(RemoteAdminWording.pruneTitle(remote.name)) "
                    + "[\(store.pruneBlockedReason(remote).map { "off: \($0)" } ?? "on")]")
            }
            log("adminmenu Remotes: prune \(RemoteAdminWording.prunableRemotes(remotes)) "
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
            default: nil
            }
        }
    }

#endif
