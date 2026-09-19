import GitCore
import SwiftUI

/// The working copy as a single list: what is in the index on top, what is only in the
/// worktree below, with a button on every row that moves the file across.
///
/// A file changed on both sides appears in both sections, so a path alone cannot identify a
/// row; the selection is keyed by `"S:<path>"` / `"U:<path>"` instead, and picking a row also
/// tells the store which side to diff.
struct WorkingCopyFileList: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        List(selection: rowSelection) {
            section(
                title: "Staged",
                staged: true,
                files: store.stagedFiles,
                actionTitle: "Unstage All",
                placeholder: "Nothing staged",
                action: { store.unstageAll() }
            )
            section(
                title: "Unstaged",
                staged: false,
                files: store.unstagedFiles,
                actionTitle: "Stage All",
                placeholder: "No local changes",
                action: { store.stageAll() }
            )
        }
        .listStyle(.inset)
        // Staging the selected file moves it to the other section, which deletes the row the
        // selection points at. Both lists are watched because either can be the one the
        // selected path just left.
        .onChange(of: store.stagedFiles) { followSelection() }
        .onChange(of: store.unstagedFiles) { followSelection() }
        .onKeyPress(.space) { toggleSelected() }
    }

    // MARK: - Sections and rows

    private func section(
        title: String,
        staged: Bool,
        files: [FileStatus],
        actionTitle: String,
        placeholder: String,
        action: @escaping () -> Void
    ) -> some View {
        Section {
            if files.isEmpty {
                Text(placeholder)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            } else {
                ForEach(rows(files, staged: staged)) { row in
                    self.row(row.file, staged: row.staged)
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text("\(title) (\(files.count))")
                Spacer()
                Button(actionTitle, action: action)
                    .buttonStyle(.borderless)
                    .disabled(files.isEmpty || store.isMutating)
            }
        }
    }

    /// One row's identity. A file changed on both sides is the *same* `FileStatus` in both
    /// sections, and `FileStatus.id` is its path — so identifying rows by the file itself
    /// makes the list's two entries collide and the second one renders as the first
    /// (an unstaged row drawn with the staged row's minus button). The side is part of the
    /// identity here, as it is in the selection.
    private struct Row: Identifiable {
        let id: String
        let file: FileStatus
        let staged: Bool
    }

    private func rows(_ files: [FileStatus], staged: Bool) -> [Row] {
        files.map { Row(id: Self.id(of: $0, staged: staged), file: $0, staged: staged) }
    }

    private func row(_ file: FileStatus, staged: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                toggle(file, staged: staged)
            } label: {
                Image(systemName: staged ? "minus.circle" : "plus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(store.isMutating)
            .help(staged ? "Unstage" : "Stage")
            .accessibilityLabel(staged ? "Unstage \(file.path)" : "Stage \(file.path)")

            ChangeBadge(kind: staged ? file.staged : file.unstaged)

            Text(label(for: file))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .tag(Self.id(of: file, staged: staged))
        .contentShape(.rect)
        // Simultaneous so the list's own click-to-select still runs: the first click selects
        // the row, the second stages or unstages it.
        .simultaneousGesture(TapGesture(count: 2).onEnded { toggle(file, staged: staged) })
    }

    private func label(for file: FileStatus) -> String {
        guard let originalPath = file.originalPath else { return file.path }
        return "\(originalPath) → \(file.path)"
    }

    private static func id(of file: FileStatus, staged: Bool) -> String {
        "\(staged ? "S" : "U"):\(file.path)"
    }

    // MARK: - Acting on a row

    private func toggle(_ file: FileStatus, staged: Bool) {
        guard !store.isMutating else { return }
        if staged {
            store.unstage(file)
        } else {
            store.stage(file)
        }
    }

    /// Space bar stages or unstages the selected row, as in the row's own button.
    private func toggleSelected() -> KeyPress.Result {
        let files = store.stagedView ? store.stagedFiles : store.unstagedFiles
        guard !store.isMutating,
            let path = store.selectedPath,
            let file = files.first(where: { $0.path == path })
        else { return .ignored }
        toggle(file, staged: store.stagedView)
        return .handled
    }

    // MARK: - Selection

    private var rowSelection: Binding<String?> {
        Binding(
            get: {
                store.selectedPath.map { "\(store.stagedView ? "S" : "U"):\($0)" }
            },
            set: { newValue in
                guard let newValue, let separator = newValue.firstIndex(of: ":") else {
                    store.selectPath(nil)
                    return
                }
                let staged = newValue[newValue.startIndex] == "S"
                let path = String(newValue[newValue.index(after: separator)...])

                if path == store.selectedPath {
                    // Only the side changed. `stagedView`'s `didSet` reloads the diff by
                    // itself, and `selectPath` reloads unconditionally — calling both here
                    // would run `git diff` twice for the same file.
                    store.stagedView = staged
                } else {
                    if store.stagedView != staged { store.stagedView = staged }
                    store.selectPath(path)
                }
            }
        )
    }

    /// Keeps the selected file selected across a refresh that moved it between the sections.
    ///
    /// Lives here rather than in the store because it is about which *row* stays highlighted:
    /// the store already drops a path that vanished from the status entirely.
    private func followSelection() {
        guard let path = store.selectedPath else { return }
        let inStaged = store.stagedFiles.contains { $0.path == path }
        let inUnstaged = store.unstagedFiles.contains { $0.path == path }

        if inStaged && inUnstaged { return }  // still on both sides: leave the current one.
        guard inStaged || inUnstaged else {
            store.selectPath(nil)
            return
        }
        // Exactly one side has it now; follow the file there so the row stays selected and
        // the diff below shows the version that still exists.
        if store.stagedView != inStaged { store.stagedView = inStaged }
    }
}
