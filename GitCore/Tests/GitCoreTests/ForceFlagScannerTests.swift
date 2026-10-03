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

        // "No findings" is also what a lexer that quietly read nothing would report. Count the
        // literals it actually saw, so an empty result is evidence rather than silence.
        var literalCount = 0
        for (path, text) in sources.sorted(by: { $0.key < $1.key }) {
            // The file's path relative to `Sources/GitCore`, because one rule is per file:
            // `read-tree`, `update-index` and `write-tree` are allowed in one file only.
            let findings = ForceFlagScanner.findings(in: text, fileName: path)
            #expect(findings.isEmpty, "\(path): \(findings.joined(separator: "; "))")
            let code = ForceFlagScanner.strippingCommentsAndStringContents(text)
            literalCount += ForceFlagScanner.literals(in: text, code: code).count
        }
        let counted = "\(literalCount) literals lexed out of \(sources.count) files"
        #expect(literalCount > 200, "\(counted): a scan that sees nothing cannot prove an absence")
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
        #"_ = try await run(["restore", "--worktree", "--", path], cwd: root)"#,
        // The working-copy milestone: `stash` left the forbidden subcommands for a table of
        // allowed shapes, and these are the shapes that stay forbidden.
        #"_ = try await run(["stash", "pop", s], cwd: root)"#,
        #"_ = try await run(["stash", "clear"], cwd: root)"#,
        #"_ = try await run(["stash", "apply", "--index", s], cwd: root)"#,
        #"_ = try await run(["stash", "push", "--", p], cwd: root)"#,
        #"_ = try await run(["read-tree", "-u", t], cwd: root)"#,
        #"_ = try await run(["apply", "--unidiff-zero", f], cwd: root)"#,
        #"_ = try await run(["hash-object", "-w", "--", p], cwd: root)"#,
        // `--quit` leaves the sequencer's state behind instead of undoing it, and `--skip`
        // throws away the commit git stopped on. Neither is ever what Gitter's "Abort" means.
        // `--skip` is permitted in exactly three whole vectors since A2 Task 3 (Skip, behind
        // its own record and readiness check); anything else carrying it stays a finding.
        #"_ = try await run(["cherry-pick", "--quit"], cwd: root)"#,
        #"_ = try await run(["rebase", "--skip", upstream], cwd: root)"#,
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
        // `git reset --merge` resets the index to HEAD; `git reset --merge <commit>` moves
        // HEAD there as well. Only the position of the flag tells the two apart.
        (#"_ = try await run(["reset", "--merge", revision], cwd: root)"#, "--merge"),
        (#"_ = try await run(["reset", "--merge", "HEAD~1"], cwd: root)"#, "--merge"),
        (#"_ = try await run(["reset", "--merge", "--end-of-options", rev], cwd: root)"#, "--merge"),
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
        // `--no-recurse-submodules` joined the unstage vector in the working-copy milestone,
        // when every `restore` without it became a finding; the pathspec file in A2 (Ruling 26).
        #"_ = try await run(["restore", "--no-recurse-submodules", "--staged", "--pathspec-from-file=\(file)", "--pathspec-file-nul"], cwd: root)"#,
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

    /// `-B` is `git checkout -B` / `git branch -B`, the force-create this project's README and
    /// design doc have claimed was scanned since the milestone began. It was not: the token
    /// appeared in no table at all, so `a.append("-B")` and a bare `let flag = "-B"` both
    /// walked straight through. Nothing in `GitCore/Sources` uses `-B` (checked with `git
    /// grep`), so adding it costs nothing today.
    @Test(arguments: [
        #"var a = ["switch"]; a.append("-B")"#,
        #"var a = ["branch"]; a += ["-B", name]"#,
        #"let flag = "-B""#,
    ])
    func catchesTheForceCreateFlagTheDocsAlreadyClaimed(source: String) {
        #expect(!ForceFlagScanner.findings(in: source).isEmpty, "missed: \(source)")
    }

    /// The whole-file sweep used to check `alwaysForbidden` alone, so a dangerous token that
    /// reached git by any route the array/append rules could not follow was invisible. Both of
    /// these are real shapes: a flag held in a `let` (the array element is not a literal at
    /// all) and a subcommand appended to a vector built empty.
    @Test(arguments: [
        (#"let resolve = "--ours"; _ = try await run(["merge", resolve, b], cwd: root)"#, "--ours"),
        (#"var a: [String] = []; a.append("clean"); a.append("-fdx")"#, "clean"),
        (#"let sub = "checkout"; _ = try await run([sub, "--", path], cwd: root)"#, "checkout"),
        (#"let flag = "--discard-changes""#, "--discard-changes"),
    ])
    func catchesATokenOnlyTheWholeFileSweepCanSee(source: String, token: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(!findings.isEmpty, "missed: \(source)")
        #expect(findings.contains { $0.contains(token) }, "\(findings) should name \(token)")
    }

    /// The sweep must stay narrower than `fragmentForbidden` in the two places where a token is
    /// legitimate somewhere in `GitCore/Sources`: `--abort`/`--merge` are what `+Abort.swift`
    /// runs, and `-M` is `diff-tree`'s rename detection. Widening onto those would have made
    /// the suite fail on correct code, which is the failure mode that gets a rule deleted.
    @Test(arguments: [
        #"_ = try await run(["merge", "--abort"], cwd: root)"#,
        #"_ = try await run(["reset", "--merge"], cwd: root)"#,
        #"let arguments = ["--no-commit-id", "-p", "-U3", "-M", "-r"]"#,
        #"let arguments = ["diff", "--cached", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/", "-U3", "-M", "--", path]"#,
    ])
    func theWholeFileSweepDoesNotFireOnTokensTheSourcesLegitimatelyUse(source: String) {
        #expect(ForceFlagScanner.findings(in: source).isEmpty,
                "false positive: \(ForceFlagScanner.findings(in: source))")
    }

    /// `-M` used to be subtracted from the fragment union globally, to spare one `diff-tree`
    /// argument list. The carve-out is now that list's own shape — a fragment carrying
    /// `--no-commit-id`, which is not an option `branch` or `switch` has — so `-M` appended to
    /// anything else is caught again.
    ///
    /// The last case is why the carve-out cannot apply to appended literals at all: every
    /// `.append("…")` in a file is pooled into one list, so a `--no-commit-id` appended to one
    /// vector sat in the same list as a `-M` appended to another and excused it. Two unrelated
    /// vectors, one of them `branch`.
    @Test(arguments: [
        #"var a = ["branch"]; a.append("-M")"#,
        #"var a = ["branch"]; a += ["-M", old, new]"#,
        #"_ = try await run([repoFlag, "branch", "-M", old, new], cwd: root)"#,
        #"var d = [String](); d.append("--no-commit-id"); var b = ["branch"]; b.append("-M")"#,
    ])
    func theRenameDetectionCarveOutNoLongerCoversEveryFragment(source: String) {
        #expect(!ForceFlagScanner.findings(in: source).isEmpty, "missed: \(source)")
    }

    /// A trailing comma left an empty phantom element at the end of the vector, so the one
    /// positional rule read `["reset", "--merge",]` as three elements and reported `--merge`
    /// for not being last. A false positive on a vector that is exactly the allowed one.
    @Test(arguments: [
        #"_ = try await run(["reset", "--merge",], cwd: root)"#,
        """
        _ = try await run([
            "reset",
            "--merge",
        ], cwd: root)
        """,
    ])
    func aTrailingCommaDoesNotMakeTheLastElementLookLikeAnArgument(source: String) {
        #expect(ForceFlagScanner.findings(in: source).isEmpty,
                "false positive: \(ForceFlagScanner.findings(in: source))")
    }

    /// The lexer pairs `"` characters, so one unpaired quote inside a multi-line or raw literal
    /// shifts every element boundary after it for the rest of the file — and the failure is
    /// silent, which is the worst shape a safety check can take. It now refuses to judge such a
    /// file at all. `GitCore/Sources` contains neither construct today
    /// (`containsOnlyLexableStringLiterals` below), so the rule costs nothing.
    @Test(arguments: [
        "let s = \"\"\"\n  a \" b\n  \"\"\"\nlet fine = [\"switch\", branch]\n",
        "let s = #\"a \" b\"#\nlet fine = [\"switch\", branch]\n",
        "let s = ##\"a\"##\n",
    ])
    func refusesToScanAFileItCannotLex(source: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(findings.count == 1, "expected exactly the refusal, got \(findings)")
        #expect(findings.first?.contains("cannot be scanned") == true, "\(findings)")
    }

    /// And the refusal is not simply "any file with a quote in it".
    @Test func stillScansOrdinaryFiles() {
        #expect(ForceFlagScanner.findings(in: #"let a = ["switch", "--no-guess", b]"#).isEmpty)
        #expect(!ForceFlagScanner.findings(in: #"let a = ["switch", "--force", b]"#).isEmpty)
    }

    /// The premise of the refusal above: no source it has to scan uses either construct, so
    /// the rule is a guard against a future file rather than a standing failure.
    @Test func gitCoreSourcesContainOnlyLexableStringLiterals() throws {
        let sources = try ForceFlagScanner.gitCoreSources(root: Self.sourcesRoot)
        #expect(sources.count >= 10)
        for (path, text) in sources.sorted(by: { $0.key < $1.key }) {
            #expect(!text.contains("\"\"\""), "\(path) has a multi-line string literal")
            #expect(!text.contains("#\""), "\(path) has a raw string literal")
        }
    }

    // MARK: - Remotes: push, fetch, rebase, leases and refspecs

    /// The deny tables this milestone adds. `push` can delete a branch on the server
    /// (`--delete`/`-d`), replace every ref on it (`--mirror`), or push refs the user never
    /// named (`--all`, `--tags`); `fetch --prune` deletes remote-tracking refs behind the
    /// user's back; `rebase --autostash`/`--skip`/`--quit` each move or drop work without a
    /// confirmation; and `pull` is not a command Gitter runs at all — the store fetches and
    /// then merges or rebases itself, so that the sheet can say what will happen first.
    @Test(arguments: [
        #"_ = try await run(["push", "--force-with-lease", r, s], cwd: root)"#,
        #"_ = try await run(["switch", "--force-with-lease=x:y", b], cwd: root)"#,
        #"let l = "--force-with-lease""#,
        #"_ = try await run(["push", r, "+refs/heads/a:refs/heads/a"], cwd: root)"#,
        #"var a = ["push"]; a.append("+refs/heads/a:refs/heads/a")"#,
        #"_ = try await run(["push", "--mirror", r], cwd: root)"#,
        #"_ = try await run(["push", "--delete", r, b], cwd: root)"#,
        #"_ = try await run(["push", "-d", r, b], cwd: root)"#,
        #"_ = try await run(["push", "--all", r], cwd: root)"#,
        #"_ = try await run(["push", "--no-verify", r, s], cwd: root)"#,
        #"_ = try await run(["push", "--force-if-includes", r, s], cwd: root)"#,
        #"_ = try await run(["fetch", "--prune", r], cwd: root)"#,
        #"_ = try await run(["fetch", "-p", r], cwd: root)"#,
        #"_ = try await run(["fetch", "--prune-tags", "--tags", r], cwd: root)"#,
        #"_ = try await run(["pull", r], cwd: root)"#,
        #"_ = try await run(["rebase", "--autostash", u], cwd: root)"#,
        #"_ = try await run(["rebase", "--force-rebase", u], cwd: root)"#,
        // `--update-refs` moves every other local branch that points into the rewritten range.
        #"_ = try await run(["rebase", "--update-refs", u], cwd: root)"#,
        // `--follow-tags` pushes tags the user never named; `--no-force-with-lease` cancels a
        // lease written earlier in the same vector, leaving a plain force push behind.
        #"_ = try await run(["push", "--follow-tags", r], cwd: root)"#,
        #"_ = try await run(["push", "--force-with-lease=\(ref):\(sha)", "--no-force-with-lease", r], cwd: root)"#,
    ])
    func catchesAForbiddenRemoteInvocation(source: String) {
        #expect(!ForceFlagScanner.findings(in: source).isEmpty, "missed: \(source)")
    }

    /// A lease with no expected value is the failure the lease rule exists to prevent.
    /// `--force-with-lease=<ref>` with no `:<sha>` leases against the *remote-tracking* ref —
    /// which this app's own auto-fetch rewrites, seconds before the push, with a value nobody
    /// was shown. `--force-with-lease=<ref>:` (an empty expectation) means "only if that ref
    /// does not exist", which is never what Gitter wants. And a literal sha is not the sha the
    /// sheet showed unless it came from the sheet, which only an interpolation can do.
    ///
    /// So the permitted spelling is one string literal beginning `--force-with-lease=`, whose
    /// remainder has a non-empty part on both sides of a `:`, and whose part after the last `:`
    /// is an interpolation. The concatenated `"--force-with-lease=" + lease` is a finding for
    /// the same reason: the scanner cannot see what is on the other side of the `+`.
    @Test(arguments: [
        #"_ = try await run(["push", "--porcelain", "--force-with-lease=\(remoteRef)", r, s], cwd: root)"#,
        #"_ = try await run(["push", "--force-with-lease=refs/heads/main", r, s], cwd: root)"#,
        #"_ = try await run(["push", "--force-with-lease=", r, s], cwd: root)"#,
        #"_ = try await run(["push", "--force-with-lease=refs/heads/main:", r, s], cwd: root)"#,
        #"_ = try await run(["push", "--force-with-lease=:\(tip)", r, s], cwd: root)"#,
        #"_ = try await run(["push", "--force-with-lease=\(ref):0123456789abcdef", r, s], cwd: root)"#,
        #"_ = try await run(["push", "--porcelain", "--force-with-lease=" + lease, remote, spec], cwd: root)"#,
    ])
    func catchesALeaseThatNamesNoExpectedValue(source: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(!findings.isEmpty, "missed: \(source)")
        #expect(findings.contains { $0.contains("--force-with-lease=") }, "\(findings)")
    }

    /// Two ways a lease can satisfy the shape rule and still not be the lease it looks like.
    ///
    /// `isPermittedLease` asked only that the part after the separator *begin* `\(` and *end*
    /// `)`, so anything between the interpolation's closing parenthesis and the end of the
    /// literal rode along: `--force-with-lease=<ref>:\(sha)extra)` is the expected object name
    /// `<sha>extra)`, which is not what any sheet showed, and `--force-with-lease=x:\()`
    /// interpolates nothing at all.
    ///
    /// And the separator was the **last** `:`, where git takes the **first** — measured:
    /// `git push --force-with-lease=refs/heads/feature:a:b` answers `error: cannot parse
    /// expected object name 'a:b'`. So a literal with a second `:` outside the interpolation is
    /// not a lease git will honour, and reading it as one (ref `…feature:a`, expectation
    /// `\(c)`) let a shape through that git itself rejects.
    @Test(arguments: [
        #"_ = try await run(["push", "--force-with-lease=\(ref):\(sha)extra)", r, s], cwd: root)"#,
        #"_ = try await run(["push", "--force-with-lease=\(ref):\(sha) ", r, s], cwd: root)"#,
        #"_ = try await run(["push", "--force-with-lease=x:\()", r, s], cwd: root)"#,
        #"_ = try await run(["push", "--force-with-lease=\(a):\(b):\(c)", r, s], cwd: root)"#,
    ])
    func catchesALeaseWhoseShapeOnlyLooksRight(source: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(!findings.isEmpty, "missed: \(source)")
        #expect(findings.contains { $0.contains("--force-with-lease=") }, "\(findings)")
    }

    /// A lease vouches for a delete refspec — the one permission in this scanner that lets a
    /// destructive literal through — and `carriesLease` used to read *every* literal anywhere in
    /// an element. So a lease in one arm of a ternary vouched for a refspec that deletes the
    /// branch whichever way the condition falls: on the other arm nothing leases it at all.
    ///
    /// Reading every literal is right for a deny table (both arms can reach git, so both must be
    /// checked) and wrong for a rule that *grants* permission, which has to read the value the
    /// element really has. A lease therefore counts only as a lone-literal element of the vector
    /// — which is the only shape `allowsTheRemoteOperationsThisMilestoneNeeds` writes anyway.
    @Test(arguments: [
        #"_ = try await run(["push", force ? "--force-with-lease=\(ref):\(tip)" : "--dry-run", remote, ":refs/heads/\(b)"], cwd: root)"#,
        #"_ = try await run(["push", ok ? "--force-with-lease=\(ref):\(tip)" : "--quiet", remote, ":"], cwd: root)"#,
    ])
    func aLeaseInOneArmOfATernaryVouchesForNoDeleteRefspec(source: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(!findings.isEmpty, "missed: \(source)")
        #expect(findings.contains { $0.contains("delete refspec") }, "\(findings)")
    }

    /// The lease's own permission is bounded the same way and for the same reason: the other arm
    /// of `ok ? lease : "--quiet"` is a push with no lease on it, so the element cannot be read
    /// as "a lease". The permitted spelling is one whole literal standing as an element of the
    /// `push` vector — not a literal buried in an expression that may evaluate to something else.
    @Test func aLeaseInOneArmOfATernaryIsNotAPermittedLease() {
        let source = #"_ = try await run(["push", "--porcelain", ok ? "--force-with-lease=\(ref):\(tip)" : "--quiet", remote, spec], cwd: root)"#
        let findings = ForceFlagScanner.findings(in: source)
        #expect(!findings.isEmpty, "missed: \(source)")
        #expect(findings.contains { $0.contains("--force-with-lease=") }, "\(findings)")
    }

    /// The delete-refspec sweep stands down inside a `push` vector because only there can a
    /// lease in the same array vouch for the refspec. That stand-down covered the vector's whole
    /// *range*, so a `:refs/…` nested in a sub-expression of a leased push escaped both rules at
    /// once: the sweep by offset, and the array rule by the lease. The inner array is classified
    /// by its own first element, so it is not a fragment either. The stand-down is now the
    /// vector's own lone-literal elements, which is exactly what the lease can speak for.
    @Test func aDeleteRefspecNestedInsideALeasedPushVectorIsStillAFinding() {
        let source = #"_ = try await run(["push", "--force-with-lease=\(ref):\(tip)", extra([":refs/heads/main"])], cwd: root)"#
        let findings = ForceFlagScanner.findings(in: source)
        #expect(!findings.isEmpty, "missed: \(source)")
        #expect(findings.contains { $0.contains(":refs/heads/main") }, "\(findings)")
    }

    /// Deleting a branch on the server is spelled as data, not as a flag: a refspec whose source
    /// side is empty (`:refs/heads/x`) tells the server to delete that ref. `--delete` and `-d`
    /// are already findings, so this is the same command written the way that walks past them.
    ///
    /// Inside a `push` vector it is permitted only when that same vector carries a *permitted*
    /// lease, which is what makes the deletion conditional on the sha the sheet showed. Outside
    /// one, a literal beginning `:refs/` is a finding wherever it sits. The narrowing to
    /// `:refs/` is a fact about this codebase: `CLIGitBackend`'s `":(literal)" + path` is the
    /// only other `:`-leading literal in `GitCore/Sources`, and pathspec magic is not a refspec.
    @Test(arguments: [
        #"_ = try await run(["push", remote, ":refs/heads/\(b)"], cwd: root)"#,
        #"_ = try await run(["push", "--porcelain", "--end-of-options", remote, ":refs/heads/main"], cwd: root)"#,
        #"_ = try await run(["push", "--force-with-lease=x:y", remote, ":refs/heads/main"], cwd: root)"#,
        #"_ = try await run(["push", remote, ":" + ref], cwd: root)"#,
        #"_ = try await run(["fetch", remote, ":refs/heads/main"], cwd: root)"#,
        #"let spec = ":refs/heads/main""#,
        #"var a = [String](); a.append(":refs/heads/main")"#,
    ])
    func catchesAnUnleasedDeleteRefspec(source: String) {
        #expect(!ForceFlagScanner.findings(in: source).isEmpty, "missed: \(source)")
    }

    /// A global option before the subcommand demotes the whole vector to a fragment: the array
    /// no longer begins with a literal that names a subcommand, so every per-subcommand table,
    /// the positional rules, the lease rule and the wide `+`/`:` rules are all lost at once.
    /// `["-c", "push.default=matching", "push", r]` was clean.
    ///
    /// No vector in `GitCore/Sources` begins with one (`git grep`: `"-c"` appears only as
    /// `["switch", "-c", name]`), so the rule can simply be "don't": pass a working directory
    /// instead. The finding must name the option, or this passes for the wrong reason.
    @Test(arguments: [
        (#"_ = try await run(["-c", "push.default=matching", "push", r], cwd: root)"#, "-c"),
        (#"_ = try await run(["-C", dir, "push", "--force-with-lease=\(ref):\(sha)", r], cwd: root)"#, "-C"),
        (#"_ = try await run(["--git-dir", dir, "branch", "--end-of-options", name], cwd: root)"#, "--git-dir"),
        (#"_ = try await run(["--work-tree", dir, "status", "--porcelain"], cwd: root)"#, "--work-tree"),
        // Rerere is turned off through the environment (`runWithEnvironment` + `rerereOff`),
        // never with a leading `-c`, which would hide the `stash` shape from this scanner.
        (#"_ = try await run(["-c", "rerere.enabled=false", "stash", "apply", "-q", "--no-index", s], cwd: root)"#, "-c"),
    ])
    func catchesAGlobalOptionBeforeTheSubcommand(source: String, option: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(!findings.isEmpty, "missed: \(source)")
        #expect(findings.contains { $0.contains(option) }, "\(findings) should name \(option)")
    }

    /// The `--no-commit-id` carve-out excuses `-M`/`-p` in a `diff-tree` argument list. It must
    /// not excuse them in a fragment that names a subcommand of its own: `[repoFlag, "branch",
    /// "--no-commit-id", "-M", a, b]` is a `branch -M` with a decoy in it, and it was clean —
    /// while the scanner's own doc comment claimed that could not happen.
    @Test(arguments: [
        (#"_ = try await run([repoFlag, "branch", "--no-commit-id", "-M", a, b], cwd: root)"#, "-M"),
        (#"_ = try await run([repoFlag, "fetch", "--no-commit-id", "-p", r], cwd: root)"#, "-p"),
        (#"_ = try await run([repoFlag, "switch", "--no-commit-id", "-M", a, b], cwd: root)"#, "-M"),
    ])
    func theDiffTreeCarveOutDoesNotCoverAFragmentThatNamesASubcommand(source: String, flag: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(!findings.isEmpty, "missed: \(source)")
        #expect(findings.contains { $0.contains(flag) }, "\(findings) should name \(flag)")
    }

    /// `git remote`'s destructive forms are *words*, not flags — `remote prune`, `remote
    /// remove`, `remote set-url` — so no flag table can see them, and `remote` was an
    /// unconstrained subcommand. The one form Gitter runs is `git remote -v`; the rule is an
    /// allowed *shape* rather than a deny list, because the list of words git may add to
    /// `remote` in a future release is not knowable here.
    @Test(arguments: [
        #"_ = try await run(["remote", "prune", r], cwd: root)"#,
        #"_ = try await run(["remote", "remove", r], cwd: root)"#,
        #"_ = try await run(["remote", "rm", r], cwd: root)"#,
        #"_ = try await run(["remote", "set-url", r, url], cwd: root)"#,
        #"_ = try await run(["remote", "rename", old, new], cwd: root)"#,
        #"_ = try await run(["remote", "add", name, url], cwd: root)"#,
        #"_ = try await run(["remote", "update"], cwd: root)"#,
        #"_ = try await run(["remote", "set-head", r, b], cwd: root)"#,
        #"_ = try await run(["remote", "set-branches", r, b], cwd: root)"#,
        #"_ = try await run(["remote", "-v", extra], cwd: root)"#,
        #"_ = try await run(["remote"], cwd: root)"#,
    ])
    func constrainsTheRemoteSubcommandToTheOneShapeGitterRuns(source: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(!findings.isEmpty, "missed: \(source)")
        #expect(findings.contains { $0.contains("remote") }, "\(findings) should name remote")
    }

    /// The allowed-shape rule above runs on *classified* arrays only, and one leading
    /// non-literal is all it takes to lose it: `[repoFlag, "remote", "rm", r]` is a fragment,
    /// and a fragment is checked against a union of flag tables that no word can be in. So
    /// `git remote rm` was clean by the same route the flag rules were taught about in fix
    /// round 1 — plus a second one the append pool opens, since an appended literal belongs to
    /// no vector at all.
    ///
    /// Two rules answer it, and the split between them is a fact about this codebase rather
    /// than a principle. `remote`'s destructive words — `prune`, `remove`, `set-url`, `rename`,
    /// `set-head`, `set-branches`, `update` — appear in `GitCore/Sources` **zero** times, so
    /// they are findings file-wide, wherever a literal holds one; that is also what catches
    /// `a += ["prune", r]`, whose array reads as a vector named `prune`. `remote` and `rm` are
    /// written in the sources as the first element of a classified vector, so they are
    /// findings in a fragment or the append pool only, where the shape rule cannot reach.
    @Test(arguments: [
        (#"_ = try await run([repoFlag, "remote", "rm", r], cwd: root)"#, "remote"),
        (#"_ = try await run([repoFlag, "remote", "set-branches", r, b], cwd: root)"#, "set-branches"),
        (#"var a = ["remote", "-v"]; a.append("prune")"#, "prune"),
        (#"var a = ["remote", "-v"]; a.append("remove")"#, "remove"),
        (#"var a = [String](); a.append("set-url")"#, "set-url"),
        (#"var a = ["remote"]; a += ["rename", old, new]"#, "rename"),
        (#"var a = [String](); a.append("set-head")"#, "set-head"),
        (#"var a = [String](); a.append("remote")"#, "remote"),
        (#"let word = "set-url""#, "set-url"),
    ])
    func catchesARemoteVectorThatHidesItsShape(source: String, word: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(!findings.isEmpty, "missed: \(source)")
        #expect(findings.contains { $0.contains(word) }, "\(findings) should name \(word)")
    }

    /// And the word rules fire on none of the vectors the sources already build, which is the
    /// survey they rest on: `git grep -nE
    /// '"(prune|rm|remove|set-url|rename|set-head|set-branches|add|update)"' -- GitCore/Sources`
    /// returns **four** hits, all in `CLIGitBackend+WorkingCopy.swift` — `["add", "--"] + …`
    /// (:8), `["rm", "--cached", "-q", "--ignore-unmatch", "--"] + …` (:23; both through a
    /// pathspec file since Ruling 26, spelled so below), `["add", "-A"]`
    /// (:29), `["rm", "--cached", "-r", "-q", "--", "."]` (:42). Every one is the first element
    /// of a classified vector, so no fragment rule looks there; `add` is excluded from both
    /// lists anyway, because `git remote add` adds a remote rather than destroying one and
    /// `git add` is a command four lines away.
    @Test(arguments: [
        #"_ = try await run(["add", "--pathspec-from-file=\(file)", "--pathspec-file-nul"], cwd: root)"#,
        #"_ = try await run(["add", "-A"], cwd: root)"#,
        #"_ = try await run(["rm", "--cached", "-q", "--ignore-unmatch", "--pathspec-from-file=\(file)", "--pathspec-file-nul"], cwd: root)"#,
        #"_ = try await run(["rm", "--cached", "-r", "-q", "--", "."], cwd: root)"#,
        #"async let remoteData = run(["remote", "-v"], cwd: root)"#,
    ])
    func theRemoteWordsDoNotFireOnTheVectorsTheSourcesAlreadyBuild(source: String) {
        #expect(ForceFlagScanner.findings(in: source).isEmpty,
                "false positive: \(ForceFlagScanner.findings(in: source))")
    }

    /// Escapes are decoded before the tables are consulted — but the *classifying* first element
    /// was read raw, so `["\u{72}emote", "rm", r]` named the subcommand `\u{72}emote`, which no
    /// table holds, and the allowed-shape rule never ran. Git reads that literal as `remote`,
    /// because Swift does; so does classification now.
    @Test func decodesEscapesBeforeClassifyingTheSubcommand() {
        let source = #"_ = try await run(["\u{72}emote", "rm", r], cwd: root)"#
        let findings = ForceFlagScanner.findings(in: source)
        #expect(!findings.isEmpty, "missed: \(source)")
        #expect(findings.contains { $0.contains("remote") }, "\(findings) should name remote")
    }

    /// A flag spelled with unicode escapes matches no table, because the lexer keeps a literal's
    /// *raw* text: `"\u{2d}\u{2d}force"` is the value `\u{2d}\u{2d}force`. Every `\u{…}` in
    /// `GitCore/Sources` is `"\u{0}"`, git's `-z` record separator (`git grep`: four of them,
    /// in `CLIGitBackend` and three parsers), and NUL matches no rule — so the escapes can be
    /// decoded and the decoded spelling checked as well, at no cost in false positives.
    @Test(arguments: [
        #"_ = try await run(["switch", "\u{2d}\u{2d}force", b], cwd: root)"#,
        #"let flag = "\u{2d}\u{2d}force""#,
        #"_ = try await run(["push", remote, "\u{2b}refs/heads/a:refs/heads/a"], cwd: root)"#,
        #"var a = ["switch"]; a.append("\u{2d}\u{2d}discard-changes")"#,
    ])
    func catchesAFlagSpelledWithUnicodeEscapes(source: String) {
        #expect(!ForceFlagScanner.findings(in: source).isEmpty, "missed: \(source)")
    }

    /// Real lines from `GitCore/Sources` that each new rule above could have false-positived on:
    /// the pathspec magic that is not a delete refspec, the record separator that is not a
    /// flag, and the one `remote` vector Gitter runs.
    @Test(arguments: [
        #"":(literal)" + path"#,
        #"let fields = text.split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)"#,
        #"async let remoteData = run(["remote", "-v"], cwd: root)"#,
        #"arguments = ["switch", "-c", name]"#,
    ])
    func doesNotFireOnTheRealLinesTheseRulesPassOver(source: String) {
        #expect(ForceFlagScanner.findings(in: source).isEmpty,
                "false positive: \(ForceFlagScanner.findings(in: source))")
    }

    /// The mirror image, and a **contract**: these are the argument vectors the remote work is
    /// going to write, spelled exactly as it will write them. Nothing here may become a
    /// finding — a rule that turns one of them red has to be narrowed here, before the code
    /// that writes it exists, rather than argued about afterwards.
    ///
    /// Eight arguments holding **eleven** vectors: the fifth is a two-line source with both
    /// `fetch` vectors in it (one remote, and `--all`), and the eighth holds the three `merge`
    /// vectors. This comment and the design doc both said "seven vectors" until fix round 2 —
    /// count them below.
    ///
    /// **`--no-recurse-submodules` joined all four push vectors in the final review's fix
    /// wave**, right after `--no-follow-tags`, because `submodule.recurse=true` pushed a
    /// submodule's branch nobody named (measured — see `CLIGitBackend+Push.swift` and
    /// `PushSubmoduleTests`). No `push` rule keys on it, so the table needed no narrowing.
    ///
    /// **The `merge` vectors joined in the final review's fix wave**, with `--no-autostash`:
    /// Pull's fast-forward and the pull sheet's Merge run them, and under `merge.autoStash=true`
    /// they reported success while stashing the user's edit (measured — see
    /// `CLIGitBackend+Merge.swift` and `MergeAutoStashTests`). The scanner's `merge` table
    /// forbids `--autostash`, a different whole token, so it needed no narrowing.
    ///
    /// Read them as the shape the scanner demands in return for what it permits: one complete
    /// array literal, its subcommand first, the lease carrying an interpolated expected sha,
    /// and the delete refspec standing in the same literal as the lease that guards it.
    ///
    /// **`--no-follow-tags` joined all four push vectors in Task 6's fix round**, because
    /// `push.followTags=true` made every one of them create tags on the server (measured — see
    /// `CLIGitBackend+Push.swift`). It is checked here as well as in the source, and this is
    /// also where it was probed before it was written anywhere: every rule in this scanner keys
    /// on a **whole token**, `--follow-tags` is a different token from `--no-follow-tags`, and
    /// the only prefix rule is `--force-with-lease=`. So the deny table for `push` needed no
    /// narrowing — these four sources staying clean is the proof.
    @Test(arguments: [
        #"_ = try await run(["push", "--porcelain", "--progress", "--no-follow-tags", "--no-recurse-submodules", "--end-of-options", remote, "refs/heads/\(branch):\(remoteRef)"], cwd: root)"#,
        #"_ = try await run(["push", "--porcelain", "--progress", "--no-follow-tags", "--no-recurse-submodules", "-u", "--end-of-options", remote, "refs/heads/\(branch):\(remoteRef)"], cwd: root)"#,
        #"_ = try await run(["push", "--porcelain", "--progress", "--no-follow-tags", "--no-recurse-submodules", "--force-with-lease=\(remoteRef):\(tip)", "--end-of-options", remote, "\(expectedLocalTip):\(remoteRef)"], cwd: root)"#,
        #"_ = try await run(["push", "--porcelain", "--progress", "--no-follow-tags", "--no-recurse-submodules", "--force-with-lease=refs/heads/\(b):\(tip)", "--end-of-options", remote, ":refs/heads/\(b)"], cwd: root)"#,
        #"""
        _ = try await run(["fetch", "--progress", "--no-prune", "--end-of-options", remote], cwd: root)
        _ = try await run(["fetch", "--progress", "--no-prune", "--all"], cwd: root)
        """#,
        #"_ = try await run(["rebase", "--no-autostash", "--no-update-refs", "--no-rebase-merges", "--end-of-options", target], cwd: root)"#,
        #"_ = try await run(["remote", "-v"], cwd: root)"#,
        #"""
        arguments = ["merge", "--no-autostash", "--ff", "--no-edit", "--end-of-options", target]
        arguments = ["merge", "--no-autostash", "--no-ff", "--no-edit", "--end-of-options", target]
        arguments = ["merge", "--no-autostash", "--ff", "--squash", "--end-of-options", target]
        """#,
    ])
    func allowsTheRemoteOperationsThisMilestoneNeeds(source: String) {
        #expect(ForceFlagScanner.findings(in: source).isEmpty,
                "false positive: \(ForceFlagScanner.findings(in: source))")
    }

    /// The lease rule is a *prefix* rule, and it is the only one: the permitted token is not a
    /// fixed string but everything beginning `--force-with-lease=`, because the sha comes from
    /// the sheet (`"--force-with-lease=\(ref):\(sha)"`, `"--force-with-lease=" + lease`).
    /// Permitting a prefix is a hole unless the position is pinned too, so it is pinned to an
    /// array literal classified `push`: any other vector, any fragment, any `.append`, and any
    /// bare `let` is a finding.
    ///
    /// None of these literals is in `alwaysForbidden` — the bare token is, the `=<value>` form
    /// cannot be, since it is not one token — so nothing here can pass by exact match.
    @Test(arguments: [
        (#"_ = try await run(["fetch", "--force-with-lease=\(ref):\(sha)", remote], cwd: root)"#,
         #"--force-with-lease=\(ref):\(sha)"#),
        (#"_ = try await run(["switch", "--force-with-lease=x:y", b], cwd: root)"#,
         "--force-with-lease=x:y"),
        (#"var a = ["push"]; a.append("--force-with-lease=\(ref):\(sha)")"#,
         #"--force-with-lease=\(ref):\(sha)"#),
        (#"var a = ["push"]; a += ["--force-with-lease=" + lease]"#, "--force-with-lease="),
        (#"let lease = "--force-with-lease=\(ref):\(sha)""#, #"--force-with-lease=\(ref):\(sha)"#),
        (#"_ = try await run([remoteFlag, "push", "--force-with-lease=x:y"], cwd: root)"#,
         "--force-with-lease=x:y"),
    ])
    func catchesALeaseOutsideAPushVector(source: String, literal: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(!findings.isEmpty, "missed: \(source)")
        #expect(findings.contains { $0.contains("--force-with-lease=") }, "\(findings)")
        #expect(!ForceFlagScanner.alwaysForbidden.contains(literal),
                "\(literal) is forbidden by exact match, so this proves nothing about the prefix rule")
    }

    /// The exemption is a *position*, not a token: one legitimate lease in a `push` vector must
    /// not vouch for the identical text elsewhere in the same file. That is why the sweep asks
    /// where the literal sits rather than which literals a push vector contains.
    @Test func aLeaseInAPushVectorDoesNotExcuseTheSameTextElsewhere() {
        let clean = #"_ = try await run(["push", "--porcelain", "--force-with-lease=x:\(sha)", r], cwd: root)"#
        #expect(ForceFlagScanner.findings(in: clean).isEmpty,
                "false positive: \(ForceFlagScanner.findings(in: clean))")
        let stray = #"let stray = "--force-with-lease=x:\(sha)""#
        let findings = ForceFlagScanner.findings(in: clean + "\n" + stray)
        #expect(findings.count == 1, "expected exactly the stray lease, got \(findings)")
        #expect(findings.first?.contains("--force-with-lease=x:") == true, "\(findings)")
    }

    /// A refspec beginning `+` forces the update git would otherwise refuse — the same loss as
    /// `--force`, spelled as data rather than as a flag, and it would sail past every table
    /// here. The rule cannot be "any literal beginning with `+`": `PatchBuilder` and
    /// `DiffParser` are full of them (`"+" + line.text`, `"+++ "`). It is narrowed to the
    /// shapes a refspec actually has — see `isForceRefspec` — plus anything `+` inside a
    /// `push`/`fetch` vector, where a leading `+` can only be a refspec.
    @Test(arguments: [
        #"_ = try await run(["push", remote, "+refs/heads/a:refs/heads/a"], cwd: root)"#,
        #"_ = try await run(["push", remote, "+\(src):\(dst)"], cwd: root)"#,
        #"_ = try await run(["fetch", remote, "+refs/heads/*:refs/remotes/origin/*"], cwd: root)"#,
        #"_ = try await run(["push", remote, "+" + src + ":" + dst], cwd: root)"#,
        #"_ = try await run(["push", remote, "+HEAD"], cwd: root)"#,
        #"var a = [String](); a.append("+refs/heads/a:refs/heads/a")"#,
        #"let spec = "+refs/heads/a""#,
        #"let spec = "+\(branch):\(branch)""#,
    ])
    func catchesAForceRefspec(source: String) {
        #expect(!ForceFlagScanner.findings(in: source).isEmpty, "missed: \(source)")
    }

    /// And the `+` rule does not fire on the diff code, which is where every other `+` literal
    /// in `GitCore/Sources` lives. Each of these is a line copied from a real source file; the
    /// last is `commitDiff`'s fragment, whose `-p` is `diff-tree`'s patch option and not
    /// `fetch -p`.
    @Test(arguments: [
        #"case .added: return "+" + text"#,
        #"out.append("+" + line.text)"#,
        #"} else if line.hasPrefix("+++ ") {"#,
        #"if part.hasPrefix("+"), let n = Int(part.dropFirst()) {"#,
        #"let marker = ["+", "-", " "]"#,
        #"let arguments = ["--no-commit-id", "-p", "-U3", "-M", "-r"]"#,
    ])
    func doesNotFireOnTheDiffMarkersTheSourcesUse(source: String) {
        #expect(ForceFlagScanner.findings(in: source).isEmpty,
                "false positive: \(ForceFlagScanner.findings(in: source))")
    }

    /// What the lexer does with interpolation, pinned, because both new rules are prefix rules
    /// and the real code will write the interpolated spelling: `\(…)` inside a literal is blanked
    /// like any other content, so the literal stays *one* literal and its value is the raw
    /// source text, interpolation marks and all. `hasPrefix` therefore works on it.
    @Test func readsAnInterpolatedLiteralAsOneLiteralWithItsRawText() {
        let source = #"let a = ["push", "--force-with-lease=\(ref):\(sha)", remote]"#
        let code = ForceFlagScanner.strippingCommentsAndStringContents(source)
        #expect(ForceFlagScanner.literals(in: source, code: code).map(\.1)
                == ["push", #"--force-with-lease=\(ref):\(sha)"#])
        let elements = ForceFlagScanner.argumentArrays(in: source, code: code).first?.elements
        #expect(elements?.map(\.value) == ["push", #"--force-with-lease=\(ref):\(sha)"#, nil])
    }

    /// The limit that buys: a string literal *inside* an interpolation ends the outer literal as
    /// far as this lexer is concerned, so a flag split across one is invisible. Recorded rather
    /// than fixed — closing it needs a real Swift parser — and it is the same "only literals"
    /// hole as `"--" + verb`, reached by a different road. Quote parity survives, so the rest of
    /// the file is still lexed correctly; nothing desynchronises.
    @Test func recordsThatAFlagSplitByAnInterpolatedLiteralIsInvisible() {
        let source = #"_ = try await run(["switch", "--for\("ce")", b], cwd: root)"#
        #expect(ForceFlagScanner.findings(in: source).isEmpty,
                "the limit has moved — update the doc comment, do not fix this quietly")
        #expect(!ForceFlagScanner.findings(in: #"_ = try await run(["switch", "--force", b])"#)
                .isEmpty, "the unsplit spelling must still be caught")
    }

    @Test func doesNotConfuseElementsOfNestedExpressions() {
        let source = #"""
            _ = try await run(["branch", "--end-of-options", name] + (start.map { [$0] } ?? []), cwd: root)
            """#
        #expect(ForceFlagScanner.findings(in: source).isEmpty)
    }

    // MARK: - Working copy: stash, restore, the record's plumbing, apply

    /// The one file the record's plumbing may be written in, and two it may not.
    static let recordFile = "CLIGitBackend+StashRecord.swift"

    /// `stash` is permitted in five whole shapes and nothing else. Its dangerous forms are
    /// subcommands (`pop`, `clear`, `create`, `branch`, `show`), options (`--index`,
    /// `--keep-index`, `--staged`, `--all`, `-p`) and a pathspec, so a deny table would have to
    /// know every one of them; the allowed shapes invert the rule, as `remote -v` did.
    @Test(arguments: [
        (#"_ = try await run(["stash", "push"], cwd: root)"#, "stash"),
        (#"_ = try await run(["stash"], cwd: root)"#, "stash"),
        (#"_ = try await run(["stash", "create"], cwd: root)"#, "create"),
        (#"_ = try await run(["stash", "branch", b, s], cwd: root)"#, "branch"),
        (#"_ = try await run(["stash", "show", "-p", s], cwd: root)"#, "show"),
        (#"_ = try await run(["stash", "push", "-q", "--message", m, "--keep-index"], cwd: root)"#, "--keep-index"),
        (#"_ = try await run(["stash", "push", "-q", "--message", m, "--staged"], cwd: root)"#, "--staged"),
        (#"_ = try await run(["stash", "push", "-q", "--message", m, "--all"], cwd: root)"#, "--all"),
        (#"_ = try await run(["stash", "push", "-q", "--message", m, "-p"], cwd: root)"#, "-p"),
        (#"_ = try await run(["stash", "push", "-q", "--message", m, "--", p], cwd: root)"#, "stash"),
        (#"_ = try await run(["stash", "push", "-q", "--message", m] + paths, cwd: root)"#, "stash"),
        (#"_ = try await run(["stash", "push", "-q", "--message", m, "--include-untracked"] + ["--", p], cwd: root)"#, "stash"),
        (#"_ = try await run(["stash", "push", "-q", "--message", "--all"], cwd: root)"#, "--all"),
        (#"_ = try await run(["stash", "push", "-q", "--message", keep ? "--keep-index" : m], cwd: root)"#, "--keep-index"),
        (#"_ = try await run(["stash", "apply", "-q", s], cwd: root)"#, "stash"),
        (#"_ = try await run(["stash", "apply", "-q", "--no-index", "--index", s], cwd: root)"#, "--index"),
        (#"_ = try await run(["stash", "drop", s], cwd: root)"#, "stash"),
        (#"_ = try await run(["stash", "drop", "-q"], cwd: root)"#, "stash"),
        (#"_ = try await run(["stash", "drop", "-q", a, b], cwd: root)"#, "stash"),
        (#"_ = try await run(["stash", "store", "-q", sha], cwd: root)"#, "stash"),
        (#"_ = try await run(["stash", "list", "-z", "--date=iso", "--format=%H%x1f%gd%x1f%gs%x1f%ct%x1f%P"], cwd: root)"#, "stash"),
    ])
    func catchesAStashVectorOutsideTheAllowedShapes(source: String, word: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(!findings.isEmpty, "missed: \(source)")
        #expect(findings.contains { $0.contains(word) }, "\(findings) should name \(word)")
    }

    /// A stash vector that hides its shape: a leading non-literal makes it a fragment, and an
    /// appended word belongs to no vector. `stash` is a finding in either place, and the words
    /// that can only be `stash`'s are findings wherever a literal holds one.
    @Test(arguments: [
        (#"_ = try await run([repoFlag, "stash", "pop"], cwd: root)"#, "stash"),
        (#"var a = [String](); a.append("stash")"#, "stash"),
        (#"var a = ["stash", "push", "-q", "--message", m]; a.append("--keep-index")"#, "--keep-index"),
        (#"let word = "pop""#, "pop"),
        (#"let word = "clear""#, "clear"),
        (#"let word = "create""#, "create"),
        (#"let flag = "--index""#, "--index"),
        // Fix round 1: a stash vector held in a `var` and extended where no shape can see it.
        (#"var a = ["stash", "push", "-q", "--message", m]; a += ["--", p]"#, "stash"),
        (#"var a = ["stash", "push", "-q", "--message", m]; a.append("--"); a.append(p)"#, "stash"),
        (#"var a = ["stash", "push", "-q", "--message", m]; a += ["--staged"]"#, "stash"),
        (#"var a = ["stash", "push", "-q", "--message", m]; a.append("-a")"#, "stash"),
        (#"var a = ["stash", "push", "-q", "--message", m]; a.append("-S")"#, "stash"),
        (#"var a = ["stash", "push", "-q", "--message", m]; a += paths"#, "stash"),
        (#"var a = ["stash", "push", "-q", "--message", m]; a.insert(contentsOf: ["--", p], at: 5)"#, "stash"),
        // Fix round 1: the subcommand held in a `let`, and a stray literal outside any vector.
        (#"let sub = "stash"; _ = try await run([sub, "push", "--", p], cwd: root)"#, "stash"),
        (#"let sub = "stash""#, "stash"),
    ])
    func catchesAStashVectorThatHidesItsShape(source: String, word: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(!findings.isEmpty, "missed: \(source)")
        #expect(findings.contains { $0.contains(word) }, "\(findings) should name \(word)")
    }

    /// A stash vector must be written inline as an argument of `run(` or `runWithEnvironment(`.
    /// A shape is matched on the array literal, so a vector bound to a name — `var` or `let`,
    /// directly or through a ternary — can be extended afterwards (`a += paths`, `a.append(x)`,
    /// `a.insert(contentsOf:at:)`, `run(a + paths)`) where no shape can see it. Each of these
    /// is caught by the binding rule alone: none contains a literal any other rule reads.
    @Test(arguments: [
        #"var a = ["stash", "push", "-q", "--message", m]; a += paths"#,
        #"let a = ["stash", "push", "-q", "--message", m]; _ = try await run(a + paths, cwd: root)"#,
        #"let a = untracked ? ["stash", "push", "-q", "--message", m, "--include-untracked"] : ["stash", "push", "-q", "--message", m]"#,
        #"func arguments() -> [String] { return ["stash", "apply", "-q", "--no-index", sha] }"#,
        #"_ = try await run((["stash", "drop", "-q", "stash@{\(n)}"]) + extra, cwd: root)"#,
        #"_ = try await other(["stash", "drop", "-q", "stash@{\(n)}"], cwd: root)"#,
    ])
    func catchesAStashVectorThatIsNotAnInlineArgumentOfRun(source: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(findings.contains { $0.contains("inline") }, "missed: \(source) → \(findings)")
    }

    /// In a file that names `stash`, the words that turn an allowed stash shape into a
    /// forbidden one are findings wherever no vector holds them — a fragment, an `.append`, an
    /// `.insert` — whatever the stash vector itself looks like. The vector here is a clean
    /// inline one, so only this rule can fire.
    @Test(arguments: [
        (#"var b = [String](); b += ["--", p]"#, "\"--\""),
        (#"var b = [String](); b.append("--")"#, "\"--\""),
        (#"var b = [String](); b.insert("--", at: 0)"#, "\"--\""),
        (#"var b = [String](); b += ["--staged"]"#, "--staged"),
        (#"var b = [String](); b.append("-S")"#, "\"-S\""),
        (#"var b = [String](); b.append("-a")"#, "\"-a\""),
        (#"var b = [String](); b.append("-k")"#, "\"-k\""),
        (#"var b = [String](); b.append("--patch")"#, "--patch"),
        (#"var b = [String](); b.insert(contentsOf: ["--all"], at: 0)"#, "--all"),
    ])
    func catchesAStashWordAddedOutsideAnyVectorInAFileThatRunsStash(extra: String, word: String) {
        let clean = #"_ = try await run(["stash", "push", "-q", "--message", m], cwd: root)"#
        #expect(ForceFlagScanner.findings(in: clean).isEmpty,
                "the baseline must be clean: \(ForceFlagScanner.findings(in: clean))")
        let findings = ForceFlagScanner.findings(in: clean + "\n" + extra)
        #expect(findings.contains { $0.contains(word) }, "missed: \(extra) → \(findings)")
        // And the same words are not findings in a file that does not name `stash`: `--` is
        // how every pathspec in this code base is introduced.
        if word == "\"--\"" {
            #expect(ForceFlagScanner.findings(in: extra).isEmpty,
                    "false positive without stash: \(ForceFlagScanner.findings(in: extra))")
        }
    }

    /// Fix round 2's ruling, pinned with its message: in a file that runs `git stash`, *every*
    /// git vector — not only the stash ones — is written as one array literal, optionally
    /// followed by `+ paths`. A `"--"` added in a second statement cannot be attributed to a
    /// command, so it is a finding even when the vector it joins is not `stash`; the message
    /// says what is required rather than blaming stash.
    @Test func inAFileThatRunsStashEveryVectorIsOneLiteral() {
        let stash = #"_ = try await run(["stash", "store", "-q", "-m", m, sha], cwd: root)"#
        let split = #"var args = ["update-index", "--add", "--remove"]; args += ["--"] + paths"#
        let whole = #"_ = try await runWithEnvironment(["update-index", "--add", "--remove", "--"] + paths, cwd: root, extra: index)"#
        let file = Self.recordFile

        let findings = ForceFlagScanner.findings(in: stash + "\n" + split, fileName: file)
        #expect(findings.count == 1, "\(findings)")
        #expect(findings.first?.contains("write every git vector as one array literal") == true,
                "\(findings)")
        #expect(findings.first?.contains("\"--\"") == true, "\(findings)")

        #expect(ForceFlagScanner.findings(in: stash + "\n" + whole, fileName: file).isEmpty,
                "false positive: \(ForceFlagScanner.findings(in: stash + "\n" + whole, fileName: file))")
        // Without a stash vector in the file, the two-statement spelling is not this rule's.
        #expect(ForceFlagScanner.findings(in: split, fileName: file).isEmpty,
                "\(ForceFlagScanner.findings(in: split, fileName: file))")
    }

    /// `restore` overwrites files on disk through `--worktree` and `--source=…`, and with
    /// `submodule.recurse=true` it discards work inside a submodule unless
    /// `--no-recurse-submodules` is given (M A.5). So its vectors are whole shapes too: the
    /// unstage vector and the three discard literals, each with `--no-recurse-submodules`.
    @Test(arguments: [
        (#"_ = try await run(["restore", "--staged", "--"] + paths, cwd: root)"#, "restore"),
        (#"_ = try await run(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + paths, cwd: root)"#, "restore"),
        (#"_ = try await run(["restore", "--no-recurse-submodules", "--source=\(sha)", "--worktree", "--"] + paths, cwd: root)"#, "restore"),
        (#"_ = try await run(["restore", "--no-recurse-submodules", "--source=\(sha)^2extra", "--staged", "--"] + paths, cwd: root)"#, "restore"),
        (#"_ = try await run(["restore", "--no-recurse-submodules", "--source=HEAD~1^2", "--staged", "--"] + paths, cwd: root)"#, "restore"),
        (#"_ = try await run(["restore", "--no-recurse-submodules", "-W", "--"] + paths, cwd: root)"#, "restore"),
        (#"_ = try await run(["restore", "--no-recurse-submodules", "--worktree", p], cwd: root)"#, "restore"),
        (#"_ = try await run(["restore", "--no-recurse-submodules", "--worktree"] + ["--", p], cwd: root)"#, "restore"),
        (#"var a = ["restore", "--no-recurse-submodules", "--staged", "--"]; a.append("--worktree")"#, "--worktree"),
        (#"let source = "--source=HEAD""#, "--source="),
        (#"let w = "--worktree""#, "--worktree"),
    ])
    func catchesARestoreVectorOutsideTheDiscardLiterals(source: String, word: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(!findings.isEmpty, "missed: \(source)")
        #expect(findings.contains { $0.contains(word) }, "\(findings) should name \(word)")
    }

    /// The scanner's first per-file rule. Without `GIT_INDEX_FILE`, `read-tree HEAD` overwrites
    /// the real index and drops every staged change, and a scanner cannot see an environment, so
    /// the three plumbing subcommands are confined to the one file that owns the temporary index.
    @Test(arguments: [
        #"_ = try await run(["read-tree", "HEAD"], cwd: root)"#,
        #"_ = try await run(["update-index", "--add", "--remove", "--"] + paths, cwd: root)"#,
        #"_ = try await run(["write-tree"], cwd: root)"#,
        #"let sub = "update-index""#,
        #"var a = [String](); a.append("write-tree")"#,
    ])
    func confinesTheRecordsPlumbingToOneFile(source: String) {
        for name in [nil, "CLIGitBackend+Stash.swift", "Parsers/" + Self.recordFile] as [String?] {
            let findings = ForceFlagScanner.findings(in: source, fileName: name)
            #expect(!findings.isEmpty, "missed in \(name ?? "an unnamed file"): \(source)")
        }
        #expect(ForceFlagScanner.findings(in: source, fileName: Self.recordFile).isEmpty,
                "false positive in the record's own file: \(ForceFlagScanner.findings(in: source, fileName: Self.recordFile))")
    }

    /// `read-tree -u`, `-m` and `--reset` write the worktree or merge into the index, and are
    /// findings even in the one file allowed to name `read-tree`.
    @Test(arguments: [
        (#"_ = try await run(["read-tree", "-u", t], cwd: root)"#, "-u"),
        (#"_ = try await run(["read-tree", "-m", t], cwd: root)"#, "-m"),
        (#"_ = try await run(["read-tree", "--reset", t], cwd: root)"#, "--reset"),
        (#"_ = try await run(["read-tree", "--reset", "-u", "HEAD"], cwd: root)"#, "--reset"),
        (#"_ = try await run([indexFlag, "read-tree", "-m", t], cwd: root)"#, "-m"),
        // Appended, so no vector holds it: in a file that runs `read-tree`, the three are
        // findings in the append pool too.
        (#"var a = ["read-tree", t]; a.append("-u")"#, "-u"),
        (#"var a = ["read-tree"]; a.append("--reset"); a.append(t)"#, "--reset"),
    ])
    func catchesAReadTreeThatWritesTheWorktreeEvenInTheRecordFile(source: String, flag: String) {
        let findings = ForceFlagScanner.findings(in: source, fileName: Self.recordFile)
        #expect(!findings.isEmpty, "missed: \(source)")
        #expect(findings.contains { $0.contains(flag) }, "\(findings) should name \(flag)")
    }

    /// `--unidiff-zero` lets a context-free hunk apply at an offset: it can remove the wrong
    /// line from the worktree (M 9) and, on an index that changed after the diff was loaded,
    /// stage lines nobody selected (A1 Task 3, Step 5; `PartialStagingStaleTests`). Nothing in
    /// `GitCore/Sources` passes it any more, `--cached` or not, so it is a finding wherever it
    /// is spelled: in any `apply` vector, a fragment, an append or a `let`, and under the
    /// abbreviations git accepts for it (`--unid` is the shortest; `--uni` is ambiguous with
    /// `--union`).
    @Test(arguments: [
        #"_ = try await run(["apply", "--unidiff-zero", f], cwd: root)"#,
        #"_ = try await run(["apply", "--reverse", "--whitespace=nowarn", "--unidiff-zero", f], cwd: root)"#,
        #"var a = ["apply", "--whitespace=nowarn"]; a.append("--unidiff-zero")"#,
        #"let zero = "--unidiff-zero""#,
        #"_ = try await run([applyFlag, "apply", "--unidiff-zero", f], cwd: root)"#,
        """
        var a = ["apply", "--cached", "--whitespace=nowarn"]
        var b = ["apply", "--reverse", "--whitespace=nowarn"]
        b.append("--unidiff-zero")
        """,
        // An index apply is no longer an exception.
        #"_ = try await run(["apply", "--cached", "--whitespace=nowarn", "--unidiff-zero", tmp.path], cwd: root)"#,
        #"_ = try await run(["apply", "--cached", "--reverse", "--unidiff-zero", f], cwd: root)"#,
        #"_ = try await run([applyFlag, "apply", "--cached", "--unidiff-zero", f], cwd: root)"#,
        // The line-staging code as it was until A1's inserted fix 2.
        """
        var arguments = ["apply", "--cached", "--whitespace=nowarn"]
        if patch.needsUnidiffZero { arguments.append("--unidiff-zero") }
        if reverse { arguments.append("--reverse") }
        """,
        """
        var arguments = ["apply", "--cached", "--whitespace=nowarn"]
        let zero = "--unidiff-zero"
        """,
        #"_ = try await run(["apply", "--cached"] + (zero ? ["--unidiff-zero"] : []) + [f], cwd: root)"#,
        // Abbreviated, and escaped.
        #"_ = try await run(["apply", "--cached", "--unidiff", f], cwd: root)"#,
        #"_ = try await run(["apply", "--unid", f], cwd: root)"#,
        #"var a = ["apply", "--cached"]; a.append("--unidiff-zer")"#,
        #"_ = try await run(["apply", "--cached", "--\u{75}nidiff-zero", f], cwd: root)"#,
    ])
    func catchesUnidiffZeroEverywhere(source: String) {
        for name in [nil, "CLIGitBackend+WorkingCopy.swift", Self.recordFile] as [String?] {
            let findings = ForceFlagScanner.findings(in: source, fileName: name)
            #expect(!findings.isEmpty, "missed in \(name ?? "an unnamed file"): \(source)")
            #expect(
                findings.contains { $0.contains("--unid") }, "\(findings) should name the flag")
        }
    }

    /// The other side of `catchesUnidiffZeroEverywhere`: it is keyed on `--unidiff-zero` and
    /// its abbreviations, not on anything that merely starts the same way.
    @Test(arguments: [
        #"_ = try await run(["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/", "--unified=3", "--", p], cwd: root)"#,
        #"_ = try await run(["apply", "--cached", "--whitespace=nowarn", f], cwd: root)"#,
        #"let message = "unidiff-zero is never passed""#,
    ])
    func doesNotMistakeOtherWordsForUnidiffZero(source: String) {
        #expect(ForceFlagScanner.findings(in: source).isEmpty,
                "false positive: \(ForceFlagScanner.findings(in: source))")
    }

    /// `hash-object` follows a symlink and hashes its target's content instead of the link
    /// (M 8), so the record is built with `update-index` instead and the word stays a finding.
    @Test(arguments: [
        #"_ = try await run(["hash-object", "-w", "--", p], cwd: root)"#,
        #"let sub = "hash-object""#,
        #"var a = [String](); a.append("hash-object")"#,
    ])
    func catchesHashObject(source: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(!findings.isEmpty, "missed: \(source)")
        #expect(findings.contains { $0.contains("hash-object") }, "\(findings)")
    }

    /// A **contract**, like `allowsTheRemoteOperationsThisMilestoneNeeds`: the vectors the
    /// working-copy milestone writes outside the record's file, spelled exactly as the plan
    /// spells them. A rule that turns one red is narrowed here first.
    ///
    /// `--include-untracked` is spelled one way only: last, inside the complete literal. A
    /// `+ [...]` after a `stash` vector is a finding, because a pathspec would ride along the
    /// same way.
    @Test(arguments: [
        #"_ = try await run(["stash", "list", "-z", "--format=%H%x1f%gd%x1f%gs%x1f%ct%x1f%P"], cwd: root)"#,
        #"_ = try await run(["diff-tree", "-p", "--no-color", "--no-ext-diff", "-U3", "-M", "\(sha)^1", sha], cwd: root)"#,
        #"_ = try await run(["diff-tree", "-p", "--no-color", "--no-ext-diff", "-U3", "4b825dc642cb6eb9a060e54bf8d69288fbee4904", "\(sha)^3"], cwd: root)"#,
        #"_ = try await run(["stash", "push", "-q", "--message", m], cwd: root)"#,
        #"_ = try await run(["stash", "push", "-q", "--message", m, "--include-untracked"], cwd: root)"#,
        // The optional flag chosen inline, the one way to choose it now that a stash vector
        // may not be bound to a name.
        #"_ = try await run(untracked ? ["stash", "push", "-q", "--message", m, "--include-untracked"] : ["stash", "push", "-q", "--message", m], cwd: root)"#,
        """
        let data = try await run(
            ["stash", "list", "-z", "--format=%H%x1f%gd%x1f%gs%x1f%ct%x1f%P"], cwd: root)
        """,
        #"_ = try await run(["stash", "store", "-q", "-m", m, sha], cwd: root)"#,
        // Task 4 runs the push through `runWithEnvironment`, as the apply: a refused push says
        // `f: needs merge` on stdout, which `run`'s thrown error does not carry (M 13).
        """
        let result = try await runWithEnvironment(
            includeUntracked
                ? ["stash", "push", "-q", "--message", m, "--include-untracked"]
                : ["stash", "push", "-q", "--message", m],
            cwd: root, extra: [:], allowedExitCodes: [1, 128])
        """,
        #"_ = try await runWithEnvironment(["stash", "apply", "-q", "--no-index", sha], cwd: root, extra: Self.rerereOff(env))"#,
        #"_ = try await run(["stash", "drop", "-q", "stash@{\(n)}"], cwd: root)"#,
        #"_ = try await run(["rev-parse", "-q", "--verify", "stash@{\(n)}"], cwd: root, allowedExitCodes: [1, 128])"#,
        #"_ = try await run(["rev-parse", "-q", "--verify", "refs/stash"], cwd: root, allowedExitCodes: [1])"#,
        #"_ = try await run(["ls-files", "-s", "-z", "--", literalPathspec(p)], cwd: root)"#,
        // Final review I1: the record's survey and the discard sheet's read, one call for every
        // path instead of one per path. `--no-renames` keeps the batched read equal to the
        // per-path one (`DiscardScalingTests.theBatchedReadIsThePerPathRead`).
        #"let data = try await backend.run(["ls-files", "-s", "-z", "--"] + paths.map(backend.literalPathspec), cwd: root)"#,
        #"let data = try await run(["diff", "--cached", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/", "--full-index", "-U3", "--no-renames", "--"] + paths.map(literalPathspec), cwd: root)"#,
        #"let data = try await run(["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/", "--full-index", "-U3", "--no-renames", "--"] + named.map(literalPathspec), cwd: root)"#,
        // Task 4's reads beside the stash vectors: each one literal, optionally `+ paths`.
        #"_ = try await run(["ls-files", "-u", "-z"], cwd: root)"#,
        #"_ = try await run(["ls-files", "-o", "-z", "--exclude-standard", "--", literalPathspec(directory)], cwd: root)"#,
        #"_ = try await run(["ls-tree", "-z", "--full-tree", rev, "--"] + paths.map(literalPathspec), cwd: root)"#,
        #"_ = try await run(["status", "--porcelain=v2", "-z", "--untracked-files=normal"], cwd: root)"#,
        #"_ = try await run(t ? ["rev-parse", "\(s)^{tree}", "\(s)^3^{tree}"] : ["rev-parse", "\(s)^{tree}"], cwd: root)"#,
        #"_ = try await run(["commit-tree", tree, "-p", "HEAD", "-m", m], cwd: root)"#,
        #"_ = try await run(["commit-tree", tree, "-p", "HEAD", "-p", i, "-m", m], cwd: root)"#,
        // Ruling 26: the paths in a pathspec file, one call however many.
        #"_ = try await run(["restore", "--no-recurse-submodules", "--worktree", "--pathspec-from-file=\(file)", "--pathspec-file-nul"], cwd: root)"#,
        #"_ = try await run(["restore", "--no-recurse-submodules", "--source=HEAD", "--staged", "--worktree", "--pathspec-from-file=\(file)", "--pathspec-file-nul"], cwd: root)"#,
        #"_ = try await run(["restore", "--no-recurse-submodules", "--source=\(sha)^2", "--staged", "--pathspec-from-file=\(file)", "--pathspec-file-nul"], cwd: root)"#,
        #"_ = try await run(["restore", "--no-recurse-submodules", "--staged", "--pathspec-from-file=\(file)", "--pathspec-file-nul"], cwd: root)"#,
        #"_ = try await run(["apply", "--reverse", "--whitespace=nowarn", tmp.path], cwd: root)"#,
        #"_ = try await run(["apply", "--whitespace=nowarn", tmp.path], cwd: root)"#,
        // Today's line staging, as `CLIGitBackend+WorkingCopy.swift` writes it: no
        // `--unidiff-zero` (see `catchesUnidiffZeroEverywhere`).
        """
        var arguments = ["apply", "--cached", "--whitespace=nowarn"]
        if reverse { arguments.append("--reverse") }
        """,
    ])
    func allowsTheWorkingCopyOperationsThisMilestoneNeeds(source: String) {
        for name in [nil, "CLIGitBackend+Stash.swift", Self.recordFile] as [String?] {
            #expect(ForceFlagScanner.findings(in: source, fileName: name).isEmpty,
                    "false positive in \(name ?? "an unnamed file"): \(ForceFlagScanner.findings(in: source, fileName: name))")
        }
    }

    /// The record's own vectors, which are findings anywhere but its file (see
    /// `confinesTheRecordsPlumbingToOneFile`).
    @Test(arguments: [
        #"_ = try await runWithEnvironment(["read-tree", "HEAD"], cwd: root, extra: index)"#,
        // Final review I1: one call for every path the real index lacks, and the entries in
        // calls of at most `cacheinfoLimit`, each `--cacheinfo` built in a fragment (it carries
        // none of the words a stash vector could take).
        #"_ = try await runWithEnvironment(["update-index", "--add"] + cacheinfo, cwd: root, extra: index)"#,
        #"entries[start..<end].flatMap { entry in ["--cacheinfo", "\(entry.mode),\(entry.sha),\(entry.path)"] }"#,
        #"_ = try await runWithEnvironment(["update-index", "--force-remove", "--"] + batch, cwd: root, extra: index)"#,
        #"_ = try await runWithEnvironment(["write-tree"], cwd: root, extra: index)"#,
        #"_ = try await runWithEnvironment(["update-index", "--add", "--remove", "--"] + batch, cwd: root, extra: index)"#,
        #"_ = try await run(["stash", "store", "-q", "-m", message, w], cwd: root)"#,
    ])
    func allowsTheRecordsVectorsInItsOwnFile(source: String) {
        #expect(ForceFlagScanner.findings(in: source, fileName: Self.recordFile).isEmpty,
                "false positive: \(ForceFlagScanner.findings(in: source, fileName: Self.recordFile))")
    }

    // MARK: - A patch read pins its format (fix/diff-config-prefix)

    /// A **contract**: the parsed `diff` reads exactly as `CLIGitBackend.swift` and
    /// `+Discard.swift` write them, and the reads that print no patch, which need no pin.
    @Test(arguments: [
        #"let data = try await run(["diff", "--cached", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/", "--full-index", "-U3", "-M", "--", literalPathspec(path)], cwd: root)"#,
        #"let data = try await run(["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/", "--full-index", "-U3", "--", literalPathspec(path)], cwd: root)"#,
        #"let data = try await run(["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/", "--full-index", "-U3", "--no-index", "--", "/dev/null", path], cwd: root, allowedExitCodes: [1])"#,
        #"_ = try await run(["diff", "--cached", "--quiet"], cwd: root)"#,
        #"_ = try await run(["diff", "--quiet"], cwd: root)"#,
        #"let data = try await run(["diff", "--cached", "--name-only", "-z", "--no-renames", "--"] + paths.map(literalPathspec), cwd: root)"#,
        #"let data = try await run(["diff", "--cached", "--raw", "-z", "--no-abbrev", "--no-renames", "--no-color", "--", pathspec], cwd: root)"#,
        // Rulings 22 and 25: the operation's source commits, names only.
        #"Self.nulSeparated(try await run(["diff", "--name-only", "-z", "--no-renames", from, to], cwd: root))"#,
        #"let bases = GitLines.split(try await run(["merge-base", "--all", "HEAD", head], cwd: root, allowedExitCodes: [1]))"#,
        #"let tips = GitLines.split(try await run(["merge-base", "--independent"] + listed, cwd: root))"#,
        #"let parents = GitLines.split(try await run(["rev-parse", "\(pseudoRef)^@"], cwd: root))"#,
        #"return Self.nulSeparated(try await run(["diff-tree", "-r", "--root", "--name-only", "-z", "--no-renames", "--no-commit-id", pseudoRef], cwd: root))"#,
    ])
    func allowsTheDiffReadsGitterMakes(source: String) {
        #expect(ForceFlagScanner.findings(in: source).isEmpty,
                "false positive: \(ForceFlagScanner.findings(in: source))")
    }

    static let pinnedDiff =
        #"_ = try await run(["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/", "-U3", "--", p], cwd: root)"#

    /// Each pin taken out of an otherwise clean vector, one at a time. Built from the clean
    /// vector in memory, so the shapes it proves the rule refuses are never written anywhere.
    static let eachPinRemoved: [(String, String)] = ForceFlagScanner.diffFormatPins.map { pin in
        (pinnedDiff.replacingOccurrences(of: "\"\(pin)\", ", with: ""), pin)
    }

    @Test(arguments: eachPinRemoved + [
        // After `--` it is a pathspec, not an option.
        (#"_ = try await run(["diff", "--no-color", "--no-textconv", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/", "--", "--no-ext-diff"], cwd: root)"#, "--no-ext-diff"),
        // One arm of a ternary is a pin only half the time.
        (#"_ = try await run(["diff", e ? "--no-ext-diff" : "-U3", "--no-textconv", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/", "--", p], cwd: root)"#, "--no-ext-diff"),
        // The flags added where the array literal cannot show them.
        (#"_ = try await run(["diff"] + format + ["--", p], cwd: root)"#, "--src-prefix=a/"),
        // `-p` puts a patch back beside a non-patch format.
        (#"_ = try await run(["diff", "--raw", "-p", "--", p], cwd: root)"#, "--no-ext-diff"),
    ])
    func catchesAPatchReadThatDoesNotPinItsFormat(source: String, pin: String) {
        #expect(source != Self.pinnedDiff)
        let findings = ForceFlagScanner.findings(in: source)
        #expect(findings.contains { $0.contains(pin) }, "missed \(pin) in \(source): \(findings)")
    }

    /// A pin taken back later in the same vector: git reads the last of each.
    @Test(arguments: ["--ext-diff", "--textconv", "--no-prefix", "--src-prefix=X/", "--dst-prefix=", "--submodule=log", "--submodule"])
    func catchesAPinTakenBack(flag: String) {
        let source = Self.pinnedDiff.replacingOccurrences(of: #""-U3""#, with: #""-U3", "\#(flag)""#)
        #expect(source != Self.pinnedDiff)
        let findings = ForceFlagScanner.findings(in: source)
        #expect(findings.contains { $0.contains(flag) }, "missed \(flag): \(findings)")
    }

    // MARK: - Conflict reads (A2 Task 1)

    /// A **contract**: the conflict reader's vectors, spelled as `CLIGitBackend+ConflictRead.swift`
    /// writes them, and Stage All's status read and batched `add`.
    @Test(arguments: [
        #"let data = try await run(["check-attr", "-z", "merge", "conflict-marker-size", "--", path], cwd: root)"#,
        #"let result = try await runWithEnvironment(["merge-file", "--object-id", "--diff-algorithm=histogram", "--marker-size=\(size)", "-L", "ours", "-L", "base", "-L", "theirs", ":2:\(path)", base, ":3:\(path)"], cwd: root, extra: [:], allowedExitCodes: codes)"#,
        #"let result = try await runWithEnvironment(["merge-file", "--object-id", "--diff-algorithm=histogram", "--diff3", "--marker-size=\(size)", "-L", "ours", "-L", "base", "-L", "theirs", ":2:\(path)", base, ":3:\(path)"], cwd: root, extra: [:], allowedExitCodes: codes)"#,
        #"_ = try await run(["merge-file", "--object-id", "--diff-algorithm=histogram", "--marker-size=\(n)", "-L", "ours", "-L", "base", "-L", "theirs", ":2:\(p)", ":1:\(p)", ":3:\(p)"], cwd: root)"#,
        // Fix round 1: `AUTO_MERGE` (its tree, the path's entry, the entry's bytes) and a merge
        // driver's definition.
        #"let data = try await run(["rev-parse", "-q", "--verify", "AUTO_MERGE^{tree}"], cwd: root, allowedExitCodes: [1])"#,
        #"let data = try await run(["ls-tree", "-z", "--full-tree", tree, "--", literalPathspec(path)], cwd: root)"#,
        #"let data = try await run(["cat-file", "blob", oid], cwd: root)"#,
        #"let data = try await run(["config", "--get", key], cwd: root, allowedExitCodes: [1])"#,
        #"let data = try await run(["cat-file", "--filters", "--path=\(path)", oid], cwd: root)"#,
        #"let data = try await run(["cat-file", "--filters", "--path=\(path)", ":\(n):\(path)"], cwd: root)"#,
        #"let data = try await run(["cat-file", "--filters", "--path=\(path)", stage], cwd: root)"#,
        #"try await run(["cat-file", "blob", "\(record.sha):\(path)"], cwd: root)"#,
        #"try await run(["cat-file", "--filters", "\(record.sha):\(path)"], cwd: root)"#,
        #"let data = try await run(["status", "--porcelain=v2", "-z", "--untracked-files=normal"], cwd: root)"#,
        #"_ = try await run(["add", "--"] + batch.map(literalPathspec), cwd: root)"#,
    ])
    func allowsTheConflictReadsThisMilestoneNeeds(source: String) {
        #expect(ForceFlagScanner.findings(in: source).isEmpty,
                "false positive: \(ForceFlagScanner.findings(in: source))")
    }

    /// Everything else `merge-file`, `cat-file` and `check-attr` can do is a finding. Built in
    /// test strings only.
    @Test(arguments: [
        // Without `--object-id` the result overwrites the first argument's file (M 2).
        (#"_ = try await run(["merge-file", "--marker-size=7", "-L", "ours", "-L", "base", "-L", "theirs", ":2:\(p)", ":1:\(p)", ":3:\(p)"], cwd: root)"#, "merge-file"),
        (#"_ = try await run(["merge-file", "ours.txt", "base.txt", "theirs.txt"], cwd: root)"#, "merge-file"),
        // `-p`: output mode.
        (#"_ = try await run(["merge-file", "-p", "--object-id", "--marker-size=\(n)", "-L", "ours", "-L", "base", "-L", "theirs", ":2:\(p)", ":1:\(p)", ":3:\(p)"], cwd: root)"#, "merge-file"),
        // Without histogram, the algorithm a merge diffs with (fix round 1), or with another.
        (#"_ = try await run(["merge-file", "--object-id", "--marker-size=\(n)", "-L", "ours", "-L", "base", "-L", "theirs", ":2:\(p)", ":1:\(p)", ":3:\(p)"], cwd: root)"#, "merge-file"),
        (#"_ = try await run(["merge-file", "--object-id", "--diff3", "--marker-size=\(n)", "-L", "ours", "-L", "base", "-L", "theirs", ":2:\(p)", ":1:\(p)", ":3:\(p)"], cwd: root)"#, "merge-file"),
        (#"_ = try await run(["merge-file", "--object-id", "--diff-algorithm=myers", "--marker-size=\(n)", "-L", "ours", "-L", "base", "-L", "theirs", ":2:\(p)", ":1:\(p)", ":3:\(p)"], cwd: root)"#, "merge-file"),
        (#"_ = try await run(["merge-file", "--object-id", "--diff-algorithm=histogram", "--diff3", "--diff-algorithm=myers", "--marker-size=\(n)", "-L", "ours", "-L", "base", "-L", "theirs", ":2:\(p)", ":1:\(p)", ":3:\(p)"], cwd: root)"#, "merge-file"),
        // Extra flags.
        (#"_ = try await run(["merge-file", "--object-id", "--zdiff3", "--marker-size=\(n)", "-L", "ours", "-L", "base", "-L", "theirs", ":2:\(p)", ":1:\(p)", ":3:\(p)"], cwd: root)"#, "merge-file"),
        (#"_ = try await run(["merge-file", "--object-id", "--union", "--marker-size=\(n)", "-L", "ours", "-L", "base", "-L", "theirs", ":2:\(p)", ":1:\(p)", ":3:\(p)"], cwd: root)"#, "merge-file"),
        (#"_ = try await run(["merge-file", "--object-id", "--marker-size=\(n)", "-L", "ours", "-L", "base", "-L", "theirs", ":2:\(p)", "--ours", ":3:\(p)"], cwd: root)"#, "merge-file"),
        // Other labels, or the stages swapped.
        (#"_ = try await run(["merge-file", "--object-id", "--marker-size=\(n)", "-L", "HEAD", "-L", "base", "-L", "theirs", ":2:\(p)", ":1:\(p)", ":3:\(p)"], cwd: root)"#, "merge-file"),
        (#"_ = try await run(["merge-file", "--object-id", "--marker-size=\(n)", "-L", "ours", "-L", "base", "-L", "theirs", ":3:\(p)", ":1:\(p)", ":2:\(p)"], cwd: root)"#, "merge-file"),
        // Anything appended.
        (#"_ = try await run(["merge-file", "--object-id", "--marker-size=\(n)", "-L", "ours", "-L", "base", "-L", "theirs", ":2:\(p)", ":1:\(p)", ":3:\(p)"] + extra, cwd: root)"#, "merge-file"),
        // `cat-file` without `--filters`, or in another output mode.
        (#"_ = try await run(["cat-file", "--path=\(p)", oid], cwd: root)"#, "cat-file"),
        (#"_ = try await run(["cat-file", "-p", oid], cwd: root)"#, "cat-file"),
        (#"_ = try await run(["cat-file", "--textconv", "--path=\(p)", oid], cwd: root)"#, "cat-file"),
        (#"_ = try await run(["cat-file", "--filters", "--path=\(p)", "--batch"], cwd: root)"#, "cat-file"),
        (#"_ = try await run(["cat-file", "blob", "--path=\(p)", oid], cwd: root)"#, "cat-file"),
        // `check-attr` of anything but the two attributes, or a pathspec-looking path.
        (#"_ = try await run(["check-attr", "-a", "--", p], cwd: root)"#, "check-attr"),
        (#"_ = try await run(["check-attr", "-z", "merge", "conflict-marker-size", "--"] + paths, cwd: root)"#, "check-attr"),
        (#"_ = try await run(["check-attr", "-z", "merge", "conflict-marker-size", "--", "-x"], cwd: root)"#, "check-attr"),
    ])
    func catchesAConflictReadOutsideItsShapes(source: String, subcommand: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(findings.contains { $0.contains("`git \(subcommand)` vector") }, "missed: \(source) → \(findings)")
    }

    /// Not vacuous: the reader's real file is clean, and each of its vectors, changed in memory
    /// only, becomes a finding — so the shapes are what stand between that file and git.
    @Test(arguments: [
        (#""merge-file", "--object-id", "--diff-algorithm=histogram", "--diff3", "#, #""merge-file", "--diff-algorithm=histogram", "--diff3", "#),
        (#""merge-file", "--object-id", "--diff-algorithm=histogram", "--marker-size="#, #""merge-file", "-p", "--object-id", "--diff-algorithm=histogram", "--marker-size="#),
        (#""merge-file", "--object-id", "--diff-algorithm=histogram", "--marker-size="#, #""merge-file", "--object-id", "--marker-size="#),
        (#""cat-file", "--filters", "--path=\(path)", oid]"#, #""cat-file", "--path=\(path)", oid]"#),
        (#""cat-file", "--filters", "--path=\(path)", stage]"#, #""cat-file", "--textconv", "--path=\(path)", stage]"#),
        (#""check-attr", "-z", "merge", "conflict-marker-size", "--", path]"#, #""check-attr", "-z", "merge", "conflict-marker-size", "--", literalPathspec(path), "-a"]"#),
    ])
    func theConflictReadersVectorsAreChecked(original: String, mutated: String) throws {
        let file = "CLIGitBackend+ConflictRead.swift"
        let source = try String(contentsOf: Self.sourcesRoot.appendingPathComponent(file), encoding: .utf8)
        #expect(ForceFlagScanner.findings(in: source, fileName: file).isEmpty)
        #expect(source.contains(original), "the reader no longer spells \(original)")
        let changed = source.replacingOccurrences(of: original, with: mutated)
        #expect(changed != source)

        #expect(!ForceFlagScanner.findings(in: changed, fileName: file).isEmpty)
    }

    // MARK: - Path lists in a pathspec file (Ruling 26)

    /// A **contract**: every write of a path list, spelled as the sources write it — the paths
    /// in a pathspec file (`withPathspecFile`), so one call takes any number of them and stays
    /// all or nothing; `Process` crashes past 4096 arguments.
    @Test(arguments: [
        #"_ = try await run(["add", "--pathspec-from-file=\(file)", "--pathspec-file-nul"], cwd: root)"#,
        #"try await run(["restore", "--no-recurse-submodules", "--staged", "--pathspec-from-file=\(file)", "--pathspec-file-nul"], cwd: root)"#,
        #"try await run(["restore", "--no-recurse-submodules", "--worktree", "--pathspec-from-file=\(file)", "--pathspec-file-nul"], cwd: root)"#,
        #"try await run(["restore", "--no-recurse-submodules", "--source=HEAD", "--staged", "--worktree", "--pathspec-from-file=\(file)", "--pathspec-file-nul"], cwd: root)"#,
        #"try await run(["restore", "--no-recurse-submodules", "--source=\(sha)^2", "--staged", "--pathspec-from-file=\(file)", "--pathspec-file-nul"], cwd: root)"#,
        #"try await run(["rm", "--cached", "-q", "--ignore-unmatch", "--pathspec-from-file=\(file)", "--pathspec-file-nul"], cwd: root)"#,
        #"""
        _ = try await withPathspecFile(survey.paths) { file in
            try await run(["restore", "--no-recurse-submodules", "--worktree", "--pathspec-from-file=\(file)", "--pathspec-file-nul"], cwd: root)
        }
        """#,
    ])
    func allowsThePathspecFileWrites(source: String) {
        for name in [nil, "CLIGitBackend+Stash.swift", Self.recordFile] as [String?] {
            #expect(ForceFlagScanner.findings(in: source, fileName: name).isEmpty,
                    "false positive in \(name ?? "an unnamed file"): \(ForceFlagScanner.findings(in: source, fileName: name))")
        }
    }

    /// And every other way to hand `restore` or `rm --cached` a path list is a finding: the
    /// paths as arguments again (`-- + paths`, the crash), a file that is not one interpolation
    /// (`-`, stdin, which is `/dev/null` here; a concatenation), a pathspec beside the file, no
    /// `--pathspec-file-nul` (a newline in a name would split it), or the file on a vector
    /// without `--no-recurse-submodules` or with another layer. Built in test strings only.
    @Test(arguments: [
        #"_ = try await run(["restore", "--no-recurse-submodules", "--staged", "--"] + paths.map(literalPathspec), cwd: root)"#,
        #"_ = try await run(["restore", "--no-recurse-submodules", "--worktree", "--"] + paths.map(literalPathspec), cwd: root)"#,
        #"_ = try await run(["restore", "--no-recurse-submodules", "--source=HEAD", "--staged", "--worktree", "--"] + paths.map(literalPathspec), cwd: root)"#,
        #"_ = try await run(["restore", "--no-recurse-submodules", "--source=\(sha)^2", "--staged", "--"] + paths.map(literalPathspec), cwd: root)"#,
        #"_ = try await run(["rm", "--cached", "-q", "--ignore-unmatch", "--"] + paths.map(literalPathspec), cwd: root)"#,
        #"_ = try await run(["restore", "--no-recurse-submodules", "--worktree", "--pathspec-from-file=-", "--pathspec-file-nul"], cwd: root)"#,
        #"_ = try await run(["restore", "--no-recurse-submodules", "--worktree", "--pathspec-from-file=" + file, "--pathspec-file-nul"], cwd: root)"#,
        #"_ = try await run(["restore", "--no-recurse-submodules", "--worktree", "--pathspec-from-file=\(file)extra", "--pathspec-file-nul"], cwd: root)"#,
        #"_ = try await run(["restore", "--no-recurse-submodules", "--worktree", "--pathspec-from-file=\(file)", "--pathspec-file-nul"] + paths, cwd: root)"#,
        #"_ = try await run(["restore", "--no-recurse-submodules", "--worktree", "--pathspec-from-file=\(file)", "--pathspec-file-nul", "--", p], cwd: root)"#,
        #"_ = try await run(["restore", "--no-recurse-submodules", "--worktree", "--pathspec-from-file=\(file)"], cwd: root)"#,
        #"_ = try await run(["restore", "--worktree", "--pathspec-from-file=\(file)", "--pathspec-file-nul"], cwd: root)"#,
        #"_ = try await run(["restore", "--no-recurse-submodules", "--staged", "--worktree", "--pathspec-from-file=\(file)", "--pathspec-file-nul"], cwd: root)"#,
        #"_ = try await run(["rm", "--cached", "-q", "--ignore-unmatch", "--pathspec-from-file=-", "--pathspec-file-nul"], cwd: root)"#,
        #"_ = try await run(["rm", "-q", "--pathspec-from-file=\(file)", "--pathspec-file-nul"], cwd: root)"#,
        #"_ = try await run(["rm", "--cached", "-q", "--pathspec-from-file=\(file)", "--pathspec-file-nul"], cwd: root)"#,
    ])
    func catchesAPathListOutsideThePathspecFileShapes(source: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(!findings.isEmpty, "missed: \(source)")
        #expect(findings.contains { $0.contains("`git restore` vector") || $0.contains("`git rm` vector") }, "\(findings)")
    }

    // MARK: - Conflict writes (A2 Task 2)

    /// A **contract**: the conflict writer's vectors, spelled as
    /// `CLIGitBackend+ConflictWrite.swift` writes them — and the two `rm` vectors Stage and
    /// Unstage already ran, now under `rm`'s shapes.
    @Test(arguments: [
        #"_ = try await run(["add", "--", literalPathspec(path)], cwd: root)"#,
        #"_ = try await run(["rm", "-q", "--", literalPathspec(path)], cwd: root)"#,
        #"_ = try await run(["restore", "--no-recurse-submodules", "--ours", "--", literalPathspec(path)], cwd: root)"#,
        #"_ = try await run(["restore", "--no-recurse-submodules", "--theirs", "--", literalPathspec(path)], cwd: root)"#,
        #"_ = try await run(["restore", "--no-recurse-submodules", "--merge", "--", literalPathspec(path)], cwd: root)"#,
        #"let data = try await run(["ls-files", "--resolve-undo", "-z", "--", literalPathspec(path)], cwd: root)"#,
        #"let data = try await run(["ls-files", "-s", "-z", "--", literalPathspec(path)], cwd: root)"#,
        #"let data = try await run(["diff", "--check", "--", literalPathspec(path)], cwd: root, allowedExitCodes: [2])"#,
        #"_ = try await run(["rm", "--cached", "-q", "--ignore-unmatch", "--pathspec-from-file=\(file)", "--pathspec-file-nul"], cwd: root)"#,
        #"_ = try await run(["rm", "--cached", "-r", "-q", "--", "."], cwd: root)"#,
    ])
    func allowsTheConflictWritesThisMilestoneNeeds(source: String) {
        #expect(ForceFlagScanner.findings(in: source).isEmpty,
                "false positive: \(ForceFlagScanner.findings(in: source))")
    }

    /// `restore --ours|--theirs` deletes a file whose stage is missing and exits 0, and discards
    /// an unstaged change on a path that is not conflicted (M 27); `rm` deletes files on disk.
    /// Every other shape of either is a finding. Built in test strings only.
    @Test(arguments: [
        // Without `--no-recurse-submodules`.
        (#"_ = try await run(["restore", "--ours", "--", literalPathspec(path)], cwd: root)"#, "restore"),
        (#"_ = try await run(["restore", "--merge", "--", literalPathspec(path)], cwd: root)"#, "restore"),
        // More than the one path the write checked.
        (#"_ = try await run(["restore", "--no-recurse-submodules", "--theirs", "--", literalPathspec(path)] + more, cwd: root)"#, "restore"),
        (#"_ = try await run(["restore", "--no-recurse-submodules", "--theirs", "--"] + paths, cwd: root)"#, "restore"),
        (#"_ = try await run(["restore", "--no-recurse-submodules", "--ours", "--", literalPathspec(a), literalPathspec(b)], cwd: root)"#, "restore"),
        // Another style, or another layer too.
        (#"_ = try await run(["restore", "--no-recurse-submodules", "--merge", "--conflict=diff3", "--", literalPathspec(path)], cwd: root)"#, "restore"),
        (#"_ = try await run(["restore", "--no-recurse-submodules", "--ours", "--worktree", "--", literalPathspec(path)], cwd: root)"#, "restore"),
        (#"_ = try await run(["restore", "--no-recurse-submodules", "--theirs", "--staged", "--", literalPathspec(path)], cwd: root)"#, "restore"),
        (#"_ = try await run(["restore", "--no-recurse-submodules", "--ours", "--", "-p"], cwd: root)"#, "restore"),
        // `rm` recursive, loud, of several paths, of a flag, or of another directory.
        (#"_ = try await run(["rm", "-q", "-r", "--", literalPathspec(path)], cwd: root)"#, "rm"),
        (#"_ = try await run(["rm", "--", literalPathspec(path)], cwd: root)"#, "rm"),
        (#"_ = try await run(["rm", "-q", "--", literalPathspec(path)] + more, cwd: root)"#, "rm"),
        (#"_ = try await run(["rm", "-q", "--"] + paths, cwd: root)"#, "rm"),
        (#"_ = try await run(["rm", "-q", "--", "-r"], cwd: root)"#, "rm"),
        (#"_ = try await run(["rm", "--cached", "-r", "-q", "--", dir], cwd: root)"#, "rm"),
        (#"_ = try await run(["rm", "-r", "-q", "--", "."], cwd: root)"#, "rm"),
    ])
    func catchesAConflictWriteOutsideItsShapes(source: String, subcommand: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(findings.contains { $0.contains("`git \(subcommand)` vector") }, "missed: \(source) → \(findings)")
    }

    /// Not vacuous: the writer's real file is clean, and each of its vectors, changed in memory
    /// only, becomes a finding.
    @Test(arguments: [
        (#""restore", "--no-recurse-submodules", "--ours", "--""#, #""restore", "--ours", "--""#),
        (#""restore", "--no-recurse-submodules", "--theirs", "--""#, #""restore", "--no-recurse-submodules", "--theirs", "--worktree", "--""#),
        (#""restore", "--no-recurse-submodules", "--merge", "--""#, #""restore", "--no-recurse-submodules", "--merge", "--conflict=diff3", "--""#),
        (#""rm", "-q", "--""#, #""rm", "-q", "-r", "--""#),
    ])
    func theConflictWritersVectorsAreChecked(original: String, mutated: String) throws {
        let file = "CLIGitBackend+ConflictWrite.swift"
        let source = try String(contentsOf: Self.sourcesRoot.appendingPathComponent(file), encoding: .utf8)
        #expect(ForceFlagScanner.findings(in: source, fileName: file).isEmpty)
        #expect(source.contains(original), "the writer no longer spells \(original)")
        let changed = source.replacingOccurrences(of: original, with: mutated)
        #expect(changed != source)

        #expect(!ForceFlagScanner.findings(in: changed, fileName: file).isEmpty)
    }

    // MARK: - Continue and Skip (A2 Task 3)

    /// A **contract**: every vector `CLIGitBackend+Continue.swift` runs, spelled as it writes
    /// them. The three `--skip` vectors are the only ones in `GitCore/Sources` that may carry
    /// the flag; `--continue` was never forbidden, and the two `diff` reads print no patch.
    @Test(arguments: [
        #"result = try await runWithEnvironment(["rebase", "--continue"], cwd: root, extra: Self.withConfig("commit.cleanup", "scissors", over: ProcessInfo.processInfo.environment), allowedExitCodes: Self.anyExitCode)"#,
        #"result = try await runWithEnvironment(["cherry-pick", "--continue"], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)"#,
        #"result = try await runWithEnvironment(["revert", "--continue", "--no-reference"], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)"#,
        #"arguments = ["rebase", "--skip"]"#,
        #"arguments = ["cherry-pick", "--skip"]"#,
        #"arguments = ["revert", "--skip", "--no-reference"]"#,
        #"let data = try await run(["diff", "--cached", "--name-only", "-z", "--no-renames", "HEAD"], cwd: root)"#,
        #"let data = try await run(["diff", "--name-only", "-z", "--no-renames", "HEAD", "AUTO_MERGE"], cwd: root)"#,
        #"let data = try await run(["rev-parse", "--git-path", name], cwd: root)"#,
        #"let data = try await run(["rev-parse", "-q", "--verify", name], cwd: root, allowedExitCodes: [1])"#,
        #"let data = try await run(["config", "-z", "--get-regexp", "^core[.]comment(char|string)$"], cwd: root, allowedExitCodes: [1])"#,
        #"let data = try await run(["log", "-1", "--no-show-signature", "--format=%H%x00%h%x00%s", "--end-of-options", rev], cwd: root, allowedExitCodes: [128])"#,
        // Ruling 30: a range stop concluded by `git commit` — HEAD's authorship and message.
        #"let data = try await run(["log", "-1", "--no-show-signature", "--format=%an%x00%ae%x00%at%x00%B", "--end-of-options", rev], cwd: root, allowedExitCodes: [128])"#,
        // Final review I2: the commits a range's `--abort` takes off the branch.
        #"let data = try await run(["log", "--reverse", "--no-show-signature", "--format=%H%x00%s", "--end-of-options", "\(start)..\(head)"], cwd: root)"#,
    ])
    func allowsTheContinueAndSkipVectorsThisMilestoneNeeds(source: String) {
        #expect(ForceFlagScanner.findings(in: source).isEmpty,
                "false positive: \(ForceFlagScanner.findings(in: source))")
    }

    /// `--skip` throws away the commit git stopped on — and `rebase --skip` every tracked change
    /// with it (M 17). It is allowed in the three whole vectors above and nowhere else: not with
    /// anything more in the vector, not after another subcommand (`am --skip` stays abort-only
    /// territory), not appended, not bound to a name. Built in test strings only.
    @Test(arguments: [
        #"_ = try await run(["rebase", "--skip", upstream], cwd: root)"#,
        #"_ = try await run(["cherry-pick", "--skip", "--no-commit"], cwd: root)"#,
        #"_ = try await run(["revert", x, "--skip"], cwd: root)"#,
        #"_ = try await run(["rebase", "--skip"] + extra, cwd: root)"#,
        #"_ = try await run(["am", "--skip"], cwd: root)"#,
        #"_ = try await run(["merge", "--skip"], cwd: root)"#,
        #"_ = try await run(["log", "--skip", n], cwd: root)"#,
        #"_ = try await run([repoFlag, "rebase", "--skip"], cwd: root)"#,
        #"var a = ["rebase"]; a += ["--skip"]"#,
        #"var a = ["cherry-pick"]; a.append("--skip")"#,
        #"let skip = "--skip""#,
        #"_ = try await run(["revert", done ? "--skip" : "--continue"], cwd: root)"#,
    ])
    func catchesASkipOutsideItsThreeShapes(source: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(findings.contains { $0.contains("--skip") }, "missed: \(source) → \(findings)")
    }

    /// Moving `--skip` did not move `--quit`: it drops the sequencer's state and leaves the
    /// half-applied result staged, and no vector of Gitter's may carry it.
    @Test(arguments: [
        #"_ = try await run(["rebase", "--quit"], cwd: root)"#,
        #"_ = try await run(["cherry-pick", "--quit"], cwd: root)"#,
        #"_ = try await run(["revert", "--quit"], cwd: root)"#,
        #"arguments = ["rebase", "--quit"]"#,
    ])
    func quitIsStillAFinding(source: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(findings.contains { $0.contains("--quit") }, "missed: \(source) → \(findings)")
        #expect(ForceFlagScanner.alwaysForbidden.contains("--quit"))
    }

    /// The three shapes are the whole permission: each one's table entry, and nothing else
    /// under `rebase`, `cherry-pick` or `revert` names `--skip`. The revert one carries
    /// `--no-reference` (final fix wave I1): `sequencer/opts` does not keep it, so a skip without
    /// it commits the rest of a range with git's placeholder subject under
    /// `revert.reference=true`.
    @Test func theSkipShapesAreExactlyTheThreeVectors() {
        let shapes = ForceFlagScanner.skipShapes
        #expect(Set(shapes.keys) == ["rebase", "cherry-pick", "revert"])
        let expected = [
            "rebase": #"["rebase", "--skip"]"#, "cherry-pick": #"["cherry-pick", "--skip"]"#,
            "revert": #"["revert", "--skip", "--no-reference"]"#,
        ]
        for (subcommand, list) in shapes {
            #expect(list.count == 1, "\(subcommand)")
            #expect(list.first.map { ForceFlagScanner.spelling(of: subcommand, [$0]) } == expected[subcommand])
        }
        #expect(ForceFlagScanner.alwaysForbidden.contains("--skip"), "vouched for by the shapes, forbidden elsewhere")
    }

    /// Not vacuous: the continue file is clean, and each of its vectors, changed in memory only,
    /// becomes a finding.
    @Test(arguments: [
        (#"arguments = ["rebase", "--skip"]"#, #"arguments = ["rebase", "--skip", "--no-verify"]"#),
        (#"arguments = ["cherry-pick", "--skip"]"#, #"arguments = ["am", "--skip"]"#),
        (#"arguments = ["revert", "--skip", "--no-reference"]"#, #"arguments = ["revert", "--quit"]"#),
        (#"["rebase", "--continue"]"#, #"["rebase", "--continue", "--autostash"]"#),
        // Final fix wave I1: the pin left out of either revert way on is a finding.
        (#"arguments = ["revert", "--skip", "--no-reference"]"#, #"arguments = ["revert", "--skip"]"#),
        (#"["revert", "--continue", "--no-reference"]"#, #"["revert", "--continue"]"#),
    ])
    func theContinueFilesVectorsAreChecked(original: String, mutated: String) throws {
        let file = "CLIGitBackend+Continue.swift"
        let source = try String(contentsOf: Self.sourcesRoot.appendingPathComponent(file), encoding: .utf8)
        #expect(ForceFlagScanner.findings(in: source, fileName: file).isEmpty)
        #expect(source.contains(original), "the file no longer spells \(original)")
        let changed = source.replacingOccurrences(of: original, with: mutated)
        #expect(changed != source)

        #expect(!ForceFlagScanner.findings(in: changed, fileName: file).isEmpty)
    }

    // MARK: - History actions (B1 Task 1)

    /// A **contract**: the three vectors that start a history action, spelled as the sources
    /// write them, and the reads the plans make. `cherry-pick`, `revert` and `rebase` are
    /// shape-governed since B1: these, `--abort`, `--continue` and `--skip` are their only
    /// permitted forms, so a vector that leaves out a pin is a finding — an absence no deny
    /// table could see.
    @Test(arguments: [
        #"let result = try await runWithEnvironment(["cherry-pick", "--empty=drop", "--end-of-options"] + shas, cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)"#,
        #"let result = try await runWithEnvironment(["revert", "--no-edit", "--no-reference", "--end-of-options"] + shas, cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)"#,
        #"_ = try await run(["rebase", "--no-autostash", "--no-update-refs", "--no-rebase-merges", "--end-of-options", target], cwd: root)"#,
        #"_ = try await run(["cherry-pick", "--abort"], cwd: root)"#,
        #"_ = try await run(["revert", "--continue", "--no-reference"], cwd: root)"#,
        #"arguments = ["rebase", "--skip"]"#,
        #"let data = try await run(["rev-list", "--topo-order", "--reverse", "--end-of-options"] + sorted + ["^" + head], cwd: root)"#,
        #"let data = try await run(["rev-list", "--count", "--not", "--remotes", "--not", "--end-of-options", range], cwd: root)"#,
        #"let data = try await run(["log", "--reverse", "--topo-order", "--cherry-mark", "--right-only", "--no-merges", "--no-show-signature", "--format=%m%x00%H%x00%s", "--end-of-options", "\(target)...\(head)"], cwd: root)"#,
    ])
    func allowsTheHistoryVectorsThisMilestoneNeeds(source: String) {
        #expect(ForceFlagScanner.findings(in: source).isEmpty,
                "false positive: \(ForceFlagScanner.findings(in: source))")
    }

    /// Each pin left out, an option added, the shas passed before `--end-of-options`, or the
    /// vector hidden from its shape: a finding. Built in test strings only, never in a source.
    @Test(arguments: [
        // `--empty=drop` left out: an already-applied commit stops the pick as "empty" (B4).
        #"_ = try await run(["cherry-pick", "--end-of-options"] + shas, cwd: root)"#,
        #"_ = try await run(["cherry-pick", "--empty=stop", "--end-of-options"] + shas, cwd: root)"#,
        #"_ = try await run(["cherry-pick", "--empty=keep", "--end-of-options"] + shas, cwd: root)"#,
        #"_ = try await run(["cherry-pick", "--empty=drop", "-x", "--end-of-options"] + shas, cwd: root)"#,
        #"_ = try await run(["cherry-pick", "--empty=drop", "--no-commit", "--end-of-options"] + shas, cwd: root)"#,
        #"_ = try await run(["cherry-pick", "--empty=drop"] + shas, cwd: root)"#,
        #"_ = try await run(["cherry-pick", "--empty=drop", "--end-of-options", sha], cwd: root)"#,
        // `--no-reference` left out: `revert.reference=true` commits git's placeholder (B9).
        #"_ = try await run(["revert", "--no-edit", "--end-of-options"] + shas, cwd: root)"#,
        #"_ = try await run(["revert", "--no-reference", "--end-of-options"] + shas, cwd: root)"#,
        #"_ = try await run(["revert", "--no-edit", "--no-reference", "-m", "1", "--end-of-options"] + shas, cwd: root)"#,
        // Final fix wave I1: `sequencer/opts` keeps `edit = false` but not `--no-reference`, so
        // a way on without it commits the rest of a range with git's placeholder subject.
        #"_ = try await run(["revert", "--continue"], cwd: root)"#,
        #"_ = try await run(["revert", "--skip"], cwd: root)"#,
        #"_ = try await run(["revert", "--continue", "--reference"], cwd: root)"#,
        #"_ = try await run(["revert", "--skip", "--no-reference", "--no-edit"], cwd: root)"#,
        // `--no-rebase-merges` left out: `rebase.rebaseMerges=true` recreates merges (B13).
        #"_ = try await run(["rebase", "--no-autostash", "--no-update-refs", "--end-of-options", target], cwd: root)"#,
        #"_ = try await run(["rebase", "--no-autostash", "--no-update-refs", "--rebase-merges", "--end-of-options", target], cwd: root)"#,
        #"_ = try await run(["rebase", "--no-autostash", "--no-update-refs", "--no-rebase-merges", "--end-of-options", target] + more, cwd: root)"#,
        #"_ = try await run(["rebase", "--no-update-refs", "--no-rebase-merges", "--end-of-options", target], cwd: root)"#,
        #"_ = try await run(["rebase", "--no-autostash", "--no-update-refs", "--no-rebase-merges", "-i", "--end-of-options", target], cwd: root)"#,
        #"_ = try await run(["rebase", "--continue", "--no-verify"], cwd: root)"#,
    ])
    func catchesAHistoryVectorOutsideItsShapes(source: String) {
        #expect(!ForceFlagScanner.findings(in: source).isEmpty, "missed: \(source)")
    }

    /// The three subcommands are shape-governed, and their shapes are exactly these.
    @Test func theHistorySubcommandsAreShapeGoverned() {
        #expect(ForceFlagScanner.spelling(of: "cherry-pick", ForceFlagScanner.allowedShapes["cherry-pick"] ?? [])
            == #"["cherry-pick", "--abort"] or ["cherry-pick", "--continue"] or ["cherry-pick", "--empty=drop", "--end-of-options"] + revisions"#)
        #expect(ForceFlagScanner.spelling(of: "revert", ForceFlagScanner.allowedShapes["revert"] ?? [])
            == #"["revert", "--abort"] or ["revert", "--continue", "--no-reference"] or ["revert", "--no-edit", "--no-reference", "--end-of-options"] + revisions"#)
        #expect(ForceFlagScanner.spelling(of: "rebase", ForceFlagScanner.allowedShapes["rebase"] ?? [])
            == #"["rebase", "--abort"] or ["rebase", "--continue"] or ["rebase", "--no-autostash", "--no-update-refs", "--no-rebase-merges", "--end-of-options", <data>]"#)
    }

    /// Not vacuous: each file is clean, and each of its history vectors, changed in memory
    /// only, becomes a finding.
    @Test(arguments: [
        ("CLIGitBackend+History.swift", #"["cherry-pick", "--empty=drop", "--end-of-options"]"#, #"["cherry-pick", "--end-of-options"]"#),
        ("CLIGitBackend+History.swift", #"["revert", "--no-edit", "--no-reference", "--end-of-options"]"#, #"["revert", "--no-edit", "--end-of-options"]"#),
        ("CLIGitBackend+Rebase.swift", #"["rebase", "--no-autostash", "--no-update-refs", "--no-rebase-merges", "--end-of-options", target]"#, #"["rebase", "--no-autostash", "--no-update-refs", "--end-of-options", target]"#),
        ("CLIGitBackend+Abort.swift", #"arguments = ["rebase", "--abort"]"#, #"arguments = ["rebase", "--abort", "--no-verify"]"#),
    ])
    func theHistoryFilesVectorsAreChecked(file: String, original: String, mutated: String) throws {
        let source = try String(contentsOf: Self.sourcesRoot.appendingPathComponent(file), encoding: .utf8)
        #expect(ForceFlagScanner.findings(in: source, fileName: file).isEmpty)
        #expect(source.contains(original), "\(file) no longer spells \(original)")
        let changed = source.replacingOccurrences(of: original, with: mutated)
        #expect(changed != source)

        #expect(!ForceFlagScanner.findings(in: changed, fileName: file).isEmpty)
    }

    // MARK: - Tags (B1 Task 2)

    /// A **contract**: every vector `CLIGitBackend+Tags.swift` runs, spelled as it writes them.
    /// `tag` and `update-ref` are shape-governed: the two creates (the restore is the
    /// lightweight one) and the one compare-and-delete are their only permitted forms.
    @Test(arguments: [
        #"_ = try await run(["tag", "--no-sign", "--end-of-options", name, sha], cwd: root)"#,
        #"_ = try await run(["tag", "--no-sign", "-a", "-F", file.path, "--cleanup=verbatim", "--end-of-options", name, sha], cwd: root)"#,
        #"_ = try await run(["tag", "--no-sign", "--end-of-options", receipt.name, receipt.objectID], cwd: root)"#,
        #"let result = try await runWithEnvironment(["update-ref", "--no-deref", "-d", "--end-of-options", "refs/tags/\(name)", "\(expected)"], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)"#,
        #"let data = try await run(["symbolic-ref", "-q", "refs/tags/\(name)"], cwd: root, allowedExitCodes: [1])"#,
        #"let data = try await run(["remote", "-v"], cwd: root)"#,
        #"let arguments = ["push", "--porcelain", "--no-follow-tags", "--no-recurse-submodules", "--end-of-options", remote, "refs/tags/\(n):refs/tags/\(n)"]"#,
        #"let arguments = ["push", "--porcelain", "--no-follow-tags", "--no-recurse-submodules", "--force-with-lease=refs/tags/\(n):\(id)", "--end-of-options", remote, ":refs/tags/\(n)"]"#,
        #"let result = try await runStreaming(["ls-remote", "--exit-code", "--end-of-options", remote, "refs/tags/\(n)"], cwd: root, allowedExitCodes: [2], progress: { _ in })"#,
        #"let check = try await runWithEnvironment(["check-ref-format", "refs/tags/\(name)"], cwd: root, extra: [:], allowedExitCodes: [1])"#,
        #"let data = try await run(["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes", "refs/tags"], cwd: root)"#,
        // Task 4 fix round 1: which remotes fetch no tags — a config read.
        #"let data = try await run(["config", "-z", "--get-regexp", "^remote[.].*[.]tagopt$"], cwd: root, allowedExitCodes: [1])"#,
    ])
    func allowsTheTagVectorsThisMilestoneNeeds(source: String) {
        #expect(ForceFlagScanner.findings(in: source).isEmpty,
                "false positive: \(ForceFlagScanner.findings(in: source))")
    }

    /// Each pin left out, a flag that signs, forces, deletes or opens an editor, the arguments
    /// before `--end-of-options`, or the vector hidden from its shape: a finding. Built in test
    /// strings only, never in a source.
    @Test(arguments: [
        // `--no-sign` left out: `tag.gpgSign=true` turns even a lightweight tag into a signed
        // annotated one (B17).
        #"_ = try await run(["tag", "--end-of-options", name, sha], cwd: root)"#,
        #"_ = try await run(["tag", "-a", "-F", f, "--cleanup=verbatim", "--end-of-options", name, sha], cwd: root)"#,
        // `-a` left out: `tag.forceSignAnnotated=true` beats `--no-sign` (B17).
        #"_ = try await run(["tag", "--no-sign", "-F", f, "--cleanup=verbatim", "--end-of-options", name, sha], cwd: root)"#,
        #"_ = try await run(["tag", "--no-sign", "-m", message, "--end-of-options", name, sha], cwd: root)"#,
        // `--cleanup=verbatim` left out: `-F` strips the `#` lines (B17).
        #"_ = try await run(["tag", "--no-sign", "-a", "-F", f, "--end-of-options", name, sha], cwd: root)"#,
        #"_ = try await run(["tag", "--no-sign", "-a", "-F", f, "--cleanup=strip", "--end-of-options", name, sha], cwd: root)"#,
        // Forcing, signing, deleting, listing, an editor.
        #"_ = try await run(["tag", "-f", "--no-sign", "--end-of-options", name, sha], cwd: root)"#,
        #"_ = try await run(["tag", "--force", name, sha], cwd: root)"#,
        #"_ = try await run(["tag", "-s", "-m", m, name, sha], cwd: root)"#,
        #"_ = try await run(["tag", "--sign", "-m", m, name, sha], cwd: root)"#,
        #"_ = try await run(["tag", "-u", key, "-m", m, name, sha], cwd: root)"#,
        #"_ = try await run(["tag", "--local-user=\(key)", name, sha], cwd: root)"#,
        #"_ = try await run(["tag", "--local-user", key, name, sha], cwd: root)"#,
        #"_ = try await run(["tag", "-d", name], cwd: root)"#,
        #"_ = try await run(["tag", "--delete", name], cwd: root)"#,
        #"_ = try await run(["tag", "-d", "--end-of-options", name], cwd: root)"#,
        #"_ = try await run(["tag", "-l"], cwd: root)"#,
        #"_ = try await run(["tag", "--no-sign", "-a", "-e", "-F", f, "--cleanup=verbatim", "--end-of-options", name, sha], cwd: root)"#,
        // The name and the target before `--end-of-options`, inline, or with more after.
        #"_ = try await run(["tag", "--no-sign", name, sha], cwd: root)"#,
        #"_ = try await run(["tag", "--no-sign", "--end-of-options", "v1", sha], cwd: root)"#,
        #"_ = try await run(["tag", "--no-sign", "--end-of-options", name, sha] + more, cwd: root)"#,
        #"_ = try await run(["tag", "--no-sign", "--end-of-options", name, sha, "-f"], cwd: root)"#,
        // Hidden from the shape: a fragment, an append.
        #"_ = try await run([repoFlag, "tag", "-m", m, name, sha], cwd: root)"#,
        #"var a = [String](); a.append("tag"); a += [name, sha]"#,
    ])
    func catchesATagVectorOutsideItsShapes(source: String) {
        #expect(!ForceFlagScanner.findings(in: source).isEmpty, "missed: \(source)")
    }

    /// `update-ref` is shape-governed: the one compare-and-delete, with the tag's full ref name
    /// and the expected id an interpolation. A literal old value — empty, forty zeros — deletes
    /// with no check at all (B19); a short ref name is refused by git, a branch is not a tag,
    /// and every other form of `update-ref` moves or deletes refs the sheet never named.
    @Test(arguments: [
        #"_ = try await run(["update-ref", "--no-deref", "-d", "--end-of-options", "refs/tags/\(name)", ""], cwd: root)"#,
        #"_ = try await run(["update-ref", "--no-deref", "-d", "--end-of-options", "refs/tags/\(name)", "0000000000000000000000000000000000000000"], cwd: root)"#,
        #"_ = try await run(["update-ref", "--no-deref", "-d", "--end-of-options", "refs/tags/\(name)"], cwd: root)"#,
        #"_ = try await run(["update-ref", "--no-deref", "-d", "--end-of-options", "refs/tags/\(name)", expected], cwd: root)"#,
        #"_ = try await run(["update-ref", "--no-deref", "-d", "--end-of-options", "refs/tags/\(name)", "\(expected)^0"], cwd: root)"#,
        #"_ = try await run(["update-ref", "--no-deref", "-d", "--end-of-options", name, "\(expected)"], cwd: root)"#,
        #"_ = try await run(["update-ref", "--no-deref", "-d", "--end-of-options", "refs/heads/\(name)", "\(expected)"], cwd: root)"#,
        #"_ = try await run(["update-ref", "--no-deref", "-d", "refs/tags/\(name)", "\(expected)"], cwd: root)"#,
        // Fix round 1 (I2): without `--no-deref` a symbolic ref under `refs/tags/` is followed,
        // and the branch it names is deleted instead.
        #"_ = try await run(["update-ref", "-d", "--end-of-options", "refs/tags/\(name)", "\(expected)"], cwd: root)"#,
        #"_ = try await run(["update-ref", "-d", "--no-deref", "--end-of-options", "refs/tags/\(name)", "\(expected)"], cwd: root)"#,
        #"_ = try await run(["update-ref", "--no-deref", "-d", "--end-of-options", "refs/tags/\(name)", "\(expected)"] + more, cwd: root)"#,
        #"_ = try await run(["update-ref", "refs/heads/main", sha], cwd: root)"#,
        #"_ = try await run(["update-ref", "--stdin"], cwd: root)"#,
        #"_ = try await run(["update-ref", "-m", why, "refs/tags/\(name)", sha], cwd: root)"#,
        #"_ = try await run([repoFlag, "update-ref", "-d", ref], cwd: root)"#,
    ])
    func catchesAnUpdateRefOutsideTheCompareAndDelete(source: String) {
        #expect(!ForceFlagScanner.findings(in: source).isEmpty, "missed: \(source)")
    }

    /// `push … tag <name>` is git's keyword form for `refs/tags/<name>:refs/tags/<name>` — a
    /// short name the scanner never saw a shape for (B20). Gitter spells the refspec in full.
    @Test(arguments: [
        #"let arguments = ["push", "--porcelain", "--no-follow-tags", "--no-recurse-submodules", "--end-of-options", remote, "tag", n]"#,
        #"_ = try await run(["push", remote, "tag", name], cwd: root)"#,
        #"_ = try await run(["push", remote, cond ? "tag" : "refs/tags/x", name], cwd: root)"#,
    ])
    func catchesThePushKeywordFormForATag(source: String) {
        let findings = ForceFlagScanner.findings(in: source)
        #expect(findings.contains { $0.contains("tag") }, "missed: \(source) → \(findings)")
    }

    /// The pushes Gitter makes that the push rules already cover, written for a tag: no force,
    /// no unleased delete, no `--tags`, `--follow-tags`, `--mirror` or `--all`.
    @Test(arguments: [
        #"let arguments = ["push", "--porcelain", "--no-follow-tags", "--no-recurse-submodules", "--end-of-options", remote, "+refs/tags/\(n):refs/tags/\(n)"]"#,
        #"let arguments = ["push", "--porcelain", "--no-follow-tags", "--no-recurse-submodules", "--end-of-options", remote, ":refs/tags/\(n)"]"#,
        #"let arguments = ["push", "--porcelain", "--no-follow-tags", "--no-recurse-submodules", "--force-with-lease=refs/tags/\(n)", "--end-of-options", remote, ":refs/tags/\(n)"]"#,
        #"let arguments = ["push", "--porcelain", "--tags", "--end-of-options", remote]"#,
        #"let arguments = ["push", "--porcelain", "--follow-tags", "--end-of-options", remote, "refs/tags/\(n):refs/tags/\(n)"]"#,
        #"let arguments = ["push", "--porcelain", "--mirror", "--end-of-options", remote]"#,
        #"let arguments = ["push", "--porcelain", "--delete", "--end-of-options", remote, "refs/tags/\(n)"]"#,
        #"let arguments = ["push", "--porcelain", "-f", "--end-of-options", remote, "refs/tags/\(n):refs/tags/\(n)"]"#,
    ])
    func catchesATagPushThePushRulesAlreadyForbid(source: String) {
        #expect(!ForceFlagScanner.findings(in: source).isEmpty, "missed: \(source)")
    }

    /// The two subcommands are shape-governed, and their shapes are exactly these.
    @Test func theTagAndUpdateRefSubcommandsAreShapeGoverned() {
        #expect(ForceFlagScanner.spelling(of: "tag", ForceFlagScanner.allowedShapes["tag"] ?? [])
            == #"["tag", "--no-sign", "--end-of-options", <expression>, <expression>] or ["tag", "--no-sign", "-a", "-F", <expression>, "--cleanup=verbatim", "--end-of-options", <expression>, <expression>]"#)
        // B2 Task 1 added the remote-tracking twin (`thePruneShapesAreExactlyTheListingAndTheDelete`).
        #expect(ForceFlagScanner.spelling(of: "update-ref", ForceFlagScanner.allowedShapes["update-ref"] ?? [])
            == #"["update-ref", "--no-deref", "-d", "--end-of-options", "refs/tags/\(…)", "\(…)"] or ["update-ref", "--no-deref", "-d", "--end-of-options", "refs/remotes/\(…)", "\(…)"]"#)
        #expect(Set((ForceFlagScanner.forbiddenFlags["tag"] ?? [:]).keys)
            == ["-f", "--force", "-s", "--sign", "-u", "--local-user", "-d", "--delete"])
    }

    /// Not vacuous: the tags file is clean, and each of its vectors, changed in memory only,
    /// becomes a finding.
    @Test(arguments: [
        (#"["tag", "--no-sign", "--end-of-options", name, sha]"#, #"["tag", "--end-of-options", name, sha]"#),
        (#"["tag", "--no-sign", "-a", "-F", file.path, "--cleanup=verbatim", "--end-of-options", name, sha]"#, #"["tag", "--no-sign", "-a", "-F", file.path, "--end-of-options", name, sha]"#),
        (#"["tag", "--no-sign", "--end-of-options", receipt.name, receipt.objectID]"#, #"["tag", "-f", "--no-sign", "--end-of-options", receipt.name, receipt.objectID]"#),
        (#""refs/tags/\(name)", "\(expected)"]"#, #""refs/tags/\(name)", ""]"#),
        (#"["update-ref", "--no-deref", "-d", "#, #"["update-ref", "-d", "#),
        (#""--end-of-options", remote, "refs/tags/\(n):refs/tags/\(n)"]"#, #""--end-of-options", remote, "tag", n]"#),
        (#""--force-with-lease=refs/tags/\(n):\(id)", "#, #""--force-with-lease=refs/tags/\(n)", "#),
    ])
    func theTagFilesVectorsAreChecked(original: String, mutated: String) throws {
        let file = "CLIGitBackend+Tags.swift"
        let source = try String(contentsOf: Self.sourcesRoot.appendingPathComponent(file), encoding: .utf8)
        #expect(ForceFlagScanner.findings(in: source, fileName: file).isEmpty)
        #expect(source.contains(original), "\(file) no longer spells \(original)")
        let changed = source.replacingOccurrences(of: original, with: mutated)
        #expect(changed != source)

        #expect(!ForceFlagScanner.findings(in: changed, fileName: file).isEmpty)
    }

    // MARK: - Prune and gone branches (B2 Task 1)

    /// A **contract**: every vector `CLIGitBackend+Prune.swift` runs, spelled as it writes them.
    /// The dry-run listing is the one place `fetch --prune` is permitted (always with
    /// `--dry-run --no-prune-tags`, R2/R8); the delete is `update-ref`'s second shape, a full
    /// `refs/remotes/` name and an interpolated expected id (R6); the kept branch is
    /// `branch --no-track`, which no upstream config can turn into a tracking branch.
    @Test(arguments: [
        #"let listed = try await runStreaming(["fetch", "--prune", "--no-prune-tags", "--dry-run", "--porcelain", "--no-progress", "--end-of-options", remote], cwd: root, progress: { _ in })"#,
        #"let result = try await runWithEnvironment(["update-ref", "--no-deref", "-d", "--end-of-options", "refs/remotes/\(rest)", "\(expected)"], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)"#,
        #"let result = try await runWithEnvironment(["branch", "--no-track", "--end-of-options", name, id], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)"#,
        #"var arguments = ["rev-list", "--count", "--not", "--branches", "--tags"]"#,
        #"var listing = ["rev-list", "--max-count=\(StrandedCommits.displayLimit)", "--format=%H%x00%s", "--no-commit-header", "--not", "--branches", "--tags"]"#,
        #"var one = ["rev-list", "--count", "--not", "--branches", "--tags"]"#,
        #"arguments.append("--remotes"); arguments.append("--not"); arguments.append("--end-of-options")"#,
        #"let data = try await run(["worktree", "list", "--porcelain", "-z"], cwd: root)"#,
        #"let data = try await run(["for-each-ref", "--format=%(refname)%00%(objectname)%00%(upstream)%00%(upstream:track)%00%(worktreepath)%00", "--end-of-options", "refs/heads"], cwd: root)"#,
        #"let data = try await run(["for-each-ref", "--format=%(refname)%00%(objectname)", "--end-of-options", "refs/remotes"], cwd: root)"#,
        #"let data = try await run(["remote", "-v"], cwd: root)"#,
        #"let data = try await run(["rev-parse", "--verify", "-q", "--end-of-options", ref], cwd: root, allowedExitCodes: [1])"#,
    ])
    func allowsThePruneVectorsThisMilestoneNeeds(source: String) {
        #expect(ForceFlagScanner.findings(in: source).isEmpty,
                "false positive: \(ForceFlagScanner.findings(in: source))")
    }

    /// `fetch --prune` anywhere but the exact listing shape is a finding: without `--dry-run` it
    /// deletes whatever the server lacks at that moment (R6), without `--no-prune-tags` the
    /// user's `fetch.pruneTags` makes it list and delete local tags (R8). And `update-ref -d`
    /// through the remote-tracking shape is still only that: never `refs/heads/`, never a
    /// literal or empty old value, never without `--no-deref`. Built in test strings only.
    @Test(arguments: [
        #"_ = try await run(["fetch", "--prune", "--no-prune-tags", "--porcelain", "--no-progress", "--end-of-options", remote], cwd: root)"#,
        #"_ = try await run(["fetch", "--prune", "--dry-run", "--porcelain", "--no-progress", "--end-of-options", remote], cwd: root)"#,
        #"_ = try await run(["fetch", "--prune", "--no-prune-tags", "--dry-run", "--porcelain", "--no-progress", "--end-of-options", "origin"], cwd: root)"#,
        #"_ = try await run(["fetch", "--prune", "--no-prune-tags", "--dry-run", "--porcelain", "--no-progress", "--end-of-options", remote] + more, cwd: root)"#,
        #"_ = try await run(["fetch", "--prune", "--no-prune-tags", "--dry-run", "--porcelain", "--no-progress", "--end-of-options", remote, "+refs/heads/*:refs/heads/*"], cwd: root)"#,
        #"_ = try await run(["fetch", "--prune", "--prune-tags", "--dry-run", "--porcelain", "--no-progress", "--end-of-options", remote], cwd: root)"#,
        #"_ = try await run(["fetch", "--dry-run", "--prune", "--no-prune-tags", "--porcelain", "--no-progress", "--end-of-options", remote], cwd: root)"#,
        #"_ = try await run([repoFlag, "fetch", "--prune", "--no-prune-tags", "--dry-run", "--porcelain", "--no-progress", "--end-of-options", remote], cwd: root)"#,
        #"_ = try await run(["fetch", "-p", "--end-of-options", remote], cwd: root)"#,
        #"_ = try await run(["update-ref", "--no-deref", "-d", "--end-of-options", "refs/heads/\(rest)", "\(expected)"], cwd: root)"#,
        #"_ = try await run(["update-ref", "--no-deref", "-d", "--end-of-options", "refs/remotes/\(rest)", ""], cwd: root)"#,
        #"_ = try await run(["update-ref", "--no-deref", "-d", "--end-of-options", "refs/remotes/\(rest)", "0000000000000000000000000000000000000000"], cwd: root)"#,
        #"_ = try await run(["update-ref", "--no-deref", "-d", "--end-of-options", "refs/remotes/\(rest)"], cwd: root)"#,
        #"_ = try await run(["update-ref", "-d", "--end-of-options", "refs/remotes/\(rest)", "\(expected)"], cwd: root)"#,
        #"_ = try await run(["update-ref", "--no-deref", "-d", "--end-of-options", "refs/remotes/origin/gone", "\(expected)"], cwd: root)"#,
        #"_ = try await run(["update-ref", "--no-deref", "-d", "--end-of-options", ref, "\(expected)"], cwd: root)"#,
        #"_ = try await run(["branch", "--no-track", "-f", "--end-of-options", name, id], cwd: root)"#,
    ])
    func catchesAPruneVectorOutsideItsShapes(source: String) {
        #expect(!ForceFlagScanner.findings(in: source).isEmpty, "missed: \(source)")
    }

    /// The listing is the one exception to `fetch`'s deny table, and `update-ref` has exactly
    /// the two compare-and-deletes.
    @Test func thePruneShapesAreExactlyTheListingAndTheDelete() {
        let exceptions = ForceFlagScanner.denyTableExceptionShapes
        #expect(Set(exceptions.keys) == ["fetch"])
        #expect(ForceFlagScanner.spelling(of: "fetch", exceptions["fetch"] ?? [])
            == #"["fetch", "--prune", "--no-prune-tags", "--dry-run", "--porcelain", "--no-progress", "--end-of-options", <expression>]"#)
        #expect(ForceFlagScanner.forbiddenFlags["fetch"]?["--prune"] != nil, "still forbidden everywhere else")
        #expect(ForceFlagScanner.spelling(of: "update-ref", ForceFlagScanner.allowedShapes["update-ref"] ?? [])
            == #"["update-ref", "--no-deref", "-d", "--end-of-options", "refs/tags/\(…)", "\(…)"] or ["update-ref", "--no-deref", "-d", "--end-of-options", "refs/remotes/\(…)", "\(…)"]"#)
    }

    /// Not vacuous: the prune file is clean, and each of its vectors, changed in memory only,
    /// becomes a finding.
    @Test(arguments: [
        (#"["fetch", "--prune", "--no-prune-tags", "--dry-run", "#, #"["fetch", "--prune", "--no-prune-tags", "#),
        (#"["fetch", "--prune", "--no-prune-tags", "--dry-run", "#, #"["fetch", "--prune", "--dry-run", "#),
        (#""refs/remotes/\(rest)", "\(expected)"]"#, #""refs/remotes/\(rest)", ""]"#),
        (#""refs/remotes/\(rest)", "\(expected)"]"#, #""refs/heads/\(rest)", "\(expected)"]"#),
        (#"["update-ref", "--no-deref", "-d", "#, #"["update-ref", "-d", "#),
        (#"["branch", "--no-track", "--end-of-options", name, id]"#, #"["branch", "-f", "--no-track", "--end-of-options", name, id]"#),
    ])
    func thePruneFilesVectorsAreChecked(original: String, mutated: String) throws {
        let file = "CLIGitBackend+Prune.swift"
        let source = try String(contentsOf: Self.sourcesRoot.appendingPathComponent(file), encoding: .utf8)
        #expect(ForceFlagScanner.findings(in: source, fileName: file).isEmpty)
        #expect(source.contains(original), "\(file) no longer spells \(original)")
        let changed = source.replacingOccurrences(of: original, with: mutated)
        #expect(changed != source)

        #expect(!ForceFlagScanner.findings(in: changed, fileName: file).isEmpty)
    }

    /// Not vacuous: the real sources hold exactly the five parsed reads, and the rule read them.
    @Test func everyParsedDiffReadInTheSourcesIsChecked() throws {
        let sources = try ForceFlagScanner.gitCoreSources(root: Self.sourcesRoot)
        let checked = sources.values.map(ForceFlagScanner.patchDiffVectorCount(in:)).reduce(0, +)
        #expect(checked == 5, "the rule checked \(checked) patch-reading `diff` vectors")
    }
}

/// Final review M6: the scanner confines `read-tree`, `update-index` and `write-tree` to the
/// record's file, but it cannot see an environment — so within that file nothing but this test
/// stops an edit from running one of them on the real index. Each must be passed inline to
/// `runWithEnvironment(` with `extra: index`, the temporary index `make` creates.
@Suite struct RecordIndexEnvironmentTests {
    static var recordSource: String {
        get throws {
            try String(
                contentsOf: ForceFlagScannerTests.sourcesRoot.appendingPathComponent(ForceFlagScanner.recordFile),
                encoding: .utf8)
        }
    }

    @Test func everyIndexWritingVectorInTheRecordRunsOnTheTemporaryIndex() throws {
        let result = ForceFlagScanner.indexWritingVectorsOutsideTheTemporaryIndex(in: try Self.recordSource)

        #expect(result.findings.isEmpty, "\(result.findings)")
        // Not vacuous: the record's five vectors were found and read.
        #expect(result.checked.count >= 5, "\(result.checked)")
        #expect(Set(result.checked) == ["read-tree", "update-index", "write-tree"])
    }

    /// The same file, changed in memory only — never on disk — in each way that would drop the
    /// temporary index.
    @Test(arguments: [
        (#"backend.runWithEnvironment(["read-tree", "HEAD"], cwd: root, extra: index)"#,
         #"backend.run(["read-tree", "HEAD"], cwd: root)"#),
        (#"backend.runWithEnvironment(["write-tree"], cwd: root, extra: index)"#,
         #"backend.runWithEnvironment(["write-tree"], cwd: root, extra: [:])"#),
        (#"backend.runWithEnvironment(["update-index", "--add"] + cacheinfo, cwd: root, extra: index)"#,
         #"backend.run(["update-index", "--add"] + cacheinfo, cwd: root)"#),
        (#"_ = try await backend.runWithEnvironment(["update-index", "--add", "--remove", "--"] + batch, cwd: root, extra: index)"#,
         #"let vector = ["update-index", "--add", "--remove", "--"] + batch; _ = try await backend.runWithEnvironment(vector, cwd: root, extra: index)"#),
        (#"_ = try await backend.runWithEnvironment(["update-index", "--force-remove", "--"] + batch, cwd: root, extra: index)"#,
         #"_ = try await backend.run(["update-index", "--force-remove", "--"] + batch, cwd: root)"#),
    ])
    func catchesAVectorThatWouldRunOnTheRealIndex(original: String, mutated: String) throws {
        let source = try Self.recordSource
        #expect(source.contains(original), "the record no longer spells \(original)")
        let changed = source.replacingOccurrences(of: original, with: mutated)
        #expect(changed != source)

        let result = ForceFlagScanner.indexWritingVectorsOutsideTheTemporaryIndex(in: changed)

        #expect(result.findings.count == 1, "\(result.findings)")
    }
}
