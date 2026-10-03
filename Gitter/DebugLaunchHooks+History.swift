#if DEBUG

    import Foundation
    import GitCore

    /// The history actions' steps of `GITTER_DEBUG_BRANCH_ACTION` (see `DebugLaunchHooks+Branches`
    /// for the grammar and the waiting):
    ///
    ///   selectcommits:<rev,…>  selects those commits as a set, as ⌘-clicks would
    ///                          (`RepositoryStore.selectCommits`): each <rev> is `HEAD` or a
    ///                          prefix of exactly one commit in the list. (`select:` is the
    ///                          resolver's file step.) Logs the set, the detail pane's selection
    ///                          and its "N commits selected" line.
    ///   historymenu            logs the commit menu's history items for the selection — titles
    ///                          and the reasons the disabled ones show — as `CommitMenu` builds
    ///                          them, and each local branch's "Rebase … onto …" item.
    ///   pick | revert          Cherry-Pick / Revert N Commits… on the selection: plans, then the
    ///                          sheet or the refusal.
    ///   rebaseonto:<rev>       Rebase onto…: <rev> is a full ref name (`refs/heads/x`), `HEAD`, or
    ///                          a prefix of one commit in the list (given to the store in full).
    ///                          Logs the sheet's summary with the fast-forward count.
    ///   confirmhistory         the history sheet's button, with the plan it shows.
    ///   confirmrebase          the rebase sheet's button, with the plan it shows.
    ///
    /// Each goes through the store's own entry point; the result line after it shows the sheet
    /// (every line it would draw), the notice and the banner.
    extension DebugLaunchHooks {

        static let historyCommands: Set<String> = [
            "selectcommits", "historymenu", "pick", "revert", "rebaseonto", "confirmhistory", "confirmrebase",
        ]

        static func historyStep(_ command: String, step: String, store: RepositoryStore) async {
            let rest = step.count > command.count ? String(step.dropFirst(command.count + 1)) : ""
            switch command {
            case "selectcommits":
                var shas: [String] = []
                for rev in rest.split(separator: ",").map(String.init) {
                    guard let sha = resolve(rev, store: store) else { return }
                    shas.append(sha)
                }
                store.selectCommits(shas)
                log("selectcommits: \(store.selectedCommits.map { String($0.prefix(7)) }) "
                    + "| selection: \(store.selection) "
                    + "| line: \(HistoryWording.selectionLine(store.selectedCommits.count) ?? "nil")")
            case "historymenu":
                logMenu(store)
            case "pick", "revert":
                store.requestHistoryAction(command == "pick" ? .cherryPick : .revert, shas: store.selectedCommits)
            case "rebaseonto":
                let target = rest.hasPrefix("refs/") ? rest : resolve(rest, store: store)
                guard let target else { return }
                store.requestRebaseOnto(target)
                _ = await wait({ !store.isMutating })
                if case .rebaseOnto(let plan) = store.activeSheet {
                    let incoming = await store.commitsOnlyIn(plan.target, notIn: plan.head)
                    log("rebaseonto: incoming \(incoming.map(String.init) ?? "nil") "
                        + "| summary: \(HistoryWording.rebaseSummary(plan, incoming: incoming))")
                }
            case "confirmhistory":
                guard case .historyAction(let plan) = store.activeSheet else {
                    log("confirmhistory: no history sheet")
                    return
                }
                store.confirmHistoryAction(plan)
            case "confirmrebase":
                guard case .rebaseOnto(let plan) = store.activeSheet else {
                    log("confirmrebase: no rebase sheet")
                    return
                }
                store.confirmRebaseOnto(plan)
            default:
                log("unknown step: \(step)")
            }
        }

        /// `HEAD`, or the one commit in the list whose sha starts with `rev`, in full.
        private static func resolve(_ rev: String, store: RepositoryStore) -> String? {
            let commits = store.snapshot?.commits ?? []
            if rev == "HEAD", let head = store.headSha { return head }
            let matches = commits.filter { $0.sha.hasPrefix(rev.lowercased()) }
            guard matches.count == 1, !rev.isEmpty else {
                log("resolve: \"\(rev)\" matches \(matches.count) commits in the list")
                return nil
            }
            return matches[0].sha
        }

        private static func logMenu(_ store: RepositoryStore) {
            let shas = store.selectedCommits
            let history = store.historyBlockedReason(for: shas)
            let rebase = store.rebaseOntoCommitBlockedReason(shas)
            log("historymenu: \(HistoryWording.menuTitle(.cherryPick, count: shas.count)) "
                + "/ \(HistoryWording.menuTitle(.revert, count: shas.count)) [\(history ?? "enabled")] "
                + "| \(HistoryWording.rebaseMenuTitle(current: store.currentBranch, onto: nil)) "
                + "[\(rebase ?? "enabled")] | single-commit items: \(shas.count == 1)")
            for branch in store.localBranches {
                log("historymenu branch \(branch.name): "
                    + "\(HistoryWording.rebaseMenuTitle(current: store.currentBranch, onto: branch.name)) "
                    + "[\(store.rebaseOntoBranchBlockedReason(branch.name) ?? "enabled")]")
            }
        }

        /// The two sheets, with every line they draw and the plan's shas in full.
        static func describeHistorySheet(_ sheet: BranchSheet?) -> String? {
            switch sheet {
            case .historyAction(let plan)?:
                "historyAction(\(plan.action), head: \(plan.head), headRef: \(plan.headRef.debugDescription), "
                    + "commits: \(plan.commits.map(\.sha)), leftOut: \(plan.leftOut.map(\.sha)), "
                    + "mayDrop: \(plan.mayDrop.map(\.sha)) | title: \(HistoryWording.sheetTitle(plan)) "
                    + "| order: \(HistoryWording.sheetOrder(plan)) "
                    + "| list: \(plan.commits.map(HistoryWording.commit)) "
                    + "| leftOut: \(HistoryWording.leftOut(plan) ?? "nil") "
                    + "| mayDrop: \(HistoryWording.mayDrop(plan) ?? "nil") "
                    + "| button: \(HistoryWording.confirmButton(plan.action)))"
            case .rebaseOnto(let plan)?:
                "rebaseOnto(head: \(plan.head), headRef: \(plan.headRef.debugDescription), "
                    + "target: \(plan.target), targetName: \(plan.targetName), "
                    + "replayed: \(plan.replayed.map(HistoryWording.commit)), "
                    + "flattened: \(plan.flattenedMerges), skipped: \(plan.skippedAsApplied), "
                    + "pushed: \(plan.alreadyPushed) | title: \(HistoryWording.rebaseTitle(plan)) "
                    + "| \(HistoryWording.flattened(plan.flattenedMerges) ?? "") "
                    + "\(HistoryWording.skipped(plan.skippedAsApplied, plan) ?? "") "
                    + "\(HistoryWording.alreadyPushed(plan.alreadyPushed) ?? ""))"
            default: nil
            }
        }
    }

#endif
