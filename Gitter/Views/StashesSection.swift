import GitCore
import SwiftUI

/// The sidebar's "Stashes" section, under the branches: one row per entry, newest first, with
/// its message, the branch it was made on and when. Clicking a row shows the entry read-only
/// in the detail pane (`StashDetailView`); right-clicking offers Apply, Pop and Drop Stash….
///
/// N1: it lists the newest five (`SidebarLayout.stashLimit`), then "Show All 8 Stashes" — "Show
/// Fewer Stashes" once everything shows (`showsAllStashes`, per window, never saved). The selected
/// entry stays on screen when it is older. While the filter narrows the sidebar it lists every
/// entry whose title or branch matches, past the limit, or "No matches". It folds from its header.
///
/// Gitter's own records — the copies a discard files first — carry `arrow.uturn.backward`
/// (they are there to bring something back) instead of the tray a user's stash has.
struct StashesSection: View {
    /// The filter's rows, computed once by `SidebarView`.
    let rows: SidebarFilter.Rows

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        if rows.showsStashes {
            let list = store.stashList(rows)
            Section(isExpanded: SidebarSectionHeader.expansion(.stashes, store: store)) {
                ForEach(list.rows) { stash in
                    row(stash)
                        .contextMenu { StashMenu(stash: stash) }
                }
                if rows.stashesHaveNoMatches {
                    Text(SidebarFilter.noMatches)
                        .foregroundStyle(.secondary)
                }
                if let toggle = list.toggle {
                    Button(toggle) { store.showsAllStashes.toggle() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            } header: {
                SidebarSectionHeader(section: .stashes)
            }
        }
    }

    static func symbol(for kind: StashKind) -> String {
        switch kind {
        case .user: "tray.and.arrow.down"
        case .discarded: "arrow.uturn.backward"
        }
    }

    private func row(_ stash: Stash) -> some View {
        Button {
            store.selectFromSidebar(.stash(stash.sha))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(for: stash.kind))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(StashWording.title(stash))
                        .fontWeight(store.selection == .stash(stash.sha) ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(Self.caption(stash))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .helpIfPresent(stash.kind == .discarded ? StashWording.discardedRowHelp : nil)
    }

    /// "main · 5 minutes ago"; the date alone for an entry with no branch in its subject.
    static func caption(_ stash: Stash) -> String {
        let when = stash.date.formatted(.relative(presentation: .named))
        guard let branch = stash.branch else { return when }
        return "\(branch) · \(when)"
    }
}

/// A stash entry's menu: Apply, Pop, Drop Stash… — each off, with the reason at the top, while
/// a sheet is up, an operation is in progress or another change is running.
struct StashMenu: View {
    let stash: Stash

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        let reason = store.stashActionBlockedReason

        MenuReasons(reasons: [reason])

        Button("Apply") { store.applyStash(stash) }
            .disabled(reason != nil)
        Button("Pop") { store.popStash(stash) }
            .disabled(reason != nil)

        Divider()

        Button("Drop Stash…") { store.requestDropStash(stash) }
            .disabled(reason != nil)

        Divider()

        Button("Copy SHA") { Clipboard.copy(stash.sha) }
    }
}
