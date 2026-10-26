import GitCore
import SwiftUI

/// A stash entry in the detail pane's top half: its header, then its files — the tracked part,
/// then the untracked part under "Untracked" — the commit detail's idiom. The diff below is
/// the shared `DiffView`, read-only: `canPartiallyStage` is false off the working copy, so no
/// hunk or line control is drawn.
struct StashDetailView: View {
    let sha: String

    @Environment(RepositoryStore.self) private var store
    /// See `WorkingCopyFileList.isFocused`.
    @FocusState private var isFocused: Bool

    private var stash: Stash? { store.stashes.first { $0.sha == sha } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            fileList
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let stash {
                HStack(spacing: 6) {
                    Image(systemName: StashesSection.symbol(for: stash.kind))
                        .foregroundStyle(.secondary)
                    Text(StashWording.title(stash))
                        .font(.headline)
                        .textSelection(.enabled)
                }
                Text(
                    "stash@{\(stash.index)} · "
                        + (stash.branch.map { "on \($0) · " } ?? "")
                        + stash.date.formatted(date: .abbreviated, time: .shortened)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(sha)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }

    private var fileList: some View {
        let contents = store.stashContents
        return List(selection: rowSelection) {
            Section {
                ForEach(contents?.tracked ?? [], id: \.id) { diff in
                    row(diff, untracked: false)
                }
            }
            if let untracked = contents?.untracked, !untracked.isEmpty {
                Section("Untracked") {
                    ForEach(untracked, id: \.id) { diff in
                        row(diff, untracked: true)
                    }
                }
            }
        }
        .listStyle(.inset)
        .focused($isFocused)
        .simultaneousGesture(TapGesture().onEnded { isFocused = true })
        .overlay {
            if contents == nil {
                ProgressView().controlSize(.small)
            } else if contents?.all.isEmpty == true {
                ContentUnavailableView("No Files", systemImage: "doc")
            }
        }
        .frame(minHeight: 140)
    }

    private func row(_ diff: FileDiff, untracked: Bool) -> some View {
        HStack(spacing: 6) {
            ChangeBadge(kind: untracked ? .untracked : Self.kind(diff.kind))
            Text(Self.label(diff))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .tag(Self.key(diff.displayPath, untracked: untracked))
    }

    private static func label(_ diff: FileDiff) -> String {
        if diff.kind == .renamed, let old = diff.oldPath, let new = diff.newPath {
            return "\(old) → \(new)"
        }
        return diff.displayPath
    }

    private static func kind(_ kind: FileDiffKind) -> ChangeKind {
        switch kind {
        case .added: .added
        case .deleted: .deleted
        case .renamed: .renamed
        case .copied: .copied
        case .modified: .modified
        }
    }

    /// Rows are keyed by part and path, so a path in both parts is two rows; the store's
    /// selection is the path, and the diff shows every part that has it.
    private static func key(_ path: String, untracked: Bool) -> String {
        (untracked ? "U:" : "T:") + path
    }

    private var rowSelection: Binding<String?> {
        Binding(
            get: {
                guard let path = store.selectedPath else { return nil }
                let inTracked = store.stashContents?.tracked.contains { $0.displayPath == path }
                return Self.key(path, untracked: inTracked != true)
            },
            set: { newValue in
                let path = newValue.map { String($0.dropFirst(2)) }
                guard path != store.selectedPath else { return }
                store.selectPath(path)
            })
    }
}
