import Foundation
import Testing

@testable import Gitter

/// Update notices Task 1: every user-visible string of the update notices, character for character.
@Suite struct UpdateWordingTests {

    static let v020 = ReleaseVersion("0.2.0")!
    static let v030 = ReleaseVersion("v0.3.0")!

    static var newer: UpdateOutcome {
        .newer(
            LatestRelease(
                tag: "v0.3.0", version: v030,
                downloadURL: URL(string: "https://github.com/Constantine-24/gitter/releases/latest")!,
                pageURL: URL(string: "https://github.com/Constantine-24/gitter/releases/latest")!, notes: "n"))
    }

    @Test func alertsAreTheSpecsTable() {
        #expect(UpdateWording.alert(for: .upToDate(Self.v020)) == "You're up to date. Gitter 0.2.0 is the latest version.")
        #expect(UpdateWording.alert(for: .noRelease) == "No release of Gitter is published yet.")
        #expect(
            UpdateWording.alert(for: .rateLimited)
                == "GitHub is limiting requests from this network right now. Try again later.")
        #expect(UpdateWording.alert(for: .httpError(500)) == "GitHub answered with an error (HTTP 500).")
        #expect(
            UpdateWording.alert(for: .unreachable("The Internet connection appears to be offline."))
                == "Gitter couldn't reach GitHub: The Internet connection appears to be offline.")
        #expect(
            UpdateWording.alert(for: .unreachable("The request timed out"))
                == "Gitter couldn't reach GitHub: The request timed out.")
        #expect(
            UpdateWording.alert(for: .unreadable("json"))
                == "Gitter couldn't read GitHub's answer about the latest release.")
        #expect(UpdateWording.alert(for: Self.newer) == nil)
    }

    @Test func windowTextIsTheSketch() {
        #expect(UpdateWording.windowTitle == "Software Update")
        #expect(UpdateWording.headline(Self.v030) == "Gitter 0.3.0 is available")
        #expect(UpdateWording.youHave(Self.v020) == "You have 0.2.0.")
        #expect(UpdateWording.download == "Download")
        #expect(UpdateWording.later == "Later")
        #expect(UpdateWording.skip == "Skip This Version")
        #expect(UpdateWording.releasePage == "Release page")
        #expect(UpdateWording.noNotes == "No release notes.")
        #expect(UpdateWording.checkMenu == "Check for Updates…")
        #expect(UpdateWording.automaticMenu == "Check for Updates Automatically")
    }

    @Test func logLinesNameTheOutcomeTagAndVersionOnly() {
        #expect(
            UpdateWording.logLine(Self.newer, running: Self.v020, manual: false)
                == "update check (automatic): newer — latest v0.3.0, running 0.2.0")
        #expect(
            UpdateWording.logLine(.upToDate(Self.v020), running: Self.v020, manual: true)
                == "update check (manual): up to date — latest 0.2.0, running 0.2.0")
        #expect(
            UpdateWording.logLine(.unreadable("latest"), running: nil, manual: false)
                == "update check (automatic): unreadable (latest) — latest ?, running ?")
        let outcomes: [UpdateOutcome] = [
            Self.newer, .upToDate(Self.v020), .noRelease, .rateLimited, .httpError(502),
            .unreachable("Could not connect to https://api.github.com/x?y=1"),
            .unreadable("https://evil.example/"),
        ]
        // Every control and line-separating character of the untrusted reason becomes a space (I1).
        #expect(
            UpdateWording.logLine(
                .unreadable("a\rb\u{2028}c\u{1B}[31md\u{2029}e\r\nf"), running: Self.v020, manual: false)
                == "update check (automatic): unreadable (a b c [31md e  f) — latest ?, running 0.2.0")
        for outcome in outcomes {
            for manual in [true, false] {
                let line = UpdateWording.logLine(outcome, running: Self.v020, manual: manual)
                #expect(!line.contains("https://"), "\(line)")
                #expect(!line.contains("\n"))
            }
        }
    }
}
