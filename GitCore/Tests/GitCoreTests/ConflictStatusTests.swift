import Foundation
import Testing

@testable import GitCore

/// `StatusParser` keeps the `u` record's kind, modes and ids (M 1), for every kind and every
/// operation that can stop with one. Ground truth is `ls-files -u -s`, read separately.
@Suite struct ConflictStatusTests {
    /// M 1's table, per fixture kind: path → (kind, stages present).
    static func expected(_ kind: ConflictFixtureKind) -> [String: (ConflictKind, Set<Int>)] {
        switch kind {
        case .bothModified: return ["f.txt": (.bothModified, [1, 2, 3])]
        case .bothAdded: return ["aa.txt": (.bothAdded, [2, 3])]
        case .modeOnly: return ["mode.sh": (.bothAdded, [2, 3])]
        case .deletedByUs: return ["du.txt": (.deletedByUs, [1, 3])]
        case .deletedByThem: return ["ud.txt": (.deletedByThem, [1, 2])]
        case .renameRename:
            return [
                "rr.txt": (.bothDeleted, [1]), "rr-ours.txt": (.addedByUs, [2]),
                "rr-theirs.txt": (.addedByThem, [3]),
            ]
        case .renameDelete: return ["rd-ours.txt": (.deletedByThem, [1, 2])]
        case .binary: return ["bin.dat": (.bothModified, [1, 2, 3])]
        case .symlink: return ["link": (.bothModified, [1, 2, 3])]
        case .submodule: return ["sub": (.bothModified, [1, 2, 3])]
        case .mergeBinary: return ["mb.txt": (.bothModified, [1, 2, 3])]
        }
    }

    static let cases: [(ConflictOperation, ConflictFixtureKind)] =
        ConflictOperation.allCases.flatMap { op in ConflictFixtureKind.allCases.map { (op, $0) } }

    @Test(arguments: cases)
    func everyKindReadsAsItsStages(operation: ConflictOperation, kind: ConflictFixtureKind) async throws {
        let repo = try await ConflictFixtures.stopped(operation, kind: kind)
        defer { repo.cleanUp() }
        let truth = try await ConflictFixtures.stages(repo)
        let expected = Self.expected(kind)
        #expect(Set(truth.keys) == Set(expected.keys), "ls-files -u: \(truth.keys.sorted())")

        let status = try await CLIGitBackend().snapshot(at: repo.root).status
        let conflicted = status.files.filter { $0.conflict != nil }
        #expect(conflicted.map(\.path).sorted() == expected.keys.sorted())

        for file in status.files where expected[file.path] != nil {
            let (kind, stages) = expected[file.path]!
            #expect(file.staged == .unmerged && file.unstaged == .unmerged, "\(file.path)")
            let conflict = try #require(file.conflict, "\(file.path) has no conflict")
            #expect(conflict.path == file.path)
            #expect(conflict.kind == kind, "\(file.path)")
            #expect(conflict.base == truth[file.path]?[1], "\(file.path) base")
            #expect(conflict.ours == truth[file.path]?[2], "\(file.path) ours")
            #expect(conflict.theirs == truth[file.path]?[3], "\(file.path) theirs")
            let present = Set([(1, conflict.base), (2, conflict.ours), (3, conflict.theirs)]
                .compactMap { $0.1 == nil ? nil : $0.0 })
            #expect(present == stages, "\(file.path) stages")
        }
        // Every other path is an ordinary record.
        #expect(status.files.filter { $0.conflict == nil }.allSatisfy { $0.staged != .unmerged })
    }

    @Test(arguments: ConflictFixtureKind.allCases)
    func flagsFollowTheModes(kind: ConflictFixtureKind) async throws {
        let repo = try await ConflictFixtures.merge(kind: kind)
        defer { repo.cleanUp() }

        let files = try await CLIGitBackend().snapshot(at: repo.root).status.files.compactMap(\.conflict)

        #expect(!files.isEmpty)
        for file in files {
            #expect(file.isSymlink == (kind == .symlink), "\(file.path)")
            #expect(file.isSubmodule == (kind == .submodule), "\(file.path)")
            #expect(file.isModeOnly == (kind == .modeOnly), "\(file.path)")
        }
    }

    /// The details M 1 names: a mode-only add/add has equal ids and ours' 100755; a
    /// rename/delete keeps the base id at the new name; a rename/rename's three records carry
    /// one blob.
    @Test func theDetailsOfM1() async throws {
        let mode = try await ConflictFixtures.merge(kind: .modeOnly)
        defer { mode.cleanUp() }
        let modeFile = try #require(try await CLIGitBackend().snapshot(at: mode.root).status.files
            .first { $0.path == "mode.sh" }?.conflict)
        #expect(modeFile.ours?.mode == "100755")
        #expect(modeFile.theirs?.mode == "100644")
        #expect(modeFile.ours?.blob == modeFile.theirs?.blob)

        let renameDelete = try await ConflictFixtures.merge(kind: .renameDelete)
        defer { renameDelete.cleanUp() }
        let rd = try #require(try await CLIGitBackend().snapshot(at: renameDelete.root).status.files
            .first { $0.path == "rd-ours.txt" }?.conflict)
        #expect(rd.base?.blob == rd.ours?.blob)

        let renameRename = try await ConflictFixtures.merge(kind: .renameRename)
        defer { renameRename.cleanUp() }
        let rr = try await CLIGitBackend().snapshot(at: renameRename.root).status.files.compactMap(\.conflict)
        #expect(rr.count == 3)
        #expect(Set(rr.compactMap { $0.base?.blob ?? $0.ours?.blob ?? $0.theirs?.blob }).count == 1)
    }

    @Test func aStashApplyConflictIsReadWithNoOperation() async throws {
        let repo = try await ConflictFixtures.stashApplyConflict()
        defer { repo.cleanUp() }

        let status = try await CLIGitBackend().snapshot(at: repo.root).status

        #expect(status.operationInProgress == nil)
        #expect(status.files.first { $0.path == "f.txt" }?.conflict?.kind == .bothModified)
    }

    @Test(arguments: [1, 2, 3])
    func aRangePickStopsWithTheConflictItMeets(stopAt: Int) async throws {
        let repo = try await ConflictFixtures.cherryPickRange(stopAt: stopAt)
        defer { repo.cleanUp() }

        let status = try await CLIGitBackend().snapshot(at: repo.root).status

        #expect(status.operationInProgress == .cherryPick)
        #expect(status.files.compactMap(\.conflict).map(\.path) == ["f.txt"])
    }

    /// The parser alone, on the record M 1 printed for the submodule.
    @Test func parsesTheSubmoduleRecordOfM1() {
        let record = "u UU S... 160000 160000 160000 160000 "
            + String(repeating: "1", count: 40) + " " + String(repeating: "2", count: 40) + " "
            + String(repeating: "3", count: 40) + " sub\u{0}"
        let file = StatusParser.parse(Data(record.utf8)).files.first

        #expect(file?.conflict == ConflictedFile(
            path: "sub", kind: .bothModified,
            base: ConflictStage(mode: "160000", blob: String(repeating: "1", count: 40)),
            ours: ConflictStage(mode: "160000", blob: String(repeating: "2", count: 40)),
            theirs: ConflictStage(mode: "160000", blob: String(repeating: "3", count: 40))))
        #expect(file?.staged == .unmerged)
        #expect(file?.conflict?.isSubmodule == true)
    }

    /// A path with spaces keeps them: the path is the rest of the record after ten fields.
    @Test func keepsSpacesInAConflictedPath() {
        let zero = String(repeating: "0", count: 40)
        let record = "u AU N... 000000 100644 000000 100644 \(zero) " + String(repeating: "a", count: 40)
            + " \(zero) a b  c.txt\u{0}"
        let file = StatusParser.parse(Data(record.utf8)).files.first

        #expect(file?.path == "a b  c.txt")
        #expect(file?.conflict?.kind == .addedByUs)
        #expect(file?.conflict?.base == nil)
        #expect(file?.conflict?.theirs == nil)
        #expect(file?.conflict?.ours?.mode == "100644")
    }
}
