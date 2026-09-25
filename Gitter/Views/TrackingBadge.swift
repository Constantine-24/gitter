import GitCore
import SwiftUI

/// How a local branch stands against its upstream, in a few characters: `↑2 ↓3`, only the
/// halves that are not zero; nothing at all when it is level or has no upstream; "gone" in the
/// warning tint when the upstream was deleted on the remote.
///
/// **The counts are against the upstream, which is not always a remote.** A branch whose
/// upstream is another *local* branch (`tracksLocalBranch`) gets dashed arrows (`⇡2 ⇣3`) and a
/// tooltip naming the local branch, so "2 commits to push" is never read into a count that has
/// nothing to do with any server. The warning tint is the detached label's orange
/// (`BranchMenu`), and the word is spelled out, so colour is never the only signal.
struct TrackingBadge: View {
    let tracking: Tracking
    let tracksLocalBranch: Bool
    /// The upstream's short name, for the tooltip. The badge draws the same without it.
    var upstream: String? = nil

    var body: some View {
        if let text {
            Text(text)
                .monospacedDigit()
                .foregroundStyle(tracking == .gone ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .fixedSize()
                .helpIfPresent(
                    RemoteWording.trackingHelp(
                        tracking, upstream: upstream, tracksLocalBranch: tracksLocalBranch))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    RemoteWording.trackingAccessibility(
                        tracking, tracksLocalBranch: tracksLocalBranch) ?? "")
        }
    }

    /// The characters drawn, or nil for nothing to draw.
    var text: String? { Self.text(for: tracking, tracksLocalBranch: tracksLocalBranch) }

    static func text(for tracking: Tracking, tracksLocalBranch: Bool) -> String? {
        switch tracking {
        case .none: return nil
        case .gone: return "gone"
        case .counts(let ahead, let behind):
            let (up, down) = tracksLocalBranch ? ("⇡", "⇣") : ("↑", "↓")
            let parts = [ahead > 0 ? "\(up)\(ahead)" : nil, behind > 0 ? "\(down)\(behind)" : nil]
                .compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }
}
