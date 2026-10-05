import GitCore
import SwiftUI

/// Remove Worktree… and Remove All Missing… (B3 Task 5): exactly what Gitter's removal check found
/// (spec, promise 2).
///
/// - While the check runs — it walks the whole worktree, 2–3 s on a large one — a progress state
///   with only Cancel, which closes the sheet and cancels the check.
/// - Then: the folder that goes, "The branch <b> stays", the ignored entries git deletes with it
///   (count and top names), a detached HEAD's own commits with a ticked keep box each
///   (`KeepBranchList`), or "its folder is gone" for a missing worktree.
/// - Every refusal is listed **in place of the button**: with any, there is no Remove.
///
/// The button hands this very check to `confirmRemoveWorktree` (or each missing worktree's to
/// `confirmRemoveMissingWorktrees`), which GitCore makes again before it creates a kept branch or
/// runs git. Cancel holds `.defaultAction`, Escape closes, and the destructive button has no
/// shortcut. Long lists scroll inside a capped height, so the title and the buttons stay on
/// screen at the default window size.
struct RemoveWorktreeSheet: View {
    /// `.checkingWorktreeRemoval`, `.removeWorktree` or `.removeMissingWorktrees`: one view for
    /// all three, so the sheet stays up — and its boxes keep their state — as the check ends.
    let sheet: BranchSheet

    @Environment(RepositoryStore.self) private var store
    /// Holder (a worktree's path) → whether its box is ticked; filled once the check is in.
    @State private var ticked: [String: Bool] = [:]
    @State private var names: [String: String] = [:]
    @State private var problems: [String: String] = [:]
    /// The `keeping` the problems above were checked for; Remove waits for it to be current.
    @State private var checked: [String: String]?
    /// The holders the defaults were read for.
    @State private var loadedFor: [RefTip]?

    /// The checks on screen; empty while checking.
    private var removals: [WorktreeRemoval] {
        switch sheet {
        case .removeWorktree(let removal): [removal]
        case .removeMissingWorktrees(let removals): removals
        default: []
        }
    }

    private var isChecking: Bool {
        if case .checkingWorktreeRemoval = sheet { true } else { false }
    }

    private var allMissing: Bool {
        switch sheet {
        case .checkingWorktreeRemoval(_, let all): all
        case .removeMissingWorktrees: true
        default: false
        }
    }

    private var holders: [RefTip] { RepositoryStore.keepHolders(removals) }
    private var loaded: Bool { loadedFor == holders }

    /// What the button hands over: ticked holder (a worktree's path) → trimmed name.
    private var keeping: [String: String] {
        KeepBranchList.keeping(holders: holders, ticked: ticked, names: names)
    }

    /// The removals Remove would remove: those the check refused nothing for.
    private var removable: [WorktreeRemoval] { removals.filter { $0.refusals.isEmpty } }

    private var blocked: Bool {
        removable.isEmpty || !loaded || checked != keeping || keeping.keys.contains { problems[$0] != nil }
            || store.sheetBusyReason != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            switch sheet {
            case .checkingWorktreeRemoval(let worktrees, let all):
                if !all, let worktree = worktrees.first { pathLine(worktree) }
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(all ? WorktreeWording.checkingMissing : WorktreeWording.checking)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .removeWorktree(let removal):
                single(removal)
            case .removeMissingWorktrees(let removals):
                missing(removals)
            default:
                EmptyView()
            }

            if !holders.isEmpty {
                KeepBranchList(
                    holders: holders, loaded: loaded, ticked: $ticked, names: $names, problems: problems,
                    checked: checked, maxRows: Self.maxRows,
                    heading: allMissing ? WorktreeWording.missingKeepHeading : WorktreeWording.keepHeading,
                    label: WorktreeWording.keepLabel)
            }

            if !isChecking, let busy = store.sheetBusyReason {
                Text(busy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                // In place of the button while anything is refused (or nothing is checked yet).
                if !isChecking && !removable.isEmpty {
                    // No keyboard shortcut on the destructive half: Return belongs to Cancel.
                    Button(buttonTitle, role: .destructive) { confirm() }
                        // The role alone draws an ordinary grey button in a macOS sheet.
                        .foregroundStyle(.red)
                        .disabled(blocked)
                }
                Button("Cancel") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onExitCommand { close() }
        .onDisappear { store.cancelWorktreeRemovalCheck() }
        // The keep boxes' defaults, once the check is in: every holder ticked.
        .task(id: isChecking ? nil : holders) {
            guard !isChecking else { return }
            let current = holders
            let defaults = store.worktreeKeepDefaults(current)
            names = defaults.names
            ticked = Dictionary(uniqueKeysWithValues: current.map { ($0.ref, defaults.ticked.contains($0.ref)) })
            loadedFor = current
        }
        // Every change to a box or a name checks the ticked names again; Remove waits for it.
        .task(id: loaded ? keeping : nil) {
            guard loaded else { return }
            let asked = keeping
            let found = await store.keepNameProblems(asked)
            guard !Task.isCancelled else { return }
            problems = found
            checked = asked
        }
    }

    /// Rows each list shows before it scrolls, as in B2's sheets (Ruling 12).
    static let maxRows = 4

    private var title: String {
        if allMissing { return WorktreeWording.removeMissingSheetTitle }
        switch sheet {
        case .checkingWorktreeRemoval(let worktrees, _): return worktrees.first.map(WorktreeWording.removeSheetTitle) ?? ""
        case .removeWorktree(let removal): return WorktreeWording.removeSheetTitle(removal.worktree)
        default: return ""
        }
    }

    private var buttonTitle: String {
        allMissing ? WorktreeWording.removeMissingButton(removable.count) : WorktreeWording.removeButton
    }

    private func pathLine(_ worktree: Worktree) -> some View {
        Text(WorktreeWording.displayPath(worktree.path))
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }

    // MARK: - One worktree

    @ViewBuilder
    private func single(_ removal: WorktreeRemoval) -> some View {
        pathLine(removal.worktree)
        if removal.refusals.isEmpty {
            paragraph(WorktreeWording.removeIntro(removal))
            if let stays = WorktreeWording.branchStays(removal) { paragraph(stays) }
            if let stranded = WorktreeWording.strandedLine(removal) {
                paragraph(stranded)
                if removal.stranded.count > 0 {
                    CommitRefList(commits: removal.stranded.commits, maxRows: Self.maxRows)
                    if let more = RemoteAdminWording.strandedMore(removal.stranded) {
                        Text(more).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let ignored = WorktreeWording.ignoredLine(removal.ignored) {
                paragraph(ignored)
                    .foregroundStyle(.orange)
            }
        } else {
            refusals(removal.refusals)
        }
    }

    /// Why it is not removed, in place of the button.
    private func refusals(_ refusals: [WorktreeRemovalRefusal]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(WorktreeWording.refusalsHeading)
                .font(.callout.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(refusals, id: \.self) { refusal in
                        Label {
                            Text(WorktreeWording.refusal(refusal))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        } icon: {
                            Image(systemName: "xmark.octagon")
                                .foregroundStyle(.red)
                        }
                        .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: refusalsHeight(refusals))
        }
    }

    /// About ninety characters to a wrapped line at this width, at most eight lines before the
    /// list scrolls.
    private func refusalsHeight(_ refusals: [WorktreeRemovalRefusal]) -> CGFloat {
        let lines = refusals.reduce(0) { $0 + WorktreeWording.refusal($1).count / 80 + 1 }
        return CGFloat(min(lines, 8)) * 17 + CGFloat(max(refusals.count - 1, 0)) * 6
    }

    // MARK: - Every missing worktree

    @ViewBuilder
    private func missing(_ removals: [WorktreeRemoval]) -> some View {
        paragraph(WorktreeWording.removeMissingIntro(removals.count))
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(removals, id: \.worktree.path) { removal in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WorktreeWording.displayPath(removal.worktree.path))
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(WorktreeWording.branchLine(removal.worktree))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(removal.refusals, id: \.self) { refusal in
                            Text(WorktreeWording.refusal(refusal))
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if removal.refusals.isEmpty, removal.stranded.count > 0,
                            let stranded = WorktreeWording.strandedLine(removal)
                        {
                            // No list follows here: the sentence ends without its colon.
                            Text(stranded.hasSuffix(":") ? stranded.dropLast() + "." : stranded)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: missingListHeight(removals))
        if removable.isEmpty {
            paragraph(WorktreeWording.noneRemovable)
                .foregroundStyle(.secondary)
        }
    }

    /// Two lines a row, and about two more for each refusal or stranded line under it (they wrap
    /// at this width), at most 220 points before the list scrolls.
    private func missingListHeight(_ removals: [WorktreeRemoval]) -> CGFloat {
        let rows = removals.reduce(CGFloat(0)) { total, removal in
            let notes = removal.refusals.count + (removal.refusals.isEmpty && removal.stranded.count > 0 ? 1 : 0)
            return total + 42 + CGFloat(notes) * 32
        }
        return min(max(rows, 42), 220)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Buttons

    private func close() {
        store.activeSheet = nil
        store.cancelWorktreeRemovalCheck()
    }

    private func confirm() {
        guard !blocked else { return }
        // Each `confirm…` reads this very sheet for what it showed and clears it itself.
        switch sheet {
        case .removeWorktree(let removal): store.confirmRemoveWorktree(removal, keeping: keeping)
        case .removeMissingWorktrees(let removals): store.confirmRemoveMissingWorktrees(removals, keeping: keeping)
        default: break
        }
    }
}
