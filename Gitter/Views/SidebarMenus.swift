import AppKit
import GitCore
import SwiftUI

/// The right-click menus for the three kinds of ref in the sidebar, and the two small things
/// they share: how a menu explains an item it has turned off, and how a name reaches the
/// pasteboard.
///
/// Every item here goes through the store, which is where the gates live — an operation in
/// progress, a detached HEAD holding commits on no ref, git's own refusals. A disabled item is
/// therefore never the safety net; it is the explanation, given before the click.

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
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A local branch: switch to it, merge it in, branch from it, rename it, delete it, copy it.
struct LocalBranchMenu: View {
    let branch: String

    @Environment(RepositoryStore.self) private var store

    /// What a merge of this branch would merge *into*. A detached HEAD is a legal target, and
    /// has no name to quote.
    private var mergeTarget: String {
        store.currentBranch.map { "\"\($0)\"" } ?? "HEAD"
    }

    var body: some View {
        let switchReason = store.switchBlockedReason(for: branch)
        let mergeReason = store.mergeBlockedReason(for: branch)
        let deleteReason = store.deleteBlockedReason(for: branch)

        MenuReasons(reasons: [switchReason, mergeReason, deleteReason])

        Button("Switch") { store.switchTo(branch: branch) }
            .disabled(switchReason != nil)
        Button("Merge into \(mergeTarget)…") { store.requestMerge(branch) }
            .disabled(mergeReason != nil)

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
/// copy its name. Nothing here deletes or renames anything on a remote — out of scope for this
/// milestone, and not something a right-click should reach.
struct RemoteBranchMenu: View {
    let branch: String

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        let reason = store.branchSwitchingBlockedReason

        MenuReasons(reasons: [reason])

        Button("Check Out as Local Branch") { store.track(remoteBranch: branch) }
            .disabled(reason != nil)

        Divider()

        Button("New Branch from Here…") { store.requestNewBranch(from: branch) }

        Divider()

        Button("Copy Name") { Clipboard.copy(branch) }
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

/// A commit in the list: branch from it, check it out detached, copy its sha.
struct CommitMenu: View {
    let sha: String

    @Environment(RepositoryStore.self) private var store

    private var shortSha: String { String(sha.prefix(7)) }

    var body: some View {
        let reason = store.branchSwitchingBlockedReason

        MenuReasons(reasons: [reason])

        // The full sha is the start point git is given; the short one is what the sheet shows,
        // since a 40-character revision is not what the user clicked on.
        Button("New Branch from Here…") { store.requestNewBranch(from: sha, labelled: shortSha) }
        Button("Check Out (detached)") { store.detach(at: sha) }
            .disabled(reason != nil)

        Divider()

        Button("Copy SHA") { Clipboard.copy(sha) }
    }
}
