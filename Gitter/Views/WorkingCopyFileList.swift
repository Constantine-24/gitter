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

    /// Makes the list claim keyboard focus whenever it is clicked.
    ///
    /// Defensive, not a diagnosed fix: after a real click the user saw the row in the
    /// unemphasized grey and Space doing nothing, both of which follow from the list not
    /// holding focus — but *why* was never established, since in-process clicks fail to focus
    /// a stock SwiftUI list too. Delete this if the real cause turns up.
    @FocusState private var isFocused: Bool

    var body: some View {
        List(selection: rowSelection) {
            section(
                title: "Staged",
                staged: true,
                files: store.stagedFiles,
                actionTitle: "Unstage All",
                placeholder: "Nothing staged",
                // `git reset` would drop `MERGE_HEAD` and end the merge behind the user's
                // back — and it does so just as readily once every conflict is resolved.
                actionDisabled: store.operationInProgress != nil,
                actionHelp: store.operationInProgress?.unstagingBlockedHelp,
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
        .focused($isFocused)
        // Simultaneous so the row still selects and `primaryAction` still gets its double
        // click; a gesture, since a click on the selected row never reaches the setter below.
        .simultaneousGesture(TapGesture().onEnded { isFocused = true })
        // Staging the selected file moves it to the other section, which deletes the row the
        // selection points at. Both lists are watched because either can be the one the
        // selected path just left; `initial` covers coming back from a commit, where a path
        // selected earlier can be on the other side from whatever `stagedView` still says.
        .onChange(of: store.stagedFiles, initial: true) { followSelection() }
        .onChange(of: store.unstagedFiles) { followSelection() }
        .onKeyPress(.space) { toggleSelected() }
        // An empty menu: this is here for `primaryAction`, which is the list's own
        // double-click (and Return) handler, rather than a tap gesture racing the selection.
        .contextMenu(forSelectionType: String.self) { _ in
        } primaryAction: { keys in
            guard let key = keys.first, let row = RowKey.parse(key) else { return }
            let files = row.staged ? store.stagedFiles : store.unstagedFiles
            guard let file = files.first(where: { $0.path == row.path }) else { return }
            toggle(file, staged: row.staged)
        }
    }

    // MARK: - Sections and rows

    private func section(
        title: String,
        staged: Bool,
        files: [FileStatus],
        actionTitle: String,
        placeholder: String,
        actionDisabled: Bool = false,
        actionHelp: String? = nil,
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
                    // A disabled button still shows its tooltip, which is the only place the
                    // reason for the gate is written down next to the control itself.
                    .disabled(files.isEmpty || store.isMutating || actionDisabled, help: actionHelp)
            }
        }
    }

    /// A row's key: the side it is on plus the file's path.
    ///
    /// A file changed on both sides is the *same* `FileStatus` in both sections and
    /// `FileStatus.id` is its path, so the path alone makes the list's two entries collide
    /// and the second one renders as the first (an unstaged row drawn with the staged row's
    /// minus button). Built and taken apart in one place, since the row tag, the selection
    /// binding and the double-click action all have to agree on the format.
    private enum RowKey {
        static func make(_ path: String, staged: Bool) -> String {
            "\(staged ? "S" : "U"):\(path)"
        }

        /// A path may itself contain a colon, so only the first one separates the side.
        static func parse(_ key: String) -> (path: String, staged: Bool)? {
            guard let separator = key.firstIndex(of: ":"), separator != key.startIndex else {
                return nil
            }
            return (String(key[key.index(after: separator)...]), key.first == "S")
        }
    }

    /// One row, identified by its `RowKey`.
    private struct Row: Identifiable {
        let id: String
        let file: FileStatus
        let staged: Bool
    }

    private func rows(_ files: [FileStatus], staged: Bool) -> [Row] {
        files.map { Row(id: RowKey.make($0.path, staged: staged), file: $0, staged: staged) }
    }

    private func row(_ file: FileStatus, staged: Bool) -> some View {
        let blocked = isBlocked(file, staged: staged)
        return HStack(spacing: 6) {
            Button {
                toggle(file, staged: staged)
            } label: {
                Image(systemName: staged ? "minus.circle" : "plus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(store.isMutating || blocked, help: help(staged: staged, blocked: blocked))
            .accessibilityLabel(staged ? "Unstage \(file.path)" : "Stage \(file.path)")

            ChangeBadge(kind: staged ? file.staged : file.unstaged)

            Text(label(for: file))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        // Full width first, so the empty space to the right of a short path still belongs to
        // the row: clicking and double-clicking it hit the file, not the list's background.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .tag(RowKey.make(file.path, staged: staged))
    }

    private func label(for file: FileStatus) -> String {
        guard let originalPath = file.originalPath else { return file.path }
        return "\(originalPath) → \(file.path)"
    }

    // MARK: - Acting on a row

    /// Whether this row's button moves the file in a direction that would damage the
    /// operation under way. Only the staged side is blocked: staging with "+" is how a
    /// resolution is recorded, which is exactly what the user should be able to do here.
    ///
    /// Keyed on the operation rather than on the file's own conflict state — a resolved file
    /// does not look unmerged any more, and the row cannot say whether its resolution is fully
    /// or only partly staged. `RepositoryStore.operationInProgress` sets out which of those
    /// `git restore --staged` actually destroys and why the rule covers all of them.
    private func isBlocked(_ file: FileStatus, staged: Bool) -> Bool {
        staged && (store.operationInProgress != nil || store.isUnmerged(file))
    }

    /// The fallback covers only the impossible case of an unmerged file with no operation
    /// reported — a conflict always belongs to one.
    private func help(staged: Bool, blocked: Bool) -> String {
        guard blocked else { return staged ? "Unstage" : "Stage" }
        return store.operationInProgress?.unstagingBlockedHelp
            ?? "Resolve the conflict, then stage the file"
    }

    private func toggle(_ file: FileStatus, staged: Bool) {
        // Also the double-click and space-bar path, which reach the row without its button.
        guard !store.isMutating, !isBlocked(file, staged: staged) else { return }
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
                store.selectedPath.map { RowKey.make($0, staged: store.stagedView) }
            },
            set: { newValue in
                guard let newValue else {
                    // The list also writes nil when the selected *row* is removed, which is
                    // precisely what staging the selected file does — a moment before
                    // `followSelection` can move the selection to the other section. Keeping
                    // the path here makes that a follow rather than a loss; a deselect of a
                    // file that is no longer on either side still clears it.
                    if let path = store.selectedPath, isKnown(path) { return }
                    store.selectPath(nil)
                    return
                }
                guard let (path, staged) = RowKey.parse(newValue) else { return }

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

    private func isKnown(_ path: String) -> Bool {
        store.stagedFiles.contains { $0.path == path }
            || store.unstagedFiles.contains { $0.path == path }
    }

    /// Puts `stagedView` on the side that actually has the selected file.
    ///
    /// Runs after every refresh that moved a file between the sections, and once when the
    /// list appears — coming back from a commit, `selectedPath` survives while `stagedView`
    /// may still name the side the file is not on, which would leave the key pointing at a
    /// row that does not exist: nothing highlighted and an empty diff.
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
