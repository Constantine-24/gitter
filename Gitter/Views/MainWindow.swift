import SwiftUI

/// The three-pane browser: refs, commits, detail — with the error banner and a
/// loading indicator on top.
struct MainWindow: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
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
                        if store.isLoading {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if let error = store.lastError {
                ErrorBanner(message: error) { store.dismissError() }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: store.lastError)
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
