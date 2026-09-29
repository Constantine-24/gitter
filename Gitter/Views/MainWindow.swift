import SwiftUI

/// The three-pane browser: refs, commits, detail — with the branch toolbar, the banners and a
/// loading indicator on top, and whatever sheet the store has asked for.
struct MainWindow: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Group {
            if store.root == nil {
                emptyState
            } else {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                } content: {
                    CommitListView()
                        .navigationSplitViewColumnWidth(min: 360, ideal: 520)
                } detail: {
                    DetailView()
                        .navigationSplitViewColumnWidth(min: 320, ideal: 440)
                }
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        BranchMenu()
                    }
                    ToolbarItem(placement: .navigation) {
                        NewBranchButton()
                    }
                    ToolbarItem(placement: .navigation) {
                        // Always there, and only hidden while idle: an item that comes and goes
                        // resizes its glass group on every reload, and a toolbar item resizing
                        // during another one's resize animation is what sent AppKit's layout
                        // into the loop it throws for (see `ActivityReveal`). Its space is kept,
                        // so the title no longer jumps either.
                        ProgressView()
                            .controlSize(.small)
                            .opacity(store.isLoading ? 1 : 0)
                            .accessibilityHidden(!store.isLoading)
                    }
                    // Trailing, apart from the branch items: these talk to the remotes, the
                    // ones on the left only to this repository.
                    ToolbarItem(placement: .primaryAction) {
                        RemoteToolbarItem(action: .fetch)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        RemoteToolbarItem(action: .pull)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        RemoteToolbarItem(action: .push)
                    }
                }
                // On the branch that has a repository, like the toolbar items: every sheet
                // asks a question about a repository, and `open()` already clears `activeSheet`
                // when one is closed or replaced. Scoping it here means a sheet cannot outlive
                // the repository it belongs to even if something sets one without a `root`.
                .sheet(item: $store.activeSheet) { sheet in
                    BranchSheetHost(sheet: sheet)
                }
            }
        }
        .overlay(alignment: .top) {
            // Stacked, not exclusive: a notice about what just worked and a banner about what
            // just failed can both be true (a rename succeeded, the switch after it did not).
            VStack(spacing: 0) {
                if let error = store.lastError {
                    ErrorBanner(message: error, actions: bannerActions) { store.dismissError() }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let notice = store.notice {
                    NoticeBanner(notice: notice, perform: { store.perform($0) }) {
                        store.dismissNotice()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                // Under the transient one: it stays while other notices come and go.
                if let sticky = store.stickyNotice {
                    NoticeBanner(notice: sticky, perform: { store.perform($0) }) {
                        store.dismissStickyNotice()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .animation(.default, value: store.lastError)
        .animation(.default, value: store.notice)
        .animation(.default, value: store.stickyNotice)
    }

    /// "Pull" and "Force Push…" beside the banner of a push the server refused for having
    /// commits this branch lacks — the one place Force Push is reachable from. "Stash and
    /// Continue" beside a switch, merge or pull refused over local changes.
    private var bannerActions: [BannerAction] {
        if store.offeredStashAndContinue != nil {
            return [
                BannerAction(
                    title: StashWording.continueButton,
                    disabledReason: store.stashAndContinueBlockedReason
                ) { store.stashAndContinue() }
            ]
        }
        guard store.bannerOffersForcePush else { return [] }
        return [
            BannerAction(title: "Pull", disabledReason: store.pullBlockedReason) {
                store.pull()
            },
            BannerAction(title: "Force Push…", disabledReason: store.pushBlockedReason) {
                store.requestForcePush()
            },
        ]
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Open a repository to get started")
                .font(.title3)
            Button("Open Repository…") { RepositoryOpener.run(store: store) }
                .keyboardShortcut("o")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
