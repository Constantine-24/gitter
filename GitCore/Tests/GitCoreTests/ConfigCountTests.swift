import Foundation
import Testing

@testable import GitCore

/// `configCount`: `GIT_CONFIG_COUNT` read the way git reads it, and `rerereOff` built on it, so
/// a count git accepts keeps the user's own `GIT_CONFIG_KEY_<n>` (E3 B4.1).
///
/// git 2.54 reads the count like `strtoul(…, 10)` with nothing allowed after the digits: leading
/// whitespace skipped, an optional sign, a negative wrapping into its "too many" error. Swift's
/// `Int(_:)`, which `withConfig` used, reads `" 1"` as unparsable, so `rerereOff` took the count
/// for 0 and wrote its own parameter over the user's `KEY_0` (measured).
///
/// Each row is checked against the real git as well as against its expected reading, so the
/// table cannot drift from git: `GIT_CONFIG_COUNT=<v> GIT_CONFIG_KEY_0=core.x
/// GIT_CONFIG_VALUE_0=y git config core.x` prints `y` (exit 0) for a count of 1, nothing (exit 1)
/// for a count of 0, and refuses (exit 128) a count it cannot read.
@Suite struct ConfigCountTests {
    /// B4.1's table, plus the other four C-space bytes, a non-ASCII space git does not skip
    /// (`LC_ALL=C`), and two counts past `INT_MAX` (git's "too many"). nil as the value is an
    /// unset variable; nil as the reading is a count git refuses.
    static let table: [(value: String?, reading: Int?)] = [
        (" 1", 1), ("\t1", 1), ("\n1", 1), (" +1", 1), ("+1", 1), ("01", 1),
        ("1 ", nil), ("1x", nil), ("", 0), ("-1", nil), ("0", 0), ("-0", 0),
        ("1\n", nil), (" ", nil), ("0x1", nil), (nil, 0),
        ("\u{0B}1", 1), ("\u{0C}1", 1), ("\r1", 1), ("\r\n1", 1), ("\u{A0}1", nil),
        ("+", nil), ("-", nil), ("+-1", nil),
        ("2147483648", nil), ("18446744073709551617", nil),
    ]

    @Test(arguments: table)
    func theCountIsReadAsGitReadsIt(value: String?, reading: Int?) async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }

        #expect(try await Self.gitsReading(of: value, in: repo) == reading, "the table disagrees with git")
        #expect(CLIGitBackend.configCount(value) == reading)
    }

    /// Through `rerereOff`, with the user's own `GIT_CONFIG_KEY_0=core.x`: a count git reads as 1
    /// keeps `core.x` next to `rerere.enabled=false`; a count of 0 never set `core.x` for git
    /// either; and a count git refuses still produces a git that runs, as `rerereOff`'s doc says.
    @Test(arguments: table)
    func rerereOffKeepsEveryParameterGitWouldHaveRead(value: String?, reading: Int?) async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let backend = CLIGitBackend()
        var users = ["GIT_CONFIG_KEY_0": "core.x", "GIT_CONFIG_VALUE_0": "y"]
        users["GIT_CONFIG_COUNT"] = value

        let env = CLIGitBackend.rerereOff(users)
        let rerere = try await backend.runWithEnvironment(
            ["config", "rerere.enabled"], cwd: repo.root, extra: env, allowedExitCodes: [1, 128])
        let kept = try await backend.runWithEnvironment(
            ["config", "core.x"], cwd: repo.root, extra: env, allowedExitCodes: [1, 128])

        #expect(rerere.exitCode == 0 && String(decoding: rerere.stdout, as: UTF8.self) == "false\n",
                "\(rerere.exitCode) \(rerere.stderr)")
        if reading == 1 {
            #expect(kept.exitCode == 0 && String(decoding: kept.stdout, as: UTF8.self) == "y\n",
                    "the user's GIT_CONFIG_KEY_0 was lost: \(kept.exitCode) \(kept.stderr)")
        } else {
            #expect(kept.exitCode == 1 && kept.stdout.isEmpty, "\(kept.exitCode) \(kept.stderr)")
        }
    }

    /// The cross-check's control: it does catch a parse that is not git's. Swift's `Int(_:)` —
    /// `withConfig`'s parse before E3 — disagrees with git on every leading space.
    @Test func theCrossCheckCatchesAParseThatIsNotGits() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }

        withKnownIssue("Int(_:) reads a leading space as unparsable, git skips it") {
            #expect(Int(" 1") == 1)
        }
        let git = try await Self.gitsReading(of: " 1", in: repo)
        #expect(git == 1)
        withKnownIssue("Int(_:) is not git's reading") {
            for row in Self.table {
                let swift = row.value.flatMap { Int($0) }.map { max($0, 0) } ?? 0
                #expect(swift == row.reading ?? 0, "\(String(reflecting: row.value))")
            }
        }
    }

    /// git's own reading of `value`, from whether `git config core.x` sees the one parameter.
    /// The refusal is recognised by git's own words, so another failure cannot pass for one.
    private static func gitsReading(of value: String?, in repo: TestRepo) async throws -> Int?? {
        var extra = ["GIT_CONFIG_KEY_0": "core.x", "GIT_CONFIG_VALUE_0": "y"]
        extra["GIT_CONFIG_COUNT"] = value
        let result = try await CLIGitBackend().runWithEnvironment(
            ["config", "core.x"], cwd: repo.root, extra: extra, allowedExitCodes: [1, 128])
        let out = String(decoding: result.stdout, as: UTF8.self)
        switch result.exitCode {
        case 0 where out == "y\n": return .some(1)
        case 1 where out.isEmpty: return .some(0)
        case 128 where result.stderr.contains("bogus count in GIT_CONFIG_COUNT")
            || result.stderr.contains("too many entries in GIT_CONFIG_COUNT"):
            return .some(nil)
        default:
            Issue.record("an answer that is no reading: \(result.exitCode) \(out) \(result.stderr)")
            return nil
        }
    }
}
