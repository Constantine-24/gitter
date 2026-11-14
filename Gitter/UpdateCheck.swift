import Foundation

/// A release number: one to four dot-separated non-negative integers, compared part by part with
/// missing parts as 0, so `0.10.0` is newer than `0.9.0` and `0.2` equals `0.2.0`.
struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let parts: [Int]

    /// An optional lowercase leading "v", then 1...4 ASCII-digit groups joined by "."; nothing else.
    init?(_ text: String) {
        let body = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let groups = body.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(groups.count) else { return nil }
        var parts: [Int] = []
        for group in groups {
            guard !group.isEmpty, group.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let n = Int(group) else {
                return nil
            }
            parts.append(n)
        }
        self.parts = parts
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    /// The parts without trailing zeros: the identity that equality, hashing and order share.
    private var significant: ArraySlice<Int> {
        var end = parts.count
        while end > 0, parts[end - 1] == 0 { end -= 1 }
        return parts[..<end]
    }

    static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool { lhs.significant == rhs.significant }

    func hash(into hasher: inout Hasher) { hasher.combine(Array(significant)) }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        for i in 0..<max(lhs.parts.count, rhs.parts.count) {
            let a = i < lhs.parts.count ? lhs.parts[i] : 0
            let b = i < rhs.parts.count ? rhs.parts[i] : 0
            if a != b { return a < b }
        }
        return false
    }
}

/// The latest release as GitHub described it, after every field was checked.
struct LatestRelease: Equatable, Sendable {
    let tag: String
    let version: ReleaseVersion
    let downloadURL: URL
    let pageURL: URL
    let notes: String
}

/// What a fetcher returns: GitHub's answer, or the failure's description.
enum UpdateAnswer: Equatable, Sendable {
    case response(status: Int, body: Data)
    case failure(String)
}

/// What a check found.
enum UpdateOutcome: Equatable, Sendable {
    case newer(LatestRelease)
    case upToDate(ReleaseVersion)
    case noRelease
    case rateLimited
    case httpError(Int)
    case unreachable(String)
    case unreadable(String)
}

/// The rules of the update check, all pure: reading GitHub's answer (untrusted), choosing the URLs
/// to offer, and deciding when a check is due and whether a notice shows.
enum UpdateCheck {
    static let apiURL = URL(string: "https://api.github.com/repos/Constantine-24/gitter/releases/latest")!
    static let downloadPrefix = "https://github.com/Constantine-24/gitter/releases/download/"
    static let releasesPrefix = "https://github.com/Constantine-24/gitter/releases/"
    static let latestPage = URL(string: "https://github.com/Constantine-24/gitter/releases/latest")!
    static let notesLimit = 4_000
    static let dueInterval: TimeInterval = 86_400

    static func outcome(of answer: UpdateAnswer, running: ReleaseVersion) -> UpdateOutcome {
        switch answer {
        case .failure(let description):
            return .unreachable(description)
        case .response(let status, let body):
            switch status {
            case 200:
                switch read(body) {
                case .failure(let failure): return .unreadable(failure.reason)
                case .success(let release):
                    return release.version > running ? .newer(release) : .upToDate(release.version)
                }
            case 404: return .noRelease
            case 403, 429: return .rateLimited
            default: return .httpError(status)
            }
        }
    }

    /// nil when the answer can't be read: not a JSON object, or no string `tag_name` holding a version.
    static func release(from json: Data) -> LatestRelease? {
        if case .success(let release) = read(json) { return release }
        return nil
    }

    /// The failure's reason is for the log: the raw tag when it isn't a version, otherwise "json".
    private static func read(_ json: Data) -> Result<LatestRelease, ReadFailure> {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
            let tag = object["tag_name"] as? String
        else { return .failure(ReadFailure(reason: "json")) }
        guard let version = ReleaseVersion(tag) else { return .failure(ReadFailure(reason: tag)) }
        var assets: [(name: String, url: String)] = []
        for case let asset as [String: Any] in (object["assets"] as? [Any]) ?? [] {
            if let name = asset["name"] as? String, let url = asset["browser_download_url"] as? String {
                assets.append((name, url))
            }
        }
        let htmlURL = object["html_url"] as? String
        return .success(
            LatestRelease(
                tag: tag, version: version, downloadURL: downloadURL(assets: assets, htmlURL: htmlURL),
                pageURL: pageURL(htmlURL: htmlURL), notes: notes(object["body"] as? String)))
    }

    private struct ReadFailure: Error { let reason: String }

    /// The first `.dmg` asset under the download prefix, else `html_url` under the releases prefix,
    /// else the fixed latest-release page.
    static func downloadURL(assets: [(name: String, url: String)], htmlURL: String?) -> URL {
        for asset in assets where asset.name.lowercased().hasSuffix(".dmg") {
            if let url = trusted(asset.url, prefix: downloadPrefix) { return url }
        }
        return pageURL(htmlURL: htmlURL)
    }

    static func pageURL(htmlURL: String?) -> URL {
        htmlURL.flatMap { trusted($0, prefix: releasesPrefix) } ?? latestPage
    }

    /// The URL when the text starts with the prefix, parses as an https github.com URL and climbs
    /// out of the prefix through no ".." segment.
    private static func trusted(_ text: String, prefix: String) -> URL? {
        guard text.hasPrefix(prefix), let url = URL(string: text), url.scheme == "https", url.host == "github.com",
            !text.dropFirst(prefix.count).split(separator: "/").contains("..")
        else { return nil }
        return url
    }

    /// Plain text: line endings as newlines, no NULs, trimmed, cut at the limit with "…".
    static func notes(_ body: String?) -> String {
        let cleaned = (body ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return UpdateWording.noNotes }
        return cleaned.count > notesLimit ? String(cleaned.prefix(notesLimit)) + "…" : cleaned
    }

    /// Due when enabled and never checked, a day or more since the last check, or a last check that
    /// lies in the future (a clock that went back).
    static func isDue(lastCheck: Date?, now: Date, enabled: Bool) -> Bool {
        guard enabled else { return false }
        guard let lastCheck else { return true }
        return lastCheck > now || now.timeIntervalSince(lastCheck) >= dueInterval
    }

    /// An automatic check shows a release unless it is the skipped version (or older).
    static func showsAutomatically(_ release: LatestRelease, skipped: ReleaseVersion?) -> Bool {
        guard let skipped else { return true }
        return release.version > skipped
    }
}
