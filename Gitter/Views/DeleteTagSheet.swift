import GitCore
import SwiftUI

/// Delete Tag…: names the tag and its commit, says how it comes back — Restore Tag in the
/// notice afterwards or on its dimmed row under Tags (tags keep no reflog, so that is the way
/// back) — and what a fetch does after it (Ruling 2: no network on open, so remotes are named
/// only when this session saw them holding this tag; a remote set to fetch no tags never).
///
/// The sheet is a snapshot of one tag: `confirmDeleteTag` hands its `objectID` to GitCore's
/// compare-and-delete, which refuses a tag that moved. A live stale line says so before the
/// click when the list shows it moved or gone.
///
/// Cancel holds `.defaultAction`, Escape closes, and Delete Tag has the destructive role and no
/// shortcut.
struct DeleteTagSheet: View {
    let tag: Tag
    let comesBackFrom: [String]
    let noTagsFrom: [String]

    @Environment(RepositoryStore.self) private var store

    private var staleReason: String? {
        let now = store.tag(named: tag.name)
        guard now?.objectID != tag.objectID else { return nil }
        return TagWording.deleteSheetStale(tag.name, isGone: now == nil)
    }

    private var busyReason: String? {
        store.isMutating ? RemoteWording.mutationBusy : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TagWording.deleteTitle(tag.name))
                .font(.headline)

            Text(TagWording.deleteTarget(tag, subject: store.commitSubject(tag.sha)))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text(TagWording.deleteRestore(tag))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text(TagWording.comesBack(from: comesBackFrom, noTags: noTagsFrom))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach([staleReason, busyReason].compactMap { $0 }, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(
                        line == staleReason ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                // No keyboard shortcut on the destructive half: Return belongs to Cancel.
                Button(TagWording.deleteButton, role: .destructive) { confirm() }
                    .foregroundStyle(.red)
                    .disabled(busyReason != nil)
                Button("Cancel") { store.activeSheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onExitCommand { store.activeSheet = nil }
    }

    private func confirm() {
        guard busyReason == nil else { return }
        store.confirmDeleteTag(tag)
    }
}
