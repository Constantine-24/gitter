import AppKit
import SwiftUI

/// The resolver's colours (spec, "Look"): one asset-catalog colour per role, `Resolver/<Role>`,
/// each with its light and dark value. The one list of names: SwiftUI reads it through
/// `ResolverColor`, AppKit through `ResolverPalette`.
enum ResolverRole: String, CaseIterable, Sendable {
    case ours = "Ours", oursTint = "OursTint", oursWord = "OursWord"
    case theirs = "Theirs", theirsTint = "TheirsTint", theirsWord = "TheirsWord"
    case resolved = "Resolved", resolvedTint = "ResolvedTint", accent = "Accent"
    case filler = "Filler", window = "Window", bar = "Bar", sidebar = "Sidebar", header = "Header"
    case separator = "Separator", waitingSlot = "WaitingSlot", selectedFile = "SelectedFile"
    case text = "Text", secondaryText = "SecondaryText", lineNumber = "LineNumber"
    case badgeGreen = "BadgeGreen", badgeOrange = "BadgeOrange", badgePurple = "BadgePurple", link = "Link"

    var assetName: String { "Resolver/\(rawValue)" }
}

/// The palette for SwiftUI views.
enum ResolverColor {
    static let ours = color(.ours)
    static let theirs = color(.theirs)
    static let resolved = color(.resolved)
    static let accent = color(.accent)
    static let window = color(.window)
    static let bar = color(.bar)
    static let sidebar = color(.sidebar)
    static let header = color(.header)
    static let separator = color(.separator)
    static let waitingSlot = color(.waitingSlot)
    static let text = color(.text)
    static let secondaryText = color(.secondaryText)
    static let badgeGreen = color(.badgeGreen)
    static let link = color(.link)

    static func color(_ role: ResolverRole) -> Color { Color(role.assetName) }
}

/// The palette for the columns' AppKit drawing: dynamic colours, resolved in the appearance they
/// are drawn in.
struct ResolverPalette: @unchecked Sendable {
    let ours, oursTint, oursWord, theirs, theirsTint, theirsWord: NSColor
    let resolved, resolvedTint, accent, filler, window, sidebar, separator, waitingSlot: NSColor
    let text, secondaryText, lineNumber, badgeGreen, badgeOrange, badgePurple: NSColor

    /// From the asset catalog.
    static let standard = ResolverPalette()

    private init() {
        func named(_ role: ResolverRole) -> NSColor { NSColor(named: role.assetName) ?? .magenta }
        ours = named(.ours)
        oursTint = named(.oursTint)
        oursWord = named(.oursWord)
        theirs = named(.theirs)
        theirsTint = named(.theirsTint)
        theirsWord = named(.theirsWord)
        resolved = named(.resolved)
        resolvedTint = named(.resolvedTint)
        accent = named(.accent)
        filler = named(.filler)
        window = named(.window)
        sidebar = named(.sidebar)
        separator = named(.separator)
        waitingSlot = named(.waitingSlot)
        text = named(.text)
        secondaryText = named(.secondaryText)
        lineNumber = named(.lineNumber)
        badgeGreen = named(.badgeGreen)
        badgeOrange = named(.badgeOrange)
        badgePurple = named(.badgePurple)
    }

    /// A row's background; nil for none.
    func background(_ tint: RowTint) -> NSColor? {
        switch tint {
        case .none: nil
        case .oursChanged, .fromOurs: oursTint
        case .theirsChanged, .fromTheirs: theirsTint
        case .taken, .edited: resolvedTint
        case .filler: filler
        }
    }

    /// The 3 pt bar at a row's leading edge; nil for none.
    func bar(_ tint: RowTint) -> NSColor? {
        switch tint {
        case .oursChanged, .fromOurs: ours
        case .theirsChanged, .fromTheirs: theirs
        case .taken, .edited: resolved
        case .none, .filler: nil
        }
    }

    /// A word mark's colour in a column.
    func word(_ column: ResolverColumn) -> NSColor {
        column == .theirs ? theirsWord : oursWord
    }
}
