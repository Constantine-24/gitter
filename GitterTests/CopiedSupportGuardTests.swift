import Foundation
import Testing

/// GitterTests keep copies of two GitCore test helpers (E2 Ruling 6): `TimeLimitSupport.swift`
/// (`CallUnderTest` and its companions) and `TestGitEnvironment.isolated`. GitCore's test target
/// cannot be imported, so this reads both GitCore files from the source tree (through `#filePath`,
/// read only, never written) and fails when a copy has drifted. The backlog's E3 item for one
/// shared test-support target would make this unnecessary.
@Suite struct CopiedSupportGuardTests {

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    private static func read(_ relative: String) throws -> String {
        try String(contentsOf: repositoryRoot.appending(path: relative), encoding: .utf8)
    }

    /// `text` from the first `start` up to, not including, the first `end` after it (to the end of
    /// the text when `end` is nil).
    static func region(of text: String, from start: String, to end: String?) throws -> String {
        let begin = try #require(text.range(of: start), "no \(start) in the file")
        guard let end else { return String(text[begin.lowerBound...]) }
        let stop = try #require(text.range(of: end, range: begin.upperBound..<text.endIndex), "no \(end) after it")
        return String(text[begin.lowerBound..<stop.lowerBound])
    }

    /// Code lines only: no comments, no blank lines. For the environment, whose comments differ
    /// on purpose.
    static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The one documented difference: `value`'s `what` is `@Sendable` in the copy.
    static func withoutTheDocumentedSendable(_ text: String) -> String {
        text.replacingOccurrences(of: "@autoclosure @Sendable () -> String", with: "@autoclosure () -> String")
    }

    static func timeLimitRegions() throws -> (original: String, copy: String) {
        let start = "/// What `CallUnderTest.value` records"
        let original = try region(
            of: try read("GitCore/Tests/GitCoreTests/TimeLimitSupport.swift"),
            from: start, to: "/// The controls for `CallUnderTest`")
        let copy = try region(
            of: try read("GitterTests/TimeLimitSupport.swift"), from: start, to: nil)
        return (original, withoutTheDocumentedSendable(copy).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func environmentRegions() throws -> (original: String, copy: String) {
        let start = "static let isolated: Bool = {"
        let original = try region(
            of: try read("GitCore/Tests/GitCoreTests/TestGitEnvironment.swift"), from: start, to: "}()")
        let copy = try region(of: try read("GitterTests/GitterTestEnvironment.swift"), from: start, to: "}()")
        return (codeOnly(original), codeOnly(copy))
    }

    @Test func theCopiesMatchGitCoresSources() throws {
        let timeLimit = try Self.timeLimitRegions()
        #expect(timeLimit.original.trimmingCharacters(in: .whitespacesAndNewlines) == timeLimit.copy,
            "GitterTests/TimeLimitSupport.swift differs from GitCore's TimeLimitSupport.swift")
        let environment = try Self.environmentRegions()
        #expect(environment.original == environment.copy,
            "GitterTestEnvironment.isolated differs from GitCore's TestGitEnvironment.isolated")
    }

    /// Control: one changed character in either copy is caught by the same comparison.
    @Test func aOneCharacterDriftIsCaught() throws {
        let timeLimit = try Self.timeLimitRegions()
        let environment = try Self.environmentRegions()
        let driftedTimeLimit = timeLimit.copy.replacingOccurrences(of: "waiter", with: "waiteR")
        let driftedEnvironment = environment.copy.replacingOccurrences(of: "\"1\"", with: "\"0\"")
        #expect(driftedTimeLimit != timeLimit.copy)
        #expect(driftedEnvironment != environment.copy)
        withKnownIssue("a one-character drift in the hang guard copy") {
            #expect(timeLimit.original.trimmingCharacters(in: .whitespacesAndNewlines) == driftedTimeLimit)
        }
        withKnownIssue("a one-character drift in the environment copy") {
            #expect(environment.original == driftedEnvironment)
        }
    }
}
