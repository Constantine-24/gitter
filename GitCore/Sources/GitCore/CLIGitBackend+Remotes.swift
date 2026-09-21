import Foundation

/// `GitRemoteBackend`'s read-only half: fetch, and the two reads the confirmation sheets for
/// the *writing* half are built out of. See the protocol for the contract; this file is about
/// how the argument vectors are spelled and how a failure is turned into words.
extension CLIGitBackend: GitRemoteBackend {
    public func fetch(
        remote: String?, at root: URL, progress: @escaping @Sendable (String) -> Void
    ) async throws {
        // Each vector is a COMPLETE array literal beginning with `"fetch"`, chosen by this
        // branch rather than assembled — `ForceFlagScannerTests` classifies a vector by its
        // first literal element and reads the rest against `fetch`'s deny table, and an
        // `append` or a `+` would hide the arguments from it entirely. Both are pinned there,
        // character for character, by `allowsTheRemoteOperationsThisMilestoneNeeds`.
        //
        // `--progress` is not decoration: without a tty git prints no progress at all, so the
        // callback would never fire. `--end-of-options` is accepted by `fetch` in this position
        // (verified on git 2.54), which is what lets a remote whose name resembles an option
        // still be read as a remote.
        //
        // `--no-prune` is how "no `--prune`" is actually kept. Leaving the flag out is not
        // enough: `fetch.prune` and `remote.<name>.prune` turn pruning on from the user's own
        // config (measured — see the protocol), and then a fetch deletes remote-tracking refs
        // and, with the `pruneTags` twins, local tags. Both vectors carry it.
        let arguments: [String]
        if let remote {
            try requireRemoteName(remote)
            arguments = ["fetch", "--progress", "--no-prune", "--end-of-options", remote]
        } else {
            arguments = ["fetch", "--progress", "--no-prune", "--all"]
        }

        do {
            _ = try await runStreaming(arguments, cwd: root, progress: progress)
        } catch let error as GitError {
            // Two exit codes, measured on git 2.54, and neither is read as a diagnosis: a
            // single-remote failure exits 128, a partial `--all` exits 1. Only the words are
            // consulted, and anything the parser does not recognise is rethrown as git's own.
            guard case .commandFailed(let code, let stderr) = error else { throw error }

            // Git's own words — never a diagnosed cause — when several remotes were fetched and
            // some of them worked. A `RemoteOperationError` is a statement about *the*
            // operation, and there was more than one here: `.repositoryNotFound` is false for
            // every remote that succeeded, and it throws away the one fact only git has, which
            // is which remote failed. Git's stderr names the loser and shows the successes.
            // A single-remote fetch is still diagnosed: there, one cause is the whole truth.
            guard !RemoteFailureParser.reportsARemoteThatCouldNotBeFetched(stderr: stderr),
                let failure = RemoteFailureParser.parse(stderr: stderr)
            else {
                // Redacted, because these words can contain the credential the user wrote into
                // a remote URL, and this error is shown as it is.
                throw GitError.commandFailed(
                    exitCode: code, stderr: RemoteFailureParser.redactingCredentials(stderr))
            }
            throw failure
        }
    }

    public func commits(
        in revision: String, notIn base: String, limit: Int, at root: URL
    ) async throws -> [Commit] {
        try requireRevision(revision)
        try requireRevision(base)

        // `git log -n 0` prints nothing, and an empty list here would draw a sheet saying no
        // commits are at stake. Clamped rather than refused: a caller whose arithmetic produced
        // a zero has a bug, and a short list is a bug the user can see.
        let count = max(1, limit)

        // The **range** form rather than `<revision> --not <base>`, which the task brief
        // suggested and which produces byte-identical output (measured). The difference is
        // hardening: `--end-of-options` stops option parsing for the *rest* of the argv, so
        // with `--not` after it git answers `fatal: option '--not' must come before non-option
        // arguments`. With the range as the last argument there is nothing after it to lose,
        // which is the same reasoning — and the same spelling — as `commitCount(in:notIn:)`,
        // the count this list is the detail of.
        //
        // The trailing `--` says "no pathspecs follow", so a revision git cannot resolve fails
        // as `fatal: bad revision '…'` rather than being tried as a file name. Failing is the
        // point: a sheet built on a silent empty list would tell the user nothing will be lost.
        let data = try await run(
            ["log", "-n", String(count), "-z", "--format=\(Self.logFormat)", "--end-of-options",
             base + ".." + revision, "--"],
            cwd: root)
        return LogParser.parse(data)
    }

    public func commitsOnlyOnRemoteBranch(_ remoteBranch: String, at root: URL) async throws -> Int {
        try requireName(remoteBranch)
        // A glob character cannot occur in a real ref name — git's own `check-ref-format`
        // forbids all three — and one of them in the `--exclude=` argument below would exclude
        // refs nobody named, **inflating** the count. That is the safe direction of a wrong
        // answer and still a wrong answer: a sheet warning about commits that are in fact held
        // elsewhere. Refused rather than passed on.
        guard !remoteBranch.contains(where: { $0 == "*" || $0 == "?" || $0 == "[" }) else {
            throw BranchOperationError.invalidName(remoteBranch)
        }

        // No `--end-of-options`, for `commitsOnlyOn`'s reason: it would stop option parsing for
        // the rest of the argv and turn `--not`, `--branches` and the rest into revisions. It is
        // not needed either — the ref is always spelled `refs/remotes/<name>`, which cannot
        // begin with `-` however `name` is spelled.
        //
        // **The exclusion's spelling is measured, not guessed** (git 2.54). `--exclude=<pattern>`
        // applies to the *next* `--branches`/`--tags`/`--remotes`, and the pattern lives in that
        // option's namespace — so it is `origin/topic`, relative to `refs/remotes/`. The design
        // document's `--exclude=refs/remotes/origin/topic` matches nothing: measured, it returned
        // 0 against a fixture whose true answer is 3.
        //
        // `*/HEAD` is excluded as well, because `refs/remotes/<r>/HEAD` is a **symbolic ref** and
        // a symref is not an independent holder of anything. Measured: `--remotes` lists it as a
        // ref of its own, so when it points at the branch being asked about it covers that
        // branch's commits and the answer comes back 0 for a deletion that would strand them.
        // Deleting the branch leaves it dangling; it was never holding the commits. The
        // exclusion costs nothing — `HEAD` is not a valid branch name (`git branch HEAD` →
        // `fatal: 'HEAD' is not a valid branch name`), and another remote's HEAD only points at
        // a branch `--remotes` already lists in its own right.
        return try await revListCount(
            ["rev-list", "--count", "refs/remotes/" + remoteBranch, "--not", "--branches",
             "--tags", "--exclude=" + remoteBranch, "--exclude=*/HEAD", "--remotes"],
            at: root)
    }

    /// Refuses a remote name before git runs. See `GitRemoteBackend.fetch` for what git does
    /// with each of the three shapes and why `"."` is the one that earns this check its keep.
    ///
    /// It is deliberately *not* `requireName`: that one throws a `BranchOperationError`, which
    /// belongs to a different protocol, and it does not know about `"."` — a perfectly good
    /// branch name and a thoroughly bad remote.
    /// Every question is asked of the **trimmed** name. It used to ask the untrimmed one about
    /// the leading `-` and the trimmed one about everything else, so `" -x"` walked past the
    /// check and reached git — which answered it by writing a `FETCH_HEAD`.
    ///
    /// Internal rather than private because `CLIGitBackend+Push.swift` asks the same question of
    /// the same kind of name, and a second copy of a security check is a second thing to forget
    /// to fix: the leading-space hole above was in exactly one of two places for a while.
    func requireRemoteName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-"), trimmed != "." else {
            throw RemoteOperationError.noRemote
        }
    }
}
