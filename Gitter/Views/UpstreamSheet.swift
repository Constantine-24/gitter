import GitCore
import SwiftUI

/// Set / Change Upstream… of a local branch: a picker of the fetched remote branches each
/// remote's refspec maps (not the "Other" group, which git refuses: R17), and of the other local
/// branches. The choice is handed to `confirmSetUpstream` as a **full** ref name — the short
/// form is ambiguous beside a tag or branch of that name (R17) — and GitCore reads back what git
/// wrote.
///
/// Writing an upstream loses nothing, so this is a form: Set Upstream holds `.defaultAction`
/// and Cancel `.cancelAction`.
struct UpstreamSheet: View {
    let branch: String
    /// git's short spelling of the upstream when the sheet opened, or nil.
    let current: String?

    @Environment(RepositoryStore.self) private var store
    @State private var chosen: String?

    private struct Group: Identifiable {
        let title: String
        let refs: [String]
        var id: String { title }
    }

    /// Remote branches by remote, then local branches — full ref names.
    private var groups: [Group] {
        guard let refs = store.snapshot?.refs else { return [] }
        var groups = refs.remotes.compactMap { remote -> Group? in
            let names = refs.branches(of: remote).map { "refs/remotes/" + $0.name }
            return names.isEmpty ? nil : Group(title: remote.name, refs: names)
        }
        let locals = refs.localBranches.filter { $0.name != branch }.map { "refs/heads/" + $0.name }
        if !locals.isEmpty { groups.append(Group(title: RemoteAdminWording.upstreamLocalGroup, refs: locals)) }
        return groups
    }

    private var branchRef: Branch? { store.localBranches.first { $0.name == branch } }

    /// The upstream now, as a full ref.
    private var currentRef: String? { branchRef.flatMap(RepositoryStore.fullUpstreamRef(of:)) }

    private var selection: String? {
        let pick = chosen ?? currentRef
        return groups.contains { $0.refs.contains(pick ?? "") } ? pick : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(RemoteAdminWording.upstreamSheetTitle(branch, current: current))
                .font(.headline)

            Text(RemoteAdminWording.upstreamNow(current))
                .font(.callout)
            Text(RemoteAdminWording.upstreamExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if groups.isEmpty {
                Text(RemoteAdminWording.noUpstreamCandidates)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker(
                    "Track:",
                    selection: Binding(get: { selection ?? "" }, set: { chosen = $0 })
                ) {
                    if selection == nil { Text("Choose…").tag("") }
                    ForEach(groups) { group in
                        Section(group.title) {
                            ForEach(group.refs, id: \.self) { ref in
                                Text(RemoteAdminWording.shortUpstream(ref)).tag(ref)
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
            }

            ForEach(
                [branchRef == nil ? RemoteAdminWording.upstreamSheetBranchGone : nil,
                 store.isMutating ? RemoteWording.mutationBusy : nil].compactMap { $0 },
                id: \.self
            ) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                let cancel: @MainActor () -> Void = { store.activeSheet = nil }
                Button("Cancel", action: cancel)
                    .harnessButton("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                let act: @MainActor () -> Void = { confirm() }
                Button(RemoteAdminWording.upstreamButton, action: act)
                    .harnessButton(RemoteAdminWording.upstreamButton, action: act)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var canConfirm: Bool {
        guard let selection, branchRef != nil, !store.isMutating else { return false }
        return selection != currentRef
    }

    private func confirm() {
        guard canConfirm, let selection else { return }
        // `confirmSetUpstream` reads this very sheet and clears it itself.
        store.confirmSetUpstream(branch, to: selection)
    }
}
