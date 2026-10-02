import GitCore
import SwiftUI

/// The two confirmations Continue can need (spec, "Continue"; Rulings 16 and 20):
///
/// - **An empty result in a rebase** (`.continueEmpty`): the resolution equals HEAD, so the
///   rebase would leave the commit out (M 30) — or, with other files staged, the commit is kept,
///   holding only those files under its own title and author. Both facts on one sheet.
/// - **Other staged files** (`.continueOthers`): git commits the whole index, so they ride into
///   the stopped commit.
///
/// Either way the files named are exactly what Continue acknowledges; GitCore refuses any other
/// set. Cancel holds `.defaultAction`, Escape closes, the confirming button has no shortcut.
struct ContinueEmptySheet: View {
    let sheet: BranchSheet

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Text(bodyText)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if !files.isEmpty { PathList(paths: files) }

            if let busy = store.sheetBusyReason {
                Text(busy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(confirmTitle) { confirm() }
                    .disabled(store.sheetBusyReason != nil)
                Button("Cancel") { store.activeSheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onExitCommand { store.activeSheet = nil }
    }

    private var title: String {
        switch sheet {
        case .continueEmpty(let current, let otherStaged): ContinueWording.emptyTitle(current, otherStaged: otherStaged)
        case .continueOthers(_, _, let paths): ContinueWording.othersTitle(paths.count)
        default: ""
        }
    }

    private var bodyText: String {
        switch sheet {
        case .continueEmpty(let current, let otherStaged): ContinueWording.emptyBody(current, otherStaged: otherStaged)
        case .continueOthers(let operation, let current, let paths): ContinueWording.othersBody(operation, current, paths)
        default: ""
        }
    }

    private var files: [String] {
        switch sheet {
        case .continueEmpty(_, let otherStaged): otherStaged
        case .continueOthers(_, _, let paths): paths
        default: []
        }
    }

    private var confirmTitle: String {
        switch sheet {
        case .continueEmpty(_, let otherStaged): ContinueWording.emptyButton(otherStaged: otherStaged)
        case .continueOthers(_, _, let paths): ContinueWording.othersButton(paths.count)
        default: ""
        }
    }

    private func confirm() {
        switch sheet {
        case .continueEmpty: store.confirmContinueEmpty()
        case .continueOthers: store.confirmContinueOthers()
        default: break
        }
    }
}

/// The paths a confirmation names, one per row: eight rows, then it scrolls (the sentence above
/// carries the count).
struct PathList: View {
    let paths: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(paths, id: \.self) { path in
                    Text(path)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: min(CGFloat(paths.count), 8) * 20)
    }
}
