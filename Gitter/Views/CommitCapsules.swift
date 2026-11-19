import GitCore
import SwiftUI

// The pills on a commit's row, shared by the History list and the search results so both draw
// them identically.

/// A small tinted capsule for one of git's `%D` branch decorations (tags are `TagCapsule`).
struct RefCapsule: View {
    let ref: String

    var body: some View {
        let isHead = ref.hasPrefix("HEAD")
        Text(ref)
            .font(.caption2)
            .fontWeight(isHead ? .bold : .regular)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.2), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }
}

/// "worktree: <folder>" on the commit another worktree's detached HEAD is at (B3, R27): `log
/// --all` shows that commit, and nothing else on its row would say why. Its own style — teal,
/// with a window icon — so it is not read as a branch or a tag.
struct WorktreeCapsule: View {
    let worktree: Worktree

    var body: some View {
        Label(WorktreeWording.pillText(worktree), systemImage: "macwindow")
            .labelStyle(TagPillLabelStyle())
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.teal.opacity(0.2), in: Capsule())
            .foregroundStyle(Color.teal)
            .help(WorktreeWording.pillHelp(worktree))
    }
}

/// A tag's pill on its commit's row, from the tag list — the same icon and tooltip as its
/// sidebar row. The icon tells it from a branch's pill whatever the accent colour is (with an
/// orange system accent the two tints are the same).
struct TagCapsule: View {
    let tag: Tag

    var body: some View {
        Label(tag.name, systemImage: TagWording.rowIcon(tag))
            .labelStyle(TagPillLabelStyle())
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.orange.opacity(0.2), in: Capsule())
            .foregroundStyle(Color.orange)
            .help(TagWording.rowHelp(tag))
            .accessibilityLabel(TagWording.rowAccessibility(tag))
    }
}

/// Icon and title close together, sized for a pill.
struct TagPillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

