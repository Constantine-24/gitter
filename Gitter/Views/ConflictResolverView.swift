import GitCore
import SwiftUI

/// The diff pane for a conflicted file (spec, "App"): the path, what each side did and what the
/// sides are called; then either the block chooser ("Conflict 2 of 5"), why the file is whole-
/// file only, the "changed since the conflict" state with the file as it is now, or a submodule's
/// explanation; and the actions `ResolverOffer` gives this document.
///
/// Nothing is written while the user chooses: the choices live in the store's memory, and the
/// buttons hand GitCore the snapshot this view shows. The only view state is which block is on
/// screen.
struct ConflictResolverView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var current = 0

    var body: some View {
        Group {
            if let document = store.selectedConflict {
                resolver(document)
            } else if let failure = store.conflictLoadFailure, failure.path == store.selectedPath,
                let file = store.snapshot?.status.files.first(where: { $0.path == failure.path })?.conflict
            {
                failed(failure, file)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Another file starts at its first block.
        .onChange(of: store.selectedPath) { current = 0 }
    }

    private func resolver(_ document: ConflictDocument) -> some View {
        let sides = store.conflictSides
        return VStack(alignment: .leading, spacing: 0) {
            header(document.snapshot.file, sides)
            Divider()
            ScrollView(.vertical) {
                content(document, sides)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            Divider()
            actions(document, sides)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// The third state (B4 item 4): the read failed. Git's words, and the actions that need no
    /// document — Mark Resolved through the row's own entry, which takes its own snapshot.
    private func failed(_ failure: ConflictLoadFailure, _ file: ConflictedFile) -> some View {
        let sides = store.conflictSides
        let blocked = store.conflictActionBlockedReason
        return VStack(alignment: .leading, spacing: 0) {
            header(file, sides)
            Divider()
            ScrollView(.vertical) {
                note(ConflictWording.loadFailed(failure.message), systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            Divider()
            HStack(spacing: 8) {
                Button(ConflictWording.title(.openInEditor, file)) { store.openInEditor(file.path) }
                    .disabled(blocked != nil, help: blocked ?? ConflictWording.help(.openInEditor, file, sides))
                if file.kind != .bothDeleted {
                    Button(ConflictWording.title(.markResolved, file)) { store.markResolved(file) }
                        .disabled(blocked != nil, help: blocked ?? ConflictWording.help(.markResolved, file, sides))
                }
                Spacer().frame(width: 8)
                Button(ConflictWording.tryAgain) { store.loadConflict() }
                Spacer(minLength: 0)
            }
            .controlSize(.regular)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Header

    private func header(_ file: ConflictedFile, _ sides: SideLabels) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(file.path)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Text(ConflictWording.kind(file, sides: sides))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                legend(ConflictWording.side(.ours, sides), .blue)
                legend(ConflictWording.side(.theirs, sides), .purple)
            }
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legend(_ text: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(text).lineLimit(1).truncationMode(.tail)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ document: ConflictDocument, _ sides: SideLabels) -> some View {
        let path = document.snapshot.file.path
        switch document.presentation {
        case .submodule:
            note(ConflictWording.submodule, systemImage: "shippingbox")
        case .wholeFile(let reason):
            VStack(alignment: .leading, spacing: 8) {
                note(ConflictWording.wholeFile(reason), systemImage: "doc")
                if !document.matchesGitsConflict, document.worktree != nil {
                    note(ConflictWording.replaceBody(path), systemImage: "pencil")
                }
            }
        case .blocks:
            if let blocks = ResolverOffer.blocks(of: document), !blocks.isEmpty {
                chooser(blocks, sides)
            } else {
                changedSince(document)
            }
        }
    }

    private func note(_ text: String, systemImage: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func chooser(_ blocks: [ConflictBlock], _ sides: SideLabels) -> some View {
        let index = min(max(current, 0), blocks.count - 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    current = index - 1
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(index == 0)
                .help(ConflictWording.previous)
                .accessibilityLabel(ConflictWording.previous)
                Text(ConflictWording.position(index, of: blocks.count))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Button {
                    current = index + 1
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(index == blocks.count - 1)
                .help(ConflictWording.next)
                .accessibilityLabel(ConflictWording.next)
                Spacer()
                Text(ConflictWording.chosen(store.blockChoices.count, of: blocks.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ConflictBlockView(
                block: blocks[index], sides: sides, choice: store.blockChoices[index],
                onChoose: { store.chooseBlock(index, $0) }
            )
            // A fresh disclosure for each block: the base of one is not the base of another.
            .id(index)
        }
    }

    private func changedSince(_ document: ConflictDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            note(ConflictWording.changedSinceConflict(document.snapshot.file.path), systemImage: "pencil")
            if let worktree = document.worktree {
                Text(ConflictWording.currentFile)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(ResolverPreview.text(worktree))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    // MARK: - Actions

    private func actions(_ document: ConflictDocument, _ sides: SideLabels) -> some View {
        let file = document.snapshot.file
        let offered = ResolverOffer.actions(for: document)
        let blocked = store.conflictActionBlockedReason
        return HStack(spacing: 8) {
            ForEach(offered, id: \.self) { action in
                let reason = reason(action, blocked: blocked)
                Button(ConflictWording.title(action, file)) { perform(action, file.path) }
                    .disabled(reason != nil, help: reason ?? ConflictWording.help(action, file, sides))
                if action == .resolveFile { Spacer().frame(width: 8) }
            }
            Spacer(minLength: 0)
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Why a button is off: a sheet or another change, or — for Resolve File — a block without a
    /// choice.
    private func reason(_ action: ResolverAction, blocked: String?) -> String? {
        if let blocked { return blocked }
        if action == .resolveFile, store.resolverChoices.ordered == nil {
            return ConflictWording.resolveHelp(remaining: store.resolverChoices.remaining)
        }
        return nil
    }

    private func perform(_ action: ResolverAction, _ path: String) {
        switch action {
        case .resolveFile: store.resolveSelectedFile()
        case .takeOurs: store.takeSide(.ours)
        case .takeTheirs: store.takeSide(.theirs)
        case .delete: store.deleteConflictedFile()
        case .keep: store.keepConflictedFile()
        case .openInEditor: store.openInEditor(path)
        case .markResolved: store.markSelectedResolved()
        }
    }
}
