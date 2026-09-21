import GitCore
import SwiftUI

/// The Merge form: which branch, into where, how much it brings in, and which of git's three
/// merge modes to use.
///
/// The sheet predicts nothing about the merge itself — whether it fast-forwards, whether it
/// conflicts, whether git will refuse it over a staged change — because only git can answer
/// those and the answer arrives as a notice or a banner. The one thing it does say up front is
/// how many commits are on the other side, which is a plain read (`commitCount(in:notIn:)`) and
/// is simply left out when it cannot be taken.
struct MergeSheet: View {
    let branch: String

    @Environment(RepositoryStore.self) private var store
    /// What the user has picked in this sheet, or nil while it still shows the remembered
    /// choice. Kept separate from `rememberedMergeMode` rather than copied into `onAppear`, so
    /// the radio group is never drawn once with the wrong mode and corrected a frame later —
    /// and so that cancelling this sheet leaves the remembered mode untouched (it is recorded
    /// where the merge is actually run, never here).
    @State private var chosen: MergeMode?
    @State private var incoming: IncomingCount = .counting

    /// What `commitCount` came back with. `.unavailable` is a real state, not an error worth a
    /// banner: the merge is still perfectly possible, there is just no number to show.
    private enum IncomingCount {
        case counting
        case counted(Int)
        case unavailable
    }

    private var mode: MergeMode { chosen ?? store.rememberedMergeMode }

    /// Why merging is off at the moment (an operation in progress), or nil. Read live rather
    /// than captured: a terminal can start a merge while this sheet is open.
    private var blockedReason: String? { store.mergeBlockedReason(for: branch) }

    private var canMerge: Bool { !store.isMutating && blockedReason == nil }

    /// What the merge merges *into*, in words. A detached HEAD is a legal target — git allows
    /// it and so does the backend — and it has no branch name to quote.
    private var into: String {
        if let current = store.currentBranch { return "\"\(current)\"" }
        if let sha = store.shortHeadSha { return "the detached HEAD at \(sha)" }
        return "HEAD"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge")
                .font(.headline)

            Text("Merging \"\(branch)\" into \(into).")
                .font(.callout)
                .foregroundStyle(.secondary)

            incomingLine
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker(selection: Binding(get: { mode }, set: { chosen = $0 })) {
                ForEach(MergeMode.allCases, id: \.self) { mode in
                    // The explanation is part of the option's own label, so each radio button
                    // carries its own sentence rather than the sheet explaining only whichever
                    // one happens to be selected.
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.title(of: mode))
                        Text(Self.explanation(of: mode))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(mode)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.radioGroup)

            if let blockedReason {
                Text(blockedReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { store.activeSheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Merge") { merge() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canMerge)
            }
        }
        .padding(20)
        // Wider than the other sheets so each mode's explanation is the one line it is written
        // as: at 420 the squash sentence wrapped, which made the three options read as unequal.
        .frame(width: 480)
        .task {
            // Cancelled with the sheet, and its answer is only ever shown, never acted on — so
            // unlike the store's own reads this needs no generation check: a repository swap
            // closes the sheet (`open()` clears `activeSheet`) and takes this task with it.
            incoming = await store.incomingCommitCount(for: branch).map { .counted($0) }
                ?? .unavailable
        }
    }

    /// "N commits in "x" are not in "main"" — with the singular spelled out, and a 0 that says
    /// what 0 means rather than reading as a bug.
    @ViewBuilder
    private var incomingLine: some View {
        switch incoming {
        case .counting:
            Text("Counting what it would bring in…")
        case .counted(0):
            Text("\(into) already has everything in \"\(branch)\".")
        case .counted(1):
            Text("1 commit in \"\(branch)\" is not in \(into).")
        case .counted(let count):
            Text("\(count) commits in \"\(branch)\" are not in \(into).")
        case .unavailable:
            Text("Gitter could not count what this merge would bring in.")
        }
    }

    private func merge() {
        guard canMerge else { return }
        // First: `merge` does not close its own sheet, and nothing it may put on screen
        // afterwards (a notice, a banner) should be cleared by this.
        store.activeSheet = nil
        store.merge(branch, mode: mode)
    }

    // MARK: - The three modes in words

    private static func title(of mode: MergeMode) -> String {
        switch mode {
        case .fastForwardIfPossible: "Fast-forward if possible"
        case .alwaysMergeCommit: "Always create a merge commit"
        case .squash: "Squash"
        }
    }

    private static func explanation(of mode: MergeMode) -> String {
        switch mode {
        case .fastForwardIfPossible:
            "Moves straight to the branch when history allows, otherwise merges."
        case .alwaysMergeCommit:
            "Records a merge commit even when a fast-forward was possible."
        case .squash:
            "Stages the combined changes as one commit. No merge commit is created."
        }
    }
}
