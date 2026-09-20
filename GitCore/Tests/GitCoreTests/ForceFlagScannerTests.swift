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

    /// The whole-tree path — `gitCoreSources` + `findings` together — really fails when a
    /// source file contains a violation.
    ///
    /// Against a throwaway directory, never the real one: a forbidden flag must never be
    /// written into `GitCore/Sources`, even for a moment, even reverted. `gitCoreSources`
    /// takes its root as a parameter precisely so this test can point it somewhere else.
    @Test func theWholeTreeScanFailsOnAFileThatContainsAViolation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("force-flag-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
            func createBranch(_ name: String) async throws {
                var arguments = ["switch", "-c", name]
                arguments += ["--merge"]
                _ = try await run(arguments, cwd: root)
            }
            """.write(to: directory.appendingPathComponent("Offender.swift"), atomically: true,
                      encoding: .utf8)
        try "let clean = [\"switch\", \"--no-guess\", branch]\n"
            .write(to: directory.appendingPathComponent("Fine.swift"), atomically: true,
                   encoding: .utf8)

        let sources = try ForceFlagScanner.gitCoreSources(root: directory)
        #expect(sources.count == 2)
        #expect(ForceFlagScanner.findings(in: try #require(sources["Fine.swift"])).isEmpty)
        let findings = ForceFlagScanner.findings(in: try #require(sources["Offender.swift"]))
        #expect(findings.count == 1)
        #expect(findings.first?.contains("--merge") == true)
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
        // `--quit` leaves the sequencer's state behind instead of undoing it, and `--skip`
        // throws away the commit git stopped on. Neither is ever what Gitter's "Abort" means.
        #"_ = try await run(["cherry-pick", "--quit"], cwd: root)"#,
        #"_ = try await run(["rebase", "--skip"], cwd: root)"#,
    ])
    func catchesAForbiddenInvocation(source: String) {
        #expect(!ForceFlagScanner.findings(in: source).isEmpty, "missed: \(source)")
    }

    /// The allow-list this task added is *positional*: `--abort` is only ever safe after the
    /// five subcommands that have one, and `--merge` only after `reset` (undoing a pending
    /// squash). Anywhere else both are a way to lose work — `git switch --merge` merges local
    /// changes into a checkout silently, `git reset --abort` is not even a command — so the
    /// scanner must not have been widened into "`--abort` and `--merge` are fine now".
    ///
    /// Neither flag is in `alwaysForbidden` (it asserts so below), so nothing here can pass by
    /// way of the whole-file literal sweep: only the per-subcommand rule can catch these.
    @Test(arguments: [
        (#"_ = try await run(["switch", "--abort"], cwd: root)"#, "--abort"),
        (#"_ = try await run(["reset", "--abort"], cwd: root)"#, "--abort"),
        (#"_ = try await run(["branch", "--abort", name], cwd: root)"#, "--abort"),
        (#"var a = ["merge"]; a += ["--abort"]"#, "--abort"),
        (#"_ = try await run(["rebase", "--merge", upstream], cwd: root)"#, "--merge"),
        (#"_ = try await run(["merge", "--merge"], cwd: root)"#, "--merge"),
        (#"_ = try await run(["cherry-pick", x ? "--abort" : "--merge"], cwd: root)"#, "--merge"),
    ])
    func catchesARestrictedFlagAfterTheWrongSubcommand(source: String, flag: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(!findings.isEmpty, "missed: \(source)")
        #expect(findings.contains { $0.contains(flag) }, "\(findings) should name \(flag)")
        #expect(!ForceFlagScanner.alwaysForbidden.contains(flag),
                "\(flag) is always forbidden, so this case would pass without the positional rule")
    }

    /// Three shapes the first version of this scanner missed, each of which the production
    /// code actually uses: `createBranch` builds its argument vector with `var` + `+=`, and a
    /// global option before the subcommand would leave the array unclassified. A fragment
    /// cannot be attributed to a subcommand, so it is checked against the union of the
    /// dangerous flags instead.
    @Test(arguments: [
        #"var a = ["switch", "-c", name]; a += ["--merge"]"#,
        #"var a = ["switch", "-c", name]; a.append("--merge")"#,
        #"_ = try await run(["-C", path, "switch", "--merge", b], cwd: root)"#,
        #"var a = ["switch"]; a += ["--discard-changes"]"#,
        #"var a = ["switch"]; a.append("-C")"#,
        #"_ = try await run([repoFlag, "switch", "--ours"], cwd: root)"#,
    ])
    func catchesAFlagAddedAwayFromItsSubcommand(source: String) {
        #expect(!ForceFlagScanner.findings(in: source).isEmpty, "missed: \(source)")
    }

    /// A flag hidden inside a ternary was the scanner's last structural blind spot: the element
    /// `cond ? "--squash" : "--merge"` holds two literals, and the lexer used to give up on any
    /// element that was not exactly one, so *neither* was ever checked. Every literal inside an
    /// element is now checked, wherever in the expression it sits.
    ///
    /// This is why `CLIGitBackend+Merge.swift` still builds each argument vector as a complete
    /// literal chosen by a `switch`: the scanner sees those plainly, and nobody has to rely on
    /// this rule catching a cleverer shape.
    /// Each case names a flag that is dangerous only *in context* — none of them is in
    /// `alwaysForbidden`, so the whole-file literal sweep cannot be what catches them and the
    /// test cannot pass vacuously. The finding must name the hidden flag itself.
    @Test(arguments: [
        (#"_ = try await run(["switch", squash ? "--merge" : "--no-guess", b], cwd: root)"#, "--merge"),
        (#"_ = try await run(["switch", squash ? "--no-guess" : "--merge", b], cwd: root)"#, "--merge"),
        (#"_ = try await run(["branch", force ? "-M" : "-m", old, new], cwd: root)"#, "-M"),
        (#"var a = ["switch"]; a += [force ? "--ours" : "--theirs"]"#, "--ours"),
        (#"_ = try await run(["merge", x ? "--ff" : (y ? "--no-ff" : "-X"), b], cwd: root)"#, "-X"),
    ])
    func catchesAFlagHiddenInsideATernaryElement(source: String, flag: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(!findings.isEmpty, "missed: \(source)")
        #expect(findings.contains { $0.contains(flag) }, "\(findings) should name \(flag)")
        #expect(!ForceFlagScanner.alwaysForbidden.contains(flag),
                "\(flag) is always forbidden, so this case would pass without the ternary rule")
    }

    /// The mirror image, so the new rule is not simply "flag every multi-literal element":
    /// a ternary between two harmless flags stays clean, and the element's first literal is
    /// still not mistaken for a subcommand.
    @Test(arguments: [
        #"_ = try await run(["merge", squash ? "--squash" : "--ff", b], cwd: root)"#,
        #"_ = try await run(["merge", "--ff", squash ? "--squash" : "--no-edit", b], cwd: root)"#,
        #"_ = try await run([squash ? "--squash" : "--ff", "b"], cwd: root)"#,
    ])
    func doesNotFireOnATernaryBetweenHarmlessFlags(source: String) {
        #expect(ForceFlagScanner.findings(in: source).isEmpty,
                "false positive: \(ForceFlagScanner.findings(in: source))")
    }

    /// The fragment rule must not fire on what `CLIGitBackend` already does: `commitDiff`
    /// builds `["--no-commit-id", "-p", "-U3", "-M", "-r"]`, a leading-flag fragment whose
    /// `-M` means rename detection, not `branch -M`. That is why `-M` is only dangerous in a
    /// `branch`-classified array.
    @Test(arguments: [
        #"let arguments = ["--no-commit-id", "-p", "-U3", "-M", "-r"]"#,
        #"let arguments = ["--no-commit-id", "--name-status", "-z", "-r", "-M"]"#,
        #"var arguments = ["commit", "-q"]; arguments.append("--amend")"#,
        #"var arguments = ["commit", "-q"]; arguments += ["-F", file.path]"#,
        #"var arguments = ["switch", "-c", name]; arguments += ["--end-of-options", startPoint]"#,
    ])
    func doesNotFireOnTheArgumentFragmentsTheCodeAlreadyBuilds(source: String) {
        #expect(ForceFlagScanner.findings(in: source).isEmpty,
                "false positive: \(ForceFlagScanner.findings(in: source))")
    }

    @Test(arguments: [
        #"_ = try await run(["branch", "-D", name], cwd: root)"#,
        #"_ = try await run(["merge", "--abort"], cwd: root)"#,
        #"_ = try await run(["cherry-pick", "--abort"], cwd: root)"#,
        #"_ = try await run(["revert", "--abort"], cwd: root)"#,
        #"_ = try await run(["rebase", "--abort"], cwd: root)"#,
        #"_ = try await run(["am", "--abort"], cwd: root)"#,
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
