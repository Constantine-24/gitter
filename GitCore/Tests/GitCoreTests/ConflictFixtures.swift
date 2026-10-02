import Foundation
import Testing

@testable import GitCore

/// The conflict kinds a fixture can stop in, one path set each, named as in M 1.
enum ConflictFixtureKind: String, CaseIterable, Sendable {
    /// `f.txt`, two blocks six common lines apart (UU).
    case bothModified
    /// `aa.txt` (AA).
    case bothAdded
    /// `mode.sh`: the same bytes added 100755 on ours, 100644 on theirs (AA).
    case modeOnly
    /// `du.txt`: deleted on ours, modified on theirs (DU).
    case deletedByUs
    /// `ud.txt`: modified on ours, deleted on theirs (UD).
    case deletedByThem
    /// `rr.txt` renamed to `rr-ours.txt` and to `rr-theirs.txt` (DD + AU + UA).
    case renameRename
    /// `rd.txt` renamed to `rd-ours.txt` on ours, deleted on theirs (UD at the new name).
    case renameDelete
    /// `bin.dat`, a NUL in every version (UU, no markers).
    case binary
    /// `link`, a symlink retargeted on both sides (UU, 120000).
    case symlink
    /// `sub`, an unpopulated gitlink moved on both sides (UU, 160000).
    case submodule
    /// `mb.txt`, text under `merge=binary` (UU, no markers).
    case mergeBinary

    /// The paths `ls-files -u` lists for this kind.
    var unmergedPaths: [String] {
        switch self {
        case .bothModified: return ["f.txt"]
        case .bothAdded: return ["aa.txt"]
        case .modeOnly: return ["mode.sh"]
        case .deletedByUs: return ["du.txt"]
        case .deletedByThem: return ["ud.txt"]
        case .renameRename: return ["rr-ours.txt", "rr-theirs.txt", "rr.txt"]
        case .renameDelete: return ["rd-ours.txt"]
        case .binary: return ["bin.dat"]
        case .symlink: return ["link"]
        case .submodule: return ["sub"]
        case .mergeBinary: return ["mb.txt"]
        }
    }
}

/// How a fixture got to its stop, and the file that proves it did.
enum ConflictOperation: String, CaseIterable, Sendable {
    case merge, squash, cherryPick, revert, rebase

    /// `MERGE_HEAD`, `SQUASH_MSG`, … — under the git directory while the operation is stopped.
    var marker: String {
        switch self {
        case .merge: return "MERGE_HEAD"
        case .squash: return "SQUASH_MSG"
        case .cherryPick: return "CHERRY_PICK_HEAD"
        case .revert: return "REVERT_HEAD"
        case .rebase: return "REBASE_HEAD"
        }
    }
}

struct ConflictFixtureError: Error, CustomStringConvertible {
    let description: String
}

/// Repositories stopped with conflicts, built with real git. Every builder checks its own stop
/// (`ls-files -u` non-empty, the operation's marker present) and throws when git did something
/// else, so a broken fixture fails the test that asked for it rather than proving nothing.
///
/// Each history is `base` (tagged) → `main` ("ours change") and `base` → `theirs` ("theirs
/// change"), so every operation meets the same three versions: stage 1 = base, stage 2 = main,
/// stage 3 = theirs. `prepare` runs on the empty repository before the base commit — the place
/// for configuration and `.gitattributes` a conflict is read under.
enum ConflictFixtures {
    typealias Prepare = @Sendable (TestRepo) async throws -> Void

    /// The ten lines of `f.txt` in each version: lines 2 and 9 differ, six common lines between,
    /// so every conflict style draws two blocks (M 2; default style merges blocks at most three
    /// lines apart). Line 5 holds `@@` for the smudge-filter case.
    static let baseText = lines(["one", "two", "three", "four", "five @@", "six", "seven", "eight", "nine", "ten"])
    static let oursText = lines(["one", "two OURS", "three", "four", "five @@", "six", "seven", "eight", "nine OURS", "ten"])
    static let theirsText = lines(["one", "two THEIRS", "three", "four", "five @@", "six", "seven", "eight", "nine THEIRS", "ten"])

    static func lines(_ lines: [String]) -> String { lines.map { $0 + "\n" }.joined() }

    static func merge(
        kind: ConflictFixtureKind, prepare: Prepare = { _ in }, onTheirs: Prepare = { _ in }
    ) async throws -> TestRepo {
        let repo = try await history(kind, prepare: prepare, onTheirs: onTheirs)
        try await repo.git(["merge", "--no-edit", "theirs"], allowedExitCodes: [1])
        try await requireStopped(repo, marker: ConflictOperation.merge.marker)
        return repo
    }

    static func squash(
        kind: ConflictFixtureKind, prepare: Prepare = { _ in }, onTheirs: Prepare = { _ in }
    ) async throws -> TestRepo {
        let repo = try await history(kind, prepare: prepare, onTheirs: onTheirs)
        try await repo.git(["merge", "--squash", "theirs"], allowedExitCodes: [1])
        try await requireStopped(repo, marker: ConflictOperation.squash.marker)
        return repo
    }

    static func cherryPick(
        kind: ConflictFixtureKind, prepare: Prepare = { _ in }, onTheirs: Prepare = { _ in }
    ) async throws -> TestRepo {
        let repo = try await history(kind, prepare: prepare, onTheirs: onTheirs)
        try await repo.git(["cherry-pick", "theirs"], allowedExitCodes: [1])
        try await requireStopped(repo, marker: ConflictOperation.cherryPick.marker)
        return repo
    }

    /// A revert that meets base / main / theirs as a merge does: `theirs` gets a second commit
    /// that puts the base tree back, and reverting *that* on main takes the base as stage 1 and
    /// the theirs version (the reverted commit's parent) as stage 3 (M 6).
    static func revert(
        kind: ConflictFixtureKind, prepare: Prepare = { _ in }, onTheirs: Prepare = { _ in }
    ) async throws -> TestRepo {
        let repo = try await history(kind, prepare: prepare, onTheirs: onTheirs, backToBaseOnTheirs: true)
        try await repo.git(["revert", "--no-edit", "theirs"], allowedExitCodes: [1])
        try await requireStopped(repo, marker: ConflictOperation.revert.marker)
        return repo
    }

    /// `theirs` rebased onto `main`: stage 2 is main (the upstream), stage 3 the replayed commit.
    static func rebase(
        kind: ConflictFixtureKind, prepare: Prepare = { _ in }, onTheirs: Prepare = { _ in }
    ) async throws -> TestRepo {
        let repo = try await history(kind, prepare: prepare, onTheirs: onTheirs)
        try await repo.git(["switch", "-q", "theirs"])
        try await repo.git(["rebase", "main"], allowedExitCodes: [1])
        try await requireStopped(repo, marker: ConflictOperation.rebase.marker)
        return repo
    }

    static func stopped(
        _ operation: ConflictOperation, kind: ConflictFixtureKind, prepare: Prepare = { _ in },
        onTheirs: Prepare = { _ in }
    ) async throws -> TestRepo {
        switch operation {
        case .merge: return try await merge(kind: kind, prepare: prepare, onTheirs: onTheirs)
        case .squash: return try await squash(kind: kind, prepare: prepare, onTheirs: onTheirs)
        case .cherryPick: return try await cherryPick(kind: kind, prepare: prepare, onTheirs: onTheirs)
        case .revert: return try await revert(kind: kind, prepare: prepare, onTheirs: onTheirs)
        case .rebase: return try await rebase(kind: kind, prepare: prepare, onTheirs: onTheirs)
        }
    }

    /// `git am -3` of `theirs`' commit on `main`: stage 2 is main, stage 3 the patch's side.
    /// Exits 128 on the conflict (measured, A2 Task 4) and stops with `rebase-apply/`. Not a
    /// `ConflictOperation` case, so the suites iterating those keep their five.
    static func am(
        kind: ConflictFixtureKind, prepare: Prepare = { _ in }, onTheirs: Prepare = { _ in }
    ) async throws -> TestRepo {
        let repo = try await history(kind, prepare: prepare, onTheirs: onTheirs)
        let patch = try await repo.git(["format-patch", "-1", "--stdout", "theirs"])
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-am-\(UUID().uuidString).patch")
        defer { try? FileManager.default.removeItem(at: file) }
        try patch.write(to: file)
        try await repo.git(["am", "-3", file.path], allowedExitCodes: [128])
        try await requireStopped(repo, marker: "rebase-apply")
        return repo
    }

    /// `cherry-pick base..theirs` over three commits, each adding `pick-<n>.txt`; commit
    /// `stopAt` (1…3) also changes `f.txt` against main, so the range stops there with the rest
    /// of the sequence in `sequencer/`.
    static func cherryPickRange(stopAt: Int) async throws -> TestRepo {
        precondition((1...3).contains(stopAt))
        let repo = try await TestRepo.makeEmpty()
        try repo.write("keep.txt", "keep\n")
        try repo.write("f.txt", baseText)
        try await repo.commitAll("base")
        try await repo.git(["tag", "base"])
        try await repo.git(["switch", "-q", "-c", "theirs"])
        for n in 1...3 {
            try repo.write("pick-\(n).txt", "pick \(n)\n")
            if n == stopAt { try repo.write("f.txt", theirsText) }
            try await repo.commitAll("pick \(n)")
        }
        try await repo.git(["switch", "-q", "main"])
        try repo.write("f.txt", oursText)
        try await repo.commitAll("ours change")
        try await repo.git(["cherry-pick", "base..theirs"], allowedExitCodes: [1])
        try await requireStopped(repo, marker: ConflictOperation.cherryPick.marker)
        try await requireGitPath(repo, "sequencer")
        return repo
    }

    /// `stash apply` conflicting with a later commit: `u UU f.txt` and no operation at all.
    static func stashApplyConflict() async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("keep.txt", "keep\n")
        try repo.write("f.txt", baseText)
        try await repo.commitAll("base")
        try repo.write("f.txt", theirsText)
        try await repo.git(["stash", "push", "-q"])
        try repo.write("f.txt", oursText)
        try await repo.commitAll("ours change")
        try await repo.git(["stash", "apply", "-q"], allowedExitCodes: [1])
        try await requireUnmerged(repo)
        try await requireGitPath(repo, "refs/stash")
        return repo
    }

    // MARK: - Histories

    /// The history alone, on `main`, with no operation started: for a test that starts its own.
    /// `onTheirs` runs on `theirs` before its commit: more changes the operation brings in
    /// cleanly (a revert gets them back through the commit that undoes them). Not committed for
    /// `.submodule`, whose commits take `keep.txt` alone.
    static func history(
        _ kind: ConflictFixtureKind, prepare: Prepare = { _ in }, onTheirs: Prepare = { _ in },
        backToBaseOnTheirs: Bool = false
    ) async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try await prepare(repo)
        try repo.write("keep.txt", "keep\n")
        try await write(kind, .base, in: repo)
        try await commit(kind, "base", in: repo)
        try await repo.git(["tag", "base"])

        try await repo.git(["switch", "-q", "-c", "theirs"])
        try await write(kind, .theirs, in: repo)
        try await onTheirs(repo)
        try await commit(kind, "theirs change", in: repo)
        if backToBaseOnTheirs {
            try await repo.git(["revert", "--no-edit", "HEAD"])
        }

        try await repo.git(["switch", "-q", "main"])
        try await write(kind, .ours, in: repo)
        try await commit(kind, "ours change", in: repo)
        return repo
    }

    private enum Version { case base, ours, theirs }

    private static func write(_ kind: ConflictFixtureKind, _ version: Version, in repo: TestRepo) async throws {
        func pick(_ base: String?, _ ours: String?, _ theirs: String?) -> String? {
            switch version {
            case .base: return base
            case .ours: return ours
            case .theirs: return theirs
            }
        }
        switch kind {
        case .bothModified:
            try place(repo, "f.txt", pick(baseText, oursText, theirsText))
        case .bothAdded:
            try place(repo, "aa.txt", pick(nil, "one\nOURS\nthree\n", "one\nTHEIRS\nthree\n"))
        case .modeOnly:
            try place(repo, "mode.sh", pick(nil, "same\n", "same\n"))
            if version != .base {
                try FileManager.default.setAttributes(
                    [.posixPermissions: version == .ours ? 0o755 : 0o644],
                    ofItemAtPath: repo.root.appendingPathComponent("mode.sh").path)
            }
        case .deletedByUs:
            try place(repo, "du.txt", pick("d\n", nil, "d THEIRS\n"))
        case .deletedByThem:
            try place(repo, "ud.txt", pick("u\n", "u OURS\n", nil))
        case .renameRename:
            let text = "rename me\nline two\nline three\nline four\n"
            try place(repo, "rr.txt", pick(text, nil, nil))
            try place(repo, "rr-ours.txt", pick(nil, text, nil))
            try place(repo, "rr-theirs.txt", pick(nil, nil, text))
        case .renameDelete:
            let text = "renamed or deleted\nline two\nline three\nline four\n"
            try place(repo, "rd.txt", pick(text, nil, nil))
            try place(repo, "rd-ours.txt", pick(nil, text, nil))
        case .binary:
            try placeData(repo, "bin.dat", pick("\u{0}bin base\n", "\u{0}bin OURS\n", "\u{0}bin THEIRS\n"))
        case .symlink:
            let link = repo.root.appendingPathComponent("link")
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(
                atPath: link.path,
                withDestinationPath: pick("target-base", "target-ours", "target-theirs")!)
        case .submodule:
            // A gitlink with no repository behind it: `sub` stays an unpopulated submodule,
            // and its empty directory keeps `add -A` from reading it as deleted (M 1).
            try FileManager.default.createDirectory(
                at: repo.root.appendingPathComponent("sub"), withIntermediateDirectories: true)
            let digit = pick("1", "2", "3")!
            try await repo.git([
                "update-index", "--add", "--cacheinfo",
                "160000,\(String(repeating: digit, count: 40)),sub",
            ])
        case .mergeBinary:
            if version == .base { try repo.write(".gitattributes", "mb.txt merge=binary\n") }
            try place(repo, "mb.txt", pick(baseText, oursText, theirsText))
        }
    }

    private static func commit(_ kind: ConflictFixtureKind, _ message: String, in repo: TestRepo) async throws {
        if kind == .submodule {
            try await repo.git(["add", "--", "keep.txt"])
            try await repo.git(["commit", "-q", "-m", message])
        } else {
            try await repo.commitAll(message)
        }
    }

    /// Writes `text` to `path`, or removes the file when `text` is nil.
    private static func place(_ repo: TestRepo, _ path: String, _ text: String?) throws {
        let url = repo.root.appendingPathComponent(path)
        guard let text else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try repo.write(path, text)
    }

    private static func placeData(_ repo: TestRepo, _ path: String, _ text: String?) throws {
        let url = repo.root.appendingPathComponent(path)
        try? FileManager.default.removeItem(at: url)
        if let text { try Data(text.utf8).write(to: url) }
    }

    // MARK: - Preconditions

    static func requireStopped(_ repo: TestRepo, marker: String) async throws {
        try await requireUnmerged(repo)
        try await requireGitPath(repo, marker)
    }

    static func requireUnmerged(_ repo: TestRepo) async throws {
        let unmerged = try await repo.git(["ls-files", "-u"])
        guard !unmerged.isEmpty else {
            let status = String(decoding: try await repo.git(["status", "--porcelain=v2"]), as: UTF8.self)
            throw ConflictFixtureError(description: "the fixture did not stop with conflicts:\n\(status)")
        }
    }

    /// `name` exists under the git directory (a pseudo-ref, `SQUASH_MSG`, `sequencer/`).
    static func requireGitPath(_ repo: TestRepo, _ name: String) async throws {
        let path = try await gitPath(repo, name)
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ConflictFixtureError(description: "the fixture's stop has no \(name)")
        }
    }

    /// `rev-parse --git-path name`, as a URL under the repository.
    static func gitPath(_ repo: TestRepo, _ name: String) async throws -> URL {
        let out = try await repo.git(["rev-parse", "--git-path", name])
        let relative = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .newlines)
        return relative.hasPrefix("/")
            ? URL(fileURLWithPath: relative) : repo.root.appendingPathComponent(relative)
    }

    /// `ls-files -u -s -z`: one `(mode, oid, stage)` per present stage, keyed by path.
    static func stages(_ repo: TestRepo) async throws -> [String: [Int: ConflictStage]] {
        let data = try await repo.git(["ls-files", "-u", "-s", "-z"])
        var result: [String: [Int: ConflictStage]] = [:]
        for record in String(decoding: data, as: UTF8.self).split(separator: "\0") {
            let parts = record.split(separator: "\t", maxSplits: 1)
            let fields = parts[0].split(separator: " ")
            result[String(parts[1]), default: [:]][Int(fields[2])!] =
                ConflictStage(mode: String(fields[0]), blob: String(fields[1]))
        }
        return result
    }
}
