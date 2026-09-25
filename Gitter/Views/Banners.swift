import SwiftUI

/// A dismissible strip across the top of the window. Two kinds use it, and they are told apart
/// by tint and glyph rather than by wording alone: a yellow warning triangle for something that
/// went wrong, a neutral accent-tinted tick for something that went right.
struct Banner: View {
    let message: String
    let systemImage: String
    let iconTint: Color
    let tint: Color
    /// What the close button says to VoiceOver; "Dismiss error" and "Dismiss message" are
    /// different things to hear.
    let dismissLabel: String
    /// Buttons drawn before the close button — the rejected push's "Pull" and "Force Push…".
    /// Empty for every other banner.
    var actions: [BannerAction] = []
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(iconTint)
            Text(message)
                .font(.callout)
                .lineLimit(Self.lineLimit(for: message))
                .textSelection(.enabled)
            Spacer(minLength: 8)
            ForEach(actions) { action in
                Button(action.title, action: action.perform)
                    .controlSize(.small)
                    .disabled(action.disabledReason != nil)
                    .help(action.disabledReason ?? "")
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dismissLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Opaque first, tint second. A banner floats over the commit graph and the diff, and a
        // tint alone at a quarter opacity lets both through far enough to compete with the text
        // that is the whole reason the strip is there.
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(.background)
                .overlay(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.25)))
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.6)))
        .padding(8)
    }

    /// Three lines for a sentence, and room for every line a message was built with on top:
    /// a server's refusal is a sentence plus up to `RemoteWording.maxServerLines` lines and a
    /// "(N more lines)" count, and a fixed three would hide the count — the one line that says
    /// something was left out. Two per extra line, since a 200-character server line wraps;
    /// capped so a banner can never take the window.
    static func lineLimit(for message: String) -> Int {
        let extraLines = message.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        return min(3 + 2 * extraLines, 24)
    }
}

/// One trailing button on a banner.
struct BannerAction: Identifiable {
    let title: String
    /// Why it is off right now, or nil; shown as its tooltip.
    var disabledReason: String?
    let perform: () -> Void

    var id: String { title }
}

/// The store's `lastError`: something did not happen, and the message stays until dismissed.
struct ErrorBanner: View {
    let message: String
    var actions: [BannerAction] = []
    let dismiss: () -> Void

    var body: some View {
        Banner(
            message: message, systemImage: "exclamationmark.triangle.fill", iconTint: .orange,
            tint: .yellow, dismissLabel: "Dismiss error", actions: actions, dismiss: dismiss)
    }
}

/// The store's `notice`: something did happen ("Created branch \"x\"."). Deliberately not the
/// error style — nothing is wrong — and it clears itself after a few seconds, so the close
/// button here is for impatience rather than for getting the window back.
///
/// Neutral grey rather than the accent colour for the strip itself: the accent is the user's
/// choice and on an orange-accented Mac an accent-tinted banner is the yellow warning again.
/// The tick keeps the accent, which is the one place it cannot be mistaken for anything.
struct NoticeBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        Banner(
            message: message, systemImage: "checkmark.circle.fill", iconTint: .accentColor,
            tint: .secondary, dismissLabel: "Dismiss message", dismiss: dismiss)
    }
}
