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
                        if store.isLoading {
                            ProgressView().controlSize(.small)
                        }
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
                    ErrorBanner(message: error) { store.dismissError() }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let notice = store.notice {
                    NoticeBanner(message: notice) { store.dismissNotice() }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .animation(.default, value: store.lastError)
        .animation(.default, value: store.notice)
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
