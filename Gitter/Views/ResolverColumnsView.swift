import SwiftUI

/// Focus mode's three columns for the draft of `path`: Ours | Result | Theirs, on the grid the
/// column headers use (`ResolverGrid`).
///
/// A placeholder until the columns are drawn: each column shows its text as it is, unaligned,
/// read-only, with no tints or take buttons. The shell around it (headers, bars, bottom bar) is
/// final.
struct ResolverColumnsView: View {
    let path: String

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        let draft = store.resolverDrafts[path]
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                column(draft.flatMap { $0.sides.ours }.map { String(decoding: $0, as: UTF8.self) })
                ResolverGrid.gutter
                column(draft?.document.resultText)
                ResolverGrid.gutter
                column(draft.flatMap { $0.sides.theirs }.map { String(decoding: $0, as: UTF8.self) })
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // The strips run the whole height, below the text too.
        .background {
            HStack(spacing: 0) {
                Color("Resolver/Window")
                ResolverGrid.gutter
                Color("Resolver/Window")
                ResolverGrid.gutter
                Color("Resolver/Window")
            }
        }
    }

    private func column(_ text: String?) -> some View {
        Text(text ?? "")
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(Color("Resolver/Text"))
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
