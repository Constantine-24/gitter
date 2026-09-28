import Foundation
import Testing

@testable import GitCore

/// The stash messages `BranchRefusalParser` does not know, verbatim from git 2.54 (M 6, 7, 13,
/// 14, 17). `f: needs merge` arrives on **stdout**, everything else on stderr.
@Suite struct StashFailureParserTests {
    @Test func needsMergeOnStdoutIsUnmerged() {
        let failure = StashFailureParser.parse(
            stdout: "f: needs merge\nsp ace.txt: needs merge\n",
            stderr: "error: could not write index\n")
        #expect(failure == .unmerged(["f", "sp ace.txt"]))
    }

    @Test func alreadyExistsNoCheckoutIsAnUntrackedFileNotRestored() {
        let failure = StashFailureParser.parse(
            stdout: "",
            stderr: "u.txt already exists, no checkout\nud/v already exists, no checkout\n"
                + "error: could not restore untracked files from stash\n")
        #expect(failure == .untrackedAlreadyExists(["u.txt", "ud/v"]))
    }

    @Test func aShaThatIsNotAStashReference() {
        let failure = StashFailureParser.parse(
            stdout: "",
            stderr: "error: 'e47b0bad8134fad3c6aa210e2d2e453865b17020' is not a stash reference\n")
        #expect(failure == .notAStashReference)
    }

    @Test func noStashEntriesFound() {
        #expect(StashFailureParser.parse(stdout: "", stderr: "No stash entries found.\n") == .noEntries)
    }

    @Test func entryNotUptodateIsIntentToAdd() {
        let failure = StashFailureParser.parse(
            stdout: "",
            stderr: "Ignoring path nested/\nerror: Entry 'ita' not uptodate. Cannot merge.\n"
                + "Cannot save the current worktree state\n")
        #expect(failure == .intentToAdd(["ita"]))
    }

    @Test func aNameWithAQuoteInsideTheEntryMessage() {
        let failure = StashFailureParser.parse(
            stdout: "", stderr: "error: Entry 'it's' not uptodate. Cannot merge.\n")
        #expect(failure == .intentToAdd(["it's"]))
    }

    @Test func indexLockIsLocked() {
        let failure = StashFailureParser.parse(
            stdout: "",
            stderr: "error: Unable to create '/private/var/folders/x/T/tmp.a/.git/index.lock': File exists.\n"
                + "\nAnother git process seems to be running in this repository, or the lock file may be stale\n"
                + "error: could not write index\n")
        #expect(failure == .indexLocked)
    }

    /// The lock wins over `could not write index`'s other cause: with both present, the user
    /// must be told about the lock first.
    @Test func theLockIsReportedBeforeAnythingElse() {
        let failure = StashFailureParser.parse(
            stdout: "f: needs merge\n",
            stderr: "fatal: Unable to create '/r/.git/index.lock': File exists.\n")
        #expect(failure == .indexLocked)
    }

    @Test func anythingElseIsNil() {
        #expect(StashFailureParser.parse(stdout: "", stderr: "") == nil)
        #expect(StashFailureParser.parse(
            stdout: "", stderr: "fatal: 'HEAD' is not a stash-like commit\n") == nil)
        #expect(StashFailureParser.parse(stdout: "Saved working directory and index state On main: m\n",
                                         stderr: "") == nil)
    }
}
