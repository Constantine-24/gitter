import Foundation
import GitCore
import Testing

@testable import Gitter

/// Every sentence the stash puts on screen, pinned: outcome notices, refusals, the drop notice
/// and the blocked reasons. Pure — no store, no repository, no `UserDefaults`.
@Suite struct StashWordingTests {

    static let sha = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"

    static func stash(
        _ subject: String = "On main: half-done login", index: Int = 0, untracked: Bool = false
    ) -> Stash {
        Stash(
            sha: sha, index: index, reflogSubject: subject,
            parents: untracked ? ["p1", "p2", "p3"] : ["p1", "p2"],
            date: Date(timeIntervalSince1970: 1_800_000_000))
    }

    // MARK: - Names

    @Test func namesAreQuotedAndCappedAtThreeWithACount() {
        #expect(StashWording.names(["a"]) == "\"a\"")
        #expect(StashWording.names(["a", "b"]) == "\"a\" and \"b\"")
        #expect(StashWording.names(["a", "b", "c"]) == "\"a\", \"b\" and \"c\"")
        #expect(StashWording.names(["a", "b", "c", "d"]) == "\"a\", \"b\", \"c\" and 1 more")
        #expect(
            StashWording.names(["a", "b", "c", "d", "e", "f"]) == "\"a\", \"b\", \"c\" and 3 more")
    }

    @Test func aStashIsNamedByItsMessageOrItsPositionWhenItHasNone() {
        #expect(StashWording.name(Self.stash()) == "\"half-done login\"")
        #expect(StashWording.name(Self.stash("On main: ", index: 2)) == "stash@{2}")
    }

    // MARK: - Push outcomes

    @Test func savedSaysWhereTheChangesAre() {
        #expect(
            StashWording.pushOutcome(.saved(Self.stash()), includeUntracked: false, onlySelected: false)
                == "Your changes are in stash \"half-done login\".")
    }

    @Test func nothingToSaveSaysWhyForEachKindOfStash() {
        #expect(
            StashWording.pushOutcome(.nothingToSave, includeUntracked: false, onlySelected: false)
                == "Nothing was stashed: there are no changes to tracked files. Untracked files "
                + "are stashed only with \"Include untracked files\".")
        #expect(
            StashWording.pushOutcome(.nothingToSave, includeUntracked: true, onlySelected: false)
                == "Nothing was stashed: there are no changes a stash can hold.")
        #expect(
            StashWording.pushOutcome(.nothingToSave, includeUntracked: false, onlySelected: true)
                == "Nothing was stashed: the selected files have no changes.")
    }

    @Test func savedWithErrorSaysTheChangesAreInTheStashAndMayStillBeInTheFiles() {
        let outcome = StashPushOutcome.savedWithError(
            Self.stash(), gitsWords: "error: unable to unlink old 'f'\nfatal: could not reset",
            trashed: [:])
        #expect(
            StashWording.pushOutcome(outcome, includeUntracked: false, onlySelected: true)
                == "Your changes are in stash \"half-done login\"; git also said: error: unable "
                + "to unlink old 'f' fatal: could not reset; some may still be in your files.")
    }

    @Test func savedWithErrorNamesWhatWentToTheTrash() {
        let trash = URL(fileURLWithPath: "/Users/x/.Trash")
        let outcome = StashPushOutcome.savedWithError(
            Self.stash(), gitsWords: "Operation not permitted",
            trashed: [
                "u2.txt": trash.appending(path: "u2.txt"),
                "dir/u1.txt": trash.appending(path: "u1.txt"),
            ])
        #expect(
            StashWording.pushOutcome(outcome, includeUntracked: false, onlySelected: true)
                == "Your changes are in stash \"half-done login\"; git also said: Operation not "
                + "permitted; some may still be in your files. Already moved to the Trash: "
                + "\"dir/u1.txt\" and \"u2.txt\".")
    }

    // MARK: - Apply and pop outcomes

    struct ApplyCase: Sendable, CustomTestStringConvertible {
        let outcome: StashApplyOutcome
        let popping: Bool
        let sentence: String
        var testDescription: String { "\(outcome) popping: \(popping)" }
    }

    static let applyCases: [ApplyCase] = [
        ApplyCase(
            outcome: .applied, popping: false,
            sentence: "Applied stash \"half-done login\". It stays in the list."),
        ApplyCase(
            outcome: .applied, popping: true,
            sentence: "Popped stash \"half-done login\": applied and dropped."),
        ApplyCase(
            outcome: .appliedButKept(
                reason: "The stash list changed before the entry could be dropped."),
            popping: true,
            sentence: "Applied stash \"half-done login\", but it was not dropped: The stash list "
                + "changed before the entry could be dropped. It is still in the list."),
        ApplyCase(
            outcome: .appliedButKept(reason: "error: cannot lock ref 'refs/stash'"),
            popping: true,
            sentence: "Applied stash \"half-done login\", but it was not dropped: error: cannot "
                + "lock ref 'refs/stash'. It is still in the list."),
        ApplyCase(
            outcome: .conflicts(["a.swift", "b.swift"]), popping: false,
            sentence: "Stash \"half-done login\" applied with conflicts in \"a.swift\" and "
                + "\"b.swift\". Resolve them, then stage the files. The stash is kept."),
        ApplyCase(
            outcome: .conflicts(["a", "b", "c", "d", "e"]), popping: true,
            sentence: "Stash \"half-done login\" applied with conflicts in \"a\", \"b\", \"c\" "
                + "and 2 more. Resolve them, then stage the files. The stash is kept, not "
                + "dropped."),
        ApplyCase(
            outcome: .partiallyApplied(untrackedNotRestored: ["u.txt"]), popping: false,
            sentence: "Stash \"half-done login\" applied, except its untracked \"u.txt\": a file "
                + "of that name already exists and was left as it is. The stash is kept."),
        ApplyCase(
            outcome: .partiallyApplied(untrackedNotRestored: ["u.txt", "v.txt"]), popping: true,
            sentence: "Stash \"half-done login\" applied, except its untracked \"u.txt\" and "
                + "\"v.txt\": files of those names already exist and were left as they are. The "
                + "stash is kept, not dropped."),
        ApplyCase(
            outcome: .refused(wouldOverwrite: ["f"]), popping: false,
            sentence: "Can't apply stash \"half-done login\": it would overwrite \"f\". Commit, "
                + "stash or move it first. Nothing changed."),
        ApplyCase(
            outcome: .refused(wouldOverwrite: ["f", "g"]), popping: true,
            sentence: "Can't pop stash \"half-done login\": it would overwrite \"f\" and \"g\". "
                + "Commit, stash or move them first. Nothing changed."),
        ApplyCase(
            outcome: .failed(gitsWords: "fatal: Unable to create '.git/index.lock': File exists."),
            popping: false,
            sentence: "Couldn't apply stash \"half-done login\": fatal: Unable to create "
                + "'.git/index.lock': File exists. The stash is kept."),
        ApplyCase(
            outcome: .failed(gitsWords: "error: something"), popping: true,
            sentence: "Couldn't pop stash \"half-done login\": error: something. The stash is "
                + "kept, not dropped."),
    ]

    @Test(arguments: applyCases)
    func everyApplyOutcomeHasItsSentence(_ c: ApplyCase) {
        #expect(StashWording.applyOutcome(c.outcome, of: Self.stash(), popping: c.popping) == c.sentence)
    }

    /// Final review M2: a line discard's record holds the whole file, and git refuses to apply
    /// it while the file's other changes are unstaged — committing or stashing is not what it
    /// takes; staging (or committing) the rest is. Only such a record gets that advice.
    @Test func aLineDiscardsRecordIsAppliedOnceTheFilesOtherChangesAreStaged() {
        let lines = Self.stash("Discarded by Gitter: 3 lines in a.txt")
        let one = Self.stash("Discarded by Gitter: 1 line in a.txt")
        let files = Self.stash("Discarded by Gitter: a.txt")

        #expect(StashWording.isLinesRecord(lines))
        #expect(StashWording.isLinesRecord(one))
        #expect(!StashWording.isLinesRecord(files))
        #expect(!StashWording.isLinesRecord(Self.stash("On main: 3 lines in a.txt")))
        #expect(
            StashWording.applyOutcome(.refused(wouldOverwrite: ["a.txt"]), of: lines, popping: false)
                == "Can't apply stash \"Discarded by Gitter: 3 lines in a.txt\": it would overwrite "
                + "\"a.txt\". Stage or commit its other changes first. Nothing changed.")
        #expect(
            StashWording.applyOutcome(.refused(wouldOverwrite: ["a.txt"]), of: one, popping: true)
                == "Can't pop stash \"Discarded by Gitter: 1 line in a.txt\": it would overwrite "
                + "\"a.txt\". Stage or commit its other changes first. Nothing changed.")
        // Any other entry keeps the general advice.
        #expect(
            StashWording.applyOutcome(.refused(wouldOverwrite: ["a.txt"]), of: files, popping: false)
                == "Can't apply stash \"Discarded by Gitter: a.txt\": it would overwrite \"a.txt\". "
                + "Commit, stash or move it first. Nothing changed.")
    }

    /// Only `.applied` is a notice; everything else stays up until it is read.
    @Test func onlyACleanApplyIsANotice() {
        for c in Self.applyCases {
            #expect(StashWording.isNotice(c.outcome) == (c.outcome == .applied), "\(c.outcome)")
        }
    }

    // MARK: - Refusals

    struct RefusalCase: Sendable, CustomTestStringConvertible {
        let refusal: StashRefusal
        let verb: StashVerb
        let sentence: String
        var testDescription: String { "\(refusal) \(verb)" }
    }

    static let refusalCases: [RefusalCase] = [
        RefusalCase(
            refusal: .operationInProgress(.merge), verb: .stash,
            sentence: "Can't stash while a merge is in progress. Commit or abort it first."),
        RefusalCase(
            refusal: .operationInProgress(.rebase), verb: .apply,
            sentence: "Can't apply stash \"half-done login\" while a rebase is in progress. "
                + "Commit or abort it first."),
        RefusalCase(
            refusal: .operationInProgress(.applyingPatches), verb: .pop,
            sentence: "Can't pop stash \"half-done login\" while git am is applying patches. "
                + "Commit or abort it first."),
        RefusalCase(
            refusal: .operationInProgress(.squash), verb: .stash,
            sentence: "Can't stash while a squash is pending. Commit or abort it first."),
        RefusalCase(
            refusal: .operationInProgress(.cherryPick), verb: .stash,
            sentence: "Can't stash while a cherry-pick is in progress. Commit or abort it first."),
        RefusalCase(
            refusal: .operationInProgress(.revert), verb: .stash,
            sentence: "Can't stash while a revert is in progress. Commit or abort it first."),
        RefusalCase(
            refusal: .unmergedPaths(["c.txt"]), verb: .stash,
            sentence: "Can't stash: \"c.txt\" has unresolved conflicts. Resolve them and stage "
                + "the files first."),
        RefusalCase(
            refusal: .unmergedPaths(["c.txt", "d.txt"]), verb: .apply,
            sentence: "Can't apply stash \"half-done login\": \"c.txt\" and \"d.txt\" have "
                + "unresolved conflicts. Resolve them and stage the files first."),
        RefusalCase(
            refusal: .intentToAdd(["n.txt"]), verb: .stash,
            sentence: "Can't stash: \"n.txt\" is only marked to be added (git add -N). Stage it "
                + "fully or unstage it first."),
        RefusalCase(
            refusal: .intentToAdd(["n.txt", "m.txt"]), verb: .stash,
            sentence: "Can't stash: \"n.txt\" and \"m.txt\" are only marked to be added (git add "
                + "-N). Stage them fully or unstage them first."),
        RefusalCase(
            refusal: .submodules(["lib"]), verb: .stash,
            sentence: "Can't stash: \"lib\" is a submodule, and a stash can't hold the work "
                + "inside one."),
        RefusalCase(
            refusal: .submodules(["lib", "vendor"]), verb: .stash,
            sentence: "Can't stash: \"lib\" and \"vendor\" are submodules, and a stash can't hold "
                + "the work inside one."),
        RefusalCase(
            refusal: .nestedRepositories(["inner/f"]), verb: .stash,
            sentence: "Can't stash: \"inner/f\" belongs to another repository (a submodule, or a "
                + "repository inside this one), and a stash can't hold its files."),
        RefusalCase(
            refusal: .nestedRepositories(["inner", "sub/x"]), verb: .stash,
            sentence: "Can't stash: \"inner\" and \"sub/x\" belong to another repository (a "
                + "submodule, or a repository inside this one), and a stash can't hold their "
                + "files."),
        RefusalCase(
            refusal: .stashListChanged, verb: .drop,
            sentence: "The stash list changed since it was read: \"half-done login\" is no longer "
                + "stash@{0}. Nothing was dropped."),
        RefusalCase(
            refusal: .stashListChanged, verb: .pop,
            sentence: "The stash list changed since it was read: \"half-done login\" is no longer "
                + "stash@{0}. Nothing was applied or dropped."),
        RefusalCase(
            refusal: .stashListChanged, verb: .apply,
            sentence: "The stash list changed since it was read: \"half-done login\" is no longer "
                + "stash@{0}. Nothing was applied."),
        RefusalCase(
            refusal: .nothingSelected, verb: .stash,
            sentence: "Select the files to stash first."),
    ]

    @Test(arguments: refusalCases)
    func everyRefusalHasItsSentence(_ c: RefusalCase) {
        #expect(StashWording.refusal(c.refusal, verb: c.verb, stash: Self.stash()) == c.sentence)
    }

    /// Both shapes of a file/folder swap, named for what each is on disk now.
    @Test func aTypeChangeNamesEachShape() {
        #expect(
            StashWording.typeChanged([.fileBecameFolder("p")], verb: .stash)
                == "Can't stash: \"p\" was a file and is now a folder. A stash would lose what is "
                + "there now. Put it back, or commit the change first.")
        #expect(
            StashWording.typeChanged([.folderBecameFile(path: "d/a", file: "d")], verb: .stash)
                == "Can't stash: \"d\" was a folder (holding \"d/a\") and is now a file. A stash "
                + "would lose what is there now. Put it back, or commit the change first.")
        #expect(
            StashWording.typeChanged(
                [
                    .fileBecameFolder("p"), .folderBecameFile(path: "d/a", file: "d"),
                    .changed("q"), .changed("r"), .changed("s"),
                ], verb: .stash)
                == "Can't stash: \"p\" was a file and is now a folder; \"d\" was a folder "
                + "(holding \"d/a\") and is now a file; \"q\" changed between a file and a "
                + "folder; and 2 more. A stash would lose what is there now. Put it back, or "
                + "commit the change first.")
    }

    /// The refusal without a disk reading falls back to the neutral phrase for every path.
    @Test func aTypeChangeRefusalWithoutShapesIsNeutral() {
        #expect(
            StashWording.refusal(.pathTypeChanged(["p"]), verb: .stash, stash: nil)
                == "Can't stash: \"p\" changed between a file and a folder. A stash would lose "
                + "what is there now. Put it back, or commit the change first.")
    }

    // MARK: - Drop

    @Test func theDropNoticeGivesTheShortShaAndTheWayBack() {
        #expect(
            StashWording.dropped(Self.stash())
                == "Dropped \"half-done login\" (a1b2c3d). \"git stash apply a1b2c3d\" brings it "
                + "back until git's cleanup removes it.")
        // An entry with an empty message is named by its position, never by `""`.
        #expect(
            StashWording.dropped(Self.stash("On main: ", index: 3))
                == "Dropped stash@{3} (a1b2c3d). \"git stash apply a1b2c3d\" brings it back until "
                + "git's cleanup removes it.")
    }

    @Test func theDropSheetSaysWhatItDropsAndWhenItIsStale() {
        #expect(StashWording.dropTitle(Self.stash()) == "Drop stash \"half-done login\"?")
        #expect(
            StashWording.dropFiles(tracked: ["a", "b", "c", "d"], untracked: ["u"])
                == "\"a\", \"b\", \"c\" and 1 more + untracked \"u\"")
        #expect(StashWording.dropFiles(tracked: ["a"], untracked: []) == "\"a\"")
        #expect(StashWording.dropFiles(tracked: [], untracked: ["u", "v"]) == "untracked \"u\" and \"v\"")
        #expect(StashWording.dropFiles(tracked: [], untracked: []) == "No files.")
        #expect(
            StashWording.dropSheetStale(movedTo: nil)
                == "This stash is no longer in the list. Drop Stash will be refused.")
        #expect(
            StashWording.dropSheetStale(movedTo: 1)
                == "The stash list changed: this stash is now stash@{1}. Drop Stash will be "
                + "refused; close this and ask again.")
    }

    // MARK: - Blocked reasons

    @Test func blockedReasonsSayWhy() {
        #expect(StashWording.blockedBySheet == "Answer the open sheet first.")
        #expect(StashWording.nothingToStash == "There are no changes to stash.")
        #expect(StashWording.busy == "Wait for the current change to finish.")
        #expect(
            StashWording.actionsBlocked(by: .merge)
                == "Stashes can't be applied, popped or dropped while a merge is in progress. "
                + "Commit or abort it first.")
        #expect(
            StashWording.refusal(.intentToAdd(["n"]), verb: .stash, stash: nil)
                == "Can't stash: \"n\" is only marked to be added (git add -N). Stage it fully or "
                + "unstage it first.")
    }

    @Test func aPathStashWithoutAMessageIsNamedByItsFiles() {
        #expect(StashWording.defaultMessage(forPaths: ["a.txt"]) == "a.txt")
        #expect(StashWording.defaultMessage(forPaths: ["a", "b"]) == "a and b")
        #expect(StashWording.defaultMessage(forPaths: ["a", "b", "c", "d"]) == "a, b, c and 1 more")
    }

    @Test func thePopButtonOnANoticeIsNamed() {
        #expect(NoticeWording.title(.popStash(Self.stash())) == "Pop Stash")
    }
}

/// Which shape a file/folder swap is on disk — read in a scratch folder under the temporary
/// directory, never a repository.
@MainActor @Suite struct StashTypeChangeTests {

    @Test func eachShapeIsReadFromTheDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "gitter-typechange-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "p"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appending(path: "p/x"))
        try Data("file".utf8).write(to: root.appending(path: "d"))
        try fm.createDirectory(at: root.appending(path: "e/f"), withIntermediateDirectories: true)
        try Data("file".utf8).write(to: root.appending(path: "e/f/g"))
        defer { try? fm.removeItem(at: root) }

        #expect(RepositoryStore.typeChange(of: "p", under: root) == .fileBecameFolder("p"))
        #expect(
            RepositoryStore.typeChange(of: "d/a", under: root)
                == .folderBecameFile(path: "d/a", file: "d"))
        #expect(
            RepositoryStore.typeChange(of: "e/f/g/h", under: root)
                == .folderBecameFile(path: "e/f/g/h", file: "e/f/g"))
        #expect(RepositoryStore.typeChange(of: "gone/a", under: root) == .changed("gone/a"))
        #expect(RepositoryStore.typeChange(of: "d", under: root) == .changed("d"))
    }
}
