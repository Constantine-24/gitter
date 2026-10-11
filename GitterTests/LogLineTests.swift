import Foundation
import GitCore
import Testing

@testable import Gitter

/// P1 Task 2: what a line of the app's log looks like — an event's time stamp, the escaping that
/// keeps every event and every git call on lines of its own (RF3), the quoting of arguments, and a
/// git call's entry with its stderr indented under it.
@Suite struct LogLineTests {

    @Test func anEventStartsWithAnISO8601TimeWithMillisecondsAndAnOffset() throws {
        let line = LogLine.event("hello", at: Date())
        let pattern = try Regex(#"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}[+-]\d\d:\d\d hello$"#)
        #expect(line.wholeMatch(of: pattern) != nil, "\(line)")
    }

    @Test func theTimeIsTheLocalTimeWithItsOffset() throws {
        // 2026-10-11T06:08:38.264Z.
        let date = Date(timeIntervalSince1970: 1_791_698_918.264)
        let dubai = try #require(TimeZone(secondsFromGMT: 4 * 3600))
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let newfoundland = try #require(TimeZone(secondsFromGMT: -(3 * 3600 + 1800)))
        #expect(LogLine.time(date, in: dubai) == "2026-10-11T10:08:38.264+04:00")
        #expect(LogLine.time(date, in: utc) == "2026-10-11T06:08:38.264+00:00")
        #expect(LogLine.time(date, in: newfoundland) == "2026-10-11T02:38:38.264-03:30")
    }

    /// RF3: a newline, a carriage return or a tab in a text never breaks a line of the log, nor
    /// does any other control character; everything else is kept as it is.
    @Test func controlCharactersAreEscaped() {
        #expect(LogLine.escape("a\nb") == #"a\nb"#)
        #expect(LogLine.escape("a\rb") == #"a\rb"#)
        #expect(LogLine.escape("a\tb") == #"a\tb"#)
        #expect(LogLine.escape("a\u{0}b") == #"a\u{00}b"#)
        #expect(LogLine.escape("a\u{7F}b") == #"a\u{7F}b"#)
        #expect(LogLine.escape("a\u{1B}[31mb") == #"a\u{1B}[31mb"#)
        #expect(LogLine.escape(#"café ✓ "q" 'q'"#) == #"café ✓ "q" 'q'"#)
        let escaped = LogLine.escape("one\ntwo\r\nthree\u{0}")
        #expect(!escaped.contains("\n") && !escaped.contains("\r") && !escaped.contains("\u{0}"))
    }

    /// The final review's m6: the C1 controls (NEL among them) and the line and paragraph
    /// separators, which a text view may break a line at, are escaped too; and a backslash is
    /// doubled, so a text holding a backslash and an `n` reads otherwise than an escaped newline.
    @Test func c1ControlsSeparatorsAndABackslashAreEscaped() {
        #expect(LogLine.escape("a\u{80}b") == #"a\u{80}b"#)
        #expect(LogLine.escape("a\u{85}b") == #"a\u{85}b"#)
        #expect(LogLine.escape("a\u{9F}b") == #"a\u{9F}b"#)
        #expect(LogLine.escape("a\u{2028}b") == #"a\u{2028}b"#)
        #expect(LogLine.escape("a\u{2029}b") == #"a\u{2029}b"#)
        #expect(LogLine.escape(#"a\b"#) == #"a\\b"#)
        #expect(LogLine.escape(#"a\nb"#) != LogLine.escape("a\nb"))
        // Next to them, kept: U+00A0 (after the C1 block) and U+2027 (before the separators).
        #expect(LogLine.escape("a\u{A0}b\u{2027}c") == "a\u{A0}b\u{2027}c")
    }

    /// The control for the backslash row: the escaped text is not the text as it was.
    @Test func theBackslashCheckCanFail() {
        withKnownIssue("a backslash is doubled, so it is not kept as it is") {
            #expect(LogLine.escape(#"a\nb"#) == #"a\nb"#)
        }
    }

    /// A quoted argument's `'\''` is written as it is: the escape runs on each part of a git line
    /// before the quoting, so the quoting's own backslash is not doubled, while one in the argument is.
    @Test func aQuotedArgumentsBackslashesReadOneWay() {
        let entry = CommandLogEntry(
            started: Date(), duration: .zero, directory: URL(fileURLWithPath: #"/tmp/a\b"#),
            rawArguments: ["stash", "push", "--message", #"it's a\b"#], outcome: .succeeded, rawStderr: "")
        let line = LogLine.entry(entry)
        #expect(line.hasSuffix(#" git 0.000s /tmp/a\\b: stash push --message 'it'\''s a\\b' → ok"#), "\(line)")
    }

    @Test func anEventsTextIsEscaped() {
        let line = LogLine.event("banner /tmp/repo: line one\nline two", at: Date())
        #expect(!line.contains("\n"))
        #expect(line.hasSuffix(#" banner /tmp/repo: line one\nline two"#))
    }

    @Test func anArgumentWithASpaceAQuoteOrNothingIsSingleQuoted() {
        #expect(LogLine.quoted("") == "''")
        #expect(LogLine.quoted("a b") == "'a b'")
        #expect(LogLine.quoted("it's") == #"'it'\''s'"#)
        #expect(LogLine.quoted(#"say "hi""#) == #"'say "hi"'"#)
        #expect(LogLine.quoted("--porcelain=v2") == "--porcelain=v2")
        #expect(LogLine.quoted("refs/heads/main") == "refs/heads/main")
    }

    @Test func anEntrysStderrIsIndentedUnderItsFirstLine() throws {
        let started = Date(timeIntervalSince1970: 1_791_698_918.264)
        let entry = CommandLogEntry(
            started: started, duration: .milliseconds(12), directory: URL(fileURLWithPath: "/tmp/my repo"),
            rawArguments: ["commit", "-F", "/tmp/msg file"], outcome: .exitCode(128),
            rawStderr: "fatal: one\nhint: two\nhint: three\n")
        let lines = LogLine.entry(entry).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 4, "\(lines)")
        let first = try #require(lines.first)
        #expect(
            first == "\(LogLine.time(started)) git 0.012s /tmp/my repo: commit -F '/tmp/msg file' → exit 128")
        #expect(Array(lines.dropFirst()) == ["    fatal: one", "    hint: two", "    hint: three"])
    }

    @Test func aNewlineInsideAnArgumentStaysOnTheFirstLineEscaped() {
        let entry = CommandLogEntry(
            started: Date(), duration: .seconds(1.5), directory: URL(fileURLWithPath: "/tmp/repo"),
            rawArguments: ["stash", "push", "--message", "two\nlines"], outcome: .succeeded, rawStderr: "")
        let line = LogLine.entry(entry)
        #expect(!line.contains("\n"))
        #expect(line.hasSuffix(#" git 1.500s /tmp/repo: stash push --message two\nlines → ok"#), "\(line)")
    }

    @Test func anEntrysStderrLinesAreEscapedEachOnItsOwn() {
        let entry = CommandLogEntry(
            started: Date(), duration: .zero, directory: URL(fileURLWithPath: "/tmp/repo"),
            rawArguments: ["fetch"], outcome: .exitCode(1), rawStderr: "a\tb\r\nc\u{1B}d")
        let lines = LogLine.entry(entry).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(Array(lines.dropFirst()) == [#"    a\tb\r"#, #"    c\u{1B}d"#])
    }

    /// I1 through the app's line: a password the prose redactor would not see never reaches it.
    @Test func aPasswordWithAParenthesisIsInNoLine() {
        let entry = CommandLogEntry(
            started: Date(), duration: .zero, directory: URL(fileURLWithPath: "/tmp/repo"),
            rawArguments: ["remote", "add", "--end-of-options", "origin", "https://me:p(ss)@example.invalid/x.git"],
            outcome: .succeeded, rawStderr: "")
        let line = LogLine.entry(entry)
        #expect(!line.contains("p(ss)"), "\(line)")
        #expect(line.contains("origin https://example.invalid/x.git → ok"), "\(line)")
    }

    @Test func everyOutcomeHasItsWords() {
        func words(_ outcome: CommandLogEntry.Outcome) -> String {
            let entry = CommandLogEntry(
                started: Date(), duration: .zero, directory: URL(fileURLWithPath: "/r"), rawArguments: ["status"],
                outcome: outcome, rawStderr: "")
            return String(LogLine.entry(entry).split(separator: " → ").last ?? "")
        }
        #expect(words(.succeeded) == "ok")
        #expect(words(.exitCode(1)) == "exit 1")
        #expect(words(.killed) == "killed")
        #expect(words(.cancelled) == "cancelled")
        #expect(words(.launchFailed("no such file")) == "launch failed: no such file")
        #expect(words(.refusedBeforeLaunch("too many")) == "refused before launch: too many")
    }
}
