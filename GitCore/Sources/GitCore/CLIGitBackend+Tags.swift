import Foundation

/// Tags (B1 Task 2). See `GitTagBackend` for the contract; this file is about how each vector
/// is spelled, what is refused before git runs, and how git's answers are read.
///
/// Every vector below is pinned whole in `ForceFlagScannerTests.allowsTheTagVectorsThisMilestoneNeeds`,
/// which is why the local bindings are named as they are (`n`, `id`, `expected`): the contract is
/// the text. `tag` and `update-ref` are shape-governed there — these are their only forms.
///
/// **Measured for this task (git 2.54, `LC_ALL=C`, scratch repositories):**
/// - `receive.denyDeletes=true` on a local bare remote (B21 left it unexplained) **is**
///   enforced — for `refs/heads/` only: a branch delete is `[remote rejected] (deletion
///   prohibited)`, while a tag, annotated or not, leased or not, and a `refs/custom/x` are
///   `[deleted]`. git's receive-pack checks the prefix; its documentation says "a ref". The
///   same over `file://`. So a server cannot protect its tags with it — the lease and the
///   confirmation are what guard a remote tag (`TagRemoteTests`).
/// - Gitter's fetch under `remote.<r>.tagOpt=--tags`, with a tag the remote moved: exit 1, the
///   other refs updated, and ` ! [rejected] <t> -> <t>  (would clobber existing tag)` on stderr.
///   `RemoteFailureParser` recognises none of it, so the fetch throws `GitError.commandFailed`
///   carrying git's own (redacted) words; the local tag is kept (B22, `TagRemoteTests`).
/// - `%(contents:subject)` is one line whatever the message: git joins the first paragraph's
///   lines with a space, CR LF included — so the shared ref format could take it (see
///   `refFormat`).
/// - On APFS (case-insensitive) `git tag LIGHT` beside `light` is "tag 'LIGHT' already exists",
///   and `refs/tags/LIGHT` then resolves to `light`: names are compared folded.
/// - A name of 7+ hexadecimal digits in UPPER case is an abbreviated object id to git too.
/// - `ls-remote` takes `--end-of-options`; with `--exit-code` a missing ref exits 2, silent.
/// - `-F` of an empty file with `--cleanup=verbatim` makes a tag with an empty message (exit
///   0), and a message without a final newline is stored without one.
extension CLIGitBackend: GitTagBackend {

    // MARK: - Names

    public func tagNameProblem(_ name: String, at root: URL) async throws -> TagNameProblem? {
        if name.isEmpty { return .empty }
        // `HEAD` and a leading `-` pass `check-ref-format` and `git tag` refuses them; `@` git
        // takes, and then means the tag wherever the user types `@` (B17). A root-ref name
        // (`MERGE_HEAD`, `ORIG_HEAD`, `AUTO_MERGE`, …) git takes too, and then that name
        // resolves to the tag whenever the real one is absent: fix round 1 measured a tag
        // `MERGE_HEAD` making Gitter report a merge in a clean repository
        // (`operationInProgress` asks `rev-parse -q --verify MERGE_HEAD`), and a tag
        // `ORIG_HEAD` breaking `git reset`. And `stash`, folded (final fix wave I2, measured):
        // `git stash drop -q stash@{N}` resolves `stash` to the tag — "error: 'stash@{0}' is not
        // a stash reference", exit 1 — so A1's Drop, Pop's drop and the empty-stash cleanup fail
        // for every entry in the repository.
        if name == "@" || name.hasPrefix("-") || Self.isRootRefName(name)
            || Self.otherReservedNames.contains(name.uppercased())
        {
            return .reserved
        }
        // The lock file `<name>.lock` must fit in a file name (B17: 250 created, 251 "File name
        // too long").
        if name.utf8.count > 250 { return .tooLong }
        let check = try await runWithEnvironment(["check-ref-format", "refs/tags/\(name)"], cwd: root, extra: [:], allowedExitCodes: [1])
        if check.exitCode != 0 { return .invalid }
        if name.utf8.count >= 7, name.allSatisfy(Self.hexDigitsEitherCase.contains) { return .looksLikeObjectID }
        let refs = try await refNames(at: root)
        if Self.conflictsWithATag(name, refs.tags) { return .exists }
        if try await isSymbolicTagRef(name, at: root) { return .exists }
        if refs.branches.contains(name.lowercased()) { return .isBranchName }
        // A remote's name too (minor 1 of fix round 1): `origin` alone resolves to
        // `refs/remotes/origin/HEAD`, and a tag of that name wins ("refname 'origin' is
        // ambiguous"); a remote nothing was fetched from has no refs, so it comes from the
        // configuration.
        let data = try await run(["remote", "-v"], cwd: root)
        let remotes = RemoteParser.parse(String(decoding: data, as: UTF8.self)).map { $0.name.lowercased() }
        if remotes.contains(name.lowercased()) { return .isBranchName }
        return nil
    }

    /// Whether `refs/tags/<name>` is a symbolic ref — a dangling one included, which
    /// `for-each-ref` does not list and `git tag <name>` writes **through**, creating the branch
    /// it names (measured, fix round 1). Such a name is taken.
    private func isSymbolicTagRef(_ name: String, at root: URL) async throws -> Bool {
        let data = try await run(["symbolic-ref", "-q", "refs/tags/\(name)"], cwd: root, allowedExitCodes: [1])
        return !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let hexDigitsEitherCase: Set<Character> = Set("0123456789abcdefABCDEF")

    /// git's root-ref syntax (`refs.c`, `is_root_ref`): only `A`–`Z`, `_` and `-`, and either
    /// ending in `HEAD` (`HEAD`, `MERGE_HEAD`, `ORIG_HEAD`, `FETCH_HEAD`, …) or one of the five
    /// irregular ones. Compared folded, as APFS compares names: `merge_head` is the same file.
    /// `SQUASH_MSG` and `MERGE_MSG` are not refs — Gitter reads them as files through
    /// `--git-path`, and a tag of either name changes nothing (measured, fix round 1).
    static func isRootRefName(_ name: String) -> Bool {
        guard !name.isEmpty, name.unicodeScalars.allSatisfy({
            ("A"..."Z").contains($0) || ("a"..."z").contains($0) || $0 == "_" || $0 == "-"
        }) else { return false }
        let upper = name.uppercased()
        return upper.hasSuffix("HEAD") || irregularRootRefs.contains(upper)
    }

    /// Names git gives a meaning of their own that are not root refs, upper-cased as
    /// `isRootRefName` compares them: `STASH` (final review I2), which `stash@{N}` resolves to a
    /// tag before `refs/stash`. Spelled upper case on purpose: the scanner keeps the lower-case
    /// literal for A1's stash vectors, and git's subcommands are case-sensitive, so this one can
    /// never run as one.
    private static let otherReservedNames: Set<String> = ["STASH"]

    private static let irregularRootRefs: Set<String> = [
        "AUTO_MERGE", "BISECT_EXPECTED_REV", "NOTES_MERGE_PARTIAL", "NOTES_MERGE_REF", "MERGE_AUTOSTASH",
    ]

    /// The short names of every local and remote-tracking branch, and every tag's, folded to
    /// lower case — the way the file system compares them (see this file's doc comment).
    /// Internal since B2 Task 1: a kept branch's name is checked against the same three sets.
    func refNames(at root: URL) async throws -> (branches: Set<String>, tags: [String]) {
        let data = try await run(["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes", "refs/tags"], cwd: root)
        var branches = Set<String>()
        var tags: [String] = []
        for ref in GitLines.split(data) {
            if ref.hasPrefix("refs/tags/") {
                tags.append(String(ref.dropFirst("refs/tags/".count)).lowercased())
            } else if ref.hasPrefix("refs/heads/") {
                branches.insert(String(ref.dropFirst("refs/heads/".count)).lowercased())
            } else if ref.hasPrefix("refs/remotes/") {
                branches.insert(String(ref.dropFirst("refs/remotes/".count)).lowercased())
            }
        }
        return (branches, tags)
    }

    /// A tag of this name, ignoring case — or one a path level above or below it (`a` beside
    /// `a/b`), which git cannot store beside it either.
    private static func conflictsWithATag(_ name: String, _ tags: [String]) -> Bool {
        let folded = name.lowercased()
        return tags.contains { $0 == folded || $0.hasPrefix(folded + "/") || folded.hasPrefix($0 + "/") }
    }

    /// The check a name that is already a tag gets before it is written into an argument:
    /// nothing that would change what the argument means. `refs/tags/\(n):refs/tags/\(n)` is a
    /// refspec, so a `*` makes it a pattern (every tag) and a `:` another refspec; an
    /// `ls-remote` argument is a pattern too. git's own ref-name rules forbid every character
    /// refused here, so no tag that really exists is refused (a name beginning with `-` is
    /// allowed: it sits after `refs/tags/`).
    private static func refusingAnArgumentChangingName(_ name: String) throws {
        if name.isEmpty { throw TagOperationError.nameProblem(.empty) }
        let changesTheArgument = name.contains("..") || name.contains("@{")
            || name.unicodeScalars.contains {
                ":*?[\\^~".unicodeScalars.contains($0) || $0.properties.isWhitespace
                    || $0.value < 0x20 || $0.value == 0x7F
            }
        if changesTheArgument { throw TagOperationError.nameProblem(.invalid) }
    }

    // MARK: - Create, delete, restore

    public func createTag(_ name: String, at sha: String, message: String?, at root: URL) async throws {
        // The target first: it needs no process, so a bad one is refused before git runs.
        guard Self.isFullNonZeroObjectName(sha) else { throw TagOperationError.invalidObjectID(sha) }
        if let problem = try await tagNameProblem(name, at: root) { throw TagOperationError.nameProblem(problem) }

        // `--no-sign` beats `tag.gpgSign=true`, which would otherwise turn even a lightweight
        // tag into a signed annotated one ("fatal: no tag message?"); with a message, the
        // explicit `-a` is what beats `tag.forceSignAnnotated=true` — without it `--no-sign`
        // loses (B17). The name and target follow `--end-of-options`. A failure — a
        // reference-transaction hook, a tag made in a terminal a moment ago ("already exists")
        // — is git's words, and git made nothing.
        guard let message else {
            _ = try await run(["tag", "--no-sign", "--end-of-options", name, sha], cwd: root)
            return
        }
        // Through a file, so the message is bytes rather than an argument; `--cleanup=verbatim`
        // because `-F` otherwise strips every line starting with `#` (B17) — and the message is
        // stored exactly as the sheet showed it, with one final newline as git's own have.
        let text = message.isEmpty || message.hasSuffix("\n") ? message : message + "\n"
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gitter-tag-message-\(UUID().uuidString)")
        try Data(text.utf8).write(to: file, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await run(["tag", "--no-sign", "-a", "-F", file.path, "--cleanup=verbatim", "--end-of-options", name, sha], cwd: root)
    }

    public func deleteTag(_ tag: Tag, at root: URL) async throws -> TagReceipt {
        // Before anything runs: an empty or all-zero expected value turns `update-ref -d` into
        // a delete with no check at all (B19), and a short one is resolved by git, not compared.
        let expected = tag.objectID
        guard Self.isFullNonZeroObjectName(expected) else { throw TagOperationError.invalidObjectID(expected) }
        let name = tag.name
        try Self.refusingAnArgumentChangingName(name)
        // A symbolic ref names a branch (or any ref): Restore could not bring it back, and its
        // `objectID` is that ref's tip, which moves with it. Refused (fix round 1, I2).
        if tag.isSymbolic { throw TagOperationError.symbolicTag(name: name) }

        // `tag -d` has no expected value; this is the atomic compare-and-delete, on the tag
        // **object** for an annotated tag (B19). Every exit code is read: git refused, and what
        // the ref holds now says whether it moved.
        //
        // `--no-deref`: had the tag become a symbolic ref since the listing, a plain `-d`
        // follows it and deletes the **branch** it names, leaving the symbolic ref dangling and
        // hidden (fix round 1, measured). With it, git deletes the symbolic ref itself — still
        // compared against the id it resolves to (a wrong one: "is at … but expected …") — and
        // the branch and its reflog stay.
        let result = try await runWithEnvironment(["update-ref", "--no-deref", "-d", "--end-of-options", "refs/tags/\(name)", "\(expected)"], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
        guard result.exitCode != 0 else { return TagReceipt(name: name, objectID: expected, target: tag.sha) }
        if try await currentTagObject(name, at: root) != expected { throw TagOperationError.tagMoved(name: name) }
        // Still there, unchanged: refused for a reason of git's — a reference-transaction hook
        // ("in 'prepared' phase, update aborted by the reference-transaction hook").
        throw GitError.commandFailed(
            exitCode: result.exitCode, stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func restoreTag(_ receipt: TagReceipt, at root: URL) async throws {
        guard Self.isFullNonZeroObjectName(receipt.objectID) else {
            throw TagOperationError.invalidObjectID(receipt.objectID)
        }
        try Self.refusingAnArgumentChangingName(receipt.name)
        // Only `.exists` of the name checks: the name was this tag a moment ago. A symbolic ref
        // in its place — even a dangling one — is a taken name: `git tag` would write through
        // it, onto the branch it names (fix round 1, I2).
        let taken = Self.conflictsWithATag(receipt.name, try await refNames(at: root).tags)
        let symbolic = try await isSymbolicTagRef(receipt.name, at: root)
        if taken || symbolic { throw TagOperationError.nameProblem(.exists) }
        // The lightweight create, naming the tag **object**: `refs/tags/<name>` then holds that
        // same object, so the identical annotated tag is back (B19). No message, so no signing
        // config applies (B17), and `--no-sign` all the same.
        _ = try await run(["tag", "--no-sign", "--end-of-options", receipt.name, receipt.objectID], cwd: root)
    }

    /// What `refs/tags/<name>` holds now, or "" when there is no such tag.
    private func currentTagObject(_ name: String, at root: URL) async throws -> String {
        let data = try await run(["rev-parse", "--verify", "-q", "refs/tags/\(name)"], cwd: root, allowedExitCodes: [1])
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Remote

    public func remoteTagID(_ name: String, on remote: String, at root: URL) async throws -> String? {
        try Self.refusingAnArgumentChangingName(name)
        try requireRemoteName(remote)
        let n = name
        // Unpeeled: with a pattern `ls-remote` prints no `^{}` line (B21), and the tag object is
        // what a lease on an annotated tag must name. Exit 2 is `--exit-code`'s "no such ref".
        try await requireRemoteURL(remote, forPushing: false, at: root)
        let result: ProcessRunner.StreamedResult
        do {
            result = try await runStreaming(["ls-remote", "--exit-code", "--end-of-options", remote, "refs/tags/\(n)"], cwd: root, allowedExitCodes: [2], progress: { _ in })
        } catch GitError.commandFailed(let code, let stderr) {
            throw diagnosed(exitCode: code, stderr: stderr)
        }
        guard result.exitCode == 0 else { return nil }
        // A pattern matches from the tail (`refs/heads/refs/tags/<n>` too), so only the line
        // for exactly this ref counts.
        for line in GitLines.split(result.stdout) {
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if fields.count == 2, fields[1] == "refs/tags/\(n)", Self.isFullNonZeroObjectName(fields[0]) {
                return fields[0]
            }
        }
        return nil
    }

    public func pushTag(_ name: String, to remote: String, at root: URL) async throws -> TagPushOutcome {
        try Self.refusingAnArgumentChangingName(name)
        try requireRemoteName(remote)
        let n = name
        // Full ref names on both sides (a short `v1` is "matches more than one" beside a branch
        // `v1`, B20), never `+`, and `--no-follow-tags`: `push.followTags=true` pushed every
        // annotated tag on the pushed commits besides this one (B20). `remote.<r>.push` and
        // `push.default=matching` add nothing to an explicit refspec (measured, B20).
        try await requireRemoteURL(remote, forPushing: true, at: root)
        let arguments = ["push", "--porcelain", "--no-follow-tags", "--no-recurse-submodules", "--end-of-options", remote, "refs/tags/\(n):refs/tags/\(n)"]
        let streamed = try await runStreaming(arguments, cwd: root, allowedExitCodes: Self.anyExitCode, progress: { _ in })

        let stdout = String(decoding: streamed.stdout, as: UTF8.self)
        guard let result = PushPorcelainParser.resultLine(stdout: stdout, destinationRef: "refs/tags/\(n)") else {
            // No line for the tag: git refused before talking to the server — a `pre-push`
            // hook, `remote.<r>.mirror=true` (exit 128), a local tag that does not exist — or
            // the network failed. Only the last is Gitter's to word.
            if let failure = RemoteFailureParser.parse(stderr: streamed.stderr) { throw failure }
            return .failed(gitsWords: Self.words(streamed.stderr))
        }
        switch (result.flag, result.summary) {
        case ("*", "[new tag]"): return .pushed
        case ("=", "[up to date]"): return .alreadyThere
        case ("!", "[rejected] (already exists)"): return .rejectedExists
        default:
            // A server hook declining (`[remote rejected] (hook declined)`) and anything git has
            // not been seen to print: the line, then git's words.
            return .failed(gitsWords: Self.words(result.line, streamed.stderr))
        }
    }

    public func deleteRemoteTag(_ name: String, on remote: String, expecting id: String, at root: URL) async throws {
        try Self.refusingAnArgumentChangingName(name)
        try requireRemoteName(remote)
        // The lease is the whole safety of this delete: a short, empty or all-zero value is
        // refused before git runs (`RemoteOperationError.invalidLease`), and the full one is the
        // unpeeled id `remoteTagID` read — the peeled commit is stale (B21). Without a lease a
        // missing tag even "succeeds" (B21).
        try requireFullObjectName(id)
        let n = name
        try await requireRemoteURL(remote, forPushing: true, at: root)
        let arguments = ["push", "--porcelain", "--no-follow-tags", "--no-recurse-submodules", "--force-with-lease=refs/tags/\(n):\(id)", "--end-of-options", remote, ":refs/tags/\(n)"]
        let streamed = try await runStreaming(arguments, cwd: root, allowedExitCodes: Self.anyExitCode, progress: { _ in })

        let stdout = String(decoding: streamed.stdout, as: UTF8.self)
        let destination = "refs/tags/\(n)"
        guard let result = PushPorcelainParser.resultLine(stdout: stdout, destinationRef: destination),
            let outcome = PushPorcelainParser.parse(stdout: stdout, destinationRef: destination)
        else {
            throw diagnosed(exitCode: streamed.exitCode, stderr: streamed.stderr)
        }
        switch outcome {
        case .deleted: return
        case .rejected(.staleLease): throw TagOperationError.remoteTagMoved(name: name, remote: remote)
        default:
            throw GitError.commandFailed(exitCode: streamed.exitCode, stderr: Self.words(result.line, streamed.stderr))
        }
    }

    public func remotesFetchingNoTags(at root: URL) async throws -> [String] {
        // `-z`: each entry is `<key>\n<value>\0`. The key's section and variable come back
        // lower-cased, its subsection — the remote's name, which may hold dots — as written.
        // Exit 1 is "no such key". Entries come in file order, so a later value replaces an
        // earlier one, as git reads it.
        let data = try await run(["config", "-z", "--get-regexp", "^remote[.].*[.]tagopt$"], cwd: root, allowedExitCodes: [1])
        var last: [String: String] = [:]
        for entry in data.split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let newline = text.firstIndex(of: "\n") else { continue }
            let key = text[..<newline]
            let value = text[text.index(after: newline)...]
            guard key.hasPrefix("remote."), key.hasSuffix(".tagopt") else { continue }
            let name = String(key.dropFirst("remote.".count).dropLast(".tagopt".count))
            guard !name.isEmpty else { continue }
            last[name] = String(value)
        }
        return last.filter { $0.value == "--no-tags" }.keys.sorted()
    }

    /// git's words, redacted (a remote URL can carry a credential): the lines given, in order,
    /// without blank ones and the askpass noise.
    private static func words(_ texts: String...) -> String {
        texts.map(RemoteFailureParser.gitsOwnWords)
            .flatMap { $0.split(separator: "\n") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
