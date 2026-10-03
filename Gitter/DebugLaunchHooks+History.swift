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
    /// The tags' steps (`RepositoryStore+Tags`):
    ///
    ///   newtag:<name>:<rev>[:<msg>]  New Tag… on <rev> (as for `rebaseonto:`), the field's live
    ///                          verdict logged, then Create Tag with <msg> (`\n` for a line
    ///                          break) — annotated with a message, lightweight without. The
    ///                          confirm runs whatever the field said: the store's own checks
    ///                          (and `createTag`'s) are what refuse. `newtag::<rev>` (no name)
    ///                          only opens the sheet.
    ///   deletetag:<name>       Delete Tag… on that tag as the list shows it: the sheet, or the
    ///                          refusal.
    ///   confirmdeletetag       the Delete Tag sheet's button, with the tag it shows.
    ///   restoretag             the sticky notice's Restore Tag, through `RepositoryStore.perform`.
    ///   pushtag:<name>:<remote>         Push Tag to <remote>.
    ///   deleteremotetag:<name>:<remote> Delete from <remote>…: the read on the lane, then the
    ///                          sheet (leased on the id it logs, or saying there is none).
    ///   confirmdeleteremotetag the remote delete sheet's button, with the id it shows.
    ///   tags                   every tag row as the sidebar draws it (icon, tooltip, VoiceOver
    ///                          label), its menu's items and reasons, and each listed commit's
    ///                          pills — the sidebar cannot be snapshotted (vibrancy).
    ///
    /// Each goes through the store's own entry point; the result line after it shows the sheet
    /// (every line it would draw), the notice and the banner.
    extension DebugLaunchHooks {

        static let historyCommands: Set<String> = [
            "selectcommits", "historymenu", "pick", "revert", "rebaseonto", "confirmhistory", "confirmrebase",
            "newtag", "deletetag", "confirmdeletetag", "restoretag", "pushtag", "deleteremotetag",
            "confirmdeleteremotetag", "tags",
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
            case "newtag", "deletetag", "confirmdeletetag", "restoretag", "pushtag", "deleteremotetag",
                "confirmdeleteremotetag", "tags":
                await tagStep(command, rest: rest, store: store)
            default:
                log("unknown step: \(step)")
            }
        }

        private static func tagStep(_ command: String, rest: String, store: RepositoryStore) async {
            let fields = rest.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                .map(String.init)
            let name = fields.first ?? ""
            let second = fields.count > 1 ? fields[1] : nil
            switch command {
            case "newtag":
                guard let rev = second, let sha = resolve(rev, store: store) else { return }
                let message = fields.count > 2 ? fields[2].replacingOccurrences(of: "\\n", with: "\n") : nil
                store.requestNewTag(at: sha)
                log("newtag: sheet \(describeTagSheet(store.activeSheet, store) ?? "nil")")
                // `newtag::<rev>` only opens the sheet, for a snapshot of it.
                guard !name.isEmpty else { return }
                let problem = await store.validateNewTagName(name)
                log("newtag: field \(problem.map { "\($0)" } ?? "ok") "
                    + "| line: \(TagWording.fieldMessage(problem, edited: true) ?? "nil")")
                store.confirmNewTag(name: name, message: message, at: sha)
            case "deletetag":
                guard let tag = store.tag(named: name) else {
                    log("deletetag: no tag \(name) in the list")
                    return
                }
                store.requestDeleteTag(tag)
            case "confirmdeletetag":
                guard case .deleteTag(let tag, _) = store.activeSheet else {
                    log("confirmdeletetag: no delete tag sheet")
                    return
                }
                store.confirmDeleteTag(tag)
            case "restoretag":
                let restore = store.stickyNotice?.actions.first {
                    if case .restoreTag = $0 { true } else { false }
                }
                guard let restore else {
                    log("restoretag: no Restore Tag on screen")
                    return
                }
                store.perform(restore)
            case "pushtag":
                second.map { store.pushTag(name, to: $0) }
            case "deleteremotetag":
                second.map { store.requestDeleteRemoteTag(name, on: $0) }
            case "confirmdeleteremotetag":
                guard case .deleteRemoteTag(let tagName, let remote, let id) = store.activeSheet else {
                    log("confirmdeleteremotetag: no remote delete sheet")
                    return
                }
                guard let id else {
                    log("confirmdeleteremotetag: the sheet offers nothing (no such tag there)")
                    return
                }
                store.confirmDeleteRemoteTag(tagName, on: remote, expecting: id)
            case "tags":
                logTags(store)
            default:
                log("unknown step: \(command)")
            }
        }

        /// What the sidebar's tag rows, their menus and the commit list's pills draw.
        private static func logTags(_ store: RepositoryStore) {
            let remotes = store.snapshot?.refs.remotes.map(\.name) ?? []
            for tag in store.snapshot?.refs.tags ?? [] {
                log("tag \(tag.name): icon \(TagWording.rowIcon(tag)) "
                    + "| voiceover: \(TagWording.rowAccessibility(tag)) "
                    + "| help: \(TagWording.rowHelp(tag).replacingOccurrences(of: "\n", with: " / ")) "
                    + "| objectID: \(tag.objectID) sha: \(tag.sha)")
                let delete = store.deleteTagBlockedReason(tag)
                let remote = remotes.isEmpty ? nil : store.remoteTagBlockedReason(tag)
                let items = [TagWording.deleteTagTitle] + remotes.map { TagWording.pushTitle(remote: $0) }
                    + remotes.map { TagWording.deleteFromRemoteTitle(remote: $0) }
                log("tagmenu \(tag.name): \(items) | delete: [\(delete ?? "enabled")] "
                    + "| remote: [\(remote ?? "enabled")]")
            }
            let tags = TagWording.tagsByCommit(store.snapshot?.refs.tags ?? [])
            for commit in store.snapshot?.commits ?? [] {
                let pills = TagWording.branchDecorations(commit.refs) + (tags[commit.sha] ?? []).map { "tag:\($0.name)" }
                guard !pills.isEmpty else { continue }
                log("pills \(commit.sha.prefix(7)): \(pills) | %D: \(commit.refs)")
            }
        }

        /// The three tag sheets, with every line they draw and their ids in full.
        static func describeTagSheet(_ sheet: BranchSheet?, _ store: RepositoryStore) -> String? {
            switch sheet {
            case .newTag(let sha)?:
                "newTag(sha: \(sha)) | title: \(TagWording.newTagSheetTitle) "
                    + "| \(TagWording.newTagOn(sha, subject: store.commitSubject(sha)))"
            case .deleteTag(let tag, let comesBackFrom)?:
                "deleteTag(\(tag.name), objectID: \(tag.objectID), sha: \(tag.sha), "
                    + "comesBackFrom: \(comesBackFrom)) | title: \(TagWording.deleteTitle(tag.name)) "
                    + "| \(TagWording.deleteTarget(tag, subject: store.commitSubject(tag.sha))) "
                    + "| \(TagWording.deleteRestore(tag)) | \(TagWording.comesBack(from: comesBackFrom)) "
                    + "| button: \(TagWording.deleteButton)"
            case .deleteRemoteTag(let name, let remote, let id?)?:
                "deleteRemoteTag(\(name) on \(remote), id: \(id)) "
                    + "| title: \(TagWording.deleteRemoteTitle(name, remote: remote)) "
                    + "| \(TagWording.deleteRemoteBody(remote: remote)) "
                    + "| \(TagWording.remoteRelation(name, local: store.tag(named: name), remoteID: id)) "
                    + "| button: \(TagWording.deleteOnRemoteButton(remote))"
            case .deleteRemoteTag(let name, let remote, nil)?:
                "deleteRemoteTag(\(name) on \(remote), id: nil) "
                    + "| title: \(TagWording.noRemoteTagTitle(name, remote: remote)) "
                    + "| \(TagWording.noRemoteTagBody) | button: \(TagWording.closeButton)"
            default: nil
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
