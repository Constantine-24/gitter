import Foundation

/// A configured remote, as `git remote -v` reports it.
public struct Remote: Sendable, Hashable, Identifiable {
    public let name: String
    /// The URL git fetches from, or nil when it printed no `(fetch)` URL for this remote —
    /// a remote configured with only a `pushurl`. Not filled in from `pushURL`: a remote
    /// nothing can be fetched from must not look as though it can.
    public let fetchURL: String?
    /// The first URL git pushes to (a remote may have several), or nil when it printed no
    /// `(push)` URL. For an ordinary remote git prints a `(push)` line holding the fetch URL,
    /// which is git's own answer, not this parser inventing one.
    public let pushURL: String?

    public var id: String { name }

    public init(name: String, fetchURL: String?, pushURL: String?) {
        self.name = name
        self.fetchURL = fetchURL
        self.pushURL = pushURL
    }
}

/// How a local branch stands against its upstream.
public enum Tracking: Sendable, Hashable {
    /// Nothing to report: no upstream at all — or, defensively, a `%(upstream:track)` token
    /// this version of Gitter does not recognise, which must not be passed off as "level".
    case none
    /// The upstream is configured but its ref is not there any more (pruned elsewhere).
    case gone
    /// Both counts, level being `.counts(ahead: 0, behind: 0)`.
    case counts(ahead: Int, behind: Int)

    /// Reads one `%(upstream:track)` field. Measured on git 2.54: `[ahead 2]`, `[behind 3]`,
    /// `[ahead 1, behind 3]`, `[gone]`, or empty when the branch is level with its upstream —
    /// and also empty when there is no upstream at all, which is why `hasUpstream` has to be
    /// passed in: only the `%(upstream:short)` field tells those two apart.
    ///
    /// `field` is nil when the line does not carry the field at all (output recorded from the
    /// older format). That is not the same as an empty field: nothing is known, so nothing is
    /// claimed — least of all "level".
    static func parse(_ field: (some StringProtocol)?, hasUpstream: Bool) -> Tracking {
        guard hasUpstream, let field else { return .none }
        if field.isEmpty { return .counts(ahead: 0, behind: 0) }
        guard field.hasPrefix("["), field.hasSuffix("]") else { return .none }
        let body = field.dropFirst().dropLast()
        if body == "gone" { return .gone }

        var ahead = 0
        var behind = 0
        var recognised = false
        for part in body.components(separatedBy: ", ") {
            let words = part.split(separator: " ")
            guard words.count == 2, let count = Int(words[1]) else { return .none }
            switch words[0] {
            case "ahead": ahead = count
            case "behind": behind = count
            default: return .none
            }
            recognised = true
        }
        return recognised ? .counts(ahead: ahead, behind: behind) : .none
    }
}
