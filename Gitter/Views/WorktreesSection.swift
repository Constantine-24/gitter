import GitCore
import SwiftUI

/// The sidebar's Worktrees section (B3): every worktree `git worktree list` gives, when there is
/// more than one, each with its folder (the whole path in the tooltip), its branch or detached
/// HEAD, and its marks — this window, changes, locked, missing, the rebase or bisect there.
///
/// A double-click opens the worktree in this window, as Open Worktree does; the menu adds Reveal
/// in Finder, Copy Path, Remove Worktree… and Add Worktree… (`WorktreeMenu`), and the header's
/// Add Worktree… and Remove All Missing… (`WorktreeSectionMenu`, B3 Task 5). The section is not
/// filtered: the filter narrows branches, remote branches and tags.
struct WorktreesSection: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        if WorktreeWording.showsSection(store.worktrees) {
            Section {
                ForEach(store.worktrees) { worktree in
                    WorktreeRow(worktree: worktree, marks: store.marks(worktree))
                        .contextMenu { WorktreeMenu(worktree: worktree) }
                        // `simultaneousGesture`, as a branch row's double-click is: a single click
                        // stays the row's own.
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                store.openWorktree(worktree)
                            })
                }
            } header: {
                Text(WorktreeWording.sectionTitle)
                    .contextMenu { WorktreeSectionMenu() }
            }
        }
    }
}

/// One worktree: the folder and the branch line, the marks as icons (changes with their count),
/// and the rebase or bisect there spelled out under the branch.
struct WorktreeRow: View {
    let worktree: Worktree
    let marks: [WorktreeMark]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: worktree.isMain ? "folder.fill" : "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(WorktreeWording.folderName(worktree.path))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(worktree.isMissing ? .secondary : .primary)
                Text(secondLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            ForEach(marks, id: \.self) { mark in
                markIcon(mark)
            }
        }
        .contentShape(Rectangle())
        .help(WorktreeWording.rowHelp(worktree, marks: marks))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WorktreeWording.rowAccessibility(worktree, marks: marks))
    }

    /// The branch line, then what an operation there is doing.
    private var secondLine: String {
        let operation = marks.compactMap { mark -> String? in
            guard case .operation = mark else { return nil }
            return WorktreeWording.markText(mark)
        }
        return ([WorktreeWording.branchLine(worktree)] + operation).joined(separator: " · ")
    }

    @ViewBuilder
    private func markIcon(_ mark: WorktreeMark) -> some View {
        HStack(spacing: 2) {
            Image(systemName: WorktreeWording.markSymbol(mark))
            if case .changes = mark {
                // "3 changes" → "3": the icon says what is counted, the tooltip the rest.
                Text(WorktreeWording.markText(mark).split(separator: " ").first.map(String.init) ?? "")
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(markStyle(mark))
        .help(WorktreeWording.markHelp(mark))
    }

    private func markStyle(_ mark: WorktreeMark) -> AnyShapeStyle {
        switch mark {
        case .thisWindow: AnyShapeStyle(.tint)
        case .missing: AnyShapeStyle(.orange)
        case .changes, .changesUnknown, .locked, .operation: AnyShapeStyle(.secondary)
        }
    }
}
