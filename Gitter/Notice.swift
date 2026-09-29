import Foundation
import GitCore

/// A message about something that worked, in one of the store's two slots: the transient
/// `notice`, which fades after a few seconds, or the sticky `stickyNotice`, which stays until it
/// is dismissed or replaced (`RepositoryStore+Notices`).
struct Notice: Equatable {
    /// What the banner says. Built from outside text only through `RemoteWording.plain`, so
    /// each line of it is capped; the `links` are not.
    let text: String
    /// Whole addresses (`NoticeLinks`), never capped: what Open and Copy Link act on.
    var links: [URL] = []
    /// The banner's buttons, in order, before its ×.
    var actions: [NoticeAction] = []
}

extension Notice {
    /// `text`, with Open and Copy Link for the first of `links` when there is one — a push's
    /// result, whose pull-request link must outlive a four-second fade. Without links it is a
    /// plain notice, and stays transient.
    static func linked(text: String, links: [URL]) -> Notice {
        guard let first = links.first else { return Notice(text: text) }
        return Notice(text: text, links: links, actions: [.openLink(first), .copyLink(first)])
    }
}

/// A button on a notice. `RepositoryStore.perform(_:)` does it; a new kind is one more case
/// there, one more title in `NoticeWording`, and nothing in the banner.
enum NoticeAction: Equatable {
    case openLink(URL)
    case copyLink(URL)
    /// Pops the entry a stash just filed — the way back from "Your changes are in stash …".
    /// The `Stash` is the entry as it was filed; the button finds it again by sha
    /// (`popOfferedStash`), and GitCore's check that `stash@{index}` is still this sha guards it.
    case popStash(Stash)
    /// Puts back what a discard took (`RepositoryStore.undoDiscard`). Several receipts for one
    /// confirm — Discard All…'s tracked request and its untracked one — in the order they ran;
    /// the undo runs them in reverse.
    case undoDiscard([DiscardReceipt])
}

/// The words on a notice's buttons.
enum NoticeWording {
    static func title(_ action: NoticeAction) -> String {
        switch action {
        case .openLink: "Open"
        case .copyLink: "Copy Link"
        case .popStash: "Pop Stash"
        case .undoDiscard: DiscardWording.undoButton
        }
    }
}

/// The links a hosting service prints after a push ("Create a pull request … by visiting:"),
/// taken out of its `remote:` lines as whole addresses.
///
/// A server's hook can print anything, so what comes out is narrow: `http` and `https` only,
/// no userinfo, no trailing sentence punctuation. The **text** of the same lines goes to the
/// notice through `RemoteWording.plain` and is capped at 200 characters there; a link is taken
/// here and never capped, so Open and Copy Link get the address whole even when the banner
/// shows it cut.
enum NoticeLinks {
    /// Lines are the host's `remote:` lines as `PushResult.remoteMessages` gives them
    /// (already redacted). Returns whole http(s) URLs in order, deduplicated, trailing
    /// `.,;:` trimmed (and a `)` when unbalanced), userinfo removed; never capped in length.
    static func extract(fromRemoteLines lines: [String]) -> [URL] {
        var found: [URL] = []
        for line in lines {
            // Redacted once more: cheap, and this function must not depend on its caller for
            // the one thing that would put a token on the pasteboard. Not enough on its own —
            // the redactor looks at the first `://` of a run and does not cut at an escape, so
            // `ftp://x/https://u:t@h/p` passes it whole — which is why `link(in:)` also drops
            // the userinfo `URLComponents` finds.
            let redacted = RemoteFailureParser.redactingCredentials(line)
            for run in runs(in: redacted) {
                guard let url = link(in: run), !found.contains(url) else { continue }
                found.append(url)
            }
        }
        return found
    }

    /// Whether Open may hand `url` to the system: a web page, never a file, a script or an app's
    /// own scheme.
    static func canOpen(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// The characters an address ends before: whitespace, controls (an escape sequence's
    /// `ESC`), and the quotes and angle brackets text puts around one.
    private static func isDelimiter(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isWhitespace { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: break
        }
        return "\"'<>`".unicodeScalars.contains(scalar)
    }

    /// `line` cut at every delimiter, scalar by scalar: a joiner or a mark after a delimiter
    /// must not hide it inside one `Character` (the lesson of `redactingCredentials`).
    private static func runs(in line: String) -> [String] {
        var runs: [String] = []
        var run = String.UnicodeScalarView()
        for scalar in line.unicodeScalars {
            if isDelimiter(scalar) {
                if !run.isEmpty { runs.append(String(run)) }
                run = String.UnicodeScalarView()
            } else {
                run.append(scalar)
            }
        }
        if !run.isEmpty { runs.append(String(run)) }
        return runs
    }

    /// Sentence punctuation after an address, always trimmed. A `)` is trimmed only when it is
    /// unbalanced (`trimmingTrailingPunctuation`).
    private static let trailing: Set<Character> = [".", ",", ";", ":"]

    /// `candidate` without the punctuation a sentence put after it. A closing parenthesis goes
    /// only while the address holds more `)` than `(`: `(https://h/x)` loses its wrapper, but
    /// `https://h/wiki/Foo_(bar)` and `?q=(1)` keep theirs.
    private static func trimmingTrailingPunctuation(_ candidate: Substring) -> Substring {
        var candidate = candidate
        while let last = candidate.last {
            if trailing.contains(last) {
                candidate = candidate.dropLast()
            } else if last == ")",
                candidate.filter({ $0 == ")" }).count > candidate.filter({ $0 == "(" }).count
            {
                candidate = candidate.dropLast()
            } else {
                break
            }
        }
        return candidate
    }

    /// The address that starts at the first `http://` or `https://` in `run`, trimmed, without
    /// userinfo; nil if there is none or it has no host.
    private static func link(in run: String) -> URL? {
        guard
            let start = [
                run.range(of: "https://", options: .caseInsensitive),
                run.range(of: "http://", options: .caseInsensitive),
            ].compactMap({ $0?.lowerBound }).min()
        else { return nil }
        let candidate = trimmingTrailingPunctuation(run[start...])
        guard var components = URLComponents(string: String(candidate)),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { return nil }
        components.user = nil
        components.password = nil
        return components.url
    }
}
