import Foundation

/// `GitRemoteBackend`'s writing half: push, force push behind a lease, and delete a remote
/// branch behind the same lease. See the protocol for the contract; this file is about how the
/// four argument vectors are spelled, which names and which leases are refused before git runs,
/// and why the outcome is read out of stdout rather than out of the exit code.
///
/// **Two of the four vectors carry a `--force-with-lease=`, which is the only force this
/// package permits, and they are written in the one shape `ForceFlagScannerTests` will
/// accept**: a complete array literal beginning with `"push"`, the lease standing alone as an
/// element of it (never an arm of a ternary, never concatenated, never appended), and the
/// expected value an interpolation — because a hard-coded sha cannot have come from the sheet
/// the user just read. All four are pinned there, character for character, by
/// `allowsTheRemoteOperationsThisMilestoneNeeds`, which is why the local bindings below are
/// named `tip` and `b`: the contract is the text.
///
/// **All four also carry `--no-follow-tags`, and leaving `--follow-tags` out would not have
/// been enough** — for exactly the reason `fetch` spells `--no-prune` rather than merely
/// omitting `--prune`. `push.followTags=true` is an ordinary line in a user's own
/// configuration and turns the flag on from there. Measured on git 2.54 with that key set,
/// each vector **without** `--no-follow-tags`:
///
/// | vector | what reached the server |
/// |---|---|
/// | `push -u …` | the branch, **and** `*⇥refs/tags/annotated:refs/tags/annotated⇥[new tag]` |
/// | `push …` (no `-u`) | the branch, and the same extra tag line |
/// | `push --force-with-lease=… …` | ` ⇥refs/heads/main:…⇥e14f0f6..985b548`, and `*⇥refs/tags/annot2:…⇥[new tag]` |
/// | `push --force-with-lease=… :refs/heads/doomed` | `-⇥:refs/heads/doomed⇥[deleted]`, and `*⇥refs/tags/annotated:…⇥[new tag]` |
///
/// The last row is the one nobody would guess: a push whose only refspec **deletes** a ref
/// still follows tags. Pushing tags is not in this milestone, no confirmation names a tag, and
/// a ref appearing on somebody's server because of a key Gitter never read is precisely what
/// this package exists to make impossible.
///
/// **And the flag settles it, in every vector and against every neighbouring key** (all
/// measured on git 2.54 with `push.followTags=true` in force): with `--no-follow-tags` each of
/// the four pushed the one ref it named and no tag. `remote.<n>.push` adds none either — an
/// explicit refspec on the command line replaces a configured one outright, measured with
/// `remote.origin.push=refs/tags/*:refs/tags/*` set — `remote.<n>.pushurl` only chooses the URL
/// (same one-ref result against a second bare repository), and there is no
/// `remote.<n>.followTags`: setting it changes nothing. `--tags`, `--all`, `--mirror` and
/// `--follow-tags` itself are already in the scanner's `push` deny table, so configuration was
/// the one road left to a tag, and this closes it.
///
/// Consequence for `PushPorcelainParser`, and it is a *narrowing* rather than a change: it
/// still skips result lines for refs it was not asked about, and still must, because a user's
/// own `git push` and a future Gitter vector both can produce them — but after this, **no push
/// Gitter makes can**.
///
/// The flag is written out four times rather than hoisted into a constant, because each vector
/// is a complete array literal the scanner reads as text.
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
        // **`--no-follow-tags` is on all four vectors, and it is not decoration either.** See
        // this file's own doc comment for what it defends against and what it was measured to
        // do: without it, `push.followTags=true` made every one of the four create tags on the
        // server.
        //
        // The refspec is explicit and full on both sides, and never begins with `+`: the force
        // this package permits is a lease, and a lease is a flag with a sha in it rather than a
        // character in a refspec.
        let arguments: [String]
        if setUpstream {
            arguments = ["push", "--porcelain", "--progress", "--no-follow-tags", "-u", "--end-of-options", remote, "refs/heads/\(branch):\(remoteRef)"]
        } else {
            arguments = ["push", "--porcelain", "--progress", "--no-follow-tags", "--end-of-options", remote, "refs/heads/\(branch):\(remoteRef)"]
        }

        let (outcome, streamed) = try await pushing(
            arguments, destinationRef: remoteRef, at: root, progress: progress)
        return result(
            outcome, streamed,
            upstream: await upstreamResult(
                asked: setUpstream, outcome: outcome, branch: branch, remote: remote,
                remoteRef: remoteRef, at: root))
    }

    public func forcePush(
        _ branch: String, to remote: String, remoteRef: String, expectedRemoteTip: String,
        expectedLocalTip: String,
        at root: URL, progress: @escaping @Sendable (String) -> Void
    ) async throws -> PushResult {
        // The same three name checks `push` makes, and then the one only a lease needs. Order
        // matters only in that all four happen before git is launched, which is what makes
        // every one of these refusals a true no-op: `aLeaseThatIsNotAFullObjectNameIsRefused…`
        // proves it with a `pre-push` hook that never fires.
        try requireRefspecSide(branch)
        try requireRemoteName(remote)
        try requirePushDestination(remoteRef)
        try requireFullObjectName(expectedRemoteTip)
        // The refspec's source side, so the same rule and for a sharper reason: an abbreviation
        // or a name is resolved by git against a local state that can move, an empty source
        // side is a deletion, and forty zeros would be read the same way.
        try requireFullObjectName(expectedLocalTip)

        // Bound rather than used directly because the vector below is a **contract**: it is
        // written out in `ForceFlagScannerTests.allowsTheRemoteOperationsThisMilestoneNeeds`
        // character for character, `\(tip)` included, and the scanner permits a lease only in
        // that exact shape — one whole literal, standing alone as an element of an array
        // literal that begins with `"push"`, with the expected value an interpolation.
        //
        // The lease names `remoteRef`, the ref **on the server**, and not `branch`: it is a
        // claim about what the destination holds, and under a rename or a `remote.<n>.push`
        // refspec those are two different refs (`theLeaseNamesTheDestinationRefAndNot…`).
        //
        // **The source side is `expectedLocalTip`, a sha, and not `refs/heads/<branch>`.** The
        // lease pins what the server loses; this pins what it gets. The sheet counted the
        // commits the server has that *this* commit lacks, and a push by name would send
        // whatever the branch points at when the button is pressed — a `git reset --hard
        // <older>` in a terminal while the sheet was up took two commits off the server where
        // the sheet named one (Task 8's review). Measured on git 2.54, `push
        // --force-with-lease=refs/heads/main:<theirs> origin <sha>:refs/heads/main` pushes
        // exactly that commit and prints `+⇥<sha>:refs/heads/main⇥034c32c...d9229ae (forced
        // update)`: the destination side is unchanged, and `PushPorcelainParser` matches on the
        // destination. `branch` is still checked above, as the name the caller read the tip
        // from, but it is no longer sent.
        let tip = expectedRemoteTip
        let arguments = ["push", "--porcelain", "--progress", "--no-follow-tags", "--force-with-lease=\(remoteRef):\(tip)", "--end-of-options", remote, "\(expectedLocalTip):\(remoteRef)"]

        let (outcome, streamed) = try await pushing(
            arguments, destinationRef: remoteRef, at: root, progress: progress)
        // `.notRequested`, not `.notSet`: nothing asked for an upstream here, so there is
        // nothing to report about one. See `UpstreamResult`.
        return result(outcome, streamed, upstream: .notRequested)
    }

    public func deleteRemoteBranch(
        _ branch: String, on remote: String, expectedTip: String, at root: URL
    ) async throws -> PushResult {
        // `requireRefspecSide` rather than `requirePushDestination`, because what is passed
        // here is a branch *name* and this file writes the `refs/heads/` in front of it. That
        // prefix settles a leading `-`, `+` or `:` on its own; the `:` **inside** the name is
        // the one that would still break the argument in two, and it is what this refuses.
        try requireRefspecSide(branch)
        try requireRemoteName(remote)
        try requireFullObjectName(expectedTip)

        // `b` and `tip` for the same reason as above: this vector is pinned character for
        // character in `ForceFlagScannerTests`, and the scanner's stand-down for the delete
        // refspec (`":refs/heads/\(b)"`, an empty source side — `push --delete` written as
        // data) is granted only because a permitted lease stands as an element of the *same*
        // array literal. That is the whole design: the deletion is conditional on the tip the
        // sheet showed.
        let b = branch
        let tip = expectedTip
        let arguments = ["push", "--porcelain", "--progress", "--no-follow-tags", "--force-with-lease=refs/heads/\(b):\(tip)", "--end-of-options", remote, ":refs/heads/\(b)"]

        // No progress to report: a deletion sends one command and transfers no objects, so git
        // prints no counters. It is cancellable all the same — `runStreaming` is what makes it
        // so — and a cancelled deletion says nothing about whether the server carried it out.
        let (outcome, streamed) = try await pushing(
            arguments, destinationRef: "refs/heads/" + b, at: root, progress: { _ in })
        return result(outcome, streamed, upstream: .notRequested)
    }

    /// Runs one push vector and reads its outcome off `--porcelain` stdout.
    ///
    /// The one place all three push methods go through, so that "the outcome never comes from
    /// the exit code" and "a push with no result line is a failure" are one decision rather
    /// than three copies of one.
    private func pushing(
        _ arguments: [String], destinationRef: String, at root: URL,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> (PushOutcome, ProcessRunner.StreamedResult) {
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
        guard let outcome = PushPorcelainParser.parse(stdout: stdout, destinationRef: destinationRef)
        else {
            // git exited 0 or 1 and said nothing about the ref it was given. Either way it is a
            // failure — a push that went through always prints a line — and the code reported
            // is git's own rather than an assumed one. Four shapes reach here, measured on git
            // 2.54 (a fifth, an unreadable remote, exits 128 and is caught above):
            //
            // | shape | stdout | stderr | exit |
            // |---|---|---|---|
            // | `push origin refs/heads/ghost:…` | empty | `error: src refspec refs/heads/ghost does not match any` | 1 |
            // | a local `pre-push` hook that exits 1 | empty | the hook's own words, then `error: failed to push some refs to …` | 1 |
            // | a lease git cannot parse (a 64-hex name in a sha-1 repository) | empty | `error: cannot parse expected object name '…'` | **129** |
            // | an unreadable remote (caught above) | empty | `fatal: '…' does not appear to be a git repository` | 128 |
            //
            // The hook's words are on stderr with **no** `remote:` prefix — it ran here, not on
            // the server — so they reach the user through this error rather than through
            // `remoteMessages`. An exit 0 with no line for an explicit refspec has never been
            // observed and would be a git this code does not know; it is still a failure here.
            throw diagnosed(exitCode: streamed.exitCode, stderr: streamed.stderr)
        }
        return (outcome, streamed)
    }

    /// The outcome and everything the server said, assembled the same way for every push.
    private func result(
        _ outcome: PushOutcome, _ streamed: ProcessRunner.StreamedResult,
        upstream: UpstreamResult
    ) -> PushResult {
        PushResult(
            outcome: outcome,
            remoteMessages: PushPorcelainParser.remoteMessages(stderr: streamed.stderr),
            upstream: upstream,
            errorLines: PushPorcelainParser.errorLines(stderr: streamed.stderr))
    }

    /// Refuses an expected tip that is not a full object name, before git runs.
    ///
    /// Forty (sha-1) or sixty-four (sha-256) characters, every one of them a **lower-case**
    /// hexadecimal digit, and not all zeros. See `RemoteOperationError.invalidLease` for the
    /// five shapes measured on git 2.54 and why three of them are accepted by git and are still
    /// never what Gitter means.
    ///
    /// The digits are checked against a written-out set rather than with `Character.isHexDigit`,
    /// which is true for the full-width forms (`\u{FF10}`…) as well: a name that is "hex" by
    /// that test and not by git's would have passed a check whose whole job is to make sure the
    /// string reaching git is the sha the sheet showed.
    private func requireFullObjectName(_ tip: String) throws {
        guard tip.count == 40 || tip.count == 64,
            tip.allSatisfy(Self.lowercaseHexDigits.contains),
            !tip.allSatisfy({ $0 == "0" })
        else {
            throw RemoteOperationError.invalidLease(tip)
        }
    }

    private static let lowercaseHexDigits: Set<Character> = Set("0123456789abcdef")

    /// Whether the branch is now tracking what `-u` was asked to make it track, read back out
    /// of the configuration rather than assumed from the push having succeeded.
    ///
    /// **git's `-u` is best-effort and says so nowhere the outcome can see.** Measured on git
    /// 2.54 with `.git` and `.git/config` made unwritable: the push goes through, git exits
    /// **0**, the `branch '…' set up to track '…'.` notice is absent, and the two lines that
    /// explain it (`error: could not lock config file …`, `error: unable to write upstream
    /// branch configuration`) are on stderr with no `remote:` prefix — invisible to both the
    /// porcelain parser and `remoteMessages`.
    ///
    /// The configuration keys are read rather than `<branch>@{upstream}`, which is the same
    /// question asked in a way that can answer wrongly: `@{upstream}` resolves through the
    /// remote's *fetch* refspec, so a remote configured to map refs somewhere else would give
    /// a name that does not match while the upstream really is what was asked for. `-u` writes
    /// exactly these two keys (measured, Task 5), so these two are what is compared.
    ///
    /// `.notRequested` when nothing was asked, and when the server refused — a rejected push
    /// wrote no upstream and was never going to, and the banner is about the refusal.
    ///
    /// A read-back that **could not be run** is `.unknown` and not `.notSet`, which is the
    /// whole reason this returns `UpstreamResult` rather than `Bool?`: the two call for
    /// opposite sentences, and the failing read-back can happen with the upstream correctly
    /// written (measured — see `UpstreamResult`).
    private func upstreamResult(
        asked: Bool, outcome: PushOutcome, branch: String, remote: String, remoteRef: String,
        at root: URL
    ) async -> UpstreamResult {
        guard asked else { return .notRequested }
        if case .rejected = outcome { return .notRequested }
        do {
            // A branch name reaching here has been through `requireRefspecSide`, so it cannot
            // begin with a `-` and the key cannot be read as an option.
            let configuredRemote = try await configValue("branch.\(branch).remote", at: root)
            let configuredMerge = try await configValue("branch.\(branch).merge", at: root)
            return configuredRemote == remote && configuredMerge == remoteRef ? .set : .notSet
        } catch {
            return .unknown
        }
    }

    /// One configuration value, trimmed, or `""` when the key is not set — which `--get`
    /// reports with exit 1 rather than with a message, and which is a legitimate answer here.
    private func configValue(_ key: String, at root: URL) async throws -> String {
        let data = try await run(["config", "--get", key], cwd: root, allowedExitCodes: [1])
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A network failure in Gitter's words when the parser recognises one, and in git's own —
    /// redacted, because a remote URL can carry a token — when it does not.
    ///
    /// Unlike `fetch`, there is no partial-success case to guard against: one push is one
    /// operation against one remote, so a single diagnosed cause is always the whole truth.
    private func diagnosed(exitCode: Int32, stderr: String) -> Error {
        RemoteFailureParser.parse(stderr: stderr)
            ?? GitError.commandFailed(
                exitCode: exitCode, stderr: RemoteFailureParser.gitsOwnWords(stderr))
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
