import Foundation
import Testing

@testable import GitCore

/// Table tests over stderr captured verbatim from git 2.54 under `LC_ALL=C` (the environment
/// `ProcessRunner` always sets). Each fixture in `Fixtures/refusals/` is the exact bytes a
/// real refusal wrote; see `task-2-report.md` for the command that produced each one.
@Suite struct BranchRefusalParserTests {
    static func fixture(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/refusals"),
            "missing fixture \(name).txt"
        )
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    static func parseFixture(_ name: String) throws -> BranchOperationError? {
        BranchRefusalParser.parse(stderr: try fixture(name))
    }

    // MARK: - "would be overwritten"

    @Test func singleFileOverwrittenByCheckout() throws {
        #expect(try Self.parseFixture("switch-local-changes-one") == .wouldOverwrite(files: ["f.txt"]))
    }

    /// Every file, in git's order, with no truncation: trimming the list to "(+3 more)" is
    /// the UI's job, not the parser's. The names also prove git does NOT C-quote here — a
    /// space, a double quote and a non-ASCII byte all arrive raw.
    @Test func everyFileOverwrittenByCheckoutIsReturnedUnquoted() throws {
        #expect(
            try Self.parseFixture("switch-local-changes-many")
                == .wouldOverwrite(files: ["f.txt", "qu\"ote.txt", "sp ace.txt", "uni-é.txt"])
        )
    }

    @Test func overwrittenByMergeUsesTheSameCase() throws {
        #expect(try Self.parseFixture("merge-local-changes") == .wouldOverwrite(files: ["f.txt"]))
    }

    /// The untracked variant is checked first because its text also contains
    /// "would be overwritten by checkout:".
    @Test func untrackedFilesGetTheirOwnCase() throws {
        #expect(
            try Self.parseFixture("switch-untracked")
                == .untrackedWouldBeOverwritten(files: ["\"quoted\".txt", "new.txt"])
        )
    }

    /// A file genuinely named `"quoted".txt` keeps its own quote characters: git prints the
    /// name raw, so unquoting it would corrupt it.
    @Test func aNameThatLooksQuotedIsNotUnquoted() throws {
        guard case .untrackedWouldBeOverwritten(let files) = try #require(
            try Self.parseFixture("switch-untracked"))
        else { Issue.record("wrong case"); return }
        #expect(files.contains("\"quoted\".txt"))
    }

    @Test func theFileListStopsAtTheFirstUnindentedLine() throws {
        guard case .wouldOverwrite(let files) = try #require(
            try Self.parseFixture("switch-local-changes-one"))
        else { Issue.record("wrong case"); return }
        #expect(files == ["f.txt"])  // not "Please commit your changes..." or "Aborting"
    }

    // MARK: - operation in progress

    @Test(arguments: [
        ("switch-while-merging", "merging"),
        ("switch-while-cherry-picking", "cherry-picking"),
        ("switch-while-reverting", "reverting"),
        ("switch-while-rebasing", "rebasing"),
        ("switch-while-am", "applying patches"),
    ])
    func operationInProgress(fixture: String, operation: String) throws {
        #expect(try Self.parseFixture(fixture) == .operationInProgress(operation))
    }

    // MARK: - name refusals

    @Test(arguments: ["branch-exists-branch", "branch-exists-switch-c", "branch-exists-rename"])
    func branchAlreadyExists(fixture: String) throws {
        #expect(try Self.parseFixture(fixture) == .branchExists("feature"))
    }

    @Test(arguments: ["invalid-name-branch", "invalid-name-switch-c"])
    func notAValidBranchName(fixture: String) throws {
        #expect(try Self.parseFixture(fixture) == .invalidName("x y"))
    }

    // MARK: - anything else

    @Test func unrecognisedStderrIsNil() throws {
        #expect(try Self.parseFixture("unrecognised-invalid-reference") == nil)
    }

    @Test(arguments: ["", "\n", "warning: something harmless\n"])
    func nothingToRecogniseIsNil(stderr: String) {
        #expect(BranchRefusalParser.parse(stderr: stderr) == nil)
    }

    /// A header with no indented lines after it is not a refusal we can describe, so it falls
    /// back to `GitError.commandFailed` rather than reporting an empty file list.
    @Test func aFileListHeaderWithNoFilesIsNil() {
        #expect(
            BranchRefusalParser.parse(
                stderr: "error: Your local changes to the following files would be overwritten by checkout:\n"
            ) == nil
        )
    }
}
