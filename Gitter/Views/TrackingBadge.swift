import GitCore
import SwiftUI

/// How a local branch stands against its upstream, in a few characters: `↑2 ↓3`, only the
/// halves that are not zero; nothing at all when it is level or has no upstream; "gone" in the
/// warning tint when the upstream was deleted on the remote.
///
/// **The counts are against the upstream, which is not always a remote.** A branch whose
/// upstream is another *local* branch (`tracksLocalBranch`) says so in the badge itself —
/// `↑2 ↓3 · main`, the local branch's name after the counts — and in its tooltip and VoiceOver
/// text, so "2 commits to push" is never read into a count that has nothing to do with any
/// server. (Dashed arrows, `⇡2`, were tried first and were too subtle at badge size.)
///
/// The warning tint is the detached label's orange (`BranchMenu`), and the word is spelled out,
/// so colour is never the only signal.
struct TrackingBadge: View {
    let tracking: Tracking
    let tracksLocalBranch: Bool
    /// The upstream's short name: the tooltip names it, and for a local upstream the badge
    /// draws it after the counts ("local" when it is missing).
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
                        tracking, upstream: upstream, tracksLocalBranch: tracksLocalBranch) ?? "")
        }
    }

    /// The characters drawn, or nil for nothing to draw.
    var text: String? {
        Self.text(for: tracking, tracksLocalBranch: tracksLocalBranch, upstream: upstream)
    }

    /// `↑2 ↓3`; for a local upstream `↑2 ↓3 · main` — the upstream's name, or "local" when it
    /// is not known.
    static func text(for tracking: Tracking, tracksLocalBranch: Bool, upstream: String?) -> String? {
        switch tracking {
        case .none: return nil
        case .gone: return "gone"
        case .counts(let ahead, let behind):
            let parts = [ahead > 0 ? "↑\(ahead)" : nil, behind > 0 ? "↓\(behind)" : nil]
                .compactMap { $0 }
            guard !parts.isEmpty else { return nil }
            let counts = parts.joined(separator: " ")
            return tracksLocalBranch ? "\(counts) · \(upstream ?? "local")" : counts
        }
    }
}
