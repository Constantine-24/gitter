import Foundation
import GitCore
import SwiftUI

struct PasteDiffSheet: View {
    let preview: ClipboardPatchPreview

    @Environment(RepositoryStore.self) private var store

    private var plan: ClipboardPatchPlan { preview.plan }

    var body: some View {
        let blocked = store.clipboardPatchApplyBlockedReason
        VStack(alignment: .leading, spacing: 12) {
            Text(ClipboardPatchWording.sheetTitle)
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text(ClipboardPatchWording.repository).foregroundStyle(.secondary)
                    Text(verbatim: ClipboardPatchWording.displayName(preview.destination.path))
                }
                GridRow {
                    Text(ClipboardPatchWording.branch).foregroundStyle(.secondary)
                    Text(verbatim: ClipboardPatchWording.displayName(plan.headLabel))
                }
            }
            .font(.callout)
            .textSelection(.enabled)

            Text(ClipboardPatchWording.explanation)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            files
            patch

            if let blocked {
                Text(blocked)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                let apply: @MainActor () -> Void = { store.confirmClipboardPatch(preview.id) }
                Button(ClipboardPatchWording.applyPatch, action: apply)
                    .harnessButton(ClipboardPatchWording.applyPatch, action: apply)
                    .disabled(blocked != nil)
                let cancel: @MainActor () -> Void = { store.cancelClipboardPatch(preview.id) }
                Button(ClipboardPatchWording.cancel, action: cancel)
                    .harnessButton(ClipboardPatchWording.cancel, action: cancel)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onExitCommand { store.cancelClipboardPatch(preview.id) }
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ClipboardPatchWording.files)
                .font(.subheadline.weight(.semibold))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.files, id: \.path) { file in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(ClipboardPatchWording.fileAction(file))
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .leading)
                            Text(verbatim: ClipboardPatchWording.displayName(file.path))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("+\(file.additions)")
                                .foregroundStyle(.green)
                            Text("−\(file.deletions)")
                                .foregroundStyle(.red)
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
                .padding(8)
            }
            .frame(height: CGFloat(min(plan.files.count, 5)) * 24 + 12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var patch: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ClipboardPatchWording.patch)
                .font(.subheadline.weight(.semibold))
            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: plan.text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(8)
            }
            .frame(height: 180)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.quaternary)
                    .allowsHitTesting(false)
            }
        }
    }
}
