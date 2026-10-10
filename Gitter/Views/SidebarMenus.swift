import AppKit
import GitCore
import SwiftUI

/// The right-click menus for the three kinds of ref in the sidebar and for a remote, and the
/// two small things they share: how a menu explains an item it has turned off, and how a name
/// reaches the pasteboard.
///
/// Every item here goes through the store, which is where the gates live — an operation in
/// progress, a detached HEAD holding commits on no ref, a busy network lane, git's own
/// refusals. A disabled item is therefore never the safety net; it is the explanation, given
/// before the click.

/// Why some of this menu's items are off, as plain (disabled) lines at the top of it.
///
/// A disabled `NSMenuItem` tracks no mouse, so a tooltip on one never appears — the finding
/// that shaped the toolbar menu in Task 7, and the reason the reason is *in* the menu. Repeats
/// are collapsed, so the branch HEAD is on explains its three dead items once rather than three
/// times.
struct MenuReasons: View {
    let reasons: [String?]

    var body: some View {
        let unique = reasons.compactMap { $0 }.reduce(into: [String]()) { result, reason in
            if !result.contains(reason) { result.append(reason) }
        }
        ForEach(unique, id: \.self) { Text($0) }
        if !unique.isEmpty { Divider() }
    }
}

enum Clipboard {
    /// `pasteboard` is always `.general` from a menu; the debug harness passes a private one of
    /// its own, so reading back what a menu item copies never overwrites the user's clipboard.
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// A local branch: switch to it, merge it in, branch from it, rename it, delete it, copy it —
/// and (B2 Task 4) push or publish it, fast-forward it, and set, change or unset its upstream,
/// whether or not it is checked out. Push and Fast-Forward act at once; Publish… and Set /
/// Change Upstream… open their sheet. Unset Upstream is only there for a branch with one.
struct LocalBranchMenu: View {
    let branch: String

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        let switchReason = store.switchBlockedReason(for: branch)
        let mergeReason = store.mergeBlockedReason(for: branch)
        let rebaseReason = store.rebaseOntoBranchBlockedReason(branch)
        let deleteReason = store.deleteBlockedReason(for: branch)
        let ref = store.localBranch(branch)
        let pushReason = store.pushBranchBlockedReason(branch)
        let fastForwardReason = store.fastForwardBlockedReason(branch)
        let upstreamReason = store.upstreamBlockedReason
        let unsetReason = ref?.upstream == nil ? nil : store.unsetUpstreamBlockedReason(branch)
        let fullRef = "refs/heads/" + branch
        let compareReason = store.compareWithCurrentBlockedReason(fullRef)
        let compareBranchesReason = store.compareBranchesBlockedReason
        let worktreeReason = store.newWorktreeBlockedReason(branch)

        MenuReasons(reasons: [
            switchReason, mergeReason, rebaseReason, deleteReason, pushReason, fastForwardReason,
            upstreamReason, unsetReason, compareReason, compareBranchesReason, worktreeReason,
        ])

        Button("Switch") { store.switchTo(branch: branch) }
            .disabled(switchReason != nil)
        // `headPhrase`, not a quoted branch name: this item and the merge sheet describe the
        // same merge, and a bare "HEAD" here where the sheet says "the detached HEAD at 1a2b3c4"
        // was the two of them disagreeing.
        Button("Merge into \(store.headPhrase)…") { store.requestMerge(branch) }
            .disabled(mergeReason != nil)
        // The full ref name: a tag spelled like the branch must not take it over (B17).
        Button(HistoryWording.rebaseMenuTitle(current: store.currentBranch, onto: branch)) {
            store.requestRebaseOnto("refs/heads/" + branch)
        }
        .disabled(rebaseReason != nil)

        Divider()

        CompareItems(ref: fullRef, reason: compareReason, branchesReason: compareBranchesReason)

        Divider()

        Button("New Branch from Here…") { store.requestNewBranch(from: branch) }
        // B3: Add Worktree… preset to this branch.
        Button(WorktreeWording.newWorktreeTitle(branch)) { store.requestAddWorktree(branch: branch) }
            .disabled(worktreeReason != nil)
        Button("Rename…") { store.requestRename(branch) }
        // Spelled with an ellipsis as the design lists it, although a branch git considers
        // merged is deleted straight away: `requestDelete` runs a plain `git branch -d`, and
        // only git's "not fully merged" refusal — which changes nothing — opens a sheet.
        Button("Delete…") { store.requestDelete(branch) }
            .disabled(deleteReason != nil)

        if let ref {
            Divider()

            Button(RemoteAdminWording.pushBranchTitle(ref, remotes: store.snapshot?.refs.remotes ?? [])) {
                store.pushBranch(branch)
            }
            .disabled(pushReason != nil)
            Button(RemoteAdminWording.fastForwardTitle(branch)) { store.fastForwardBranch(branch) }
                .disabled(fastForwardReason != nil)
            Button(RemoteAdminWording.upstreamTitle(ref)) { store.requestSetUpstream(branch) }
                .disabled(upstreamReason != nil)
            if ref.upstream != nil {
                Button(RemoteAdminWording.unsetUpstreamTitle) { store.unsetUpstream(branch) }
                    .disabled(unsetReason != nil)
            }
        }

        Divider()

        Button("Copy Name") { Clipboard.copy(branch) }
    }
}

/// A remote-tracking branch: check it out as a local branch that tracks it, branch from it,
/// copy its name — and delete it **on the remote**, the one item in these menus that writes to
/// a server. That item only opens the confirmation (`requestDeleteRemoteBranch` fetches, reads
/// the tip and counts what only it holds); nothing is deleted until the sheet's own button.
struct RemoteBranchMenu: View {
    let branch: String

    @Environment(RepositoryStore.self) private var store

    /// The remote this branch belongs to, or nil for a ref no configured remote claims.
    private var owner: Remote? {
        guard let refs = store.snapshot?.refs,
            let ref = refs.remoteBranches.first(where: { $0.name == branch })
        else { return nil }
        return refs.remote(of: ref)
    }

    var body: some View {
        let reason = store.branchSwitchingBlockedReason
        let owner = owner
        let remote = owner?.name
        // Only asked for a branch that has a remote to delete it on: a ref no configured
        // remote claims (the sidebar's "Other" group) gets no delete item at all. A remote with
        // no URL gets it disabled, with the reason (fix round 1, I1).
        let deleteReason =
            remote == nil
            ? nil : (RemoteWording.deleteOnRemoteURLBlocked(owner) ?? store.deleteRemoteBranchBlockedReason)
        let fullRef = "refs/remotes/" + branch
        let compareReason = store.compareWithCurrentBlockedReason(fullRef)
        let compareBranchesReason = store.compareBranchesBlockedReason

        MenuReasons(reasons: [reason, deleteReason, compareReason, compareBranchesReason])

        Button("Check Out as Local Branch") { store.track(remoteBranch: branch) }
            .disabled(reason != nil)
        // The full ref name, as for a local branch (B17).
        Button(HistoryWording.rebaseMenuTitle(current: store.currentBranch, onto: branch)) {
            store.requestRebaseOnto("refs/remotes/" + branch)
        }
        .disabled(reason != nil)

        Divider()

        CompareItems(ref: fullRef, reason: compareReason, branchesReason: compareBranchesReason)

        Divider()

        Button("New Branch from Here…") { store.requestNewBranch(from: branch) }

        Divider()

        Button("Copy Name") { Clipboard.copy(branch) }

        if let remote {
            Divider()

            Button(RemoteWording.deleteOnRemoteTitle(remote)) {
                store.requestDeleteRemoteBranch(branch)
            }
            .disabled(deleteReason != nil)
        }
    }
}

/// "Compare with "<current>"" and Compare Branches… on a local or remote branch's menu (B3), for
/// the branch `ref` (full). Compare Branches… presets the sheet to the current branch and this
/// one. Their reasons are in the menu's `MenuReasons`.
struct CompareItems: View {
    let ref: String
    let reason: String?
    let branchesReason: String?

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        Button(CompareWording.compareWithTitle(current: store.currentBranch)) { store.compareWithCurrent(ref) }
            .disabled(reason != nil)
        Button(CompareWording.compareBranchesTitle) {
            store.requestCompareBranches(a: store.currentBranchFullRef, b: ref)
        }
        .disabled(branchesReason != nil)
    }
}

/// A configured remote's row: fetch just that remote, prune it (B2 Task 4: lists on the lane,
/// then its sheet), edit its URLs, rename or remove it (B2 Task 5: each opens its sheet; a remote
/// with no URL gets one through Edit URL…), copy its address.
///
/// "Copy URL" copies the fetch URL. A remote with only a push URL gets "Copy Push URL" in its
/// place, so the title says which address is on the pasteboard; one whose push URL differs from
/// its fetch URL gets both. A remote with neither keeps the item, disabled, with the reason.
/// What is copied is `RemoteWording.copyableURL` of the address, never the address itself: a
/// credential in it would otherwise land on the general pasteboard.
struct RemoteMenu: View {
    let remote: Remote

    @Environment(RepositoryStore.self) private var store

    /// One "Copy …" item: its title and the text it copies, or nil text for the disabled item
    /// of a remote with no address.
    struct CopyItem: Hashable {
        let title: String
        let text: String?
    }

    /// The copy items, in menu order, with the text already redacted — the menu and the debug
    /// harness's `copyurls` step both read this, so what the step reads back is what a click
    /// copies. The push URL is compared with the fetch URL *before* redaction, so two
    /// addresses that differ only in their credential still get both items.
    static func copyItems(for remote: Remote) -> [CopyItem] {
        func item(_ title: String, _ url: String) -> CopyItem {
            CopyItem(title: title, text: RemoteWording.copyableURL(url))
        }
        if let fetchURL = remote.fetchURL {
            var items = [item(RemoteWording.copyURLTitle, fetchURL)]
            if let pushURL = remote.pushURL, pushURL != fetchURL {
                items.append(item(RemoteWording.copyPushURLTitle, pushURL))
            }
            return items
        }
        if let pushURL = remote.pushURL { return [item(RemoteWording.copyPushURLTitle, pushURL)] }
        return [CopyItem(title: RemoteWording.copyURLTitle, text: nil)]
    }

    var body: some View {
        let fetchReason = store.fetchBlockedReason
        // git would fetch from the remote's name as a path (fix round 1, I1).
        let urlReason = RemoteWording.fetchURLBlocked(remote)
        // Its list is a dry-run fetch: the same URL reason, so `MenuReasons` says it once.
        let pruneReason = store.pruneBlockedReason(remote)
        let editReason = store.editURLBlockedReason
        let renameReason = store.renameRemoteBlockedReason
        let removeReason = store.removeRemoteBlockedReason

        MenuReasons(reasons: [fetchReason, urlReason, pruneReason, editReason, renameReason, removeReason])

        Button(RemoteWording.fetchRemoteTitle(remote.name)) { store.fetch(remote: remote.name) }
            .disabled(fetchReason != nil || urlReason != nil)
        Button(RemoteAdminWording.pruneTitle(remote.name)) { store.requestPrune(remote.name) }
            .disabled(pruneReason != nil)

        Divider()

        Button(RemoteAdminWording.editURLTitle) { store.requestEditURL(remote.name) }
            .disabled(editReason != nil)
        Button(RemoteAdminWording.renameRemoteTitle) { store.requestRenameRemote(remote.name) }
            .disabled(renameReason != nil)
        Button(RemoteAdminWording.removeRemoteTitle) { store.requestRemoveRemote(remote.name) }
            .disabled(removeReason != nil)

        Divider()

        ForEach(Self.copyItems(for: remote), id: \.self) { item in
            Button(item.title) { item.text.map { Clipboard.copy($0) } }
                .disabled(item.text == nil)
        }
    }
}

/// A tag: check it out (which detaches HEAD), branch from it, copy its name, delete it — with
/// Restore Tag in the notice after — and push it to, or delete it on, each remote.
///
/// Delete Tag… and Delete from <remote>… only open their confirmation; Push Tag to <remote>
/// pushes at once — one tag, never forced, so a remote with a different tag of that name keeps
/// it. A symbolic ref under `refs/tags` gets all three disabled with the reason: a delete or
/// push that followed it would act on the branch it names.
struct TagMenu: View {
    let tag: Tag

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        let reason = store.branchSwitchingBlockedReason
        let deleteReason = store.deleteTagBlockedReason(tag)
        // Only remotes with a URL for it (fix round 1, I1).
        let remotes = RemoteWording.tagMenuRemotes(store.snapshot?.refs.remotes ?? [])
        let remoteReason = remotes.push.isEmpty ? nil : store.remoteTagBlockedReason(tag)

        MenuReasons(reasons: [reason, deleteReason, remoteReason])

        Button("Check Out (detached)") { store.detach(at: tag.name) }
            .disabled(reason != nil)

        Divider()

        Button("New Branch from Here…") { store.requestNewBranch(from: tag.name) }

        Divider()

        Button("Copy Name") { Clipboard.copy(tag.name) }

        Divider()

        Button(TagWording.deleteTagTitle) { store.requestDeleteTag(tag) }
            .disabled(deleteReason != nil)

        if !remotes.push.isEmpty {
            Divider()

            ForEach(remotes.push, id: \.self) { remote in
                Button(TagWording.pushTitle(remote: remote)) {
                    store.pushTag(tag.name, to: remote)
                }
                .disabled(remoteReason != nil)
            }
            ForEach(remotes.delete, id: \.self) { remote in
                Button(TagWording.deleteFromRemoteTitle(remote: remote)) {
                    store.requestDeleteRemoteTag(tag.name, on: remote)
                }
                .disabled(remoteReason != nil)
            }
        }
    }
}

/// A worktree's row (B3): open it in this window, show it in Finder, copy its path, remove it.
/// Open is off for this window's own worktree, a missing one and a bare repository, Reveal for a
/// missing one, and Remove Worktree… for the main and this window's own, each with the reason at
/// the top. Copy Path copies the path exactly as git lists it. A missing worktree's menu also
/// has Remove All Missing…, and every row's Add Worktree… (Task 5). A linked worktree this window
/// does not show also has Open in New Window (E2 Task 4), routed as an open: its own window, or
/// the one already showing it brought to the front.
struct WorktreeMenu: View {
    let worktree: Worktree

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        let openReason = store.openWorktreeBlockedReason(worktree)
        let revealReason = WorktreeWording.revealBlocked(worktree)
        let removeReason = store.removeWorktreeBlockedReason(worktree)

        MenuReasons(reasons: [openReason, revealReason, removeReason])

        Button(WorktreeWording.openTitle) { store.openWorktree(worktree) }
            .disabled(openReason != nil)
        if WorktreeWording.offersOpenInNewWindow(worktree, isOpenHere: store.isOpenHere(worktree)) {
            Button(WorktreeWording.openInNewWindowTitle) {
                store.openWorktreeInNewWindow(worktree, in: AppModel.windows)
            }
            .disabled(WorktreeWording.openInNewWindowBlocked(worktree) != nil)
        }

        Divider()

        Button(WorktreeWording.revealTitle) { store.revealWorktree(worktree) }
            .disabled(revealReason != nil)
        Button(WorktreeWording.copyPathTitle) { Clipboard.copy(worktree.path) }

        Divider()

        Button(WorktreeWording.removeTitle) { store.requestRemoveWorktree(worktree) }
            .disabled(removeReason != nil)
        if worktree.isMissing {
            Button(WorktreeWording.removeAllMissingTitle) { store.requestRemoveAllMissing() }
        }

        Divider()

        Button(WorktreeWording.addTitle) { store.requestAddWorktree(branch: nil) }
            .disabled(store.addWorktreeBlockedReason != nil)
    }
}

/// The Worktrees section header's menu (B3 Task 5): Add Worktree…, and Remove All Missing…, off
/// with its reason while no worktree's folder is missing.
struct WorktreeSectionMenu: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        let addReason = store.addWorktreeBlockedReason
        let missingReason = store.removeAllMissingBlockedReason

        MenuReasons(reasons: [addReason, missingReason])

        Button(WorktreeWording.addTitle) { store.requestAddWorktree(branch: nil) }
            .disabled(addReason != nil)
        Button(WorktreeWording.removeAllMissingTitle) { store.requestRemoveAllMissing() }
            .disabled(missingReason != nil)
    }
}

/// One commit in the list, or several selected together: cherry-pick or revert them, rebase onto
/// one; and for a single commit branch or tag from it, check it out detached, copy its sha.
///
/// `shas` are in the order the list shows them. The history items only open their sheet — the
/// plan is GitCore's, and nothing runs before its confirmation.
struct CommitMenu: View {
    let shas: [String]

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        let reason = store.branchSwitchingBlockedReason
        let historyReason = store.historyBlockedReason(for: shas)
        let rebaseReason = store.rebaseOntoCommitBlockedReason(shas)
        let single = shas.count == 1 ? shas.first : nil

        MenuReasons(reasons: [reason, historyReason, rebaseReason])

        Button(HistoryWording.menuTitle(.cherryPick, count: shas.count)) {
            store.requestHistoryAction(.cherryPick, shas: shas)
        }
        .disabled(historyReason != nil)
        Button(HistoryWording.menuTitle(.revert, count: shas.count)) {
            store.requestHistoryAction(.revert, shas: shas)
        }
        .disabled(historyReason != nil)
        Button(HistoryWording.rebaseMenuTitle(current: store.currentBranch, onto: nil)) {
            single.map { store.requestRebaseOnto($0) }
        }
        .disabled(rebaseReason != nil)

        if let sha = single {
            Divider()

            // The full sha is the start point git is given; the short one is what the sheet
            // shows, since a 40-character revision is not what the user clicked on.
            Button("New Branch from Here…") {
                store.requestNewBranch(from: sha, labelled: String(sha.prefix(7)))
            }
            // The full sha: it is what `createTag` is given (Ruling 1).
            Button(TagWording.newTagTitle) { store.requestNewTag(at: sha) }
            Button("Check Out (detached)") { store.detach(at: sha) }
                .disabled(reason != nil)

            Divider()

            Button("Copy SHA") { Clipboard.copy(sha) }
        }
    }
}

/// The menu bar's Remotes menu: Add Remote… (B2 Task 5 — the way to a first remote, which has no
/// sidebar row to right-click yet), Prune <remote>… — one item with a single remote to fetch from,
/// a submenu with several — and Clean Up Gone Branches… (B2 Task 4). Off while a sheet is up, as
/// the Repository menu's items are: a sheet is a question the user has not answered yet. `store`
/// is the front window's (E2 Task 4); with no window open every item is off, with no reason shown.
struct RemotesMenuContent: View {
    let store: RepositoryStore?

    var body: some View {
        let off = store == nil || store?.activeSheet != nil
        let addReason = store?.addRemoteBlockedReason
        let pruneReason = store?.pruneMenuBlockedReason
        let cleanUpReason = store?.cleanUpBlockedReason
        let remotes = RemoteAdminWording.prunableRemotes(store?.snapshot?.refs.remotes ?? [])

        MenuReasons(reasons: [addReason, pruneReason, cleanUpReason])

        Button(RemoteAdminWording.addRemoteTitle) { store?.requestAddRemote() }
            .disabled(off || addReason != nil)

        Divider()

        if remotes.count > 1 {
            Menu("Prune") {
                ForEach(remotes, id: \.self) { remote in
                    Button(RemoteAdminWording.pruneTitle(remote)) { store?.requestPrune(remote) }
                }
            }
            .disabled(off || pruneReason != nil)
        } else {
            Button(remotes.first.map(RemoteAdminWording.pruneTitle) ?? "Prune…") {
                remotes.first.map { store?.requestPrune($0) }
            }
            .disabled(off || pruneReason != nil || remotes.isEmpty)
        }
        Button(RemoteAdminWording.cleanUpTitle) { store?.requestCleanUpGoneBranches() }
            .disabled(off || cleanUpReason != nil)
    }
}
