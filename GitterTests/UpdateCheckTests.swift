import Foundation
import Testing

@testable import Gitter

/// Update notices Task 1: the pure core — versions, GitHub's latest-release answer, URL choice,
/// outcomes, the due rule and the skip rule. No network, no clock, no defaults.
@Suite struct UpdateCheckTests {

    static let fixture = """
        {"tag_name":"v0.2.0","html_url":"https://github.com/Constantine-24/gitter/releases/tag/v0.2.0",\
        "body":"First public release, notarized by Apple.","assets":[{"name":"Gitter-0.2.0-409.dmg",\
        "browser_download_url":"https://github.com/Constantine-24/gitter/releases/download/v0.2.0/Gitter-0.2.0-409.dmg"}]}
        """

    static let running = ReleaseVersion("0.2.0")!
    static let fallback = URL(string: "https://github.com/Constantine-24/gitter/releases/latest")!
    static let goodPage = "https://github.com/Constantine-24/gitter/releases/tag/v0.3.0"

    static func answer(_ json: String) -> UpdateAnswer { .response(status: 200, body: Data(json.utf8)) }

    @Test func versionsParseAndCompare() {
        #expect(ReleaseVersion("v0.2.0")?.parts == [0, 2, 0])
        #expect(ReleaseVersion("0.10.0")! > ReleaseVersion("0.9.0")!)
        #expect(ReleaseVersion("0.2")! == ReleaseVersion("0.2.0")!)
        #expect(ReleaseVersion("0.2")!.hashValue == ReleaseVersion("0.2.0")!.hashValue)
        #expect(ReleaseVersion("1.2.3.4") != nil)
        #expect(ReleaseVersion("0.2.0")!.description == "0.2.0")
        #expect(ReleaseVersion("v1.2")!.description == "1.2")
        for bad in ["", "v", "1.2.3.4.5", "1.2-beta", "1..2", "-1.0", " 1.0", "1.0 ", "V1.0", "１.0", "1.0\n", "99999999999999999999.0"] {
            #expect(ReleaseVersion(bad) == nil, "\(bad.debugDescription)")
        }
    }

    @Test func theLiveAnswerReadsAsUpToDate() {
        let live = Self.answer(Self.fixture)
        #expect(UpdateCheck.outcome(of: live, running: Self.running) == .upToDate(Self.running))
        guard case .newer(let release) = UpdateCheck.outcome(of: live, running: ReleaseVersion("0.1.0")!) else {
            Issue.record("expected .newer")
            return
        }
        #expect(release.tag == "v0.2.0")
        #expect(release.version == Self.running)
        #expect(
            release.downloadURL.absoluteString
                == "https://github.com/Constantine-24/gitter/releases/download/v0.2.0/Gitter-0.2.0-409.dmg")
        #expect(release.pageURL.absoluteString == "https://github.com/Constantine-24/gitter/releases/tag/v0.2.0")
        #expect(release.notes == "First public release, notarized by Apple.")
    }

    @Test func statusesMapToOutcomes() {
        func outcome(_ a: UpdateAnswer) -> UpdateOutcome { UpdateCheck.outcome(of: a, running: Self.running) }
        #expect(outcome(.response(status: 404, body: Data())) == .noRelease)
        #expect(outcome(.response(status: 403, body: Data())) == .rateLimited)
        #expect(outcome(.response(status: 429, body: Data())) == .rateLimited)
        #expect(outcome(.response(status: 500, body: Data())) == .httpError(500))
        let offline = "The Internet connection appears to be offline."
        #expect(outcome(.failure(offline)) == .unreachable(offline))
        for body in ["{}", "[]", #"{"tag_name":"latest"}"#, #"{"tag_name":2}"#] {
            guard case .unreadable = outcome(Self.answer(body)) else {
                Issue.record("expected .unreadable for \(body)")
                continue
            }
        }
        guard case .unreadable = outcome(.response(status: 200, body: Data([0xFF, 0xFE, 0x00, 0xC0]))) else {
            Issue.record("expected .unreadable for non-UTF-8 bytes")
            return
        }
        #expect(outcome(Self.answer(#"{"tag_name":"latest"}"#)) == .unreadable("latest"))
        #expect(outcome(Self.answer("{}")) == .unreadable("json"))
    }

    @Test func olderAndEqualReleasesAreUpToDate() {
        for tag in ["v0.1.9", "v0.2.0"] {
            let json = #"{"tag_name":"\#(tag)"}"#
            let got = UpdateCheck.outcome(of: Self.answer(json), running: Self.running)
            #expect(got == .upToDate(ReleaseVersion(tag)!))
        }
    }

    @Test func aNewerReleaseWithoutAssetsOffersTheReleasePage() {
        let json = #"{"tag_name":"v0.3.0","html_url":"\#(Self.goodPage)","assets":"nope"}"#
        guard case .newer(let release) = UpdateCheck.outcome(of: Self.answer(json), running: Self.running) else {
            Issue.record("expected .newer")
            return
        }
        #expect(release.downloadURL.absoluteString == Self.goodPage)
        #expect(release.notes == UpdateWording.noNotes)
    }

    @Test func hostileURLsFallBackToTheFixedPage() {
        let dl = "https://github.com/Constantine-24/gitter/releases/download/v1/G.dmg"
        for url in [
            "https://evil.example/Constantine-24/gitter/releases/download/v1/G.dmg",
            "http://github.com/Constantine-24/gitter/releases/download/v1/G.dmg",
            "https://github.com/other/gitter/releases/download/v1/G.dmg",
            "https://github.com.evil.example/Constantine-24/gitter/releases/download/v1/G.dmg",
            "https://github.com/Constantine-24/gitter/releases/download/../../../../other/x.dmg",
            "javascript:alert(1)",
            "",
        ] {
            #expect(UpdateCheck.downloadURL(assets: [("G.dmg", url)], htmlURL: nil) == Self.fallback, "\(url)")
        }
        #expect(UpdateCheck.downloadURL(assets: [], htmlURL: "https://evil.example/releases/tag/v1") == Self.fallback)
        #expect(UpdateCheck.downloadURL(assets: [], htmlURL: nil) == Self.fallback)
        #expect(UpdateCheck.downloadURL(assets: [("a.zip", dl)], htmlURL: nil) == Self.fallback)
        #expect(UpdateCheck.downloadURL(assets: [("Gitter.DMG", dl)], htmlURL: nil) == URL(string: dl)!)
        // A bad first DMG is skipped for a later good one.
        #expect(
            UpdateCheck.downloadURL(assets: [("a.dmg", "https://evil.example/a.dmg"), ("b.dmg", dl)], htmlURL: nil)
                == URL(string: dl)!)
        #expect(
            UpdateCheck.downloadURL(assets: [], htmlURL: Self.goodPage) == URL(string: Self.goodPage)!)
        #expect(UpdateCheck.pageURL(htmlURL: Self.goodPage) == URL(string: Self.goodPage)!)
        #expect(UpdateCheck.pageURL(htmlURL: "https://evil.example/") == Self.fallback)
        #expect(UpdateCheck.pageURL(htmlURL: nil) == Self.fallback)
    }

    @Test func notesAreCappedAndCleaned() {
        #expect(UpdateCheck.notes("a\r\nb\rc") == "a\nb\nc")
        #expect(UpdateCheck.notes(nil) == UpdateWording.noNotes)
        #expect(UpdateCheck.notes("") == UpdateWording.noNotes)
        #expect(UpdateCheck.notes(" \n\t\r\n ") == UpdateWording.noNotes)
        #expect(UpdateCheck.notes(String(repeating: "x", count: 10_000)) == String(repeating: "x", count: 4_000) + "…")
        #expect(UpdateCheck.notes(String(repeating: "x", count: 4_000)) == String(repeating: "x", count: 4_000))
        #expect(UpdateCheck.notes("a\u{0}b\u{0}") == "ab")
        #expect(UpdateCheck.notes("\u{0}") == UpdateWording.noNotes)
    }

    @Test func isDueRules() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UpdateCheck.isDue(lastCheck: nil, now: now, enabled: true))
        #expect(!UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-(86_400 - 60)), now: now, enabled: true))
        #expect(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now, enabled: true))
        #expect(!UpdateCheck.isDue(lastCheck: nil, now: now, enabled: false))
        #expect(!UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-200_000), now: now, enabled: false))
    }

    @Test func isDueWhenTheLastCheckIsInTheFuture() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(2 * 86_400), now: now, enabled: true))
    }

    @Test func skipRules() {
        func release(_ v: String) -> LatestRelease {
            LatestRelease(
                tag: "v" + v, version: ReleaseVersion(v)!, downloadURL: Self.fallback, pageURL: Self.fallback,
                notes: "")
        }
        #expect(UpdateCheck.showsAutomatically(release("0.3.0"), skipped: nil))
        #expect(!UpdateCheck.showsAutomatically(release("0.3.0"), skipped: ReleaseVersion("0.3.0")))
        #expect(UpdateCheck.showsAutomatically(release("0.3.1"), skipped: ReleaseVersion("0.3.0")))
    }

    @Test func aSkipBelowTheRunningVersionShowsNothing() {
        let running = ReleaseVersion("0.4.0")!
        let got = UpdateCheck.outcome(of: Self.answer(#"{"tag_name":"v0.4.0"}"#), running: running)
        #expect(got == .upToDate(running))
    }
}
