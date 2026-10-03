import Foundation
import GitCore
import Testing

@testable import Gitter

/// Every sentence the tags put on screen (`TagWording`): the sidebar rows and their menu, the
/// commit list's pills, the New Tag, Delete Tag and Delete-on-a-remote sheets, their notices
/// and every refusal. Pure: no store, no git.
@MainActor @Suite struct TagWordingTests {

    static let commit = "1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d"
    static let tagObject = "9f8e7d6c5b4a39281706f5e4d3c2b1a098765432"
    static let other = "8e7d6c5b4a39281706f5e4d3c2b1a09876543210"
    static let when = Date(timeIntervalSince1970: 1_790_000_000)

    static let annotated = Tag(
        name: "v1.0", sha: commit, isAnnotated: true, objectID: tagObject, tagger: "Ada Lovelace",
        date: when, subject: "Release 1.0")
    static let lightweight = Tag(name: "wip", sha: commit, isAnnotated: false)
    static let symbolic = Tag(name: "alias", sha: commit, isAnnotated: false, isSymbolic: true)

    static func day(_: Date) -> String { "3 Oct 2026" }

    // MARK: - Name problems

    @Test func everyNameProblemHasItsSentence() {
        #expect(TagWording.problem(.empty) == "Enter a tag name.")
        #expect(TagWording.problem(.invalid) == "That is not a valid tag name.")
        #expect(
            TagWording.problem(.exists)
                == "A tag with that name already exists, or one git can't keep beside it (\"V1\" "
                + "beside \"v1\", \"a\" beside \"a/b\").")
        #expect(
            TagWording.problem(.isBranchName)
                == "A branch or remote has that name. git would read the tag in its place in "
                + "every command that names it.")
        #expect(
            TagWording.problem(.looksLikeObjectID)
                == "That name looks like a commit id, and git would read it as one.")
        #expect(
            TagWording.problem(.reserved)
                == "git keeps that name for itself (HEAD, ORIG_HEAD, stash and the like), or it "
                + "starts with \"-\".")
        #expect(TagWording.problem(.tooLong) == "That name is too long for git to store.")
    }

    /// The field says nothing until the user has typed: an empty field nobody touched is not a
    /// mistake yet.
    @Test func anUntouchedEmptyFieldSaysNothing() {
        #expect(TagWording.fieldMessage(.empty, edited: false) == nil)
        #expect(TagWording.fieldMessage(.empty, edited: true) == "Enter a tag name.")
        #expect(TagWording.fieldMessage(.exists, edited: false) == TagWording.problem(.exists))
        #expect(TagWording.fieldMessage(nil, edited: true) == nil)
    }

    // MARK: - Sidebar rows and menu

    @Test func anAnnotatedRowSaysWhoWhenAndWhat() {
        #expect(
            TagWording.rowHelp(Self.annotated, date: Self.day)
                == "Annotated tag on 1a2b3c4\nTagged by Ada Lovelace, 3 Oct 2026\nRelease 1.0")
        #expect(TagWording.rowAccessibility(Self.annotated) == "v1.0, annotated tag")
        #expect(TagWording.rowIcon(Self.annotated) == "tag.fill")
    }

    @Test func anAnnotatedRowWithoutTaggerOrMessageSaysSo() {
        let bare = Tag(
            name: "v0", sha: Self.commit, isAnnotated: true, objectID: Self.tagObject, tagger: nil,
            date: Self.when, subject: "")
        #expect(
            TagWording.rowHelp(bare, date: Self.day)
                == "Annotated tag on 1a2b3c4\nTagged 3 Oct 2026\n(no message)")
        let undated = Tag(
            name: "v0", sha: Self.commit, isAnnotated: true, objectID: Self.tagObject, tagger: nil,
            date: nil, subject: "Hi")
        #expect(TagWording.rowHelp(undated, date: Self.day) == "Annotated tag on 1a2b3c4\nHi")
    }

    @Test func aLightweightRowIsOnlyAName() {
        #expect(
            TagWording.rowHelp(Self.lightweight, date: Self.day)
                == "Lightweight tag on 1a2b3c4: a name for the commit, with no message, tagger or "
                + "date.")
        #expect(TagWording.rowAccessibility(Self.lightweight) == "wip, lightweight tag")
        #expect(TagWording.rowIcon(Self.lightweight) == "tag")
    }

    @Test func aSymbolicRowSaysWhatItIsAndWhatGitterLeavesAlone() {
        #expect(
            TagWording.rowHelp(Self.symbolic, date: Self.day)
                == "A symbolic ref under refs/tags, resolving to 1a2b3c4 now. Gitter does not "
                + "delete or push it.")
        #expect(TagWording.rowAccessibility(Self.symbolic) == "alias, symbolic ref")
        #expect(TagWording.rowIcon(Self.symbolic) == "arrow.turn.down.right")
    }

    /// A tagger and a message are somebody else's text.
    @Test func taggerAndSubjectAreMadePlain() {
        let odd = Tag(
            name: "v2", sha: Self.commit, isAnnotated: true, objectID: Self.tagObject,
            tagger: "Eve\u{202E}", date: nil, subject: "Red\u{1B}[31m")
        let help = TagWording.rowHelp(odd, date: Self.day)
        #expect(!help.contains("\u{202E}"))
        #expect(!help.contains("\u{1B}"))
    }

    @Test func theMenuItemsAreNamedForTheirRemote() {
        #expect(TagWording.newTagTitle == "New Tag…")
        #expect(
            TagWording.noSuchTag("v1.0")
                == "There is no tag \"v1.0\" — it may have been deleted since this list was loaded.")
        #expect(TagWording.deleteTagTitle == "Delete Tag…")
        #expect(TagWording.pushTitle(remote: "origin") == "Push Tag to \"origin\"")
        #expect(TagWording.deleteFromRemoteTitle(remote: "origin") == "Delete from \"origin\"…")
        #expect(
            TagWording.symbolicReason("alias")
                == "\"alias\" is a symbolic ref naming another ref, not an ordinary tag: Gitter "
                + "does not delete or push it. Use a terminal for it.")
    }

    // MARK: - Pills

    /// The log's `%D` is changed by `log.decorate=full` and hidden by `log.excludeDecoration`
    /// (B18): its tag entries are dropped, and the pills come from the tag list.
    @Test func tagDecorationsFromTheLogAreDropped() {
        #expect(
            TagWording.branchDecorations(["HEAD -> main", "tag: v1", "origin/main", "tag: refs/tags/v2"])
                == ["HEAD -> main", "origin/main"])
    }

    @Test func pillsComeFromTheTagListByCommit() {
        let elsewhere = Tag(name: "old", sha: Self.other, isAnnotated: false)
        let pills = TagWording.tagsByCommit([Self.annotated, elsewhere, Self.lightweight])
        #expect(pills[Self.commit]?.map(\.name) == ["v1.0", "wip"])
        #expect(pills[Self.other]?.map(\.name) == ["old"])
        #expect(pills["nothing"] == nil)
    }

    // MARK: - New Tag sheet

    @Test func theNewTagSheetSaysWhereAndWhichKind() {
        #expect(TagWording.newTagSheetTitle == "New Tag")
        #expect(TagWording.newTagOn(Self.commit, subject: "Add parser") == "On: 1a2b3c4 Add parser")
        #expect(TagWording.newTagOn(Self.commit, subject: nil) == "On: 1a2b3c4")
        #expect(TagWording.kindTitle(annotated: true) == "Annotated")
        #expect(TagWording.kindTitle(annotated: false) == "Lightweight")
        #expect(
            TagWording.kindExplanation(annotated: true)
                == "Records who tagged it, when, and a message. Never signed.")
        #expect(
            TagWording.kindExplanation(annotated: false)
                == "Only a name for the commit: no message, tagger or date.")
        #expect(TagWording.messageLabel == "Message:")
        #expect(TagWording.messageNeeded == "Enter a message, or make it a lightweight tag.")
        #expect(TagWording.createButton == "Create Tag")
    }

    @Test func theCreateNoticeNamesKindTagAndCommit() {
        #expect(
            TagWording.created("v1.0", at: Self.commit, annotated: true)
                == "Created annotated tag \"v1.0\" on 1a2b3c4.")
        #expect(
            TagWording.created("wip", at: Self.commit, annotated: false)
                == "Created tag \"wip\" on 1a2b3c4.")
    }

    // MARK: - Delete Tag sheet

    @Test func theDeleteSheetNamesTheTagAndItsCommit() {
        #expect(TagWording.deleteTitle("v1.0") == "Delete tag \"v1.0\"?")
        #expect(
            TagWording.deleteTarget(Self.annotated, subject: "Add parser")
                == "\"v1.0\" is an annotated tag on 1a2b3c4 Add parser.")
        #expect(
            TagWording.deleteTarget(Self.lightweight, subject: nil)
                == "\"wip\" is a lightweight tag on 1a2b3c4.")
        #expect(
            TagWording.deleteRestore(Self.annotated)
                == "Restore Tag, in the notice afterwards or on its row under Tags while this "
                + "repository is open, puts the identical tag back: its message, tagger and date too.")
        #expect(
            TagWording.deleteRestore(Self.lightweight)
                == "Restore Tag, in the notice afterwards or on its row under Tags while this "
                + "repository is open, puts it back.")
        #expect(TagWording.deleteButton == "Delete Tag")
    }

    /// Ruling 2: no network on open, so no claim about which remotes have it — unless this
    /// session already saw a remote with it (a push, or the remote delete's read).
    @Test func theDeleteSheetSaysWhatAFetchDoes() {
        #expect(
            TagWording.comesBack(from: [], noTags: [])
                == "If a remote still has this tag, the next fetch brings it back.")
        #expect(
            TagWording.comesBack(from: ["origin"], noTags: ["backup"])
                == "\"origin\" had this tag when Gitter last looked, so the next fetch from it "
                + "brings it back, unless it is deleted there too.")
        #expect(
            TagWording.comesBack(from: ["origin", "backup"], noTags: [])
                == "\"origin\" and \"backup\" had this tag when Gitter last looked, so the next "
                + "fetch from either brings it back, unless it is deleted there too.")
        #expect(
            TagWording.comesBack(from: ["a", "b", "c"], noTags: [])
                == "\"a\", \"b\" and \"c\" had this tag when Gitter last looked, so the next "
                + "fetch from any of them brings it back, unless it is deleted there too.")
    }

    /// Minor 1: `remote.<r>.tagOpt=--no-tags` — a fetch from it never brings the tag back
    /// (measured through Gitter's fetch, `TagFetchOptionTests`), so it is never claimed.
    @Test func aRemoteThatFetchesNoTagsIsNotClaimed() {
        #expect(
            TagWording.comesBack(from: [], noTags: ["backup"])
                == "If a remote still has this tag, the next fetch brings it back, but not from "
                + "\"backup\", which is set to fetch no tags.")
        #expect(
            TagWording.comesBack(from: [], noTags: ["a", "b"])
                == "If a remote still has this tag, the next fetch brings it back, but not from "
                + "\"a\" or \"b\", which are set to fetch no tags.")
    }

    @Test func theDeleteSheetSaysWhenItIsOutOfDate() {
        #expect(
            TagWording.deleteSheetStale("v1.0", isGone: true)
                == "\"v1.0\" is gone since this warning. Close this and look again.")
        #expect(
            TagWording.deleteSheetStale("v1.0", isGone: false)
                == "\"v1.0\" has changed since this warning, so Delete Tag would refuse. Close "
                + "this and look again.")
    }

    static let r1 = TagReceipt(name: "v1.0", objectID: tagObject, target: commit)
    static let r2 = TagReceipt(name: "wip", objectID: commit, target: commit)
    static let r3 = TagReceipt(name: "old", objectID: other, target: other)

    /// Restore Tag is the only way back (tags keep no reflog): the notice holds the button and
    /// the command, with the tag **object** for an annotated tag — and `--no-sign`, without
    /// which `tag.gpgSign=true` refuses it ("fatal: no tag message?", Minor 3).
    @Test func theDeletedNoticeCarriesTheWayBack() {
        #expect(
            TagWording.deleted([Self.r1])
                == "Deleted tag \"v1.0\", which was on 1a2b3c4. Restore Tag puts it back; so does, "
                + "in a terminal: git tag --no-sign v1.0 \(Self.tagObject)")
        #expect(TagWording.restoreButton(count: 1) == "Restore Tag")
        #expect(NoticeWording.title(.restoreTag([Self.r1])) == "Restore Tag")
        #expect(TagWording.restored([Self.r1]) == "Restored tag \"v1.0\" on 1a2b3c4.")
        #expect(
            TagWording.deletedNotice([Self.r1])
                == Notice(text: TagWording.deleted([Self.r1]), actions: [.restoreTag([Self.r1])]))
    }

    /// I1: deleting several tags in a row is ordinary clean-up — the notice names every one
    /// still deleted, with one command line that puts them all back.
    @Test func theDeletedNoticeAccumulates() {
        #expect(
            TagWording.deleted([Self.r1, Self.r2])
                == "Deleted tags \"v1.0\" (was on 1a2b3c4) and \"wip\" (was on 1a2b3c4). Restore "
                + "Tags puts them back; so does, in a terminal: git tag --no-sign v1.0 "
                + "\(Self.tagObject) && git tag --no-sign wip \(Self.commit)")
        #expect(
            TagWording.deleted([Self.r1, Self.r2, Self.r3]).hasPrefix(
                "Deleted tags \"v1.0\" (was on 1a2b3c4), \"wip\" (was on 1a2b3c4) and \"old\" "
                    + "(was on 8e7d6c5). Restore Tags puts them back;"))
        #expect(NoticeWording.title(.restoreTag([Self.r1, Self.r2])) == "Restore Tags")
        #expect(TagWording.restored([Self.r1, Self.r2]) == "Restored tags \"v1.0\" and \"wip\".")
    }

    /// The way back once the notice is gone: a dimmed row under Tags for each deleted tag.
    @Test func aDeletedTagsRowSaysHowToBringItBack() {
        #expect(TagWording.deletedRowIcon == "tag.slash")
        #expect(TagWording.deletedRowAccessibility(Self.r1) == "v1.0, deleted tag")
        #expect(
            TagWording.deletedRowHelp(Self.r1)
                == "Deleted while this repository was open; it was on 1a2b3c4. Restore Tag in its "
                + "menu puts it back; so does, in a terminal: git tag --no-sign v1.0 \(Self.tagObject)")
        #expect(TagWording.restoreMenuTitle == "Restore Tag")
    }

    /// A name the shell would read otherwise is quoted in a command to paste.
    @Test func aCommandQuotesANameTheShellWouldSplit() {
        #expect(TagWording.shellWord("v1.0") == "v1.0")
        #expect(TagWording.shellWord("rel/2026-10") == "rel/2026-10")
        #expect(TagWording.shellWord("a;rm") == "'a;rm'")
        #expect(TagWording.shellWord("it's") == "'it'\\''s'")
        // Final fix wave: zsh expands a word that begins with `=` to a command's path (`=v1` →
        // "zsh: v1 not found", measured); bash leaves it. An `=` further in is plain to both.
        #expect(TagWording.shellWord("=v1") == "'=v1'")
        #expect(TagWording.shellWord("a=b") == "a=b")
        #expect(TagWording.shellWord("x/=y") == "x/=y")
        let receipt = TagReceipt(name: "$x", objectID: Self.commit, target: Self.commit)
        #expect(TagWording.deleted([receipt]).hasSuffix("git tag --no-sign '$x' \(Self.commit)"))
    }

    // MARK: - Push

    @Test func everyPushOutcomeIsWorded() {
        #expect(
            TagWording.pushNotice(.pushed, "v1.0", remote: "origin")
                == "Pushed tag \"v1.0\" to \"origin\".")
        #expect(
            TagWording.pushNotice(.alreadyThere, "v1.0", remote: "origin")
                == "\"origin\" already has this tag \"v1.0\": nothing to push.")
        #expect(TagWording.pushNotice(.rejectedExists, "v1.0", remote: "origin") == nil)
        #expect(TagWording.pushNotice(.failed(gitsWords: "x"), "v1.0", remote: "origin") == nil)

        #expect(TagWording.pushFailure(.pushed, "v1.0", remote: "origin") == nil)
        #expect(TagWording.pushFailure(.alreadyThere, "v1.0", remote: "origin") == nil)
        #expect(
            TagWording.pushFailure(.rejectedExists, "v1.0", remote: "origin")
                == "\"origin\" already has a different tag named \"v1.0\", so nothing was pushed. "
                + "Gitter never replaces a tag on a remote: delete it there first if this one "
                + "should take its place.")
        #expect(
            TagWording.pushFailure(
                .failed(gitsWords: "error: failed to push some refs\nhook says no"), "v1.0",
                remote: "origin")
                == "The push of tag \"v1.0\" to \"origin\" did not go through. git reported: "
                + "error: failed to push some refs hook says no")
    }

    /// git's words come from a server and a hook: made plain like every other server line.
    @Test func gitsWordsInAPushFailureAreMadePlain() {
        let text = TagWording.pushFailure(
            .failed(gitsWords: "\u{1B}[31mno\u{202E}"), "v1.0", remote: "origin")
        #expect(text?.contains("\u{1B}") == false)
        #expect(text?.contains("\u{202E}") == false)
    }

    // MARK: - Delete on a remote

    @Test func theRemoteDeleteSheetNamesTheRemoteAndTheLease() {
        #expect(
            TagWording.deleteRemoteTitle("v1.0", remote: "origin")
                == "Delete tag \"v1.0\" on \"origin\"?")
        #expect(
            TagWording.deleteRemoteBody(remote: "origin")
                == "This deletes the tag on the server itself, for everyone who uses \"origin\". "
                + "Clones that already fetched it keep their copies.")
        #expect(TagWording.deleteRemoteIDLabel == "Its id there, which the deletion is leased on:")
        #expect(
            TagWording.deleteRemoteRecreate
                == "The notice after the deletion shows the command that puts it back.")
        #expect(TagWording.deleteOnRemoteButton("origin") == "Delete on \"origin\"")
    }

    @Test func theRemoteDeleteSheetComparesWithTheTagHere() {
        #expect(
            TagWording.remoteRelation("v1.0", local: Self.annotated, remoteID: Self.tagObject)
                == "It is the same tag as \"v1.0\" here, which is kept.")
        #expect(
            TagWording.remoteRelation("v1.0", local: Self.annotated, remoteID: Self.other)
                == "It is not the same tag as \"v1.0\" here (9f8e7d6), which is kept.")
        #expect(
            TagWording.remoteRelation("v1.0", local: nil, remoteID: Self.other)
                == "There is no tag \"v1.0\" here.")
    }

    /// The remote has no such tag: the sheet says so and offers nothing.
    @Test func aRemoteWithoutTheTagIsSaidSo() {
        #expect(TagWording.noRemoteTagTitle("v1.0", remote: "origin") == "\"origin\" has no tag \"v1.0\"")
        #expect(TagWording.noRemoteTagBody == "There is nothing to delete there.")
        #expect(TagWording.closeButton == "Close")
    }

    @Test func theRemoteDeletedNoticeKeepsTheLocalTagAndTheWayBack() {
        #expect(
            TagWording.deletedOnRemote("v1.0", remote: "origin", id: Self.tagObject, objectIsHere: true)
                == "Deleted tag \"v1.0\" on \"origin\"; the tag here is kept. Put it back there "
                + "with: git push origin \(Self.tagObject):refs/tags/v1.0")
    }

    /// Minor 4: the push hint needs the object here; for a tag that was not the one here, and
    /// whose object no tag here holds, there is no such command.
    @Test func theRemoteDeletedNoticeOffersNoCommandForAnObjectNotHere() {
        #expect(
            TagWording.deletedOnRemote("v1.0", remote: "origin", id: Self.other, objectIsHere: false)
                == "Deleted tag \"v1.0\" on \"origin\"; the tag here is kept. It held \(Self.other), "
                + "which no tag here holds, so there is no command here that puts it back.")
    }

    // MARK: - Refusals and failures

    @Test func aNameRefusedAtTheConfirmSaysWhy() {
        #expect(
            TagWording.failure(TagOperationError.nameProblem(.exists), .create("v1.0"))
                == "Can't create tag \"v1.0\". " + TagWording.problem(.exists))
        #expect(
            TagWording.failure(TagOperationError.nameProblem(.isBranchName), .create("main"))
                == "Can't create tag \"main\". " + TagWording.problem(.isBranchName))
    }

    @Test func aRestoreOverATagMadeSinceSaysSo() {
        #expect(
            TagWording.failure(TagOperationError.nameProblem(.exists), .restore("v1.0"))
                == "A tag named \"v1.0\" exists again, so nothing was restored. Delete that one "
                + "first to bring this one back.")
    }

    @Test func aTagThatMovedUnderTheSheetIsLeftAlone() {
        #expect(
            TagWording.failure(TagOperationError.tagMoved(name: "v1.0"), .delete("v1.0"))
                == "\"v1.0\" changed since this warning, or is gone, so nothing was deleted. "
                + "Ask again to see what it holds now.")
        #expect(
            TagWording.failure(
                TagOperationError.remoteTagMoved(name: "v1.0", remote: "origin"),
                .deleteRemote("v1.0", remote: "origin"))
                == "Tag \"v1.0\" on \"origin\" changed since this warning, or is already gone; "
                + "nothing was deleted. Delete from \"origin\"… again to see what is there now.")
    }

    @Test func aSymbolicTagIsRefusedInItsOwnWords() {
        #expect(
            TagWording.failure(TagOperationError.symbolicTag(name: "alias"), .delete("alias"))
                == TagWording.symbolicReason("alias"))
    }

    @Test func aBadObjectIDIsRefusedBeforeGitRuns() {
        #expect(
            TagWording.failure(TagOperationError.invalidObjectID("0000"), .delete("v1.0"))
                == "Can't delete tag \"v1.0\": \"0000\" is not a full object id, so nothing was "
                + "changed.")
    }

    /// git's own refusal — `dang/x` under a dangling symbolic ref passes the live check, and git
    /// refuses the create — keeps git's words.
    @Test func gitsOwnRefusalKeepsGitsWords() {
        let error = GitError.commandFailed(
            exitCode: 128,
            stderr: "fatal: cannot lock ref 'refs/tags/dang/x': 'refs/tags/dang' exists")
        #expect(
            TagWording.failure(error, .create("dang/x"))
                == "Couldn't create tag \"dang/x\": fatal: cannot lock ref 'refs/tags/dang/x': "
                + "'refs/tags/dang' exists")
    }

    /// A network failure is the remote lane's sentence; a git failure during a remote write says
    /// the remote may have changed.
    @Test func remoteFailuresAreTheLanesSentences() {
        #expect(
            TagWording.failure(
                RemoteOperationError.unreachable("example.invalid"), .push("v1.0", remote: "origin"))
                == "Couldn't push tag \"v1.0\" to \"origin\": example.invalid could not be "
                + "reached. Check the network connection and try again.")
        #expect(
            TagWording.failure(
                GitError.commandFailed(exitCode: 1, stderr: "boom"), .deleteRemote("v1.0", remote: "origin"))
                == "Couldn't delete tag \"v1.0\" on \"origin\": boom The remote may or may not have "
                + "been updated.")
        #expect(
            TagWording.failure(
                GitError.commandFailed(exitCode: 1, stderr: "boom"), .readRemote("v1.0", remote: "origin"))
                == "Couldn't read tag \"v1.0\" on \"origin\": boom")
    }

    @Test func aStoppedRemoteWriteSaysNobodyKnowsYet() {
        #expect(
            TagWording.stopped(.push("v1.0", remote: "origin"))
                == "Stopped pushing tag \"v1.0\" to \"origin\". It may or may not be there now; "
                + "Push Tag again finds out, and never replaces a tag, so it changes nothing if it "
                + "arrived.")
        #expect(
            TagWording.stopped(.deleteRemote("v1.0", remote: "origin"))
                == "Stopped deleting tag \"v1.0\" on \"origin\". It may or may not have been "
                + "deleted there; Delete from \"origin\"… again shows what is there now.")
        #expect(
            TagWording.stopped(.readRemote("v1.0", remote: "origin"))
                == "Stopped before the delete warning was ready. Nothing was deleted.")
    }

    // MARK: - What this session saw on remotes

    /// Ruling 2's memory, by id (I2): a push or the remote delete's read says which object a
    /// remote's tag holds; only a remote holding **this** tag's object is named — not one with a
    /// different tag of that name, nor one seen before the tag here was made again elsewhere.
    @Test func theRemotesSeenWithATagAreRememberedByID() {
        var seen = RemoteTagsSeen()
        #expect(seen.remotes(having: "v1", objectID: Self.tagObject) == [])
        seen.note("v1", on: "origin", id: Self.tagObject)
        seen.note("v1", on: "backup", id: Self.tagObject)
        seen.note("v1", on: "mirror", id: Self.other)
        #expect(seen.remotes(having: "v1", objectID: Self.tagObject) == ["backup", "origin"])
        #expect(seen.remotes(having: "v1", objectID: Self.other) == ["mirror"])
        seen.note("v1", on: "origin", id: nil)
        #expect(seen.remotes(having: "v1", objectID: Self.tagObject) == ["backup"])
        #expect(seen.remotes(having: "v2", objectID: Self.tagObject) == [])
    }

    // MARK: - Deleted tags

    @Test func deletedTagsAccumulateAndGoOneByOne() {
        var deleted = DeletedTags()
        deleted.add(Self.r1)
        deleted.add(Self.r2)
        deleted.add(Self.r1)
        #expect(deleted.receipts == [Self.r1, Self.r2])
        deleted.remove([Self.r1])
        #expect(deleted.receipts == [Self.r2])
    }

    /// A tag back exactly as it was — fetched, or made in a terminal — needs no restore; one of
    /// that name holding another object leaves the receipt.
    @Test func aTagBackAsItWasEndsItsReceipt() {
        var deleted = DeletedTags()
        deleted.add(Self.r1)
        deleted.add(Self.r2)
        let same = Tag(name: "v1.0", sha: Self.commit, isAnnotated: true, objectID: Self.tagObject)
        let different = Tag(name: "wip", sha: Self.other, isAnnotated: false)
        let pruned = deleted.pruningTagsBack([same, different])
        #expect(pruned)
        #expect(deleted.receipts == [Self.r2])
        let prunedAgain = deleted.pruningTagsBack([different])
        #expect(!prunedAgain)
    }

    // MARK: - The lane

    @Test func theTagLaneKindsAreWritesAndSaySo() {
        let push = RemoteActivity(kind: .pushTag, remote: "origin", progress: nil)
        let delete = RemoteActivity(kind: .deleteRemoteTag, remote: "origin", progress: nil)
        #expect(push.isWrite)
        #expect(delete.isWrite)
        #expect(RemoteWording.inProgressTitle(push) == "Pushing a tag to \"origin\"…")
        #expect(RemoteWording.inProgressTitle(delete) == "Deleting a tag on \"origin\"…")
        #expect(RemoteWording.laneBusy(push) == "Wait for the tag push to \"origin\" to finish, or stop it first.")
        #expect(
            RemoteWording.laneBusy(delete)
                == "Wait for the tag deletion on \"origin\" to finish, or stop it first.")
    }

    @Test func aRemoteTagQuestionNotShownSaysSo() {
        #expect(
            RemoteWording.sheetNotShown(.deleteRemoteTag(name: "v1.0", remote: "origin", id: Self.tagObject))
                == "The warning for deleting tag \"v1.0\" on \"origin\" wasn't shown because "
                + "another sheet was open. Nothing was deleted.")
        let a = BranchSheet.deleteRemoteTag(name: "v1.0", remote: "origin", id: Self.tagObject)
        #expect(a.asksTheSameQuestion(as: .deleteRemoteTag(name: "v1.0", remote: "origin", id: nil)))
        #expect(!a.asksTheSameQuestion(as: .deleteRemoteTag(name: "v1.0", remote: "backup", id: nil)))
    }
}
