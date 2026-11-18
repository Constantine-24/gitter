import Foundation

/// The sidebar's Recent input (N1 Task 1). Two reads, run concurrently:
/// `reflog show -n 2000 --no-show-signature --format=%gs HEAD --` and
/// `for-each-ref --format=%(refname)%00%(committerdate:unix) --end-of-options refs/heads`.
extension CLIGitBackend {

    /// Measured (git 2.54, `LC_ALL=C`, scratch repositories): in a repository whose HEAD has no
    /// commit, the reflog read exits 128 with `fatal: bad revision 'HEAD'` (the `reflog` form
    /// without a revision says "does not have any commits yet", and is not the one used); that
    /// is read as no switches. Any other failure throws.
    private static let emptyRepositoryMessages = ["bad revision 'HEAD'", "does not have any commits yet"]

    public func branchActivity(at root: URL) async throws -> BranchActivity {
        async let switches = reflogSwitchTargets(at: root)
        async let dates = localTipDates(at: root)
        return BranchActivity(switchTargets: try await switches, tipDates: try await dates)
    }

    /// The `--` ends the revisions: without it a file named `HEAD` in the worktree makes git
    /// refuse with "ambiguous argument" (measured, exit 128).
    private func reflogSwitchTargets(at root: URL) async throws -> [String] {
        do {
            let data = try await run(
                ["reflog", "show", "-n", "2000", "--no-show-signature", "--format=%gs", "HEAD", "--"], cwd: root)
            return ReflogSwitchParser.targets(String(decoding: data, as: UTF8.self))
        } catch GitError.commandFailed(let code, let stderr)
            where code == 128 && Self.emptyRepositoryMessages.contains(where: stderr.contains) {
            return []
        }
    }

    /// One record per line, `<refname> NUL <unix seconds>`: the vector has no trailing NUL, so
    /// records are cut at the newline (a ref name cannot hold one) and fields at the NUL.
    private func localTipDates(at root: URL) async throws -> [String: Date] {
        let data = try await run(
            ["for-each-ref", "--format=%(refname)%00%(committerdate:unix)", "--end-of-options", "refs/heads"], cwd: root)
        var dates: [String: Date] = [:]
        let prefix = "refs/heads/"
        for record in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") where !record.isEmpty {
            let fields = record.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2, fields[0].hasPrefix(prefix), let seconds = TimeInterval(fields[1]) else { continue }
            dates[String(fields[0].dropFirst(prefix.count))] = Date(timeIntervalSince1970: seconds)
        }
        return dates
    }
}
