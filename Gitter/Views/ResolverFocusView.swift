import AppKit
import GitCore
import SwiftUI

/// Focus mode (spec, "Conflict resolver"), in place of the browser while `resolverFocus` is set:
/// the conflicted files in the sidebar; the toolbar (the operation's sentence, Show Base, the
/// conflict position, Abort…, Done); over the centre the bars and the three column headers, then
/// the columns (`ResolverColumnsView`) or the whole-file, submodule, failed or all-resolved
/// state; and the bottom bar with the key hints and Resolve File.
///
/// Every decision is `ResolverShell`'s and every sentence `ConflictWording`'s. The only view state
/// is the sidebar's selection and, per path, the draft Keep Editing was pressed for (Ruling 18).
struct ResolverFocusView: View {
    /// The banners' height (`MainWindow`): the content moves down by it.
    let bannerHeight: CGFloat

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            ResolverSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            VStack(spacing: 0) {
                Rectangle().fill(ResolverColor.separator).frame(height: 1)
                ResolverCentreView()
            }
            .padding(.top, bannerHeight)
            .animation(.default, value: bannerHeight)
        }
        .toolbar { toolbar }
        .navigationTitle(ConflictWording.focusTitle)
        .navigationSubtitle(subtitle)
        // Escape is Done whenever no text is being edited; ⌘Z and ⇧⌘Z are the store's wherever
        // the keys are (`ResolverKeyMonitor`).
        .background(
            ResolverKeyMonitor(
                done: { store.closeResolver() }, undo: { store.resolverUndo() }, redo: { store.resolverRedo() }))
    }

    private var subtitle: String {
        let operation = store.operationInProgress
        let progress = store.operationStop?.operation == operation ? store.operationStop?.progress : nil
        return ResolverShell.subtitle(operation, progress, branch: store.currentBranch, ended: store.resolverEndedShown)
    }

    /// Every item is always there; only its content changes. An item that comes and goes resizes
    /// the toolbar during another one's animation, which AppKit answers with a layout loop
    /// (`MainWindow`).
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var store = store
        ToolbarItem(placement: .primaryAction) {
            Toggle(ConflictWording.showBase, isOn: $store.showsBase)
                .toggleStyle(.checkbox)
                .help(ConflictWording.showBaseHelp)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            navigation
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            abort
        }
        ToolbarItem(placement: .primaryAction) {
            let isDefault = ResolverShell.doneIsDefault(
                allResolved: store.resolverAllResolved, ended: store.resolverEndedShown != nil)
            // The default button is drawn as one, and takes Return.
            Button(ConflictWording.done) { store.closeResolver() }
                .keyboardShortcut(isDefault ? .defaultAction : nil)
                .help(ConflictWording.doneHelp)
        }
    }

    /// ‹ "Conflict N of M" ›: in this file, crossing into the next or previous file at its ends.
    private var navigation: some View {
        let focus = store.resolverFocus
        let position = ResolverShell.position(store.focusedDraft, current: focus?.currentChunk)
        return HStack(spacing: 6) {
            Button {
                store.resolverPreviousConflict()
            } label: {
                Image(systemName: "chevron.left")
            }
            .help(ConflictWording.previous)
            .accessibilityLabel(ConflictWording.previous)
            // A fixed width: the text changing must not resize the toolbar.
            Text(position ?? "")
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 120)
            Button {
                store.resolverNextConflict()
            } label: {
                Image(systemName: "chevron.right")
            }
            .help(ConflictWording.next)
            .accessibilityLabel(ConflictWording.next)
        }
    }

    /// Today's Abort…, with its sheet; nothing to abort after a stash apply's conflicts.
    @ViewBuilder
    private var abort: some View {
        if let operation = store.operationInProgress, ResolverShell.showsAbort(operation) {
            let abort = store.abortState
            Button(operation.abortButtonTitle) { store.requestAbort() }
                .disabled(abort != .enabled, help: abort.reason)
        }
    }
}

// MARK: - The sidebar

/// The conflicted files (`ResolverShell.rows`): a status dot, the name and folder, the trailing
/// text; several can be selected for Take Ours / Theirs for N Files…, from the context menu or
/// the footer, under the progress and the footer's line.
struct ResolverSidebar: View {
    @Environment(RepositoryStore.self) private var store
    @State private var selection: Set<String> = []

    var body: some View {
        let rows = ResolverShell.rows(
            files: store.resolverFiles, resolved: store.resolvedThisSession, drafts: store.resolverDrafts,
            summaries: store.resolverSummaries.mapValues(\.summary))
        List(selection: $selection) {
            Section(ConflictWording.conflictedFiles) {
                ForEach(rows) { row in
                    ResolverFileRow(row: row, isFocused: store.resolverFocus?.path == row.path)
                        .tag(row.path)
                }
            }
        }
        .listStyle(.sidebar)
        .tint(ResolverColor.accent)
        // Opaque, as the mockup draws it, rather than the sidebar material.
        .scrollContentBackground(.hidden)
        .background(ResolverColor.sidebar)
        .contextMenu(forSelectionType: String.self) { paths in
            takeItems(paths, rows: rows)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer(rows).background(ResolverColor.sidebar) }
        // One file clicked: focus mode moves to it. Several: they are the take's selection.
        .onChange(of: selection) { _, new in
            if let path = ResolverShell.focusAfterSelection(new, focused: store.resolverFocus?.path) {
                store.focusResolverFile(path)
            }
        }
        // The focus moved (next conflict into another file, a resolve): the selection follows.
        .onChange(of: store.resolverFocus?.path, initial: true) { _, path in
            if let path, !selection.contains(path) || selection.count > 1 { selection = [path] }
        }
    }

    /// The conflicted files of `paths`, which a whole-file take can act on.
    private func takeable(_ paths: Set<String>, rows: [ResolverRow]) -> [String] {
        rows.filter { paths.contains($0.path) && $0.isConflicted }.map(\.path)
    }

    @ViewBuilder
    private func takeItems(_ paths: Set<String>, rows: [ResolverRow]) -> some View {
        let files = takeable(paths, rows: rows)
        if !files.isEmpty {
            let blocked = store.conflictActionBlockedReason
            ForEach([ConflictSide.ours, .theirs], id: \.self) { side in
                Button(ConflictWording.takeForFilesMenuItem(side, count: files.count)) {
                    store.takeSideForFiles(files, side)
                }
                .disabled(blocked != nil)
            }
        }
    }

    private func footer(_ rows: [ResolverRow]) -> some View {
        // Read-only rows count in neither (Ruling 24).
        let (resolved, total) = ResolverShell.progress(rows)
        let allResolved = store.resolverAllResolved
        let ended = store.resolverEndedShown != nil
        let files = takeable(selection, rows: rows)
        return VStack(alignment: .leading, spacing: 6) {
            if selection.count > 1, !files.isEmpty {
                let blocked = store.conflictActionBlockedReason
                ForEach([ConflictSide.ours, .theirs], id: \.self) { side in
                    Button(ConflictWording.takeForFilesMenuItem(side, count: files.count)) {
                        store.takeSideForFiles(files, side)
                    }
                    .disabled(blocked != nil, help: blocked)
                }
                Divider().padding(.vertical, 2)
            }
            Text(ConflictWording.filesResolved(resolved, of: total))
                .font(.callout)
                .foregroundStyle(ResolverColor.text)
            ProgressView(value: Double(resolved), total: Double(max(total, 1)))
                .progressViewStyle(.linear)
                .tint(ResolverColor.resolved)
                .accessibilityLabel(ConflictWording.filesResolved(resolved, of: total))
            if let line = ResolverShell.footerLine(store.operationInProgress, allResolved: allResolved, ended: ended) {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(allResolved ? ResolverColor.badgeGreen : ResolverColor.secondaryText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A file row, as the mockup's File row: the dot (orange while there is work, green once
/// resolved), the name over its folder, the trailing text.
struct ResolverFileRow: View {
    let row: ResolverRow
    let isFocused: Bool

    var body: some View {
        let status = ConflictWording.sidebarStatus(row.status)
        HStack(spacing: 8) {
            Circle()
                .fill(row.status == .resolved ? ResolverColor.resolved : ResolverColor.accent)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fontWeight(isFocused ? .semibold : .regular)
                Text(row.folder ?? ConflictWording.noFolder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(row.status == .resolved ? ResolverColor.badgeGreen : Color.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .help(row.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ConflictWording.sidebarRowLabel(row.path, row.status))
    }
}

// MARK: - The centre

/// The bars, the column headers, the centre for the focused file, and the bottom bar.
struct ResolverCentreView: View {
    @Environment(RepositoryStore.self) private var store

    /// Per path, the draft Keep Editing was pressed for (by its snapshot, Ruling 18).
    @State private var keptEditing: [String: ConflictSnapshot] = [:]

    var body: some View {
        let path = store.resolverFocus?.path
        let draft = store.focusedDraft
        let document = store.selectedConflict
        let centre = ResolverShell.centre(
            path: path, draft: draft, document: document, failure: store.conflictLoadFailure,
            allResolved: store.resolverAllResolved)
        VStack(spacing: 0) {
            if let path, let draft {
                let kept = ResolverShell.keptEditing(draft, kept: keptEditing[path])
                // The worktree compared with what git wrote is the document's (the draft starts
                // from git's conflict either way).
                let matches = document?.snapshot.file.path == path ? document?.matchesGitsConflict ?? true : true
                ForEach(ResolverShell.bars(draft, matchesGitsConflict: matches, keptEditing: kept), id: \.self) { bar in
                    barView(bar, path: path)
                }
            }
            if let path, centre != .allResolved, centre != .loading || draft != nil {
                ResolverHeaders(path: path, keptEditing: $keptEditing)
                Rectangle().fill(ResolverColor.separator).frame(height: 1)
            }
            content(centre, path: path)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(ResolverColor.separator).frame(height: 1)
            ResolverBottomBar(showsResolve: centre == .columns)
        }
        .background(ResolverColor.window)
    }

    // MARK: Bars

    private func barView(_ bar: ResolverBar, path: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Self.symbol(bar))
                .foregroundStyle(ResolverColor.accent)
                .accessibilityHidden(true)
            Text(ConflictWording.bar(bar))
                .font(.callout)
                .foregroundStyle(ResolverColor.text)
            Spacer(minLength: 8)
            switch bar {
            case .changedOutside:
                Button(ConflictWording.reload) { reload(path) }
                Button(ConflictWording.keepEditing) {
                    if let draft = store.resolverDrafts[path] { keptEditing[path] = draft.snapshot }
                }
                Button(ConflictWording.copyResult) { store.copyResult(path) }
            case .resolvedOutside, .operationEnded:
                Button(ConflictWording.copyResult) { store.copyResult(path) }
            case .editedAfterConflict, .notEditable:
                EmptyView()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ResolverColor.waitingSlot)
        .overlay(alignment: .bottom) { Rectangle().fill(ResolverColor.separator).frame(height: 1) }
    }

    private static func symbol(_ bar: ResolverBar) -> String {
        switch bar {
        case .editedAfterConflict: "pencil"
        case .changedOutside: "arrow.triangle.2.circlepath"
        case .resolvedOutside, .operationEnded: "exclamationmark.triangle"
        case .notEditable: "lock"
        }
    }

    private func reload(_ path: String) {
        keptEditing[path] = nil
        store.reloadDraft(path)
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ centre: ResolverCentre, path: String?) -> some View {
        switch centre {
        case .columns:
            if let path { ResolverColumnsView(path: path) }
        case .wholeFile(let reason):
            if let document = store.selectedConflict { wholeFile(document, reason) }
        case .submodule:
            message(ConflictWording.submodule, systemImage: "shippingbox")
        case .failed(let message):
            failed(message, path: path)
        case .allResolved:
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(ResolverColor.resolved)
                    .accessibilityHidden(true)
                Text(ConflictWording.allResolvedTitle)
                    .font(.title3.weight(.semibold))
                if let line = ResolverShell.footerLine(
                    store.operationInProgress, allResolved: true, ended: store.resolverEndedShown != nil)
                {
                    Text(line)
                        .foregroundStyle(ResolverColor.secondaryText)
                }
            }
        case .loading:
            ProgressView()
        }
    }

    private func message(_ text: String, systemImage: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(maxWidth: 480)
        .padding(24)
    }

    /// A kind with no blocks: what each side has in its column, and in the Result's today's
    /// explanation and choices as large buttons.
    private func wholeFile(_ document: ConflictDocument, _ reason: WholeFileReason) -> some View {
        let file = document.snapshot.file
        let sides = store.conflictSides
        let blocked = store.conflictActionBlockedReason
        let offered = ResolverOffer.actions(for: document).filter { [.takeOurs, .takeTheirs, .delete, .keep].contains($0) }
        return HStack(spacing: 0) {
            ResolverWholeFileSide(content: sideContent(file, .ours, reason), side: .ours)
            ResolverGrid.gutter
            VStack(spacing: 14) {
                Text(ConflictWording.wholeFile(reason))
                    .multilineTextAlignment(.center)
                if !document.matchesGitsConflict, document.worktree != nil {
                    Text(ConflictWording.replaceBody(file.path))
                        .font(.callout)
                        .foregroundStyle(ResolverColor.secondaryText)
                        .multilineTextAlignment(.center)
                }
                ForEach(offered, id: \.self) { action in
                    Button {
                        perform(action)
                    } label: {
                        Text(ConflictWording.title(action, file)).frame(minWidth: 200)
                    }
                    .controlSize(.large)
                    .disabled(blocked != nil, help: blocked ?? ConflictWording.help(action, file, sides))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            ResolverGrid.gutter
            ResolverWholeFileSide(content: sideContent(file, .theirs, reason), side: .theirs)
        }
    }

    /// What a side's column shows: its stage as read for this file (Ruling 23), else the short
    /// description while the read is still to land or when it failed.
    private func sideContent(_ file: ConflictedFile, _ side: ConflictSide, _ reason: WholeFileReason) -> WholeFileSideContent {
        let read = store.resolverWholeFileSides.flatMap { $0.file == file ? $0.sides : nil }
        return ConflictWording.wholeFileSideContent(
            file, side, reason, content: read.flatMap { side == .ours ? $0.ours : $0.theirs })
    }

    private func perform(_ action: ResolverAction) {
        switch action {
        case .takeOurs: store.takeSide(.ours)
        case .takeTheirs: store.takeSide(.theirs)
        case .delete: store.deleteConflictedFile()
        case .keep: store.keepConflictedFile()
        case .resolveFile, .openInEditor, .markResolved: break
        }
    }

    /// Today's failed state (B4): git's words, and the actions that need no document.
    private func failed(_ message: String, path: String?) -> some View {
        let file = path.flatMap { path in store.snapshot?.status.files.first { $0.path == path }?.conflict }
        let sides = store.conflictSides
        let blocked = store.conflictActionBlockedReason
        return VStack(spacing: 14) {
            self.message(ConflictWording.loadFailed(message), systemImage: "exclamationmark.triangle")
            HStack(spacing: 8) {
                if let file {
                    Button(ConflictWording.title(.openInEditor, file)) { store.openInEditor(file.path) }
                        .disabled(blocked != nil, help: blocked ?? ConflictWording.help(.openInEditor, file, sides))
                    if file.kind != .bothDeleted {
                        Button(ConflictWording.title(.markResolved, file)) { store.markResolved(file) }
                            .disabled(blocked != nil, help: blocked ?? ConflictWording.help(.markResolved, file, sides))
                    }
                }
                Button(ConflictWording.tryAgain) { store.loadConflict() }
            }
            .controlSize(.large)
        }
    }
}

// MARK: - The column headers

/// Ours (blue dot, its label, Use Ours for the rest) | Result (the path, editable or not, "K of M
/// resolved", the overflow menu) | Theirs (purple dot, its label, Use Theirs for the rest).
struct ResolverHeaders: View {
    let path: String
    @Binding var keptEditing: [String: ConflictSnapshot]

    @Environment(RepositoryStore.self) private var store
    /// Reload… asks first for a draft with changes.
    @State private var confirmingReload = false

    var body: some View {
        let draft = store.resolverDrafts[path]
        HStack(spacing: 0) {
            side(.ours, draft)
            ResolverGrid.gutter
            result(draft)
            ResolverGrid.gutter
            side(.theirs, draft)
        }
        .frame(height: 34)
        .background(ResolverColor.header)
    }

    private func side(_ side: ConflictSide, _ draft: ResolverDraft?) -> some View {
        let sides = store.conflictSides
        let canTake = draft.map { $0.isEditable && $0.document.waitingCount > 0 } ?? false
        return HStack(spacing: 6) {
            Circle()
                .fill(side == .ours ? ResolverColor.ours : ResolverColor.theirs)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(ConflictWording.sideTitle(side))
                .fontWeight(.semibold)
                .foregroundStyle(ResolverColor.text)
            Text(sides.label(side))
                .foregroundStyle(ResolverColor.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(sides.label(side))
            Spacer(minLength: 6)
            if draft != nil {
                Button(ConflictWording.useRest(side)) { store.resolverTakeRest(side) }
                    .buttonStyle(.link)
                    .foregroundStyle(ResolverColor.link)
                    .lineLimit(1)
                    .disabled(!canTake, help: ConflictWording.useRestHelp(side, sides))
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    private func result(_ draft: ResolverDraft?) -> some View {
        HStack(spacing: 6) {
            Text(ConflictWording.resultTitle)
                .fontWeight(.semibold)
                .foregroundStyle(ResolverColor.text)
            Group {
                if let draft {
                    Text("\(path) \(ConflictWording.resultState(editable: draft.isEditable && draft.document.notEditable == nil))")
                } else {
                    Text(path)
                }
            }
            .foregroundStyle(ResolverColor.secondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
            Spacer(minLength: 6)
            if let draft {
                let total = draft.document.conflictCount
                Text(ConflictWording.resolvedCount(total - draft.document.waitingCount, of: total))
                    .foregroundStyle(ResolverColor.badgeGreen)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            overflow(draft)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    /// Mark Resolved (today's flow) and Open in Editor, as the read offers them; Copy Result and
    /// Discard Changes on a draft; Reload… on one changed outside, asking first when it has
    /// changes (Ruling 26).
    private func overflow(_ draft: ResolverDraft?) -> some View {
        let offered = store.selectedConflict.map(ResolverOffer.actions(for:)) ?? []
        let blocked = store.conflictActionBlockedReason
        let file = store.selectedConflict?.snapshot.file
        return Menu {
            if let file {
                Button(ConflictWording.title(.markResolved, file)) { store.markSelectedResolved() }
                    .disabled(!offered.contains(.markResolved) || blocked != nil)
                Button(ConflictWording.title(.openInEditor, file)) { store.openInEditor(path) }
                    .disabled(!offered.contains(.openInEditor))
            }
            if let draft {
                Divider()
                Button(ConflictWording.copyResult) { store.copyResult(path) }
                Button(ConflictWording.discardChanges) { store.discardDraft(path) }
                    .disabled(!draft.hasUserChanges && draft.detached == nil)
                if ResolverShell.offersReload(draft) {
                    Button(ConflictWording.reloadMenuItem) {
                        if ResolverShell.reloadAsks(draft) {
                            confirmingReload = true
                        } else {
                            reload()
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(ConflictWording.moreActions)
        .accessibilityLabel(ConflictWording.moreActions)
        .alert(ConflictWording.reloadQuestion, isPresented: $confirmingReload) {
            Button(ConflictWording.reload, role: .destructive) { reload() }
            Button(ConflictWording.cancel, role: .cancel) {}
        }
    }

    /// The file read again; Keep Editing's hidden bar goes with the draft.
    private func reload() {
        keptEditing[path] = nil
        store.reloadDraft(path)
    }
}

// MARK: - The bottom bar

/// The five key hints, "N conflicts left in this file" and Resolve File (off while a conflict
/// waits, or while the draft can't be written).
struct ResolverBottomBar: View {
    let showsResolve: Bool

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        HStack(spacing: 14) {
            ForEach(ConflictWording.keyHints, id: \.keys) { hint in
                HStack(spacing: 6) {
                    Text(hint.keys)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(ResolverColor.separator))
                    Text(hint.action)
                        .font(.caption)
                }
                .foregroundStyle(ResolverColor.secondaryText)
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 8)
            if showsResolve, let draft = store.focusedDraft {
                let waiting = draft.document.waitingCount
                if let left = ConflictWording.conflictsLeft(waiting) {
                    Text(left)
                        .font(.callout)
                        .foregroundStyle(ResolverColor.secondaryText)
                        .lineLimit(1)
                }
                let blocked = store.conflictActionBlockedReason
                Button(ConflictWording.title(.resolveFile, draft.snapshot.file)) { store.resolveFocusedFile() }
                    .disabled(
                        !ResolverShell.resolveFileEnabled(draft, blocked: blocked),
                        help: blocked ?? ConflictWording.resolveHelp(remaining: waiting))
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(ResolverColor.bar)
    }
}
