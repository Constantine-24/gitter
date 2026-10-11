import SwiftUI

/// The browser: the refs in the sidebar, and beside them the commits and the detail, split under
/// one toolbar strip — with the banners and a loading indicator on top, and whatever sheet the
/// store has asked for.
///
/// Two columns, not three (window polish Task 2): on macOS 26 and later each column of a
/// `NavigationSplitView` gets its own part of the toolbar and its divider runs up through the
/// title bar, so a long branch name or title in the commit column's part was drawn across that
/// divider. The commit list and the detail are an `HSplitView` inside the one detail column
/// instead, starting below the toolbar, so the toolbar is a single strip no divider runs through.
struct MainWindow: View {
    @Environment(RepositoryStore.self) private var store

    /// The height of the banners on screen (0 with none): the commits and the detail move down
    /// by it. View state, not the store's: it is layout, measured here.
    @State private var bannerHeight: CGFloat = 0

    /// Whether the sidebar is shown, for the leading hairline (shown with it, gone without it).
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    /// The sidebar filter's field has the keyboard: ⌘F sets it (`SidebarFilterCommands`, through
    /// `focusSidebarFilter`).
    @FocusState private var filterFocused: Bool

    var body: some View {
        @Bindable var store = store
        Group {
            if store.root == nil {
                emptyState
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                        // The filter (B3): its text is the store's (Ruling 2), cleared by `open()`.
                        .searchable(text: $store.sidebarFilter, placement: .sidebar, prompt: SidebarFilter.prompt)
                        .searchFocused($filterFocused)
                        // Outermost, or the split never reads it: under `.searchable` even a
                        // `min: 300` changed nothing, and the sidebar opened at 144 pt and could be
                        // dragged below 200 (measured, Task 2 review I1).
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                } detail: {
                    // The two hairlines are the toolbar strip's lower edge and the sidebar's, and
                    // what keeps the split off both: a split view touching an edge of the column
                    // is laid out under the toolbar or the sidebar, its divider then running up
                    // through the title (measured; padding by 0, a `GeometryReader`'s inset and
                    // `.safeAreaPadding` all left it there), and the sidebar's width then counted
                    // twice in the window's minimum (measured with a 144 pt sidebar: 969 pt
                    // without the hairline, 826 with it; with the 240 pt sidebar it is 922). With
                    // the sidebar hidden there is nothing to keep off, and the leading one would
                    // sit at the window's edge: it goes.
                    VStack(spacing: 0) {
                        Divider()
                        HStack(spacing: 0) {
                            if columnVisibility != .detailOnly {
                                Divider()
                            }
                            commitsAndDetail
                        }
                    }
                    // Both panes as one, under the banners: a notice or an error never covers the
                    // Working Copy row or the operation bar's Skip, Continue and Abort (fix round
                    // 1, I5), and the divider between them stays one straight line.
                    .padding(.top, bannerHeight)
                    .animation(.default, value: bannerHeight)
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
                .focusedSceneValue(\.focusSidebarFilter, SidebarFilterFocus { filterFocused = true })
                // "wt-feat (worktree of main)" for a linked worktree, the folder otherwise (B3).
                .navigationTitle(store.windowTitle)
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
            // Measured, so the commits and the detail can move down under it (`bannerHeight`): an
            // inset on the navigation split itself does not reach its columns (fix round 1, tried).
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { bannerHeight = $0 }
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

    /// The commit list and the detail side by side, with the minimums the two columns had. The
    /// divider is kept where the user leaves it across a resize, a reload and a relaunch
    /// (`SplitViewAutosave`); `HSplitView` honours the minimums but not the ideal widths, so a
    /// first launch splits the space evenly (measured).
    private var commitsAndDetail: some View {
        HSplitView {
            CommitListView()
                .frame(minWidth: 360, idealWidth: 520)
                .background(SplitViewAutosave(name: "CommitListDetail"))
            DetailView()
                .frame(minWidth: 320, idealWidth: 440)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Open a repository to get started")
                .font(.title3)
            Button("Open Repository…") { RepositoryOpener.run(front: store) }
                .keyboardShortcut("o")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What ⌘F calls to put the keyboard in the sidebar's filter field: published by the window that
/// has a repository open (`focusedSceneValue`), read by `SidebarFilterCommands`.
struct SidebarFilterFocus {
    let focus: @MainActor () -> Void
}

extension FocusedValues {
    @Entry var focusSidebarFilter: SidebarFilterFocus?
    /// The front window's store, for the menus (E2 Task 4): published by `RepositoryWindowView`
    /// for an empty window as well, kept while its sheet is up, nil with no window open (M3.3).
    @Entry var repositoryStore: RepositoryStore?
}
