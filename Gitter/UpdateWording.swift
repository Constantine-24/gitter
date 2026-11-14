import Foundation

/// Every user-visible string of the update notices, and the event-log line of a check.
enum UpdateWording {
    static let windowTitle = "Software Update"
    static func headline(_ v: ReleaseVersion) -> String { "Gitter \(v) is available" }
    static func youHave(_ v: ReleaseVersion) -> String { "You have \(v)." }
    static let download = "Download", later = "Later", skip = "Skip This Version"
    static let releasePage = "Release page", noNotes = "No release notes."
    static let checkMenu = "Check for Updates…", automaticMenu = "Check for Updates Automatically"

    /// What a manual check says; nil for a newer release, which opens the window instead.
    static func alert(for outcome: UpdateOutcome) -> String? {
        switch outcome {
        case .newer: nil
        case .upToDate(let v): "You're up to date. Gitter \(v) is the latest version."
        case .noRelease: "No release of Gitter is published yet."
        case .rateLimited: "GitHub is limiting requests from this network right now. Try again later."
        case .httpError(let n): "GitHub answered with an error (HTTP \(n))."
        case .unreachable(let d): "Gitter couldn't reach GitHub: " + (d.hasSuffix(".") ? d : d + ".")
        case .unreadable: "Gitter couldn't read GitHub's answer about the latest release."
        }
    }

    /// `update check (automatic|manual): <outcome> — latest <tag>, running <v>`. Never a URL, a
    /// header or the body: an unreachable check's description is left out, and an unreadable
    /// check's reason (the raw tag) is cut short and flattened to one line.
    static func logLine(_ outcome: UpdateOutcome, running: ReleaseVersion?, manual: Bool) -> String {
        let name: String
        var latest = "?"
        switch outcome {
        case .newer(let release): name = "newer"; latest = release.tag
        case .upToDate(let v): name = "up to date"; latest = v.description
        case .noRelease: name = "no release"
        case .rateLimited: name = "rate limited"
        case .httpError(let n): name = "HTTP \(n)"
        case .unreachable: name = "unreachable"
        case .unreadable(let reason):
            let flat = String(reason.prefix(40)).replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "://", with: ":/")
            name = "unreadable (\(flat))"
        }
        return "update check (\(manual ? "manual" : "automatic")): \(name) — latest \(latest), running \(running?.description ?? "?")"
    }
}
