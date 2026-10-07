import Foundation

/// Remote management (B2 Task 3): names, URLs as written, add, set-url, rename, the removal's
/// impact, and the read-back of a failed rename or removal. See `GitRemoteAdminBackend` for the
/// contract; this file is about how each vector is spelled, what is refused before git runs,
/// and how git's answers are read.
///
/// Every vector is pinned in `ForceFlagScannerTests.allowsTheRemoteManagementVectorsThisMilestoneNeeds`,
/// and the bindings are named as they are there (`name`, `url`, `remote`, `old`, `new`, `key`):
/// the contract is the text. The four writes are `remote`'s shapes (`allowedShapes`), each whole.
///
/// **Measured for this task (git 2.54, `LC_ALL=C`, scratch repositories, `GIT_ALLOW_PROTOCOL=file`,
/// `GIT_SSH_COMMAND=/usr/bin/false`, no ssh agent):**
/// - VERIFY: `ls-remote --get-url --end-of-options <n>` prints the `insteadOf`-rewritten URL
///   (`https://example.invalid/o/r.git` → `git@example.invalid:o/r.git`) and exits 0 for
///   https, ssh, scp-like, credential-carrying, `file://` and path URLs, with `GIT_TRACE`
///   showing no child process, while a contacting `ls-remote` of the same URL under the same
///   guards fails `transport '…' not allowed`. For a remote with no URL — and for a name that is
///   no remote at all — it prints the name itself, so it is asked only when a URL is configured.
/// - `check-ref-format refs/remotes/<n>/test` refuses exactly the names `remote add` refuses as
///   "not a valid remote name" (`.`, `a..b`, `x.lock`, `trail/`, a space, `@{x`) and accepts the
///   rest (`HEAD`, `@`, `-x`, `refs/x`, `ü`). Nesting is refused both ways: "is a subset of
///   existing remote 'u'" and "is a superset of existing remote 'up/stream'". `U` beside `u` is
///   accepted (a case-insensitive volume then shares their refs).
/// - `remote rename` under a held ref lock, `packed-refs.lock` or a refusing
///   `reference-transaction` hook: exit 128, the section renamed, its refspec and the branch
///   settings still naming the old remote, no ref moved. Renaming the new name back then
///   restores the configuration and refs exactly (one warning, "Not updating non-default fetch
///   refspec"). Under `config.lock`: exit 1, nothing changed.
/// - `remote remove` under a held ref lock or `packed-refs.lock`: exit 1, every
///   `branch.<b>.remote`/`.merge`/`.pushremote` naming it unset, the section and every ref kept
///   (one transaction: none deleted); removing again succeeds. A refusing hook: exit 128, the same.
///   Under `config.lock`: exit 128, nothing changed. It deletes exactly the `refs/remotes/` refs
///   its refspecs map (a negative refspec honoured) that no other remote's refspecs map.
/// - `set-url --push` on a remote with several `pushurl` values fails as `set-url` does on
///   several `url` values (`… has multiple values`, exit 128).
extension CLIGitBackend {

    // MARK: - Names

    public func remoteNameProblem(_ name: String, at root: URL) async throws -> RemoteNameProblem? {
        if let problem = Self.remoteNameProblemBeforeGit(name) { return problem }
        // git's own rule, as git asks it (`valid_remote_name`).
        let result = try await runWithEnvironment(["check-ref-format", "refs/remotes/\(name)/test"], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
        guard result.exitCode == 0 else { return .invalid }
        if name == "HEAD" || name == "@" { return .reserved }
        let folded = name.lowercased()
        let existing = try await configuredRemoteNames(at: root).sorted()
        if existing.contains(where: { $0.lowercased() == folded }) { return .exists }
        let nested = existing.first { other in
            let otherFolded = other.lowercased()
            return folded.hasPrefix(otherFolded + "/") || otherFolded.hasPrefix(folded + "/")
        }
        return nested.map { .nested($0) }
    }

    /// The problems a name has that need no git: empty, a leading `-`, a control character —
    /// the last also because a NUL cannot be passed to a process at all.
    static func remoteNameProblemBeforeGit(_ name: String) -> RemoteNameProblem? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if name.hasPrefix("-") || name.unicodeScalars.contains(where: isControl) { return .invalid }
        return nil
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
    }

    // MARK: - URLs

    /// A URL Gitter does not write (`RemoteAdminRefusal.unsafeURL`): empty or blank; beginning
    /// with `-`, before or after leading blanks (an option to the transport that reads it); an
    /// `ext::` command line, in any case; a control character (a newline would also split
    /// `git remote -v`'s line).
    static func isUnsafeURL(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("-") || trimmed.lowercased().hasPrefix("ext::")
            || url.unicodeScalars.contains(where: isControl)
    }

    public func remoteURLs(_ remote: String, at root: URL) async throws -> RemoteURLs {
        try requireRemoteName(remote)
        try await requireConfiguredRemote(remote, at: root)
        return try await configuredURLs(of: remote, at: root)
    }

    /// `remote`'s URLs as written, and the effective first one.
    private func configuredURLs(of remote: String, at root: URL) async throws -> RemoteURLs {
        let fetch = try await configValuesSeparatedByNUL("remote.\(remote).url", at: root)
        let push = try await configValuesSeparatedByNUL("remote.\(remote).pushurl", at: root)
        var effective: String?
        if let first = fetch.first, !first.isEmpty {
            // Contacts nothing (VERIFY, above): it applies `insteadOf` and prints.
            let data = try await run(["ls-remote", "--get-url", "--end-of-options", remote], cwd: root)
            var text = String(decoding: data, as: UTF8.self)
            if text.hasSuffix("\n") { text.removeLast() }
            effective = text.isEmpty ? nil : text
        }
        return RemoteURLs(fetch: fetch, push: push, effectiveFetch: effective)
    }

    /// Every value of `key`, NUL-separated (`--null`), so a value holding a newline stays one
    /// value; empty when the key is not set.
    private func configValuesSeparatedByNUL(_ key: String, at root: URL) async throws -> [String] {
        let data = try await run(["config", "--null", "--get-all", "--end-of-options", key], cwd: root, allowedExitCodes: [1])
        return data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map {
            String(decoding: $0, as: UTF8.self)
        }
    }

    // MARK: - Add

    public func addRemote(_ name: String, url: String, at root: URL) async throws {
        guard !Self.isUnsafeURL(url) else { throw RemoteAdminRefusal.unsafeURL }
        if let problem = try await remoteNameProblem(name, at: root) { throw RemoteAdminRefusal.nameProblem(problem) }
        let before = try await localConfigEntries(at: root)
        let result: ProcessRunner.StreamedResult
        do {
            // Never `-f` (R19): the caller fetches afterwards with Gitter's own fetch.
            result = try await runWithEnvironment(["remote", "add", "--end-of-options", name, url], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
        } catch let error where error is CancellationError || Self.wasKilledBySignal(error) {
            throw RemoteAdminPartial.urlsOutcomeUnknown(remote: name)
        }
        guard result.exitCode != 0 else { return }
        try await readBackFailedURLWrite(of: name, before: before, result: result, at: root)
    }

    // MARK: - Set URL

    public func setURLs(of remote: String, fetch: String, push change: PushURLChange, at root: URL) async throws {
        var push: String?
        if case .set(let url) = change { push = url }
        guard !Self.isUnsafeURL(fetch), !(push.map(Self.isUnsafeURL) ?? false) else {
            throw RemoteAdminRefusal.unsafeURL
        }
        try requireRemoteName(remote)
        try await requireConfiguredRemote(remote, at: root)
        let current = try await configuredURLs(of: remote, at: root)
        // Both refusals before the first write: a plain `set-url` fails on several values (R22).
        if current.fetch.count > 1 || (change != .unchanged && current.push.count > 1) {
            throw RemoteAdminRefusal.severalURLs
        }
        let before = try await localConfigEntries(at: root)
        if current.fetch != [fetch] {
            let url = fetch
            let result: ProcessRunner.StreamedResult
            do {
                result = try await runWithEnvironment(["remote", "set-url", "--end-of-options", remote, url], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
            } catch let error where error is CancellationError || Self.wasKilledBySignal(error) {
                throw RemoteAdminPartial.urlsOutcomeUnknown(remote: remote)
            }
            if result.exitCode != 0 { try await readBackFailedURLWrite(of: remote, before: before, result: result, at: root) }
        }
        if let push, current.push != [push] {
            let url = push
            let result: ProcessRunner.StreamedResult
            do {
                result = try await runWithEnvironment(["remote", "set-url", "--push", "--end-of-options", remote, url], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
            } catch let error where error is CancellationError || Self.wasKilledBySignal(error) {
                throw RemoteAdminPartial.urlsOutcomeUnknown(remote: remote)
            }
            if result.exitCode != 0 { try await readBackFailedURLWrite(of: remote, before: before, result: result, at: root) }
        }
        // Fix round 1, I3: no push URL — the remote pushes to its fetch URL again. Not `set-url
        // --push --delete` (forbidden): a config write, pinned whole in the scanner. With none
        // configured there is nothing to clear and nothing is written (git would exit 5).
        if change == .clear, !current.push.isEmpty {
            let result: ProcessRunner.StreamedResult
            do {
                result = try await runWithEnvironment(["config", "--unset-all", "--end-of-options", "remote.\(remote).pushurl"], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
            } catch let error where error is CancellationError || Self.wasKilledBySignal(error) {
                throw RemoteAdminPartial.urlsOutcomeUnknown(remote: remote)
            }
            if result.exitCode != 0 { try await readBackFailedURLWrite(of: remote, before: before, result: result, at: root) }
        }
    }

    /// A failed add or set-url is not assumed to have written nothing: the configuration is read
    /// back. Changed since `before` is `urlsChangedThenFailed` with what the remote holds now;
    /// unchanged is git's refusal (`RemoteFailureParser.remoteAdminRefusal`) or git's words.
    /// Always throws.
    private func readBackFailedURLWrite(
        of remote: String, before: [ConfigEntry], result: ProcessRunner.StreamedResult, at root: URL
    ) async throws -> Never {
        let words = RemoteFailureParser.gitsOwnWords(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        let after: [ConfigEntry]
        do {
            after = try await localConfigEntries(at: root)
        } catch {
            throw RemoteAdminPartial.urlsOutcomeUnknown(remote: remote)
        }
        if after != before {
            var now: RemoteURLs?
            if Self.configures(remote, after) { now = try? await configuredURLs(of: remote, at: root) }
            throw RemoteAdminPartial.urlsChangedThenFailed(remote: remote, now: now, gitsWords: words)
        }
        if let refusal = RemoteFailureParser.remoteAdminRefusal(stderr: result.stderr, name: remote) { throw refusal }
        throw GitError.commandFailed(exitCode: result.exitCode, stderr: words)
    }

    // MARK: - Rename

    public func renameRemote(_ old: String, to new: String, at root: URL) async throws {
        try requireRemoteName(old)
        if let problem = Self.remoteNameProblemBeforeGit(new) { throw RemoteAdminRefusal.nameProblem(problem) }
        try await requireConfiguredRemote(old, at: root)
        if let problem = try await remoteNameProblem(new, at: root) { throw RemoteAdminRefusal.nameProblem(problem) }
        let before = try await adminState(at: root)
        let result: ProcessRunner.StreamedResult
        do {
            result = try await runWithEnvironment(["remote", "rename", "--no-progress", "--end-of-options", old, new], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
        } catch let error where error is CancellationError || Self.wasKilledBySignal(error) {
            throw RemoteAdminPartial.renameOutcomeUnknown(old: old, new: new)
        }
        guard result.exitCode != 0 else { return }

        // Not assumed to be a no-op (R21): read back.
        let words = RemoteFailureParser.gitsOwnWords(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        let after: AdminState
        do {
            after = try await adminState(at: root)
        } catch {
            throw RemoteAdminPartial.renameOutcomeUnknown(old: old, new: new)
        }
        if after == before {
            if let refusal = RemoteFailureParser.remoteAdminRefusal(stderr: result.stderr, name: old) { throw refusal }
            throw GitError.commandFailed(exitCode: result.exitCode, stderr: words)
        }
        throw RemoteAdminPartial.renameHalfDone(left: Self.renameLeftover(old: old, new: new, after: after, words: words))
    }

    /// What a failed rename left, from the state read after it.
    private static func renameLeftover(old: String, new: String, after: AdminState, words: String) -> RenameLeftover {
        let oldPrefix = "refs/remotes/\(old)/"
        let newPrefix = "refs/remotes/\(new)/"
        let refspecsStillOld = after.config
            .filter { $0.key == "remote.\(new).fetch" }
            .compactMap(\.value)
            .filter { refspecDestination($0)?.hasPrefix(oldPrefix) ?? false }
        let stillNamingOld = after.config
            .filter { isRemoteNamingKey($0.key) && $0.value == old }
            .map(\.key)
        return RenameLeftover(
            old: old, new: new, configured: [old, new].filter { configures($0, after.config) },
            refspecsStillOld: refspecsStillOld, configStillNamingOld: unique(stillNamingOld),
            refsUnderOld: after.refs.map(\.ref).filter { $0.hasPrefix(oldPrefix) },
            refsUnderNew: after.refs.map(\.ref).filter { $0.hasPrefix(newPrefix) },
            gitsWords: words)
    }

    // MARK: - The removal's impact

    public func removalImpact(of remote: String, at root: URL) async throws -> RemovalImpact {
        try requireRemoteName(remote)
        let (refs, symbolic, leftBehind) = try await refsTheRemovalDeletes(remote, from: try await trackingRefs(at: root), at: root)
        // A symbolic ref holds nothing of its own (R5); its target is listed itself if it goes.
        let stranded = try await stranded(by: refs.map(\.ref).filter { !symbolic.contains($0) }, at: root)

        let config = try await scopedConfigEntries(at: root)
        let now = Self.BranchPushSettings(config, removing: nil)
        let after = Self.BranchPushSettings(config, removing: remote)
        var upstreamOf: [String] = []
        var pushRedirects: [PushRedirect] = []
        for branch in try await plainLocalBranches(at: root) {
            if now.remote[branch] == remote { upstreamOf.append(branch) }
            // git's order: `branch.<b>.pushRemote`, `remote.pushDefault`, `branch.<b>.remote`.
            let pushRemote = now.pushRemote[branch]
            guard pushRemote == remote || (pushRemote == nil && now.pushDefault == remote) else { continue }
            pushRedirects.append(PushRedirect(branch: branch, nowPushesTo: after.pushDestination(of: branch)))
        }
        return RemovalImpact(
            remote: remote, refs: refs, stranded: stranded, upstreamOf: upstreamOf,
            pushRedirects: pushRedirects, leftBehind: leftBehind)
    }

    /// What `git remote remove` deletes of `tracking`, as it decides it (R23): a `refs/remotes/`
    /// ref this remote's refspecs map and no other remote's do; which of those are symbolic; and
    /// the refs under `refs/remotes/<remote>/` it leaves that no other remote claims. Reads the
    /// remotes and their refspecs; `.noSuchRemote` when `remote` is not one of them.
    private func refsTheRemovalDeletes(
        _ remote: String, from tracking: [TrackingRef], at root: URL
    ) async throws -> (refs: [RefTip], symbolic: Set<String>, leftBehind: [String]) {
        let names = try await configuredRemoteNames(at: root)
        guard names.contains(remote) else { throw RemoteAdminRefusal.noSuchRemote(remote) }
        var refspecs: [String: [String]] = [:]
        for name in names { refspecs[name] = try await configValues("remote.\(name).fetch", at: root) }
        let others = names.filter { $0 != remote }
        var refs: [RefTip] = []
        var symbolic: Set<String> = []
        var leftBehind: [String] = []
        for ref in tracking {
            let keptByAnother = others.contains { Self.fetchRefspecsMap(ref.ref, refspecs[$0] ?? []) }
            if !keptByAnother, Self.fetchRefspecsMap(ref.ref, refspecs[remote] ?? []) {
                refs.append(RefTip(ref: ref.ref, id: ref.id))
                if !ref.symref.isEmpty { symbolic.insert(ref.ref) }
            } else if !keptByAnother, ref.ref.hasPrefix("refs/remotes/\(remote)/") {
                leftBehind.append(ref.ref)
            }
        }
        return (refs, symbolic, leftBehind)
    }

    /// Whether a fetch through `refspecs` writes `ref` — git's `remote_find_tracking`, which is
    /// what `git remote remove` asks of every ref (R23), spelled as git spells it:
    /// a negative refspec (`^<src>`) unmaps a ref whose reverse-mapped source it matches, where
    /// the reverse mapping goes through every positive pattern refspec (its destination, or its
    /// source when it has none), a matching refspec (`:`), or a literal source equal to the ref
    /// itself; then the first positive refspec with a destination maps it — a pattern by its
    /// `*`, a literal by equality.
    static func fetchRefspecsMap(_ ref: String, _ refspecs: [String]) -> Bool {
        let parsed = refspecs.compactMap(ParsedRefspec.init)
        var reversed: [String] = []
        for refspec in parsed where !refspec.negative {
            if refspec.pattern {
                if let source = matchPattern(refspec.destination ?? refspec.source, ref, value: refspec.source) {
                    reversed.append(source)
                }
            } else if refspec.matching {
                reversed.append(ref)
            } else if ref == refspec.source {
                reversed.append(refspec.source)
            }
        }
        let negatives = parsed.filter(\.negative)
        let unmapped = reversed.contains { name in
            negatives.contains { $0.pattern ? matchPattern($0.source, name, value: nil) != nil : $0.source == name }
        }
        if unmapped { return false }
        for refspec in parsed where !refspec.negative {
            guard let destination = refspec.destination else { continue }
            if refspec.pattern ? matchPattern(destination, ref, value: refspec.source) != nil : ref == destination {
                return true
            }
        }
        return false
    }

    /// One fetch refspec as git's `parse_refspec` reads it: `^` negative, `+` force (ignored
    /// here), `<src>[:<dst>]` split at the **last** `:`, a pattern when the source holds `*`,
    /// `:` alone the matching refspec.
    private struct ParsedRefspec {
        let negative: Bool
        let source: String
        let destination: String?
        let pattern: Bool
        let matching: Bool

        init?(_ text: String) {
            var body = Substring(text)
            negative = body.hasPrefix("^")
            if negative { body = body.dropFirst() } else if body.hasPrefix("+") { body = body.dropFirst() }
            if let colon = body.lastIndex(of: ":") {
                source = String(body[..<colon])
                destination = String(body[body.index(after: colon)...])
            } else {
                source = String(body)
                destination = nil
            }
            // git refuses a negative refspec with a destination; it maps nothing.
            guard !(negative && destination != nil) else { return nil }
            matching = !negative && source.isEmpty && destination == ""
            pattern = source.contains("*")
        }
    }

    /// git's `match_name_with_pattern`: `name` against `key`'s one `*`, and — when `value` is
    /// given — `value` with its `*` replaced by what the star matched. Nil when it does not match.
    private static func matchPattern(_ key: String, _ name: String, value: String?) -> String? {
        guard let star = key.firstIndex(of: "*") else { return nil }
        let prefix = key[..<star]
        let suffix = key[key.index(after: star)...]
        guard name.count >= prefix.count + suffix.count, name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        guard let value else { return name }
        let captured = name.dropFirst(prefix.count).dropLast(suffix.count)
        guard let valueStar = value.firstIndex(of: "*") else { return value }
        return String(value[..<valueStar]) + captured + String(value[value.index(after: valueStar)...])
    }

    /// The destination of one fetch refspec, or nil when it has none.
    private static func refspecDestination(_ refspec: String) -> String? {
        ParsedRefspec(refspec)?.destination
    }

    /// The settings that decide where each branch pushes, from every configuration scope git
    /// reads (last value wins, as git reads them) — as they are, or (`removing`) as they will be
    /// once `git remote remove` has unset every one naming that remote **in the repository's
    /// own configuration**: a value from another scope stays (measured: a global
    /// `remote.pushDefault` naming the removed remote is kept, with a warning, and the branch
    /// still pushes there). Keys arrive section- and variable-lowercased
    /// (`branch.<b>.pushremote`), the branch name as written.
    private struct BranchPushSettings {
        var remote: [String: String] = [:]
        var pushRemote: [String: String] = [:]
        var pushDefault: String?

        /// Where `branch` pushes by these settings, or nil when none names a destination.
        func pushDestination(of branch: String) -> String? {
            pushRemote[branch] ?? pushDefault ?? remote[branch]
        }

        init(_ entries: [(scope: String, entry: ConfigEntry)], removing removed: String?) {
            for (scope, entry) in entries {
                guard let value = entry.value else { continue }
                if scope == "local", value == removed { continue }
                if entry.key == "remote.pushdefault" {
                    pushDefault = value
                } else if let branch = CLIGitBackend.branchName(in: entry.key, variable: "remote") {
                    remote[branch] = value
                } else if let branch = CLIGitBackend.branchName(in: entry.key, variable: "pushremote") {
                    pushRemote[branch] = value
                }
            }
        }
    }

    /// `<b>` of a key `branch.<b>.<variable>`, or nil.
    private static func branchName(in key: String, variable: String) -> String? {
        let prefix = "branch."
        let suffix = "." + variable
        guard key.hasPrefix(prefix), key.hasSuffix(suffix), key.count > prefix.count + suffix.count else { return nil }
        return String(key.dropFirst(prefix.count).dropLast(suffix.count))
    }

    /// Whether `key` is one git rewrites on a rename and unsets on a removal when its value names
    /// the remote: `branch.<b>.remote`, `branch.<b>.pushremote`, `remote.pushdefault`.
    private static func isRemoteNamingKey(_ key: String) -> Bool {
        key == "remote.pushdefault" || branchName(in: key, variable: "remote") != nil
            || branchName(in: key, variable: "pushremote") != nil
    }

    /// Every local branch that is not a symbolic ref, short names in ref order.
    private func plainLocalBranches(at root: URL) async throws -> [String] {
        let data = try await run(["for-each-ref", "--format=%(refname)%00%(symref)", "--end-of-options", "refs/heads"], cwd: root)
        return GitLines.split(data).compactMap { line in
            let fields = line.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, fields[1].isEmpty, fields[0].hasPrefix("refs/heads/") else { return nil }
            return String(fields[0].dropFirst("refs/heads/".count))
        }
    }

    // MARK: - Remove

    public func removeRemote(_ impact: RemovalImpact, keeping: [String: String], at root: URL) async throws {
        let remote = impact.remote
        try requireRemoteName(remote)
        // 1. Before any process: what is kept must be what the sheet listed, at a full id.
        var listed: [String: RefTip] = [:]
        for tip in impact.refs where listed[tip.ref] == nil { listed[tip.ref] = tip }
        for ref in keeping.keys.sorted() {
            guard let tip = listed[ref] else { throw BranchOperationError.invalidName(ref) }
            guard Self.isFullNonZeroObjectName(tip.id) else { throw RemoteAdminRefusal.invalidObjectID }
        }

        // 2. The whole impact again (RF1).
        guard try await removalImpact(of: remote, at: root) == impact else { throw RemoteAdminRefusal.impactChanged }

        // 3. What the read-back compares against, read **before** any kept branch exists, so a
        // read that fails cannot leave one unreported (fix round 1, m1) — and, from it, the refs
        // git will delete compared with the sheet's once more (m2): the last check, closest to
        // git. Creating the kept branches touches neither the configuration nor `refs/remotes/`.
        let before = try await adminState(at: root)
        guard try await refsTheRemovalDeletes(remote, from: before.refs, at: root).refs == impact.refs else {
            throw RemoteAdminRefusal.impactChanged
        }

        // 4. The kept branches, before anything is removed.
        let kept = impact.refs.compactMap { tip in keeping[tip.ref].map { (tip: tip, name: $0) } }
        let keptBranches = try await createKeptBranches(kept, at: root)

        // 5. The removal.
        let result: ProcessRunner.StreamedResult
        do {
            result = try await runWithEnvironment(["remote", "remove", "--end-of-options", remote], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
        } catch let error where error is CancellationError || Self.wasKilledBySignal(error) {
            throw RemoteAdminPartial.removeOutcomeUnknown(remote: remote, keptBranches: keptBranches)
        }
        guard result.exitCode != 0 else { return }

        // Not assumed to be a no-op (R23): read back.
        let words = RemoteFailureParser.gitsOwnWords(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        let after: AdminState
        do {
            after = try await adminState(at: root)
        } catch {
            throw RemoteAdminPartial.removeOutcomeUnknown(remote: remote, keptBranches: keptBranches)
        }
        if after == before, keptBranches.isEmpty {
            if let refusal = RemoteFailureParser.remoteAdminRefusal(stderr: result.stderr, name: remote) { throw refusal }
            throw GitError.commandFailed(exitCode: result.exitCode, stderr: words)
        }
        var tipsNow: [String: String] = [:]
        for ref in after.refs { tipsNow[ref.ref] = ref.id }
        let removed = before.config.filter { !after.config.contains($0) }.map(\.key)
        throw RemoteAdminPartial.removeHalfDone(left: RemovalLeftover(
            remote: remote, stillConfigured: Self.configures(remote, after.config),
            refsLeft: impact.refs.compactMap { tip in tipsNow[tip.ref].map { RefTip(ref: tip.ref, id: $0) } },
            refsDeleted: impact.refs.filter { tipsNow[$0.ref] == nil },
            configRemoved: Self.unique(removed), keptBranches: keptBranches, gitsWords: words))
    }

    // MARK: - Reading the repository back

    /// No such remote configured: `RemoteAdminRefusal.noSuchRemote`.
    private func requireConfiguredRemote(_ remote: String, at root: URL) async throws {
        guard try await configuredRemoteNames(at: root).contains(remote) else {
            throw RemoteAdminRefusal.noSuchRemote(remote)
        }
    }

    /// One configuration entry; `value` nil for a key written with no `=` at all.
    struct ConfigEntry: Equatable {
        let key: String
        let value: String?
    }

    /// One `refs/remotes/` ref: its id (its target's, for a symbolic one) and its target ("" when
    /// it is not symbolic). A dangling symbolic ref is not listed by `for-each-ref`.
    struct TrackingRef: Equatable {
        let ref: String
        let id: String
        let symref: String
    }

    /// What a rename or a removal can change: the repository's own configuration and its
    /// remote-tracking refs. Compared before and after a failure.
    struct AdminState: Equatable {
        let config: [ConfigEntry]
        let refs: [TrackingRef]
    }

    private func adminState(at root: URL) async throws -> AdminState {
        AdminState(config: try await localConfigEntries(at: root), refs: try await trackingRefs(at: root))
    }

    private func trackingRefs(at root: URL) async throws -> [TrackingRef] {
        let data = try await run(["for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)", "--end-of-options", "refs/remotes"], cwd: root)
        return GitLines.split(data).compactMap { line in
            let fields = line.split(separator: "\u{0}", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            return TrackingRef(ref: String(fields[0]), id: String(fields[1]), symref: String(fields[2]))
        }
    }

    /// The repository's own configuration file, entry by entry (`config --local --null --list`).
    private func localConfigEntries(at root: URL) async throws -> [ConfigEntry] {
        Self.configEntries(try await run(["config", "--local", "--null", "--list"], cwd: root, allowedExitCodes: [1]))
    }

    /// Every scope git reads, each entry with its scope (`config --null --show-scope --list`:
    /// `<scope>\0<key>\n<value>\0` per entry, measured).
    private func scopedConfigEntries(at root: URL) async throws -> [(scope: String, entry: ConfigEntry)] {
        let data = try await run(["config", "--null", "--show-scope", "--list"], cwd: root, allowedExitCodes: [1])
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { Data($0) }
        var entries: [(scope: String, entry: ConfigEntry)] = []
        var index = 0
        while index + 1 < fields.count {
            let scope = String(decoding: fields[index], as: UTF8.self)
            let text = String(decoding: fields[index + 1], as: UTF8.self)
            let entry = text.firstIndex(of: "\n").map {
                ConfigEntry(key: String(text[..<$0]), value: String(text[text.index(after: $0)...]))
            } ?? ConfigEntry(key: text, value: nil)
            entries.append((scope, entry))
            index += 2
        }
        return entries
    }

    /// `--null --list` output: each entry `<key>\n<value>\0`, or `<key>\0` for a key with no value.
    static func configEntries(_ data: Data) -> [ConfigEntry] {
        data.split(separator: 0, omittingEmptySubsequences: true).map { record in
            let text = String(decoding: record, as: UTF8.self)
            guard let newline = text.firstIndex(of: "\n") else { return ConfigEntry(key: text, value: nil) }
            return ConfigEntry(key: String(text[..<newline]), value: String(text[text.index(after: newline)...]))
        }
    }

    /// Whether the repository's configuration holds a `remote.<remote>.<variable>` key — the section git
    /// renames first and removes last. (The section name is matched as written: git compares a
    /// subsection case-sensitively.)
    static func configures(_ remote: String, _ config: [ConfigEntry]) -> Bool {
        // `remote.<name>.<variable>`, and a variable holds no dot: `remote.origin.bak.url` is
        // `origin.bak`'s, not `origin`'s (fix round 1, I2).
        let prefix = "remote.\(remote)."
        return config.contains { $0.key.hasPrefix(prefix) && !$0.key.dropFirst(prefix.count).contains(".") }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
