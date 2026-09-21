import Foundation

/// `GitRemoteBackend`'s writing half: push. See the protocol for the contract; this file is
/// about how the two argument vectors are spelled, which names are refused before git runs, and
/// why the outcome is read out of stdout rather than out of the exit code.
extension CLIGitBackend {
    public func push(
        _ branch: String, to remote: String, remoteRef: String, setUpstream: Bool,
        at root: URL, progress: @escaping @Sendable (String) -> Void
    ) async throws -> PushResult {
        // Everything is checked before git is launched. `branch` and `remoteRef` both go into
        // one refspec argument, so a `:` in either would silently make a *different* refspec —
        // see `requireRefspecSide` and `requirePushDestination`.
        try requireRefspecSide(branch)
        try requireRemoteName(remote)
        try requirePushDestination(remoteRef)

        // Each vector is a COMPLETE array literal beginning with `"push"`, chosen by this
        // branch rather than assembled: `ForceFlagScannerTests` classifies a vector by its first
        // literal element and loses every `push` rule past a `+`, `+=` or `.append`, so
        // `setUpstream` is a choice between two whole literals and never a concatenation. Both
        // are pinned there, character for character, by
        // `allowsTheRemoteOperationsThisMilestoneNeeds`.
        //
        // `--porcelain` is what makes the outcome readable at all: without it git's stdout is
        // prose. `--progress` is not decoration — without a tty git prints no progress, so the
        // callback would never fire. `--end-of-options` is accepted by `push` in this position
        // (verified on git 2.54: `git push --porcelain --progress --end-of-options origin
        // refs/heads/main:refs/heads/main` exits 0 and pushes), which is what lets a remote
        // whose name resembles an option still be read as a remote.
        //
        // The refspec is explicit and full on both sides, and never begins with `+`: the force
        // this package permits is a lease, and a lease is a flag with a sha in it rather than a
        // character in a refspec.
        let arguments: [String]
        if setUpstream {
            arguments = ["push", "--porcelain", "--progress", "-u", "--end-of-options", remote, "refs/heads/\(branch):\(remoteRef)"]
        } else {
            arguments = ["push", "--porcelain", "--progress", "--end-of-options", remote, "refs/heads/\(branch):\(remoteRef)"]
        }

        let streamed: ProcessRunner.StreamedResult
        do {
            // Exit 1 is *allowed*, not tolerated: it is what every rejection exits with, and a
            // rejection is an outcome that lives on stdout. Letting `runStreaming` throw here
            // would throw the stdout away with it — `GitError.commandFailed` carries only
            // stderr — and the outcome would be unreadable.
            streamed = try await runStreaming(
                arguments, cwd: root, allowedExitCodes: [1], progress: progress)
        } catch let error as GitError {
            guard case .commandFailed(let code, let stderr) = error else { throw error }
            throw diagnosed(exitCode: code, stderr: stderr)
        }

        let stdout = String(decoding: streamed.stdout, as: UTF8.self)
        guard let outcome = PushPorcelainParser.parse(stdout: stdout, destinationRef: remoteRef)
        else {
            // git exited 0 or 1 and said nothing about the ref it was given. Either way it is a
            // failure — a push that went through always prints a line — and the code reported
            // is git's own rather than an assumed one. Three shapes reach here, measured on git
            // 2.54 (a fourth, an unreadable remote, exits 128 and is caught above):
            //
            // | shape | stdout | stderr | exit |
            // |---|---|---|---|
            // | `push origin refs/heads/ghost:…` | empty | `error: src refspec refs/heads/ghost does not match any` | 1 |
            // | a local `pre-push` hook that exits 1 | empty | the hook's own words, then `error: failed to push some refs to …` | 1 |
            // | an unreadable remote (caught above) | empty | `fatal: '…' does not appear to be a git repository` | 128 |
            //
            // The hook's words are on stderr with **no** `remote:` prefix — it ran here, not on
            // the server — so they reach the user through this error rather than through
            // `remoteMessages`. An exit 0 with no line for an explicit refspec has never been
            // observed and would be a git this code does not know; it is still a failure here.
            throw diagnosed(exitCode: streamed.exitCode, stderr: streamed.stderr)
        }
        return PushResult(
            outcome: outcome,
            remoteMessages: PushPorcelainParser.remoteMessages(stderr: streamed.stderr))
    }

    /// A network failure in Gitter's words when the parser recognises one, and in git's own —
    /// redacted, because a remote URL can carry a token — when it does not.
    ///
    /// Unlike `fetch`, there is no partial-success case to guard against: one push is one
    /// operation against one remote, so a single diagnosed cause is always the whole truth.
    private func diagnosed(exitCode: Int32, stderr: String) -> Error {
        RemoteFailureParser.parse(stderr: stderr)
            ?? GitError.commandFailed(
                exitCode: exitCode, stderr: RemoteFailureParser.redactingCredentials(stderr))
    }

    /// Refuses a branch name that would not survive being written into a refspec.
    ///
    /// `requireName`'s two rules (non-empty, no leading `-`) plus the one only a refspec needs:
    /// **no `:` anywhere**. `refs/heads/\(branch):\(remoteRef)` is a single argument, so a
    /// branch called `a:b` makes it `refs/heads/a:b:refs/heads/x` — a refspec whose destination
    /// nobody chose. git itself forbids `:` in a ref name, so no real branch is lost here; what
    /// is closed is the gap between a name that reached this function and a ref that exists.
    private func requireRefspecSide(_ branch: String) throws {
        try requireName(branch)
        guard !branch.contains(":") else { throw BranchOperationError.invalidName(branch) }
    }

    /// Refuses a push destination that is not a full branch ref.
    ///
    /// The destination is always `refs/heads/<something>`, spelled out in full, for three
    /// reasons that are each their own bug: a short name (`main`) is resolved by the *server*
    /// under rules Gitter cannot see; a second `:` turns the argument into a refspec with a
    /// destination nobody chose; and a leading `+` is git's force marker written as data, which
    /// is exactly what this package promises never to send. `refs/heads/` as a prefix settles
    /// the leading `-`, `+` and `:` cases on its own — they are kept as named conditions in the
    /// guard below because they are what the rule is *for*, and a later relaxation of the prefix
    /// must not quietly take them with it.
    private func requirePushDestination(_ ref: String) throws {
        guard ref.hasPrefix("refs/heads/"), ref.count > "refs/heads/".count,
            !ref.hasPrefix("-"), !ref.hasPrefix("+"), !ref.hasPrefix(":"), !ref.contains(":")
        else {
            throw BranchOperationError.invalidName(ref)
        }
    }
}
