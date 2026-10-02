import GitCore
import SwiftUI

/// One conflict block: ours beside theirs, the base behind a disclosure, the four choices as a
/// segmented control, and what the choice composes to (`ResolverPreview.block`, GitCore's own
/// composition) below.
///
/// Writes nothing: a choice goes to the store's in-memory choices (`chooseBlock`), and only
/// Resolve File writes the file.
struct ConflictBlockView: View {
    let block: ConflictBlock
    let sides: SideLabels
    let choice: BlockChoice?
    let onChoose: (BlockChoice) -> Void

    @State private var showsBase = false

    private static let choices: [BlockChoice] = [.ours, .theirs, .oursThenTheirs, .theirsThenOurs]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                pane(ConflictWording.side(.ours, sides), block.ours, tint: .blue)
                pane(ConflictWording.side(.theirs, sides), block.theirs, tint: .purple)
            }

            DisclosureGroup(ConflictWording.base, isExpanded: $showsBase) {
                if let base = block.base {
                    code(base, tint: .gray)
                } else {
                    Text(ConflictWording.noBase)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            Picker(
                "How to resolve this conflict",
                selection: Binding(get: { choice }, set: { if let new = $0 { onChoose(new) } })
            ) {
                ForEach(Self.choices, id: \.self) { option in
                    Text(ConflictWording.choice(option)).tag(Optional(option))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 4) {
                Text(ConflictWording.preview)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let result = ResolverPreview.block(block, choice) {
                    code(result, tint: .green)
                } else {
                    Text(ConflictWording.previewEmpty)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pane(_ title: String, _ data: Data, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.tail)
            code(data, tint: tint)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func code(_ data: Data, tint: Color) -> some View {
        Text(ResolverPreview.text(data))
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(data.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
    }
}
