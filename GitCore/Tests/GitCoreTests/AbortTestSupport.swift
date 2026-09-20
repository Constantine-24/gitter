import Foundation
import Testing

@testable import GitCore

/// The seven in-progress states the kept/lost table covers: `RepositoryOperation`'s six, with
/// `.rebase` split in two because git implements a rebase with two different backends
/// (`rebase-merge/` and the older `rebase-apply/`) and both must come out of `--abort` the same
/// way. They do; the split is here so that is a tested fact rather than an assumption.
enum AbortCase: String, CaseIterable, Sendable {
    case merge, squash, cherryPick, revert, rebase, rebaseApplyBackend, applyingPatches

    var operation: RepositoryOperation {
        switch self {
        case .merge: return .merge
        case .squash: return .squash
        case .cherryPick: return .cherryPick
        case .revert: return .revert
        case .rebase, .rebaseApplyBackend: return .rebase
        case .applyingPatches: return .applyingPatches
        }
    }

    /// Whether a tracked file can already hold an **unstaged** edit when the operation starts.
    ///
    /// Verified on git 2.54: a rebase refuses to begin at all while *any* tracked file has an
    /// unstaged change ("error: cannot rebase: You have unstaged changes."), so cell (a) of the
    /// table is unreachable for a rebase — there is no such thing as a rebase with pre-existing
    /// dirt to lose. `git am` has no rule about the *worktree* and starts happily with an
    /// unstaged edit in an untouched file, which is why it is not in this exception. It does
    /// refuse a dirty **index**, as they all do — that is cell (a′), and a different question.
    var acceptsAPreExistingEdit: Bool {
        switch self {
        case .rebase, .rebaseApplyBackend: return false
        case .merge, .squash, .cherryPick, .revert, .applyingPatches: return true
        }
    }

    /// Whether an **unstaged** edit made *after* the operation began, to a file the operation
    /// never touched, survives the abort.
    ///
    /// The one place the seven differ, and the reason the confirmation sheet cannot use one
    /// sentence for all of them. Verified on git 2.54: `merge --abort`, `cherry-pick --abort`,
    /// `revert --abort`, `am --abort` and `reset --merge` all reset the index two-way and keep
    /// whatever differs only between index and worktree, while `rebase --abort` resets *hard*
    /// and takes the edit with it.
    var keepsUnstagedEditsMadeAfterItBegan: Bool {
        switch self {
        case .rebase, .rebaseApplyBackend: return false
        case .merge, .squash, .cherryPick, .revert, .applyingPatches: return true
        }
    }
}

/// One distinct marker per table cell, so a cell that answers wrongly names itself in the
/// failure message instead of showing two indistinguishable "base" strings.
enum AbortMarker {
    static let preExistingEdit = "PRE-EXISTING EDIT\n"       // (a)
    static let stagedBefore = "STAGED BEFORE\n"              // (a′)
    static let untrackedBefore = "UNTRACKED BEFORE\n"        // (b)
    static let unstagedAfter = "UNSTAGED AFTER\n"            // (c)
    static let stagedAfter = "STAGED AFTER\n"                // (d)
    static let partialResolution = "PARTIAL RESOLUTION\n"    // (e)
    static let resolvedAndStaged = "RESOLVED AND STAGED\n"   // (f)
    static let untrackedAfter = "UNTRACKED AFTER\n"          // (g)
}

/// A repository part-way through one operation, with one of every change the kept/lost table
/// asks about already in place, plus everything needed to say what the abort did to each.
struct AbortLab {
    let repo: TestRepo
    let kind: AbortCase
    /// HEAD, symbolic HEAD, the index and every ref as they were *before* the operation began.
    let preOperation: RepoState
    /// Every worktree file as it was before the operation began — the baseline a "discarded"
    /// cell is measured against, since "gone" means "back to what it was", not "deleted".
    let preOperationWorktree: [String: Data]

    func cleanUp() { repo.cleanUp() }

    func abort() async throws {
        try await CLIGitBackend().abort(kind.operation, at: repo.root)
    }

    func operationInProgress() async throws -> RepositoryOperation? {
        try await CLIGitBackend().snapshot(at: repo.root).status.operationInProgress
    }

    /// The bytes `path` holds now.
    func now(_ path: String) throws -> String {
        try repo.fileContents(path)
    }

    /// The bytes `path` held before the operation began.
    func before(_ path: String) throws -> String {
        String(decoding: try #require(preOperationWorktree[path]), as: UTF8.self)
    }
}

/// Six tracked files, all "base" at the root commit: `c1.txt` and `c2.txt` conflict,
/// `touched.txt` is rewritten by the operation without conflicting, and `other.txt`,
/// `afterU.txt` and `afterS.txt` are never touched by either side.
private let trackedFiles = ["c1.txt", "c2.txt", "touched.txt", "other.txt", "afterU.txt", "afterS.txt"]

/// Builds a repository that is part-way through `kind`, having made — in this order — the
/// pre-existing changes (a, b), captured the pre-operation state, started the operation, and
/// then made the changes a user could only make once it was under way (c–g).
func makeAbortLab(_ kind: AbortCase) async throws -> AbortLab {
    let repo = try await makeAbortHistory(kind)

    if kind.acceptsAPreExistingEdit {
        try repo.write("other.txt", AbortMarker.preExistingEdit)
    }
    try repo.write("untracked-before.txt", AbortMarker.untrackedBefore)

    let state = try await RepoState.capture(repo)
    let worktree = worktreeSnapshot(repo)
    try await startOperation(kind, in: repo)

    try repo.write("afterU.txt", AbortMarker.unstagedAfter)
    try repo.write("afterS.txt", AbortMarker.stagedAfter)
    try await repo.git(["add", "afterS.txt"])
    try repo.write("c1.txt", AbortMarker.partialResolution)
    try repo.write("c2.txt", AbortMarker.resolvedAndStaged)
    try await repo.git(["add", "c2.txt"])
    try repo.write("untracked-after.txt", AbortMarker.untrackedAfter)

    return AbortLab(
        repo: repo, kind: kind, preOperation: state, preOperationWorktree: worktree)
}

/// Everything `makeAbortLab` builds *before* the operation starts: the six tracked files, the
/// history the operation needs, and — for a rebase — the branch it is run from. Separate so a
/// test can start the operation itself, or watch it be refused.
func makeAbortHistory(_ kind: AbortCase) async throws -> TestRepo {
    let repo = try await TestRepo.makeEmpty()
    for name in trackedFiles { try repo.write(name, "base\n") }
    try await repo.commitAll("base")
    try await buildHistory(kind, in: repo)
    return repo
}

/// Starts the operation expecting git to **refuse** it. The exit codes differ per operation —
/// 2 for a true merge, 128 for cherry-pick, revert and am, 1 for a rebase — which is exactly
/// why no caller may key on them.
func startOperationExpectingARefusal(_ kind: AbortCase, in repo: TestRepo) async throws {
    try await startOperation(kind, in: repo, allowedExitCodes: [1, 2, 128])
}

/// The history each operation needs, and — for a rebase — the branch it is run from.
private func buildHistory(_ kind: AbortCase, in repo: TestRepo) async throws {
    switch kind {
    case .revert:
        // Reverting the middle commit conflicts in c1/c2 and cleanly rewinds `touched.txt`.
        try repo.write("c1.txt", "v2\n")
        try repo.write("c2.txt", "v2\n")
        try repo.write("touched.txt", "v2\n")
        try await repo.commitAll("second")
        try repo.write("c1.txt", "v3\n")
        try repo.write("c2.txt", "v3\n")
        try await repo.commitAll("third")
    case .applyingPatches:
        // Two patches: the first applies cleanly (so `am` commits it before stopping), the
        // second conflicts. That is what makes "what happens to patches already applied?"
        // answerable.
        try await repo.git(["switch", "-q", "-c", "side"])
        try repo.write("applied.txt", "from the first patch\n")
        try await repo.commitAll("patch one, applies cleanly")
        try await writeSideChanges(repo, message: "patch two, conflicts")
        try await repo.git(["switch", "-q", "main"])
        try await writeMainChanges(repo)
        let patches = try await repo.git(["format-patch", "-2", "--stdout", "side"])
        // Inside `.git`, so it is neither an untracked file in the worktree snapshot nor
        // something to clean up separately.
        try patches.write(to: repo.root.appendingPathComponent(".git/patches.mbox"))
    case .merge, .squash, .cherryPick, .rebase, .rebaseApplyBackend:
        try await repo.git(["switch", "-q", "-c", "side"])
        try await writeSideChanges(repo, message: "side")
        try await repo.git(["switch", "-q", "main"])
        try await writeMainChanges(repo)
        if kind == .rebase || kind == .rebaseApplyBackend {
            try await repo.git(["switch", "-q", "side"])
        }
    }
}

private func writeSideChanges(_ repo: TestRepo, message: String) async throws {
    try repo.write("c1.txt", "side\n")
    try repo.write("c2.txt", "side\n")
    try repo.write("touched.txt", "side\n")
    try await repo.commitAll(message)
}

private func writeMainChanges(_ repo: TestRepo) async throws {
    try repo.write("c1.txt", "main\n")
    try repo.write("c2.txt", "main\n")
    try await repo.commitAll("main")
}

/// Starts the operation, conflicting. Exit codes verified on git 2.54: 1 for all of them
/// except `git am`, which exits 128.
private func startOperation(
    _ kind: AbortCase, in repo: TestRepo, allowedExitCodes: Set<Int32>? = nil
) async throws {
    func run(_ arguments: [String], _ expected: Set<Int32>) async throws {
        try await repo.git(arguments, allowedExitCodes: allowedExitCodes ?? expected)
    }
    switch kind {
    case .merge: try await run(["merge", "side"], [1])
    case .squash: try await run(["merge", "--ff", "--squash", "side"], [1])
    case .cherryPick: try await run(["cherry-pick", "side"], [1])
    case .revert: try await run(["revert", "--no-edit", "HEAD~1"], [1])
    case .rebase: try await run(["rebase", "main"], [1])
    case .rebaseApplyBackend: try await run(["rebase", "--apply", "main"], [1])
    case .applyingPatches: try await run(["am", "-3", ".git/patches.mbox"], [128])
    }
}
