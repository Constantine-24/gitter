import GitCore
import SwiftUI

/// A discard's confirmation: one row per file with what it loses, and one sentence saying where
/// the copy goes (the Stashes list, the Trash).
///
/// The sheet is a snapshot: `model` carries the diffs (or untracked items) its rows were built
/// from, and the destructive button hands exactly that to GitCore, which re-reads and refuses
/// when the files moved on. A live stale line says so before the click: after every snapshot
/// load it asks again (`discardSheetStaleness`), reading git again only when what the tracked
/// reads depend on moved since its last read.
///
/// Cancel holds `.defaultAction`, Escape closes, and the destructive button has no shortcut.
struct DiscardSheet: View {
    let model: DiscardSheetModel

    @Environment(RepositoryStore.self) private var store
    /// The stale line's last answer, and what the tracked reads depended on then.
    @State private var check: DiscardStaleCheck?

    /// Past this many rows the list scrolls rather than growing the sheet off the screen.
    private static let rowsBeforeScrolling = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            if model.rows.count > Self.rowsBeforeScrolling {
                ScrollView { rows }
                    .frame(height: 240)
            } else {
                rows
            }

            Text(model.destination)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(notes, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(
                        line == DiscardWording.sheetStale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                // No keyboard shortcut on the destructive half: Return belongs to Cancel.
                Button(model.confirmTitle, role: .destructive) { confirm() }
                    .foregroundStyle(.red)
                    .disabled(store.sheetBusyReason != nil)
                Button("Cancel") { store.activeSheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onExitCommand { store.activeSheet = nil }
        // Every load of the snapshot — the watcher's, after any change on disk — asks again.
        // Read-only; cancelled with the sheet. A check cut short by the next load is not kept:
        // its reads may have failed for the cancellation alone.
        .task(id: store.isLoading) {
            guard !store.isLoading else { return }
            let next = await store.discardSheetStaleness(model, after: check)
            if !Task.isCancelled { check = next }
        }
    }

    private var notes: [String] {
        [check?.isStale == true ? DiscardWording.sheetStale : nil, store.sheetBusyReason].compactMap { $0 }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.rows, id: \.self) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(row.name)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 12)
                        Text(row.loses)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(row.preview.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(color(of: line))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A previewed line's colour, from its marker (`DiscardWording.preview`).
    private func color(of line: String) -> Color {
        switch line.first {
        case "+": .green
        case "\u{2212}": .red
        default: .secondary
        }
    }

    private func confirm() {
        guard store.sheetBusyReason == nil else { return }
        // `confirmDiscard` reads this sheet for its requests and closes it itself.
        store.confirmDiscard(model)
    }
}
