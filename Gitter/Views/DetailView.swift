import GitCore
import SwiftUI

/// Right-hand pane. For the working copy: the staged/unstaged file list and the commit box
/// above, the diff of the selected file below. For a commit or a stash entry: its header and
/// file list above, the diff below (read-only).
struct DetailView: View {
    @Environment(RepositoryStore.self) private var store
    /// Makes the commit's file list claim keyboard focus when it is clicked, so its selection
    /// draws in the system highlight colour rather than the unemphasized grey. Defensive and
    /// undiagnosed, exactly as in `WorkingCopyFileList.isFocused` — see the reasoning there.
    @FocusState private var isFileListFocused: Bool

    var body: some View {
        // One split view for both selections: switching to a commit and back replaces its
        // top half, not the split itself, so the divider stays where the user put it.
        VSplitView {
            top
            DiffView(diffs: store.diff, hasSelection: store.selectedPath != nil)
                .frame(minHeight: 140)
        }
    }

    @ViewBuilder
    private var top: some View {
        switch store.selection {
        case .workingCopy:
            VStack(alignment: .leading, spacing: 0) {
                // Sits above the list rather than inside it so the list itself stays a plain
                // `List` of sections.
                if let operation = store.operationInProgress { note(for: operation) }
                // The composer is sized by its content; every remaining point of the top half
                // goes to the file list.
                WorkingCopyFileList()
                    .frame(minHeight: 120)
                    .layoutPriority(1)
                Divider()
                CommitComposerView()
            }
            // The file list is as greedy as any `List`, and left alone it takes about three
            // quarters of the pane — mostly empty rows — while the diff, which is where
            // staging actually happens, gets a handful of lines. `VSplitView` places its
            // divider by the children's limits, so capping this one is what hands the rest to
            // the diff. `layoutPriority` on the diff was tried first and moved nothing.
            // The minimum keeps a few file rows and the whole commit box visible.
            .frame(minHeight: 280, maxHeight: 460)
        case .commit(let sha):
            VStack(alignment: .leading, spacing: 0) {
                commitHeader(sha)
                Divider()
                commitFileList
            }
            .frame(minHeight: 140)
        case .stash(let sha):
            StashDetailView(sha: sha)
                .frame(minHeight: 140)
        }
    }

    /// Why half the list's buttons are off, and what to do instead. The wording changes once
    /// the last conflict is staged: nothing is unmerged any more, but the operation is still
    /// open and only a commit ends it.
    ///
    /// The trailing button is the way *out*, and the only one in the app: everything else here
    /// leads forward, to a commit. It asks before it does anything — that is what its ellipsis
    /// promises — and the question it opens is `AbortSheet`.
    private func note(for operation: RepositoryOperation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(operation.note(hasConflicts: store.hasUnmergedFiles))
                .font(.callout)
                .foregroundStyle(.secondary)
                // Two, not one: the button takes about a fifth of the strip, and the longest
                // note (a rebase with conflicts, which also names `git rebase --continue`) was
                // truncated mid-sentence at 1200 points once it was there.
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(operation.abortButtonTitle) { store.requestAbort() }
                .font(.callout)
                // Not while another git write is running: this one throws work away, and the
                // sheet it opens would describe a repository mid-change.
                .disabled(store.isMutating)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Header

    @ViewBuilder
    private func commitHeader(_ sha: String) -> some View {
        if let commit = store.snapshot?.commits.first(where: { $0.sha == sha }) {
            commitHeader(commit)
        } else {
            Text(sha).font(.system(.body, design: .monospaced)).padding(8)
        }
    }

    private func commitHeader(_ commit: Commit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(commit.summary)
                .font(.headline)
                .textSelection(.enabled)
            Text("\(commit.authorName) · \(commit.authorDate.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(commit.sha)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if !commit.parents.isEmpty {
                Text("Parents: " + commit.parents.map { String($0.prefix(7)) }.joined(separator: ", "))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }

    // MARK: - File list

    private var commitFileList: some View {
        List(store.detailFiles, selection: pathBinding) { file in
            HStack(spacing: 6) {
                ChangeBadge(kind: file.staged)
                Text(file.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .tag(file.path)
        }
        .listStyle(.inset)
        .focused($isFileListFocused)
        .simultaneousGesture(TapGesture().onEnded { isFileListFocused = true })
        .overlay {
            if store.detailFiles.isEmpty {
                ContentUnavailableView("No Files", systemImage: "doc")
            }
        }
    }

    private var pathBinding: Binding<String?> {
        Binding(
            get: { store.selectedPath },
            set: { newValue in
                guard newValue != store.selectedPath else { return }
                store.selectPath(newValue)
            }
        )
    }
}

/// A single-letter badge for a `ChangeKind`, as git's status letters.
struct ChangeBadge: View {
    let kind: ChangeKind?

    var body: some View {
        Text(letter)
            .font(.system(.caption, design: .monospaced).weight(.bold))
            .frame(width: 16, height: 16)
            .background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(color)
    }

    private var letter: String {
        switch kind {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .unmerged: "U"
        case .untracked: "?"
        case .ignored: "!"
        case .unknown, nil: "·"
        }
    }

    private var color: Color {
        switch kind {
        case .added, .untracked: .green
        case .deleted: .red
        case .modified, .typeChanged: .blue
        case .renamed, .copied: .purple
        case .unmerged: .orange
        case .ignored, .unknown, nil: .secondary
        }
    }
}
