import GitCore
import SwiftUI

/// Right-hand pane: the file list for the current selection above, the diff of
/// the selected file below.
struct DetailView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 0) {
                header
                fileList
            }
            .frame(minHeight: 140)

            DiffView(diffs: store.diff, hasSelection: store.selectedPath != nil)
                .frame(minHeight: 140)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        switch store.selection {
        case .workingCopy:
            @Bindable var bindableStore = store
            Picker("", selection: $bindableStore.stagedView) {
                Text("Unstaged").tag(false)
                Text("Staged").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
        case .commit(let sha):
            if let commit = store.snapshot?.commits.first(where: { $0.sha == sha }) {
                commitHeader(commit)
            } else {
                Text(sha).font(.system(.body, design: .monospaced)).padding(8)
            }
        }
        Divider()
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

    private var files: [FileStatus] {
        switch store.selection {
        case .workingCopy:
            let all = store.snapshot?.status.files ?? []
            return all.filter { store.stagedView ? $0.staged != nil : ($0.unstaged != nil) }
        case .commit:
            return store.detailFiles
        }
    }

    private var fileList: some View {
        List(files, selection: pathBinding) { file in
            HStack(spacing: 6) {
                ChangeBadge(kind: kind(of: file))
                Text(file.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .tag(file.path)
        }
        .listStyle(.inset)
        .overlay {
            if files.isEmpty {
                ContentUnavailableView("No Files", systemImage: "doc")
            }
        }
    }

    private func kind(of file: FileStatus) -> ChangeKind? {
        if case .workingCopy = store.selection, !store.stagedView {
            return file.unstaged
        }
        return file.staged
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
