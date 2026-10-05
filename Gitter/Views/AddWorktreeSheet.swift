import AppKit
import GitCore
import SwiftUI

/// Add Worktree… (B3 Task 5): which branch the new worktree checks out — an existing local branch
/// no worktree holds, a new branch from a start point, or a new branch tracking a remote branch —
/// and the folder it goes in.
///
/// Nothing here predicts git's answer. A new branch's name is checked by the store as New
/// Branch's is (`BranchNameValidator`); the folder is checked live, off the main actor
/// (`worktreeFolderProblem`): it must not exist or must be an empty folder, and must lie outside
/// every worktree. Add stays off until both verdicts are in **for what is on screen**, and
/// GitCore checks the branch and the folder again right before git runs. The folder starts as a
/// sibling of the main worktree's, `<main folder>-<branch>`, and follows the branch until it is
/// edited or chosen.
struct AddWorktreeSheet: View {
    /// The local branch the sheet was opened for ("New Worktree for <b>…"), or nil.
    let preset: String?

    @Environment(RepositoryStore.self) private var store
    @State private var kind: AddWorktreeKind = .existing
    @State private var existing = ""
    @State private var newName = ""
    @State private var start: RefTip?
    @State private var remote: RefTip?
    @State private var trackingName = ""
    @State private var newValidator = BranchNameValidator()
    @State private var trackingValidator = BranchNameValidator()
    @State private var folder = ""
    /// The folder was typed or chosen: it no longer follows the branch.
    @State private var folderEdited = false
    /// The folder's verdict, and the normalized text it is for.
    @State private var folderProblem: String?
    @State private var checkedFolder: String?
    @State private var loaded = false

    private var free: [String] { store.freeWorktreeBranches }

    /// The branch the worktree is for, as chosen so far.
    private var branch: String {
        switch kind {
        case .existing: existing
        case .newBranch: BranchNameValidator.trim(newName)
        case .tracking: BranchNameValidator.trim(trackingName)
        }
    }

    private var normalizedFolder: String { WorktreeWording.normalizedFolder(folder) }

    /// What Add hands over, once every part of it is chosen and vouched for.
    private var choice: AddWorktreeChoice? {
        switch kind {
        case .existing:
            return free.contains(existing) ? .existing(existing) : nil
        case .newBranch:
            guard let start, newValidator.isReady(for: newName) else { return nil }
            return .newBranch(name: BranchNameValidator.trim(newName), start: start)
        case .tracking:
            guard let remote, trackingValidator.isReady(for: trackingName) else { return nil }
            return .tracking(name: BranchNameValidator.trim(trackingName), remote: remote)
        }
    }

    private var canAdd: Bool {
        choice != nil && checkedFolder == normalizedFolder && folderProblem == nil && store.sheetBusyReason == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(WorktreeWording.addSheetTitle)
                .font(.headline)

            Picker("", selection: $kind) {
                ForEach(AddWorktreeKind.allCases, id: \.self) { kind in
                    Text(WorktreeWording.kindTitle(kind)).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(WorktreeWording.kindExplanation(kind))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                switch kind {
                case .existing: existingRows
                case .newBranch: newBranchRows
                case .tracking: trackingRows
                }
                GridRow {
                    Text(WorktreeWording.folderLabel)
                    HStack {
                        TextField("", text: $folder)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(WorktreeWording.folderLabel)
                            .onChange(of: folder) { if folder != store.defaultWorktreeFolder(for: branch) { folderEdited = true } }
                        Button(WorktreeWording.chooseFolderTitle) { chooseFolder() }
                    }
                }
                if let problem = checkedFolder == normalizedFolder ? folderProblem : nil {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let busy = store.sheetBusyReason {
                Text(busy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { store.activeSheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(WorktreeWording.addButton) { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: load)
        .onChange(of: newName) { newValidator.edited(newName, using: store) }
        .onChange(of: trackingName) { trackingValidator.edited(trackingName, using: store) }
        // The folder follows the branch until it is edited or chosen.
        .onChange(of: branch) { followBranch() }
        .onChange(of: kind) { followBranch() }
        // The live check, debounced, for the text on screen only.
        .task(id: loaded ? normalizedFolder : nil) {
            guard loaded else { return }
            let asked = normalizedFolder
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let problem = await store.worktreeFolderProblem(asked)
            guard !Task.isCancelled else { return }
            folderProblem = problem
            checkedFolder = asked
        }
    }

    @ViewBuilder
    private var existingRows: some View {
        GridRow {
            Text(WorktreeWording.branchLabel)
            if free.isEmpty {
                Text(WorktreeWording.noFreeBranches)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("", selection: $existing) {
                    ForEach(free, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private var newBranchRows: some View {
        GridRow {
            Text(WorktreeWording.newNameLabel)
            TextField("Branch name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Branch name")
        }
        if let message = newValidator.message(for: newName) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        GridRow {
            Text(WorktreeWording.startLabel)
            Picker("", selection: $start) {
                ForEach(store.worktreeStartPoints, id: \.self) { tip in
                    Text(WorktreeWording.startLabel(tip)).tag(Optional(tip))
                }
            }
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var trackingRows: some View {
        GridRow {
            Text(WorktreeWording.remoteLabel)
            if store.worktreeRemoteTips.isEmpty {
                Text(WorktreeWording.noRemoteBranches).foregroundStyle(.secondary)
            } else {
                Picker("", selection: $remote) {
                    ForEach(store.worktreeRemoteTips, id: \.self) { tip in
                        Text(WorktreeWording.startLabel(tip)).tag(Optional(tip))
                    }
                }
                .labelsHidden()
                .onChange(of: remote) { trackingName = remote.map(store.trackingName(for:)) ?? "" }
            }
        }
        GridRow {
            Text(WorktreeWording.newNameLabel)
            TextField("Branch name", text: $trackingName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Branch name")
        }
        if let message = trackingValidator.message(for: trackingName) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// The starting choices: the preset branch (or the first free one), HEAD's own start point —
    /// the current branch, or a detached HEAD's commit — and the first remote branch.
    private func load() {
        existing = preset.flatMap { free.contains($0) ? $0 : nil } ?? free.first ?? ""
        let points = store.worktreeStartPoints
        start = points.first { $0.ref == store.currentBranch.map { "refs/heads/" + $0 } } ?? points.first
        remote = store.worktreeRemoteTips.first
        trackingName = remote.map(store.trackingName(for:)) ?? ""
        newValidator.start(with: newName, using: store)
        trackingValidator.start(with: trackingName, using: store)
        folder = store.defaultWorktreeFolder(for: branch)
        folderEdited = false
        loaded = true
    }

    private func followBranch() {
        guard loaded, !folderEdited else { return }
        folder = store.defaultWorktreeFolder(for: branch)
    }

    /// An `NSOpenPanel` for a folder, which may be created there; it is checked like a typed one.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = WorktreeWording.chooseFolderMessage
        panel.directoryURL = URL(fileURLWithPath: normalizedFolder).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderEdited = true
        folder = url.path
    }

    /// Checked again rather than trusted to the disabled button: a verdict can land between the
    /// press and this call.
    private func add() {
        guard canAdd, let choice else { return }
        // `confirmAddWorktree` reads this very sheet and clears it itself.
        store.confirmAddWorktree(choice, path: normalizedFolder)
    }
}
