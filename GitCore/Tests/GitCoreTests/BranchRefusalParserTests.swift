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
        #expect(
            try Self.parseFixture("switch-local-changes-one")
                == .wouldOverwrite(tracked: ["f.txt"], untracked: [])
        )
    }

    /// Every file, in git's order, with no truncation: trimming the list to "(+3 more)" is
    /// the UI's job, not the parser's. The names also prove git does NOT C-quote here — a
    /// space, a double quote and a non-ASCII byte all arrive raw.
    @Test func everyFileOverwrittenByCheckoutIsReturnedUnquoted() throws {
        #expect(
            try Self.parseFixture("switch-local-changes-many")
                == .wouldOverwrite(
                    tracked: ["f.txt", "qu\"ote.txt", "sp ace.txt", "uni-é.txt"], untracked: [])
        )
    }

    /// Both merge captures: the fast-forwardable one (exit 1) and the true merge (exit 2,
    /// whose stderr ends with an extra "Merge with strategy ort failed." line that must not
    /// end up in the file list). The parser ignores the exit code entirely.
    @Test(arguments: [("merge-local-changes", "f.txt"), ("merge-local-changes-non-ff", "a.txt")])
    func overwrittenByMergeUsesTheSameCase(fixture: String, file: String) throws {
        #expect(try Self.parseFixture(fixture) == .wouldOverwrite(tracked: [file], untracked: []))
    }

    /// The untracked variant is checked first because its text also contains
    /// "would be overwritten by checkout:".
    @Test func untrackedFilesGetTheirOwnCase() throws {
        #expect(
            try Self.parseFixture("switch-untracked")
                == .wouldOverwrite(tracked: [], untracked: ["\"quoted\".txt", "new.txt"])
        )
    }

    /// A file genuinely named `"quoted".txt` keeps its own quote characters: git prints the
    /// name raw, so unquoting it would corrupt it.
    @Test func aNameThatLooksQuotedIsNotUnquoted() throws {
        guard case .wouldOverwrite(_, let untracked) = try #require(
            try Self.parseFixture("switch-untracked"))
        else { Issue.record("wrong case"); return }
        #expect(untracked.contains("\"quoted\".txt"))
    }

    @Test func theFileListStopsAtTheFirstUnindentedLine() throws {
        guard case .wouldOverwrite(let tracked, _) = try #require(
            try Self.parseFixture("switch-local-changes-one"))
        else { Issue.record("wrong case"); return }
        #expect(tracked == ["f.txt"])  // not "Please commit your changes..." or "Aborting"
    }

    /// A merge can also be refused over an untracked file, with the same header `switch` uses
    /// but "by merge:" instead of "by checkout:".
    @Test func untrackedFilesOverwrittenByMerge() throws {
        #expect(
            try Self.parseFixture("merge-untracked")
                == .wouldOverwrite(tracked: [], untracked: ["new.txt"])
        )
    }

    // MARK: - a dirty index

    /// The same header, a *completely* different block: `merge-ort` writes its file list on one
    /// space-indented, space-joined line instead of one TAB-indented line per file. Verified on
    /// git 2.54. It fires for any index entry that differs from HEAD, including files the merge
    /// never touches, so it is not a `.wouldOverwrite` and the names are not recoverable
    /// (a name containing a space could not be told from two names).
    @Test(arguments: ["merge-index-not-clean", "merge-index-not-clean-many"])
    func aSpaceIndentedFileBlockMeansTheIndexIsDirty(fixture: String) throws {
        #expect(try Self.parseFixture(fixture) == .indexNotClean)
    }

    /// The discriminator really is the indentation: the TAB-indented block with the very same
    /// header still means `.wouldOverwrite`, never `.indexNotClean`.
    @Test func aTabIndentedBlockIsStillWouldOverwrite() throws {
        #expect(
            try Self.parseFixture("merge-local-changes-non-ff")
                == .wouldOverwrite(tracked: ["a.txt"], untracked: [])
        )
    }

    // MARK: - operation in progress

    /// Two more wordings, neither of which mentions "switch". `MERGE_HEAD` with a clean index
    /// is "merging"; unmerged entries could belong to a merge, cherry-pick, revert or rebase,
    /// so the phrase names the state rather than guessing the operation.
    @Test(arguments: [
        ("merge-while-merging", "merging"),
        ("merge-unmerged-files", "resolving conflicts"),
    ])
    func mergeRefusedByAnOperationAlreadyInProgress(fixture: String, operation: String) throws {
        #expect(try Self.parseFixture(fixture) == .operationInProgress(operation))
    }

    @Test func aBranchGitCannotMerge() throws {
        #expect(
            try Self.parseFixture("merge-not-something-we-can-merge")
                == .noSuchBranch("nosuch-branch"))
    }

    /// Unrelated histories has no file list and no name to extract, so it stays git's own
    /// message via `GitError.commandFailed`.
    @Test func unrelatedHistoriesIsNotRecognised() throws {
        #expect(try Self.parseFixture("merge-unrelated-histories") == nil)
    }

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

    // MARK: - delete refusals

    /// Same wording, and the same `BranchOperationError` case, whether the branch is current in
    /// this worktree or checked out in a linked one — git 2.54 does not distinguish them.
    @Test func deletingABranchUsedByAWorktree() throws {
        #expect(try Self.parseFixture("branch-used-by-worktree") == .cannotDeleteCurrent("linked-branch"))
    }

    @Test func deletingANonexistentBranch() throws {
        #expect(try Self.parseFixture("branch-not-found") == .noSuchBranch("nosuch-branch"))
    }

    // MARK: - anything else

    @Test func unrecognisedStderrIsNil() throws {
        #expect(try Self.parseFixture("unrecognised-invalid-reference") == nil)
    }

    @Test(arguments: ["", "\n", "warning: something harmless\n"])
    func nothingToRecogniseIsNil(stderr: String) {
        #expect(BranchRefusalParser.parse(stderr: stderr) == nil)
    }

    /// One `git switch` can print BOTH blocks — a conflicting tracked change *and* an
    /// untracked file in the way. Returning only the first would have the user fix one file,
    /// retry, and be refused again over the other, so both lists come back from one parse.
    @Test func bothBlocksAtOnceAreBothReported() throws {
        #expect(
            try Self.parseFixture("switch-both-blocks")
                == .wouldOverwrite(tracked: ["tracked.txt"], untracked: ["untracked.txt"])
        )
    }

    /// Leading and trailing spaces in a name survive; a name containing a NEWLINE does not,
    /// because git prints it raw and its second half reads as the end of the block. Recorded
    /// here so the loss is a known, tested limit rather than a surprise.
    @Test func oddFileNamesSpacesSurviveAndANewlineTruncatesTheList() throws {
        #expect(
            try Self.parseFixture("switch-odd-file-names")
                == .wouldOverwrite(tracked: [" lead-and-trail .txt", "new"], untracked: [])
        )
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

/// `git rebase`'s refusals, captured verbatim from git 2.54 (`LC_ALL=C`) into
/// `Fixtures/refusals/rebase-*.txt`. See `task-7-report.md` for the command behind each.
@Suite struct RebaseRefusalParserTests {
    /// Both of git's sentences, and the one it prints when it has both to say: the first line
    /// names the unstaged change and an `additionally,` line adds the index.
    @Test(arguments: ["rebase-unstaged", "rebase-staged", "rebase-unstaged-and-staged"])
    func anUncommittedChangeIsTreeNotClean(fixture: String) throws {
        #expect(try BranchRefusalParserTests.parseFixture(fixture) == .treeNotClean)
    }

    /// An untracked file the rebase would have to write over is refused by the checkout that
    /// starts the rebase, under the checkout's own header — so it is the existing
    /// `.wouldOverwrite`, not a rebase-specific case.
    @Test func anUntrackedFileInTheWayIsWouldOverwrite() throws {
        #expect(
            try BranchRefusalParserTests.parseFixture("rebase-untracked-overwritten")
                == .wouldOverwrite(tracked: [], untracked: ["new.txt"]))
    }

    /// A `pre-rebase` hook's refusal is not a shape Gitter can describe better than git did.
    @Test func aHookRefusalStaysGitsOwnWords() throws {
        #expect(try BranchRefusalParserTests.parseFixture("rebase-pre-rebase-hook") == nil)
    }

    /// The match is on the sentence, not on "cannot rebase" alone.
    @Test func anotherCannotRebaseLineIsNotTreeNotClean() {
        #expect(BranchRefusalParser.parse(stderr: "error: cannot rebase: something new\n") == nil)
    }
}
