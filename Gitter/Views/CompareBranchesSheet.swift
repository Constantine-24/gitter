import GitCore
import SwiftUI

/// Compare Branches… (B3): two pickers of every local and remote branch, each with its own
/// filter (matched as the sidebar's is), and Compare — which hands the two **full** refs to
/// `confirmCompareBranches`. Reads and writes nothing itself, so it is a form: Compare holds
/// `.defaultAction` and Cancel `.cancelAction`.
///
/// Each list is height-capped, so the title and the buttons stay visible however many branches
/// there are.
struct CompareBranchesSheet: View {
    @Environment(RepositoryStore.self) private var store
    @State private var a: String?
    @State private var b: String?
    @State private var queryA = ""
    @State private var queryB = ""

    static let listHeight: CGFloat = 220

    init(a: String?, b: String?) {
        _a = State(initialValue: a)
        _b = State(initialValue: b)
    }

    var body: some View {
        let reason = CompareWording.sheetBlocked(a: a, b: b)
        VStack(alignment: .leading, spacing: 12) {
            Text(CompareWording.sheetTitle)
                .font(.headline)
            Text(CompareWording.sheetExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                picker(CompareWording.firstLabel, side: "A", query: $queryA, selection: $a)
                picker(CompareWording.secondLabel, side: "B", query: $queryB, selection: $b)
            }

            if let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                let cancel: @MainActor () -> Void = { store.activeSheet = nil }
                let compare: @MainActor () -> Void = {
                    guard reason == nil, let a, let b else { return }
                    store.confirmCompareBranches(a, b)
                }
                Button("Cancel", action: cancel)
                    .harnessButton("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(CompareWording.compareButton, action: compare)
                    .harnessButton(CompareWording.compareButton, action: compare)
                    .keyboardShortcut(.defaultAction)
                    .disabled(reason != nil)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    /// One side's list. `side` names its controls for the harness: `Branch <side>`, the list
    /// (an option per ref shown, by its name), and `Filter <side>`.
    private func picker(_ label: String, side: String, query: Binding<String>, selection: Binding<String?>) -> some View {
        let options = CompareWording.pickerOptions(store.snapshot?.refs ?? .empty, query: query.wrappedValue)
        return VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.semibold))
            TextField(SidebarFilter.prompt, text: query)
                .textFieldStyle(.roundedBorder)
                .harnessField("Filter " + side, text: query)
            List(options, id: \.self, selection: selection) { ref in
                Label(
                    CompareWording.name(ref),
                    systemImage: ref.hasPrefix("refs/remotes/") ? "cloud" : "arrow.triangle.branch")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .listStyle(.bordered)
            .frame(height: Self.listHeight)
            .harnessPicker(
                "Branch " + side, selection: selection,
                options: options.map { (label: CompareWording.name($0), value: Optional($0)) })
            .overlay {
                if options.isEmpty {
                    Text(SidebarFilter.noMatches)
                        .foregroundStyle(.secondary)
                }
            }
            Text(CompareWording.chosen(selection.wrappedValue))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
    }
}
