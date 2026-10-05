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
                picker(CompareWording.firstLabel, query: $queryA, selection: $a)
                picker(CompareWording.secondLabel, query: $queryB, selection: $b)
            }

            if let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { store.activeSheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(CompareWording.compareButton) {
                    guard reason == nil, let a, let b else { return }
                    store.confirmCompareBranches(a, b)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(reason != nil)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    private func picker(_ label: String, query: Binding<String>, selection: Binding<String?>) -> some View {
        let options = CompareWording.pickerOptions(store.snapshot?.refs ?? .empty, query: query.wrappedValue)
        return VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.semibold))
            TextField(SidebarFilter.prompt, text: query)
                .textFieldStyle(.roundedBorder)
            List(options, id: \.self, selection: selection) { ref in
                Label(
                    CompareWording.name(ref),
                    systemImage: ref.hasPrefix("refs/remotes/") ? "cloud" : "arrow.triangle.branch")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .listStyle(.bordered)
            .frame(height: Self.listHeight)
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
