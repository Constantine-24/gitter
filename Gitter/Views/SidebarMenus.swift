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

/// A local branch: switch to it, merge it in, branch from it, rename it, delete it, copy it.
struct LocalBranchMenu: View {
    let branch: String

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        let switchReason = store.switchBlockedReason(for: branch)
        let mergeReason = store.mergeBlockedReason(for: branch)
        let rebaseReason = store.rebaseOntoBranchBlockedReason(branch)
        let deleteReason = store.deleteBlockedReason(for: branch)

        MenuReasons(reasons: [switchReason, mergeReason, rebaseReason, deleteReason])

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

        Button("New Branch from Here…") { store.requestNewBranch(from: branch) }
        Button("Rename…") { store.requestRename(branch) }
        // Spelled with an ellipsis as the design lists it, although a branch git considers
        // merged is deleted straight away: `requestDelete` runs a plain `git branch -d`, and
        // only git's "not fully merged" refusal — which changes nothing — opens a sheet.
        Button("Delete…") { store.requestDelete(branch) }
            .disabled(deleteReason != nil)

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
    private var remote: String? {
        guard let refs = store.snapshot?.refs,
            let ref = refs.remoteBranches.first(where: { $0.name == branch })
        else { return nil }
        return refs.remote(of: ref)?.name
    }

    var body: some View {
        let reason = store.branchSwitchingBlockedReason
        let remote = remote
        // Only asked for a branch that has a remote to delete it on: a ref no configured
        // remote claims (the sidebar's "Other" group) gets no delete item at all.
        let deleteReason = remote == nil ? nil : store.deleteRemoteBranchBlockedReason

        MenuReasons(reasons: [reason, deleteReason])

        Button("Check Out as Local Branch") { store.track(remoteBranch: branch) }
            .disabled(reason != nil)
        // The full ref name, as for a local branch (B17).
        Button(HistoryWording.rebaseMenuTitle(current: store.currentBranch, onto: branch)) {
            store.requestRebaseOnto("refs/remotes/" + branch)
        }
        .disabled(reason != nil)

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

/// A configured remote's row: fetch just that remote, copy its address.
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
        let urlReason =
            remote.fetchURL == nil && remote.pushURL == nil
            ? RemoteWording.remoteHasNoURL(remote.name) : nil

        MenuReasons(reasons: [fetchReason, urlReason])

        Button(RemoteWording.fetchRemoteTitle(remote.name)) { store.fetch(remote: remote.name) }
            .disabled(fetchReason != nil)

        Divider()

        ForEach(Self.copyItems(for: remote), id: \.self) { item in
            Button(item.title) { item.text.map { Clipboard.copy($0) } }
                .disabled(item.text == nil)
        }
    }
}

/// A tag: check it out (which detaches HEAD), branch from it, copy its name.
struct TagMenu: View {
    let tag: String

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        let reason = store.branchSwitchingBlockedReason

        MenuReasons(reasons: [reason])

        Button("Check Out (detached)") { store.detach(at: tag) }
            .disabled(reason != nil)

        Divider()

        Button("New Branch from Here…") { store.requestNewBranch(from: tag) }

        Divider()

        Button("Copy Name") { Clipboard.copy(tag) }
    }
}

/// One commit in the list, or several selected together: cherry-pick or revert them, rebase onto
/// one; and for a single commit branch from it, check it out detached, copy its sha.
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
            Button("Check Out (detached)") { store.detach(at: sha) }
                .disabled(reason != nil)

            Divider()

            Button("Copy SHA") { Clipboard.copy(sha) }
        }
    }
}
