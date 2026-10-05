import Foundation

/// Comparing two branches (B3 Task 1). See `GitCompareBackend` for the contract; this file is
/// about how each vector is spelled, and why. Every vector here is pinned whole in
/// `ForceFlagScannerTests.compareContract`.
extension CLIGitBackend: GitCompareBackend {
    /// The comparison's files: `commitFiles`' arguments, from the merge base to B's id.
    static let comparisonFilesArguments = ["--no-commit-id", "--name-status", "-z", "-r", "-M"]
    /// The comparison's diff: `commitDiff`'s arguments and `--full-index`, so the `index` line
    /// carries full ids as `git diff --full-index A...B` does — byte for byte the pinned
    /// `diff A...B` (R5). `diff-tree` is plumbing: ext-diff, textconv, color and the prefix and
    /// context settings do not reach it (R5, measured), so the working-copy pins are not needed.
    static let comparisonPatchArguments = ["--no-commit-id", "-p", "-U3", "-M", "-r", "--full-index"]

    public func compare(_ a: String, _ b: String, at root: URL) async throws -> Comparison {
        try Self.requireBranchRef(a)
        try Self.requireBranchRef(b)
        guard a != b else { throw CompareRefusal.sameRef }

        // Each tip once, and in order; from here on only the ids are used (R11, R12).
        let tipA = try await resolveTip(a, at: root)
        let tipB = try await resolveTip(b, at: root)

        async let counts = sideCounts(tipA, tipB, at: root)
        async let onlyA = sideCommits(tipA, tipB, left: true, at: root)
        async let onlyB = sideCommits(tipA, tipB, left: false, at: root)
        async let bases = mergeBases(tipA, tipB, at: root)

        let (left, right) = try await counts
        return Comparison(
            a: tipA, b: tipB, onlyA: left, onlyB: right, commitsOnlyA: try await onlyA,
            commitsOnlyB: try await onlyB, mergeBases: try await bases)
    }

    public func comparisonFiles(_ c: Comparison, at root: URL) async throws -> [FileStatus] {
        guard let base = c.mergeBases.first else { throw CompareRefusal.noMergeBase }
        let data = try await diffTree(at: root, arguments: Self.comparisonFilesArguments, from: base, to: c.b.id)
        return parseNameStatus(data)
    }

    public func comparisonDiff(_ c: Comparison, path: String?, at root: URL) async throws -> [FileDiff] {
        guard let base = c.mergeBases.first else { throw CompareRefusal.noMergeBase }
        let trailing = path.map { ["--", literalPathspec($0)] } ?? []
        let data = try await diffTree(
            at: root, arguments: Self.comparisonPatchArguments, from: base, to: c.b.id, trailing: trailing)
        return DiffParser.parse(data)
    }

    // MARK: - The reads

    /// `ref`'s commit id, read once. `--quiet` makes a ref that does not exist exit 1 with no
    /// output, which is `.missing`; `^{commit}` peels whatever the ref holds to a commit (R11).
    /// The ref is full and checked by `requireBranchRef`, so no tag or other branch can answer
    /// for it (R10).
    private func resolveTip(_ ref: String, at root: URL) async throws -> RefTip {
        let data = try await run(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(ref)^{commit}"], cwd: root, allowedExitCodes: [1])
        let id = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw CompareRefusal.missing(ref) }
        guard Self.isFullObjectID(id) else {
            throw GitError.commandFailed(exitCode: -1, stderr: "unexpected rev-parse --verify output: \(id)")
        }
        return RefTip(ref: ref, id: id)
    }

    /// `left<TAB>right`, one process for both sides (R1). The range is two ids and comes before
    /// the `--`, so nothing in it can be read as an option or a path (R10).
    private func sideCounts(_ a: RefTip, _ b: RefTip, at root: URL) async throws -> (Int, Int) {
        let data = try await run(["rev-list", "--count", "--left-right", "--end-of-options", "\(a.id)...\(b.id)", "--"], cwd: root)
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = text.split(separator: "\t")
        guard fields.count == 2, let left = Int(fields[0]), let right = Int(fields[1]) else {
            throw GitError.commandFailed(exitCode: -1, stderr: "unexpected rev-list --count --left-right output: \(text)")
        }
        return (left, right)
    }

    /// The commits only on one side, newest first, at most `Comparison.listLimit`: the left
    /// (A's) or right (B's) half of the **same** symmetric walk the count takes.
    ///
    /// Not `commits(in:notIn:)`'s two-dot `log`, which the plan reused (R2) and fix round 1
    /// (I1) replaced: under clock skew — a side dated older than the commit it grew from — the
    /// two-dot walk stops on dates before it has marked everything the other side reaches, and
    /// lists commits the count does not count, **the merge base included** (measured, git
    /// 2.54: `count main...big` = `0 N`, `log big..main` = the root). `--topo-order` and a
    /// commit-graph do not fix it. The `...` walk is the count's own, so each list holds what
    /// its count counts. `--left-only`/`--right-only` keep `LogParser`'s seven fields (no `%m`).
    /// The range is two ids before the `--` (R10, R11).
    private func sideCommits(_ a: RefTip, _ b: RefTip, left: Bool, at root: URL) async throws -> [Commit] {
        let data = try await run(["log", "-n", String(Comparison.listLimit), "-z", "--format=\(Self.logFormat)", left ? "--left-only" : "--right-only", "--end-of-options", "\(a.id)...\(b.id)", "--"], cwd: root)
        return LogParser.parse(data)
    }

    /// Every merge base, in git's order. Exit 1 with no output is "no shared history" (R7) — a
    /// state, so `[]`, not an error. Several are criss-cross merges, and the first is the one
    /// `git diff A...B` would use (R8).
    private func mergeBases(_ a: RefTip, _ b: RefTip, at root: URL) async throws -> [String] {
        let data = try await run(["merge-base", "--all", "--end-of-options", a.id, b.id], cwd: root, allowedExitCodes: [1])
        let ids = GitLines.split(data).filter { !$0.isEmpty }
        guard ids.allSatisfy(Self.isFullObjectID) else {
            throw GitError.commandFailed(exitCode: -1, stderr: "unexpected merge-base --all output: \(ids)")
        }
        return ids
    }

    // MARK: - Names

    /// A full branch ref and nothing that could be read as anything else: `refs/heads/<name>`
    /// or `refs/remotes/<name>`, with a non-empty name and none of git's revision operators.
    ///
    /// A short name is refused because a tag or another branch can answer for it (R10: `v1` is
    /// the tag, `heads/v1` is `refs/heads/v1`). Revision syntax is refused because it names
    /// another commit than the branch's tip — `~`, `^`, `..`, `:`, `@{` — and whitespace or a
    /// control character because no ref has one. Each is `CompareRefusal.notABranch`, before
    /// git runs.
    static func requireBranchRef(_ name: String) throws {
        let rest: Substring
        if name.hasPrefix("refs/heads/") {
            rest = name.dropFirst("refs/heads/".count)
        } else if name.hasPrefix("refs/remotes/") {
            rest = name.dropFirst("refs/remotes/".count)
        } else {
            throw CompareRefusal.notABranch(name)
        }
        let operators = ["..", "^", "~", ":", "@{"]
        guard !rest.isEmpty, !operators.contains(where: rest.contains),
            !rest.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw CompareRefusal.notABranch(name)
        }
    }
}
