import Foundation
import Testing

@testable import GitCore

/// The safety promise of this milestone is an *absence*: no force flag anywhere in the code
/// that runs git. This suite makes that absence something the test run can fail on.
@Suite struct ForceFlagScannerTests {
    /// `GitCore/Sources/GitCore`, found relative to this file rather than the working
    /// directory, which `swift test` does not pin down.
    static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)  // .../GitCore/Tests/GitCoreTests/ForceFlagScannerTests.swift
            .deletingLastPathComponent()  // GitCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // GitCore
            .appendingPathComponent("Sources/GitCore")
    }

    // MARK: - The rule itself

    @Test func gitCoreSourcesContainNoForceFlags() throws {
        let sources = try ForceFlagScanner.gitCoreSources(root: Self.sourcesRoot)
        #expect(sources.count >= 10, "found no sources to scan, so this test would prove nothing")
        #expect(sources.keys.contains("CLIGitBackend.swift"))

        for (path, text) in sources.sorted(by: { $0.key < $1.key }) {
            let findings = ForceFlagScanner.findings(in: text)
            #expect(findings.isEmpty, "\(path): \(findings.joined(separator: "; "))")
        }
    }

    // MARK: - Proof the scanner is not vacuous

    @Test(arguments: [
        #"_ = try await run(["switch", "--force", branch], cwd: root)"#,
        #"_ = try await run(["switch", "-f", branch], cwd: root)"#,
        #"_ = try await run(["switch", "--discard-changes", branch], cwd: root)"#,
        #"_ = try await run(["switch", "-C", name, start], cwd: root)"#,
        #"_ = try await run(["switch", "--merge", branch], cwd: root)"#,
        #"_ = try await run(["branch", "-M", old, new], cwd: root)"#,
        #"_ = try await run(["reset", "--hard", sha], cwd: root)"#,
        #"_ = try await run(["checkout", "--", path], cwd: root)"#,
        #"_ = try await run(["clean", "-d", path], cwd: root)"#,
        #"_ = try await run(["stash", "push"], cwd: root)"#,
        #"_ = try await run(["restore", "--worktree", "--", path], cwd: root)"#,
    ])
    func catchesAForbiddenInvocation(source: String) {
        #expect(!ForceFlagScanner.findings(in: source).isEmpty, "missed: \(source)")
    }

    @Test(arguments: [
        #"_ = try await run(["branch", "-D", name], cwd: root)"#,
        #"_ = try await run(["merge", "--abort"], cwd: root)"#,
        #"_ = try await run(["cherry-pick", "--abort"], cwd: root)"#,
        #"_ = try await run(["reset", "--merge"], cwd: root)"#,
        #"_ = try await run(["switch", "--no-guess", "--end-of-options", branch], cwd: root)"#,
        #"_ = try await run(["switch", "--detach", "--end-of-options", revision], cwd: root)"#,
        #"_ = try await run(["restore", "--staged", "--"] + paths, cwd: root)"#,
        #"_ = try await run(["reset", "-q"], cwd: root)"#,
    ])
    func allowsTheOperationsThisMilestoneNeeds(source: String) {
        #expect(ForceFlagScanner.findings(in: source).isEmpty,
                "false positive: \(ForceFlagScanner.findings(in: source))")
    }

    // MARK: - Robustness of the lexer

    /// The whole point of lexing rather than grepping: this file's own prose says `--force`
    /// and `reset --hard` repeatedly, and so does the production code's documentation.
    @Test func ignoresFlagsMentionedInComments() {
        let source = """
            // Never pass --force or --discard-changes here; `git reset --hard` would
            // destroy the worktree. See also `git checkout -- <path>` and `git clean -fd`.
            /* switch -C name, branch -M old new, stash push */
            _ = try await run(["switch", "--no-guess", branch], cwd: root)
            """
        #expect(ForceFlagScanner.findings(in: source).isEmpty)
    }

    /// A branch really named `--force` is data, not a flag — but it can only reach git after
    /// `--end-of-options`, and it is never a string literal in our sources. The scanner does
    /// flag the literal wherever it appears; this test records that deliberate over-strictness.
    @Test func flagsAForbiddenTokenEvenOutsideAnArgumentArray() {
        #expect(!ForceFlagScanner.findings(in: #"let dangerous = "--force""#).isEmpty)
    }

    @Test func doesNotConfuseElementsOfNestedExpressions() {
        let source = #"""
            _ = try await run(["branch", "--end-of-options", name] + (start.map { [$0] } ?? []), cwd: root)
            """#
        #expect(ForceFlagScanner.findings(in: source).isEmpty)
    }
}
