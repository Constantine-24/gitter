import Foundation

/// `GitRemoteBackend`'s read-only half: fetch, and the two reads the confirmation sheets for
/// the *writing* half are built out of. See the protocol for the contract; this file is about
/// how the argument vectors are spelled and how a failure is turned into words.
extension CLIGitBackend: GitRemoteBackend {
    public func fetch(
        remote: String?, at root: URL, progress: @escaping @Sendable (String) -> Void
    ) async throws {
        // Each vector is a COMPLETE array literal beginning with `"fetch"`, rather than
        // assembled — `ForceFlagScannerTests` classifies a vector by its first literal element
        // and reads the rest against `fetch`'s deny table, and an `append` or a `+` would hide
        // the arguments from it entirely. Both are pinned there, character for character, by
        // `allowsTheRemoteOperationsThisMilestoneNeeds`.
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
        //
        // **And no fetch runs under a refspec that writes outside `refs/remotes/`** — see
        // `FetchRefspec` for what one did, and the protocol for the two paths below.
        if let remote {
            try requireRemoteName(remote)
            if let refspec = try await unsafeFetchRefspec(of: remote, at: root) {
                throw RemoteOperationError.unsafeFetchRefspec(remote: remote, refspec: refspec)
            }
            // After the refspec check: `remote -v` fails on a refspec git cannot parse, and that
            // refspec's own refusal is the better answer.
            try await requireRemoteURL(remote, forPushing: false, at: root)
            try await runFetch(Self.fetchVector(remote), at: root, progress: progress)
            return
        }

        let (safe, skipped, withoutURL) = try await remotesForFetchAll(at: root)
        guard let firstSkipped = skipped.first else {
            // Fix round 1, I1: `--all` visits a remote with no fetch URL too and uses its name as
            // a path, so with one configured the rest are fetched one by one and it is skipped.
            if !withoutURL.isEmpty {
                try await fetchEach(safe, at: root, progress: progress)
                return
            }
            try await runFetch(
                ["fetch", "--progress", "--no-prune", "--all"], at: root, progress: progress)
            return
        }

        // Some remote would write outside `refs/remotes/`: every other one is fetched on its
        // own, with the single-remote vector, in `git remote -v`'s order, and the skip is
        // thrown at the end. Like `--all`, a remote that fails does not stop the ones after
        // it, and git's own words for every failure are thrown instead of the skip — they are
        // what `--all` would have said, and the skip is still there to be reported by the next
        // fetch. A cancellation stops the loop at once.
        try await fetchEach(safe, at: root, progress: progress)
        throw RemoteOperationError.unsafeFetchRefspec(
            remote: firstSkipped.remote, refspec: firstSkipped.refspec)
    }

    /// The one-by-one fallback of Fetch All: every remote in `names` with the single-remote
    /// vector, in order; a failing one does not stop the rest, and git's words for every failure
    /// are thrown at the end. A cancellation stops the loop at once.
    private func fetchEach(
        _ names: [String], at root: URL, progress: @escaping @Sendable (String) -> Void
    ) async throws {
        var failures: [String] = []
        var lastCode: Int32 = 1
        for name in names {
            do {
                _ = try await runStreaming(Self.fetchVector(name), cwd: root, progress: progress)
            } catch GitError.commandFailed(let code, let stderr) {
                lastCode = code
                failures.append(RemoteFailureParser.gitsOwnWords(stderr))
            }
        }
        if !failures.isEmpty {
            throw GitError.commandFailed(
                exitCode: lastCode, stderr: failures.joined(separator: "\n"))
        }
    }

    /// The one-remote vector, a complete literal the scanner reads (see `fetch`).
    private static func fetchVector(_ remote: String) -> [String] {
        ["fetch", "--progress", "--no-prune", "--end-of-options", remote]
    }

    /// Runs one fetch vector and turns a failure into words.
    private func runFetch(
        _ arguments: [String], at root: URL, progress: @escaping @Sendable (String) -> Void
    ) async throws {
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
                    exitCode: code, stderr: RemoteFailureParser.gitsOwnWords(stderr))
            }
            throw failure
        }
    }

    /// The first of `remote`'s configured fetch refspecs that would write outside
    /// `refs/remotes/`, or nil. Read with `git config --get-all remote.<name>.fetch`, which
    /// exits 1 when the key is not set — a remote with no refspec fetches into `FETCH_HEAD`
    /// only. Any other failure is thrown: a fetch whose refspecs could not be read is not run.
    ///
    /// Internal rather than private since B2 Task 1: a prune's dry-run listing is refused under
    /// the same refspecs, for the same reason (a mirror remote lists local branches, R3).
    func unsafeFetchRefspec(of remote: String, at root: URL) async throws -> String? {
        let data = try await run(
            ["config", "--get-all", "remote." + remote + ".fetch"], cwd: root,
            allowedExitCodes: [1])
        // Cut at the `\n` byte: a value ending in a raw `\r` would otherwise be glued to the
        // next one (see `GitLines`).
        return FetchRefspec.firstUnsafe(GitLines.split(data))
    }

    /// The remotes `git fetch --all` visits, split into the ones that may be fetched and the
    /// ones whose refspecs would write outside `refs/remotes/`.
    ///
    /// **Every name `git remote -v` prints**, the name-only line of a remote with no URL
    /// included: measured on git 2.54, `--all` visits such a remote too (and tries the name as
    /// a path). The names are read here, from the same lines `RemoteParser` reads. A remote with
    /// `remote.<name>.skipFetchAll=true` is one `--all` never fetches, so it is dropped from
    /// **both** lists, safe or not, before its refspecs are looked at: an unsafe one is no
    /// reason to leave `--all`, and a safe one must not be fetched by the one-by-one fallback
    /// either (re-review: it was, on every tick). With no unsafe remote left, the plain `--all`
    /// runs, and git itself honours the setting there.
    ///
    /// **And a remote with no fetch URL is in neither list but the third** (fix round 1, I1 —
    /// a hazard older than B2): `--all` visits it and git uses its **name as a path**, which
    /// fetched from a nested checkout of that name (measured). It is skipped, silently: nothing
    /// can be fetched through it, and the sidebar says it has no URL.
    private func remotesForFetchAll(
        at root: URL
    ) async throws -> (safe: [String], skipped: [(remote: String, refspec: String)], withoutURL: [String]) {
        // Cut at the `\n` byte only: a remote's name may hold a `\r`, U+0085 or U+2028, and a
        // name cut in two is a remote whose refspecs are never read (see `GitLines`).
        var names: [String] = []
        var withFetchURL: Set<String> = []
        for line in GitLines.split(try await run(["remote", "-v"], cwd: root)) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let name = String(line[..<tab])
            if !name.isEmpty, !names.contains(name) { names.append(name) }
            if line.hasSuffix(" (fetch)") { withFetchURL.insert(name) }
        }
        var withoutURL: [String] = []
        var safe: [String] = []
        var skipped: [(remote: String, refspec: String)] = []
        for name in names {
            let skipsAll = try await run(
                ["config", "--type=bool", "--get", "remote." + name + ".skipFetchAll"],
                cwd: root, allowedExitCodes: [1])
            if String(decoding: skipsAll, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
            {
                continue
            }
            if !withFetchURL.contains(name) {
                withoutURL.append(name)
            } else if let refspec = try await unsafeFetchRefspec(of: name, at: root) {
                skipped.append((name, refspec))
            } else {
                safe.append(name)
            }
        }
        return (safe, skipped, withoutURL)
    }

    public func commits(
        in revision: String, notIn base: String, limit: Int, at root: URL
    ) async throws -> [Commit] {
        try requireRevision(revision)
        try requireRevision(base)
        // And then the check only this pair needs: both go into ONE `<base>..<revision>`
        // argument, so either of them being range syntax makes a different question. See
        // `requireRefNameOrObjectName`.
        try requireRefNameOrObjectName(revision)
        try requireRefNameOrObjectName(base)

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
        // `refs/remotes/<name>` is handed to `rev-list` as a **revision**, so a name carrying
        // range or revision syntax asks a different question — `origin/a..main` becomes a range
        // and the count comes back 0, which is "nothing would be lost".
        try requireRefNameOrObjectName(remoteBranch)

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
        // The symbolic refs are excluded too, and they are **named** rather than globbed. See
        // `symbolicRemoteRefs` for why a symref must be excluded at all and what the `*/HEAD`
        // glob that used to stand here got wrong in both directions.
        var arguments = [
            "rev-list", "--count", "refs/remotes/" + remoteBranch, "--not", "--branches",
            "--tags", "--exclude=" + remoteBranch,
        ]
        for symref in try await symbolicRemoteRefs(at: root) {
            arguments.append("--exclude=" + symref)
        }
        // Last, because every `--exclude` above applies to the `--branches`/`--tags`/`--remotes`
        // that *follows* it — and these ones are all about the remote-tracking namespace.
        arguments.append("--remotes")
        return try await revListCount(arguments, at: root)
    }

    /// Every symbolic ref under `refs/remotes`, as an `--exclude` pattern in the `--remotes`
    /// namespace (`origin/HEAD`, not `refs/remotes/origin/HEAD`).
    ///
    /// **Why any of them must be excluded.** `rev-list --remotes` lists a symref as a ref of its
    /// own, so `refs/remotes/origin/HEAD` pointing at `refs/remotes/origin/topic` *covers*
    /// `origin/topic`'s commits: measured on git 2.54, the count came back **0** for a deletion
    /// that would strand three commits. A symref holds nothing on its own — delete the branch
    /// and it dangles — so it is never a second holder.
    ///
    /// **Why by name and not `--exclude=*/HEAD`, which is what used to stand here.** That glob
    /// was defended with "it costs nothing, `HEAD` is not a valid branch name". Only a
    /// **whole-name** `HEAD` is refused. Measured on git 2.54:
    ///
    /// ```
    /// $ git check-ref-format --branch HEAD    → fatal: 'HEAD' is not a valid branch name
    /// $ git check-ref-format --branch x/HEAD  → x/HEAD      (exit 0)
    /// $ git branch x/HEAD                     → (exit 0)
    /// ```
    ///
    /// and `*` in an `--exclude` pattern crosses `/`. So the glob was wrong **both** ways, and
    /// only one of them is the safe direction:
    ///
    /// | fixture (true answer) | `--exclude=*/HEAD` | one `--exclude` per symref |
    /// |---|---|---|
    /// | `origin/HEAD` → the branch (3) | 3 | 3 |
    /// | a real `refs/remotes/other/x/HEAD` holding them (0) | **3** — over-counts | 0 |
    /// | a symref `refs/remotes/origin/default` → the branch (3) | **0** — *under*-counts | 3 |
    ///
    /// The third row is the one that decided it. An over-count only over-warns; an under-count
    /// tells the user nothing will be lost when three commits will be, and `*/HEAD` gives that
    /// answer for any symref whose last component is not `HEAD` — which `git symbolic-ref` will
    /// happily make. Naming the symrefs is exact in all three rows, costs one `for-each-ref`,
    /// and is what this does.
    ///
    /// A dangling symref (its target deleted) is simply **not listed** by `for-each-ref`
    /// (measured), which is the right answer: it holds nothing, so there is nothing to exclude.
    /// A ref name cannot contain `*`, `?` or `[` (git's own `check-ref-format` forbids them), so
    /// a name read back from here is always a literal pattern and never a glob of its own.
    ///
    /// Internal rather than private since B2 Task 1: the prune's stranded union excludes them
    /// the same way (R5).
    func symbolicRemoteRefs(at root: URL) async throws -> [String] {
        // `%(symref)` is empty for an ordinary ref and holds the target for a symbolic one. The
        // two fields are separated by a NUL because a ref name may contain neither that nor a
        // newline, so both splits below are exact.
        //
        // The separator is written as git's own `%00` escape and **not** as a Swift `"\u{0}"`:
        // a process argument is a C string, so a NUL inside one cannot survive the exec — it is
        // an `NSInvalidArgumentException` out of `Process` rather than a truncated argument
        // (seen, in this very function, before this comment existed). `%00` is an argument of
        // four printable characters that git expands into the byte, on its side.
        let data = try await run(
            ["for-each-ref", "--format=%(refname)%00%(symref)", "--end-of-options",
             "refs/remotes"],
            cwd: root)
        let prefix = "refs/remotes/"
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[1].isEmpty, fields[0].hasPrefix(prefix) else {
                return nil
            }
            let pattern = fields[0].dropFirst(prefix.count)
            return pattern.isEmpty ? nil : String(pattern)
        }
    }

    /// Refuses an argument that is a **revision** where a ref name or a plain object name is
    /// what the caller meant.
    ///
    /// The two counting/listing functions above take *names* — `refs/heads/main`,
    /// `origin/topic`, `HEAD`, a sha — and spell them into a bigger revision argument
    /// themselves. `requireName`/`requireRevision` only ask that the string be non-empty and
    /// not look like an option, which is not enough here, because git's revision language turns
    /// a name that reached these functions into a *different question* with no error anywhere:
    ///
    /// | argument | what git was actually asked | answer |
    /// |---|---|---|
    /// | `base = "refs/heads/main."` | `refs/heads/main...<revision>` — the **symmetric** difference | commits from both sides |
    /// | `revision = "a..b"` | `<base>..a..b` | a range nobody chose |
    /// | `remoteBranch = "origin/a..main"` | `refs/remotes/origin/a..main`, a range | **0**, i.e. "nothing would be lost" |
    ///
    /// So six shapes are refused: `..` (and, with it, the `...` a stray dot composes),
    /// `^` (exclusion and parent), `~` (ancestry), `:` (`<rev>:<path>`), `@{…}` (reflog and
    /// `@{upstream}`), and a leading or trailing `.` — which is dangerous only because this
    /// code writes a `..` next to it, from either side depending on which parameter it is.
    ///
    /// **The accepted forms, written down because refusing too much would break a caller**: a
    /// full ref name (`refs/heads/main`, `refs/remotes/origin/main`), a short remote-tracking
    /// name (`origin/main`), `HEAD`, and a full object name. All four are tested
    /// (`theFormsCallersLegitimatelyPassAreStillAccepted`). Everything refused here is
    /// something git's own `check-ref-format` refuses in a ref name too, so no real ref is lost;
    /// what is closed is the gap between a string that reached this function and a ref that
    /// exists.
    ///
    /// `BranchOperationError.invalidName`, thrown before git runs, so the refusal is a true
    /// no-op and the caller is told which argument was wrong.
    ///
    /// Not `private`: `rebase(onto:at:)` asks the same question of its upstream, which git
    /// would otherwise read as a revision (`origin/main~1` is accepted, measured).
    func requireRefNameOrObjectName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.revisionOperators.contains(where: trimmed.contains),
            !trimmed.hasPrefix("."), !trimmed.hasSuffix(".")
        else {
            throw BranchOperationError.invalidName(name)
        }
    }

    private static let revisionOperators = ["..", "^", "~", ":", "@{"]

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
    /// Refuses a **configured** remote git has no URL for — no URL at all, or, for a fetch or a
    /// read of its refs (`pushing == false`), only a push URL: git would use the remote's name as
    /// a path (fix round 1, I1, measured: `git fetch vendor` fetched a nested checkout called
    /// `vendor`, and `git push vendor :refs/heads/topic` deleted its branch).
    /// `RemoteOperationError.noURL`, after one read of `git remote -v` and before any fetch, push
    /// or `ls-remote`. A name that is no configured remote at all is left to git's own diagnosis,
    /// as before (`anUnknownRemoteIsGitsOwnDiagnosis`).
    func requireRemoteURL(_ remote: String, forPushing pushing: Bool, at root: URL) async throws {
        let listed = RemoteParser.parse(String(decoding: try await run(["remote", "-v"], cwd: root), as: UTF8.self))
        guard let entry = listed.first(where: { $0.name == remote }) else { return }
        guard (pushing ? entry.pushURL : entry.fetchURL) != nil else { throw RemoteOperationError.noURL(remote) }
    }

    func requireRemoteName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-"), trimmed != "." else {
            throw RemoteOperationError.noRemote
        }
    }
}
