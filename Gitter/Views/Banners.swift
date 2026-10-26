import AppKit
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
            messageView
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

    /// The whole message, always (B2 Task 5, fix round 1, I5): up to `lineLimit(for:)` lines it
    /// is drawn as it is; past that it scrolls inside that height, so a removal's or a prune's
    /// notice — the only record of every deleted ref and its id — never loses its last lines
    /// (the kept branches, where branches now push, how to bring a ref back). Selectable, so it
    /// can be copied whole.
    ///
    /// The strip is as tall as its text, up to the cap (fix round 3): the scroll view is asked
    /// for its ideal height (`fixedSize`), which is its text's, clamped by `maxHeight` — so a
    /// one-line notice is one line tall, and only a longer text scrolls. (A `ViewThatFits` here
    /// gave every banner the whole cap, the text centred in empty space.)
    private var messageView: some View {
        let height = Self.capHeight(for: message)
        let baseline = Self.firstBaseline
        return ScrollView {
            messageText.frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(Self.debugScrollAnchor)
        .frame(maxHeight: height)
        .fixedSize(horizontal: false, vertical: true)
        // A scroll view has no text baseline of its own, so the glyph and the close button
        // would drop to its middle: give it its first line's.
        .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[.top] + baseline }
    }

    /// The most a message's strip grows to before it scrolls: `lineLimit(for:)` lines.
    static func capHeight(for message: String) -> CGFloat {
        lineHeight * CGFloat(lineLimit(for: message))
    }

    private var messageText: some View {
        Text(message)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// One line of the callout font the message is set in.
    static let lineHeight: CGFloat = {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        return ceil(NSLayoutManager().defaultLineHeight(for: font))
    }()

    /// Where the first line's baseline sits below the top of the text.
    static let firstBaseline: CGFloat = ceil(NSFont.preferredFont(forTextStyle: .callout).ascender)

    /// Where a scrolling message starts: its top — or, for the debug harness, which cannot
    /// scroll, its end (`prefill:bannerAnchor=bottom`).
    private static var debugScrollAnchor: UnitPoint? {
        #if DEBUG
            if DebugLaunchHooks.sheetPrefill["bannerAnchor"] == "bottom" { return .bottom }
        #endif
        return nil
    }

    /// How many lines a message is drawn in before it scrolls.
    ///
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

/// The store's `notice` and `stickyNotice`: something did happen ("Created branch \"x\".").
/// Deliberately not the error style — nothing is wrong. The transient one clears itself after a
/// few seconds, so its close button is for impatience rather than for getting the window back;
/// the sticky one (a pushed branch's pull-request link) stays until its × is pressed.
///
/// Neutral grey rather than the accent colour for the strip itself: the accent is the user's
/// choice and on an orange-accented Mac an accent-tinted banner is the yellow warning again.
/// The tick keeps the accent, which is the one place it cannot be mistaken for anything. A
/// `.warning` notice — it worked, with a warning in it — draws the warning symbol instead, on the
/// same strip.
struct NoticeBanner: View {
    let notice: Notice
    /// Runs a button's `NoticeAction` — `RepositoryStore.perform(_:)`.
    let perform: (NoticeAction) -> Void
    let dismiss: () -> Void

    var body: some View {
        let warning = notice.tone == .warning
        Banner(
            message: notice.text,
            systemImage: warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
            iconTint: warning ? .orange : .accentColor,
            tint: .secondary, dismissLabel: "Dismiss message",
            actions: notice.actions.map { action in
                BannerAction(title: NoticeWording.title(action)) { perform(action) }
            },
            dismiss: dismiss)
    }
}
