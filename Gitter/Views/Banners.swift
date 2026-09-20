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
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(iconTint)
            Text(message)
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dismissLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.6)))
        .padding(8)
    }
}

/// The store's `lastError`: something did not happen, and the message stays until dismissed.
struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        Banner(
            message: message, systemImage: "exclamationmark.triangle.fill", iconTint: .orange,
            tint: .yellow, dismissLabel: "Dismiss error", dismiss: dismiss)
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
