import Foundation
import GitCore

/// Every sentence the app says about the network, and every decision about whether a network
/// action is available, as pure functions over plain values.
///
/// Pure so that they can be read, and one day tested, without a store: the app has no test
/// target yet (see `docs/BACKLOG.md`), so today they are exercised through the DEBUG harness,
/// which logs the three blocked reasons after every step.
///
/// **Two rules hold for everything here.**
/// - **Text that came from the network is never shown raw.** A remote's URL can carry a token
///   and a server hook can print anything at all — measured, an ANSI colour escape, a tab and a
///   BEL all arrive intact in `PushResult.remoteMessages`. So every string built from git's
///   stderr or a server's output goes through `plain(_:)`: credentials redacted
///   (`RemoteFailureParser.redactingCredentials`), escape sequences and control characters
///   stripped, length capped.
/// - **A cancelled or failed write never says "nothing changed".** Only a rejection read from
///   `--porcelain` stdout — the server considered the update and said no — may say that
///   nothing was pushed.
enum RemoteWording {

    // MARK: - What is allowed right now

    /// Everything the three blocked reasons are decided on, read out of the store in one place
    /// (`RepositoryStore.remoteGate`) so the decisions themselves stay pure.
    struct Gate {
        var hasRepository: Bool
        var activity: RemoteActivity?
        var isMutating: Bool
        var operation: RepositoryOperation?
        var isDetached: Bool
        /// The branch HEAD is on, or nil when detached or unborn.
        var branch: Branch?
        var remotes: [Remote]
    }

    /// Why Fetch is off, or nil. Fetch writes only `refs/remotes/*` and `FETCH_HEAD`, so neither
    /// an operation in progress nor a detached HEAD stops it; only the lane and the absence of
    /// anything to fetch from do.
    static func fetchBlocked(_ gate: Gate) -> String? {
        guard gate.hasRepository else { return noRepository }
        if let activity = gate.activity { return laneBusy(activity) }
        if gate.remotes.isEmpty { return noRemotes }
        return nil
    }

    /// Why Pull is off, or nil.
    ///
    /// **The operation is asked about before the detached HEAD**, and the order is load-bearing:
    /// a rebase stopped on a conflict *is* a detached HEAD (measured in Task 7 — HEAD sits on a
    /// rewritten commit no ref holds), and "HEAD is detached" would send the user looking for a
    /// branch to switch to when what they have to do is finish or abort the rebase.
    static func pullBlocked(_ gate: Gate) -> String? {
        guard gate.hasRepository else { return noRepository }
        if let activity = gate.activity { return laneBusy(activity) }
        if gate.isMutating { return mutationBusy }
        if let operation = gate.operation { return operation.movingHeadBlocked }
        if gate.isDetached { return detachedPull }
        guard let branch = gate.branch else { return noCommitsYet }
        switch PullPlan.decide(branch.tracking) {
        case .noUpstream: return noUpstream(branch.name)
        case .upstreamGone: return upstreamGone(branch)
        case .nothingToDo, .fastForward, .askHowToIntegrate: return nil
        }
    }

    /// Why Push (or Publish) is off, or nil. Same order as `pullBlocked`, for the same reason;
    /// then whatever `PushTarget.resolve` refuses — and nothing else decides where a branch goes.
    static func pushBlocked(_ gate: Gate) -> String? {
        guard gate.hasRepository else { return noRepository }
        if let activity = gate.activity { return laneBusy(activity) }
        if gate.isMutating { return mutationBusy }
        if let operation = gate.operation { return operation.movingHeadBlocked }
        if gate.isDetached { return detachedPush }
        guard let branch = gate.branch else { return noCommitsYet }
        switch PushTarget.resolve(branch, remotes: gate.remotes) {
        case .push: return nil
        case .unpublished: return gate.remotes.isEmpty ? noRemotes : nil
        case .refused(let refusal): return refused(refusal, branch: branch.name)
        }
    }

    /// Which of the three the push button is: "Publish" for a branch with no push remote —
    /// which is **not** the same as a branch with no upstream — and "Re-publish" for a branch
    /// whose upstream is gone: it still resolves to a push, and git recreates the branch on the
    /// server (design row o), so the button must not read as though the remote branch merely
    /// moves. A refused target stays `.push` (disabled, with the refusal as its reason).
    static func pushKind(branch: Branch?, remotes: [Remote]) -> PushKind {
        guard let branch else { return .push }
        switch PushTarget.resolve(branch, remotes: remotes) {
        case .unpublished: return .publish
        case .push: return branch.tracking == .gone ? .republish : .push
        case .refused: return .push
        }
    }

    static func pushTitle(_ kind: PushKind) -> String {
        switch kind {
        case .push: "Push"
        case .publish: "Publish"
        case .republish: "Re-publish"
        }
    }

    static let noRepository = "No repository is open."
    static let noRemotes = "This repository has no remotes."
    static let noCommitsYet = "There is nothing to push or pull until the first commit."
    static let mutationBusy = "Wait for the current change to finish."
    static let detachedPull =
        "HEAD is detached, so there is no branch to pull into. Switch to a branch first."
    static let detachedPush =
        "HEAD is detached, so there is no branch to push. Switch to a branch, or create one here."

    static func noUpstream(_ branch: String) -> String {
        "\"\(branch)\" has no upstream to pull from. Publish it first, or set one in a terminal "
            + "with git branch --set-upstream-to."
    }

    static func upstreamGone(_ branch: Branch) -> String {
        "\"\(branch.upstream ?? "The upstream")\", the upstream of \"\(branch.name)\", no longer "
            + "exists on the remote. Re-publish the branch, or set another upstream in a terminal."
    }

    /// The two push-target refusals. Neither sentence claims git itself would refuse: measured,
    /// what a plain `git push` does in both situations depends on `push.default`, which Gitter
    /// does not read. They say what Gitter will not guess, and how to push anyway.
    static func refused(_ refusal: PushTargetRefusal, branch: String) -> String {
        switch refusal {
        case .unknownRemote(let name):
            "\"\(branch)\" is set to push to \"\(name)\", which is not a configured remote. Fix "
                + "branch.\(branch).pushRemote or remote.pushDefault in a terminal."
        case .upstreamNameDiffers(let upstream):
            "\"\(branch)\" tracks \"\(upstream)\", a branch with a different name, so Gitter "
                + "can't tell which one a push should update. Push it once from a terminal with "
                + "an explicit destination."
        }
    }

    /// The refusal for a second network action while one runs. Not queued: see
    /// `RemoteActivity`.
    static func laneBusy(_ activity: RemoteActivity) -> String {
        "Wait for \(describe(activity)) to finish, or stop it first."
    }

    /// Opening another repository while a write is on the lane. Refused rather than cancelled:
    /// see `RepositoryStore.open`.
    static func openRefusedDuringWrite(_ activity: RemoteActivity) -> String {
        "Wait for \(describe(activity)) to finish, or stop it first, before opening another "
            + "repository."
    }

    /// A lane ended with a question while the user had another sheet open. The question is not
    /// pushed over theirs; this says what was found and how to ask it again.
    static func sheetNotShown(_ sheet: BranchSheet) -> String {
        switch sheet {
        case .pullDiverged(_, _, let upstream):
            "\"\(upstream)\" and this branch both have new commits, but another sheet was open, "
                + "so nothing was merged. Pull again to choose Merge or Rebase."
        case .forcePush:
            "The force push warning wasn't shown because another sheet was open. Nothing was "
                + "pushed. Push again to see it."
        case .deleteRemoteBranch(let remote, let branch, _, _):
            "The warning for deleting \"\(branch)\" on \"\(remote)\" wasn't shown because "
                + "another sheet was open. Nothing was deleted."
        default:
            "Another sheet was open, so the next question wasn't shown. Nothing was changed."
        }
    }

    static func describe(_ activity: RemoteActivity) -> String {
        let remote = activity.remote.map { " \"\($0)\"" } ?? ""
        return switch activity.kind {
        case .fetch: activity.remote == nil ? "the fetch" : "the fetch from\(remote)"
        case .autoFetch: "the automatic fetch"
        case .pull: "the pull"
        case .push: "the push to\(remote)"
        case .publish: "publishing to\(remote)"
        case .forcePush: "the force push to\(remote)"
        case .deleteRemoteBranch: "the deletion on\(remote)"
        }
    }

    // MARK: - Toolbar and badges

    /// What the active toolbar item says beside its spinner until git prints a progress line —
    /// and for good, for the actions whose git prints none (a deletion transfers no objects).
    static func inProgressTitle(_ activity: RemoteActivity) -> String {
        let remote = activity.remote.map { " \"\($0)\"" } ?? ""
        return switch activity.kind {
        case .fetch, .autoFetch: activity.remote == nil ? "Fetching…" : "Fetching from\(remote)…"
        case .pull: "Pulling…"
        case .push: "Pushing to\(remote)…"
        case .publish: "Publishing to\(remote)…"
        case .forcePush: "Force pushing to\(remote)…"
        case .deleteRemoteBranch: "Deleting on\(remote)…"
        }
    }

    /// The active toolbar item's line: what is running, then git's latest progress segment —
    /// "Fetching… Receiving objects:  44% (4/9)". The marker is there so a segment that ends in
    /// "done." (git prints one per phase, and a small fetch prints only `remote: …` lines that
    /// end that way) never reads as though the action itself were finished.
    ///
    /// Only the verb, never the remote: the toolbar holds all three network items at the default
    /// 1200-point window only while the line is short (Task 9's second review measured "Pushing
    /// to \"origin\" — " pushing the item's own Stop into the overflow). The remote is in
    /// `progressHelp` and in Stop's tooltip; until git prints a segment the line is the full
    /// `inProgressTitle`, remote included.
    static func progressLine(_ activity: RemoteActivity) -> String {
        guard let progress = activity.progress else { return inProgressTitle(activity) }
        // git pads its percentages to three places ("Receiving objects:  83%"); at this width
        // the padding is what pushes the "%" past the cut, so runs of spaces become one.
        let compact = progress.split(separator: " ").joined(separator: " ")
        return "\(inProgressVerb(activity.kind))… \(compact)"
    }

    /// The progress line's tooltip: the whole of it, remote included — "Pushing to \"origin\" —
    /// Writing objects: 100% (3/3), 250 bytes | 250.00 KiB/s, done."
    static func progressHelp(_ activity: RemoteActivity) -> String {
        let title = inProgressTitle(activity)
        guard let progress = activity.progress else { return title }
        let running = title.hasSuffix("…") ? String(title.dropLast()) : title
        return "\(running) — \(progress)"
    }

    private static func inProgressVerb(_ kind: RemoteActivity.Kind) -> String {
        switch kind {
        case .fetch, .autoFetch: "Fetching"
        case .pull: "Pulling"
        case .push: "Pushing"
        case .publish: "Publishing"
        case .forcePush: "Force pushing"
        case .deleteRemoteBranch: "Deleting"
        }
    }

    /// The tooltips of the three toolbar items while they are available.
    static let fetchHelp = "Fetch from every remote"
    static func pullHelp(_ branch: Branch?) -> String {
        branch?.upstream.map { "Pull from \"\($0)\"" } ?? "Pull"
    }
    /// The Push item's tooltip: where a push would go, from `PushTarget.resolve` — never from
    /// the upstream, which a triangular branch (`pushRemote` ≠ `upstreamRemote`) does not push
    /// to. Only called while Push is enabled, so a refused target does not reach it.
    static func pushHelp(_ kind: PushKind, branch: Branch?, remotes: [Remote]) -> String {
        guard let branch else { return pushTitle(kind) }
        switch kind {
        case .publish: return "Publish \"\(branch.name)\" to a remote"
        case .republish:
            return "Publish \"\(branch.name)\" again: its upstream was deleted on the remote"
        case .push:
            guard case .push(let remote, let ref) = PushTarget.resolve(branch, remotes: remotes)
            else { return "Push \"\(branch.name)\"" }
            let destination = "Push \"\(branch.name)\" to \(Self.destination(branch: branch.name, remote: remote, remoteRef: ref))"
            // The badge counts against the upstream; say so when the push goes elsewhere, so
            // the missing count on the button is explained where the user looks for it.
            guard let upstream = branch.upstream else { return destination }
            if remote != branch.upstreamRemote || ref != branch.upstreamRef {
                return destination + " — not to its upstream \"\(upstream)\", which the badge counts against"
            }
            // Same remote and ref, but `remote.<name>.pushurl` sends the push to another
            // repository than the one the upstream is fetched from.
            guard PushTarget.pushesWhereItFetches(remote, remotes: remotes) else {
                return destination + " — \"\(remote)\" pushes to a different URL than it fetches from, and the badge counts against \"\(upstream)\" as fetched"
            }
            return destination
        }
    }

    /// The Fetch item's tooltip when the last automatic fetch failed. Quiet on purpose — being
    /// offline is normal — so this and a dimmed mark are all it ever gets.
    static func autoFetchFailedHelp(_ reason: String) -> String {
        "The last automatic fetch failed: \(reason)"
    }

    /// A tracking badge's tooltip. Counts are against **the upstream, by name** — never "the
    /// remote": the upstream can be another local branch (`tracksLocalBranch`), or live on a
    /// repository the branch does not push to.
    static func trackingHelp(
        _ tracking: Tracking, upstream: String?, tracksLocalBranch: Bool
    ) -> String? {
        let name = upstream.map { "\"\($0)\"" } ?? "the upstream"
        let against = tracksLocalBranch ? "local branch \(name)" : name
        switch tracking {
        case .none: return nil
        case .gone:
            return upstream.map { "Its upstream, \"\($0)\", no longer exists on the remote." }
                ?? "Its upstream no longer exists on the remote."
        case .counts(let ahead, let behind):
            var parts: [String] = []
            if ahead > 0 { parts.append("\(commits(ahead)) ahead of") }
            if behind > 0 { parts.append("\(commits(behind)) behind") }
            guard !parts.isEmpty else { return nil }
            let head = parts.joined(separator: " and ")
            return tracksLocalBranch
                ? "\(head) \(against) — compared with a local branch, not a remote"
                : "\(head) \(against)"
        }
    }

    /// What VoiceOver reads for a badge: "2 ahead, 3 behind", "upstream gone", and for a local
    /// upstream "2 ahead, 3 behind, compared with local branch main".
    static func trackingAccessibility(
        _ tracking: Tracking, upstream: String?, tracksLocalBranch: Bool
    ) -> String? {
        switch tracking {
        case .none: return nil
        case .gone: return "upstream gone"
        case .counts(let ahead, let behind):
            var parts: [String] = []
            if ahead > 0 { parts.append("\(ahead) ahead") }
            if behind > 0 { parts.append("\(behind) behind") }
            guard !parts.isEmpty else { return nil }
            let local = upstream.map { ", compared with local branch \($0)" }
                ?? ", compared with a local branch"
            return parts.joined(separator: ", ") + (tracksLocalBranch ? local : "")
        }
    }

    private static func commits(_ count: Int) -> String {
        count == 1 ? "1 commit" : "\(count) commits"
    }

    // MARK: - Fetch

    static func fetched(from remote: String?) -> String {
        remote.map { "Fetched from \"\($0)\"." } ?? "Fetched from every remote."
    }

    /// A cancelled fetch wrote nothing on the server, and may have updated some remote-tracking
    /// branches here before it stopped — which is why the store refreshes anyway.
    static func fetchStopped(from remote: String?) -> String {
        "Stopped fetching\(remote.map { " from \"\($0)\"" } ?? ""). Some remote branches may "
            + "already have been updated."
    }

    // MARK: - Pull

    static func alreadyUpToDate(with upstream: String) -> String {
        "Already up to date with \"\(upstream)\"."
    }

    static let pullBranchChanged =
        "The branch changed while fetching, so nothing was merged. Pull again."
    /// The pull's fetch finished and it would fast-forward, but a commit or a branch action
    /// held the mutation slot when the lane freed. Nothing was merged; the fetch stands.
    static let pullSlotBusy =
        "The pull fetched, but couldn't integrate while another change was running. Pull again."

    /// Merge or Rebase chosen on the pull sheet while another change holds the slot. The sheet
    /// stays up, so the way to try again is right there.
    static let pullAnswerSlotBusy =
        "Another change is still running, so nothing was merged. Wait for it to finish, then "
        + "choose Merge or Rebase again."

    /// Stop pressed after the pull's fetch had finished, before it merged anything.
    static func pullStoppedAfterFetch(_ remote: String?) -> String {
        "Stopped the pull after fetching\(remote.map { " from \"\($0)\"" } ?? ""). Nothing was "
            + "merged."
    }

    static let pullSheetStale =
        "The branch or its upstream changed since that question was asked. Nothing was "
        + "merged or rebased. Pull again."

    /// The pull sheet's Merge line (Task 10 draws it).
    static func mergeExplanation(ahead: Int, behind: Int) -> String {
        "Creates a merge commit joining \(commits(ahead, "your")) and \(commits(behind, "their"))."
    }

    /// The pull sheet's Rebase line. It must not promise the history's shape: measured in
    /// Task 7, a plain rebase **flattens** a merge commit among the replayed ones — the merge is
    /// dropped and the commits under it are replayed — so "your N commits" is true of the
    /// commits and not of how they were joined.
    static func rebaseExplanation(ahead: Int) -> String {
        "Replays \(commits(ahead, "your")) on top of theirs as new commits. Any merge commit "
            + "among them is flattened, not kept. Needs every change committed first."
    }

    static func rebaseNotice(_ outcome: RebaseOutcome, branch: String, upstream: String) -> String? {
        switch outcome {
        case .upToDate: "Already up to date with \"\(upstream)\"."
        case .fastForwarded: "Fast-forwarded \"\(branch)\" to \"\(upstream)\"."
        case .rebased: "Rebased \"\(branch)\" onto \"\(upstream)\"."
        // The operation note above the file list already explains a stopped rebase and offers
        // the way out; a second message would compete with it.
        case .conflicts: nil
        }
    }

    // MARK: - Push

    /// Where a push went, as a phrase: `"origin"`, or `"origin" as "renamed"` when the ref on
    /// the server has another name than the branch.
    static func destination(branch: String, remote: String, remoteRef: String) -> String {
        let name = remoteRef.hasPrefix("refs/heads/")
            ? String(remoteRef.dropFirst("refs/heads/".count)) : remoteRef
        return name == branch ? "\"\(remote)\"" : "\"\(remote)\" as \"\(name)\""
    }

    /// What a successful push, publish or force push says. nil for a rejection, which is a
    /// banner (`rejected(_:…)`), never a notice.
    ///
    /// `.created` has three readings and they need three sentences: a first publish, a branch
    /// whose upstream was **gone** (somebody deleted it on the server and this put it back —
    /// the design's binding note says to present that as publishing again, never as "up to
    /// date" or as the branch merely moving), and a push to a push remote that had no such
    /// branch yet (a triangular setup's first push).
    static func pushed(
        _ outcome: PushOutcome, branch: String, remote: String, remoteRef: String,
        publishing: Bool, wasGone: Bool
    ) -> String? {
        let place = destination(branch: branch, remote: remote, remoteRef: remoteRef)
        return switch outcome {
        case .upToDate: "\"\(branch)\" is already up to date on \(place)."
        case .created:
            if wasGone {
                "Published \"\(branch)\" to \(place) again — it had been deleted there."
            } else if publishing {
                "Published \"\(branch)\" to \(place)."
            } else {
                "Created \"\(branch)\" on \(place)."
            }
        case .pushed(let from, let to): "Pushed \"\(branch)\" to \(place) (\(from)..\(to))."
        case .forced(let from, let to):
            "Force-pushed \"\(branch)\" to \(place) (\(from)...\(to)). The commits that were "
                + "only there are no longer on that branch."
        case .deleted: "Deleted \"\(branch)\" on \(place)."
        case .rejected: nil
        }
    }

    /// The sentence about the upstream after a publish, or nil when there is nothing to say.
    ///
    /// - `.set` names the new upstream, and — when the branch tracked something else before —
    ///   the old one too: `-u` rewrites `branch.<n>.remote`/`.merge`, and measured on git 2.54
    ///   it repoints an existing upstream without a word (the triangular case in
    ///   `GitRemoteBackend.push`). A badge that starts counting against a different branch
    ///   deserves a sentence.
    /// - `.notSet` is the push having gone through **without** the upstream: git's own `error:`
    ///   lines, and the command that sets it.
    /// - `.unknown` never borrows `.notSet`'s words: the upstream may be exactly what was asked
    ///   for, and only the check could not be run.
    static func upstreamAfterPublish(
        _ result: PushResult, branch: String, remote: String, remoteRef: String,
        previousUpstream: String?
    ) -> String? {
        let name = remoteRef.hasPrefix("refs/heads/")
            ? String(remoteRef.dropFirst("refs/heads/".count)) : remoteRef
        let wanted = "\(remote)/\(name)"
        switch result.upstream {
        case .notRequested:
            return nil
        case .set:
            if let previousUpstream, previousUpstream != wanted {
                return "It now tracks \"\(wanted)\" instead of \"\(previousUpstream)\"."
            }
            return "It now tracks \"\(wanted)\"."
        case .notSet:
            let why = plainJoined(result.errorLines)
            let stop = why.last.map { ".!?".contains($0) } == true ? "" : "."
            return "Pushed, but the upstream could not be set"
                + (why.isEmpty ? "." : ": \(why)\(stop)")
                + " Set it once in a terminal with: git branch --set-upstream-to=\(wanted) \(branch)"
        case .unknown:
            return "Gitter could not check which upstream \"\(branch)\" tracks now. Run "
                + "git status -sb in a terminal to see it."
        }
    }

    /// The error banner for a push the server refused. `nil` means "not a rejection".
    ///
    /// A rejection is read from `--porcelain` stdout: the server considered this ref and said
    /// no, so here — and only here — "nothing was pushed" is a true sentence.
    static func rejected(
        _ outcome: PushOutcome, branch: String, remote: String, remoteMessages: [String]
    ) -> String? {
        guard case .rejected(let rejection) = outcome else { return nil }
        let base: String =
            switch rejection {
            case .fetchFirst, .nonFastForward:
                "\"\(remote)\" has commits on \"\(branch)\" that this repository doesn't, so "
                    + "the push was refused and nothing was pushed. Pull to bring them in, or "
                    + "force push to replace them."
            case .staleLease:
                staleForcePush
            case .remoteRejected(let reason):
                "\"\(remote)\" refused the push (\(plain(reason))). Nothing was pushed."
            case .other(let line):
                "The push of \"\(branch)\" did not go through. git reported: \(plain(line))"
            }
        return withServerLines(base, remoteMessages)
    }

    /// The force push sheet's lease was out of date: the server said `[rejected] (stale info)`
    /// and changed nothing.
    static let staleForcePush = "The remote branch changed again; nothing was pushed."

    static func deleteRejected(
        _ outcome: PushOutcome, branch: String, remote: String, remoteMessages: [String]
    ) -> String? {
        guard case .rejected(let rejection) = outcome else { return nil }
        let base: String =
            switch rejection {
            case .staleLease:
                "\"\(branch)\" on \"\(remote)\" changed since that warning, or is already gone; "
                    + "nothing was deleted."
            case .remoteRejected(let reason):
                "\"\(remote)\" refused to delete \"\(branch)\" (\(plain(reason))). Nothing was "
                    + "deleted."
            case .other(let line):
                "\"\(remote)\" did not delete \"\(branch)\". git reported: \(plain(line))"
            case .fetchFirst, .nonFastForward:
                "\"\(remote)\" refused to delete \"\(branch)\". Nothing was deleted."
            }
        return withServerLines(base, remoteMessages)
    }

    static func deleted(branch: String, remote: String, tip: String) -> String {
        "Deleted \"\(branch)\" on \"\(remote)\". Recreate it with: "
            + "git push \(remote) \(tip):refs/heads/\(branch)"
    }

    /// A push, force push or delete that was **cancelled**. Cancelling kills git wherever it
    /// had got to, which may be after the server accepted the update and before this end heard
    /// about it: the only true sentence is that nobody knows yet — and the store fetches to find
    /// out.
    static func cancelledWrite(_ kind: RemoteActivity.Kind, branch: String, remote: String)
        -> String
    {
        switch kind {
        case .deleteRemoteBranch:
            "Stopped deleting \"\(branch)\" on \"\(remote)\". It may or may not have been deleted "
                + "there; fetching to find out."
        default:
            "Stopped pushing \"\(branch)\" to \"\(remote)\". The remote may or may not have been "
                + "updated; fetching to find out."
        }
    }

    static let publishSheetStale =
        "The branch changed since that question was asked. Nothing was published."
    static let forcePushSheetStale = "The branch changed since that warning. Nothing was pushed."

    /// Confirmed, but the branch no longer points at the commit the sheet counted against —
    /// reset, amended or committed on in a terminal while it was up. The push would still send
    /// exactly that commit (it goes by sha), but the sheet called it "your branch", and it is
    /// not that any more, so nothing is sent and the user is asked to look again.
    static func forcePushBranchMoved(_ branch: String) -> String {
        "\"\(branch)\" has moved since that warning, so the commit it described is no longer "
            + "your branch. Nothing was pushed. Push again to see what a force push would "
            + "replace now."
    }

    /// The branch a force push was asked for is gone by the time its sheet was being prepared.
    static func forcePushBranchGone(_ branch: String) -> String {
        "\"\(branch)\" is no longer a branch here, so there is nothing to force push."
    }

    /// Stop pressed while the force push sheet was being prepared (its fetch had finished, the
    /// reload or the counting had not). Nothing is written by preparing a sheet.
    static let forcePushWarningStopped =
        "Stopped before the force push warning was ready. Nothing was pushed."
    /// The same for the delete sheet.
    static let deleteWarningStopped =
        "Stopped before the delete warning was ready. Nothing was deleted."
    /// Stop pressed after confirming, while the branch was still being re-read and before git
    /// was asked to push anything.
    static let forcePushStoppedBeforeSending =
        "Stopped the force push before anything was sent. Nothing was pushed."

    static func noSuchRemote(_ remote: String) -> String {
        "There is no remote named \"\(remote)\". Nothing was published."
    }

    static func noSuchRemoteBranch(_ remoteBranch: String) -> String {
        "There is no remote branch \"\(remoteBranch)\"."
    }

    static func alreadyGone(_ branch: String, on remote: String) -> String {
        "\"\(branch)\" is no longer on \"\(remote)\"."
    }

    static func nothingToForce(_ remoteBranch: String, branch: String) -> String {
        "\"\(remoteBranch)\" no longer has anything \"\(branch)\" lacks, so a force push "
            + "would replace nothing. Push again."
    }

    /// The delete sheet's line about what goes with the branch (Task 10 draws it). Worded as
    /// exactly the question `commitsOnlyOnRemoteBranch` asks — "held by no branch, tag or
    /// other remote" — and never "unreachable": that count does not consult the stash, notes,
    /// a detached HEAD, another worktree or the reflog.
    static func onlyThere(_ count: Int) -> String {
        switch count {
        case 0: "Its commits are also on another branch, tag or remote."
        case 1: "1 of its commits is held by no branch, tag or other remote."
        default: "\(count) of its commits are held by no branch, tag or other remote."
        }
    }

    static let forcePushNotOffered =
        "Force Push is only offered after a push was refused. Push again first."
    static func noRemoteTrackingRef(_ remoteBranch: String) -> String {
        "Gitter couldn't find \"\(remoteBranch)\" after fetching, so it can't show what a force "
            + "push would replace."
    }

    // MARK: - Failures

    /// A thrown network error as a banner sentence. `attempt` reads on from "Couldn't …" —
    /// `fetch from "origin"`. `isWrite` marks a push, force push or delete: for those a failure
    /// in git's own words gets the sentence that the remote may have changed, because git may
    /// have been part-way through when it failed.
    static func failure(_ error: Error, attempt: String, isWrite: Bool) -> String {
        let maybe = isWrite ? " The remote may or may not have been updated." : ""
        switch error {
        case let error as RemoteOperationError:
            return sentence(error, attempt: attempt)
        case GitError.commandFailed(let code, let stderr):
            let words = plainJoined(stderr.split(whereSeparator: \.isNewline).map(String.init))
            return "Couldn't \(attempt): "
                + (words.isEmpty ? "git exited with code \(code)." : words) + maybe
        case let refusal as BranchOperationError:
            return refusal.sentence(refusing: attempt)
        default:
            return "Couldn't \(attempt): \(plain(error.localizedDescription))\(maybe)"
        }
    }

    private static func sentence(_ error: RemoteOperationError, attempt: String) -> String {
        switch error {
        case .authenticationNeeded(let url):
            "\(plain(url)) needs a login that git doesn't have. Run git fetch once in a "
                + "terminal to sign in; Gitter will use it afterwards."
        case .authenticationFailed(let url):
            "\(plain(url)) refused the login git offered. Run git fetch in a terminal to sign "
                + "in again."
        case .hostKeyNotTrusted:
            "The server's host key isn't trusted yet. Connect once from a terminal (git fetch) "
                + "to check its fingerprint and accept it."
        case .unreachable(let what):
            "Couldn't \(attempt): \(plain(what)) could not be reached. Check the network "
                + "connection and try again."
        case .repositoryNotFound:
            "Couldn't \(attempt): there is no repository at that address, or you don't have "
                + "access to it."
        case .noRemote:
            "Couldn't \(attempt): there is no such remote."
        case .noUpstream:
            "Couldn't \(attempt): the branch has no upstream."
        case .invalidLease(let value):
            "Couldn't \(attempt): \"\(plain(value))\" is not a full commit id, so nothing was sent."
        }
    }

    // MARK: - Somebody else's text

    /// At most this many server lines reach a banner or a notice.
    static let maxServerLines = 8
    /// And at most this many characters of each.
    static let maxLineLength = 200

    /// One line of text that came from outside — git's stderr, a server hook, a progress
    /// segment — made safe to show, in this order: escape sequences removed whole (so `ESC[31m`
    /// leaves no `[31m` behind), every other control, bidirectional-formatting or line/paragraph
    /// separator character (Cc, Cf, Zl, Zp) dropped and tabs turned into spaces; **then**
    /// credentials redacted; then the result capped at `maxLineLength`, on one line.
    ///
    /// **Strip before redacting, never the other way round.** The redactor matches a URL's
    /// userinfo as ordinary text, so a control character inside it — `https://u:<VT>secret@host`
    /// — breaks the match and the password survives; the stripping that follows then removes
    /// the VT and puts the password back together, on screen (found in Task 8's review). With
    /// the controls gone first, the redactor sees the URL the user would see.
    ///
    /// **Marks on ASCII punctuation are dropped too** (Mn, Me directly after a `@`, `:`, `/`,
    /// `.` …, however many). No real text puts an accent or a variation selector on a URL's
    /// punctuation, but a hostile line can: `@` + U+FE0F renders as a plain `@`, and was enough
    /// to hide the `@` from a redactor that compared `Character`s. The redactor now compares
    /// scalars and no longer needs this; it is kept so that what is shown is the address as git
    /// would parse it, not an `@` with something invisible riding on it. Marks anywhere else
    /// are **kept**: stripping every Mn would take the accents off decomposed text (`e` +
    /// U+0301 is how a macOS path spells `é`) and the vowel signs off whole scripts.
    static func plain(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        var afterASCIIPunctuation = false
        while let scalar = scalars.next() {
            if scalar == "\u{1B}" {
                skipEscape(&scalars)
                continue
            }
            if scalar == "\t" {
                out.append(" ")
                afterASCIIPunctuation = false
                continue
            }
            // Cc: C0/C1 controls (BEL, CR, backspace, CSI as one byte …). Cf: format characters,
            // which include the bidirectional overrides a line could use to reorder what it
            // appears to say. Zl/Zp: U+2028 and U+2029, which a text view breaks a line on —
            // a second line inside what is meant to be one.
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: continue
            // Two cases, not one: a `where` after a pattern list guards only the last pattern.
            case .nonspacingMark where afterASCIIPunctuation: continue
            case .enclosingMark where afterASCIIPunctuation: continue
            default:
                out.append(scalar)
                afterASCIIPunctuation =
                    scalar.isASCII && scalar.properties.generalCategory != .control
                    && !scalar.properties.isAlphabetic && !scalar.properties.isWhitespace
                    && !("0"..."9").contains(scalar)
            }
        }
        let redacted = RemoteFailureParser.redactingCredentials(String(out))
        let line = redacted.trimmingCharacters(in: .whitespaces)
        guard line.count > maxLineLength else { return line }
        return String(line.prefix(maxLineLength - 1)) + "…"
    }

    /// Skips the rest of an escape sequence after its `ESC`: a CSI (`ESC [ … final`), an OSC
    /// (`ESC ] … BEL` or `ESC \`), or a two-character escape.
    private static func skipEscape(_ scalars: inout String.UnicodeScalarView.Iterator) {
        guard let next = scalars.next() else { return }
        switch next {
        case "[":
            // Parameters and intermediates, then one final byte in 0x40–0x7E.
            while let scalar = scalars.next() {
                if (0x40...0x7E).contains(scalar.value) { return }
            }
        case "]", "P", "X", "^", "_":
            // String commands end at BEL or at ST (`ESC \`).
            while let scalar = scalars.next() {
                if scalar == "\u{07}" { return }
                if scalar == "\u{1B}" {
                    _ = scalars.next()
                    return
                }
            }
        default:
            return
        }
    }

    /// Server lines made plain, blank ones dropped, capped at `maxServerLines` with a count of
    /// the rest.
    static func serverLines(_ lines: [String]) -> [String] {
        let shown = lines.map(plain).filter { !$0.isEmpty }
        guard shown.count > maxServerLines else { return shown }
        return Array(shown.prefix(maxServerLines))
            + ["(\(shown.count - maxServerLines) more lines)"]
    }

    /// Several lines of outside text joined into one sentence-sized string.
    static func plainJoined(_ lines: [String]) -> String {
        serverLines(lines).joined(separator: " ")
    }

    /// The server lines worth a notice after a successful push: the ones carrying a URL (a
    /// hosting service's "create a pull request" link), each with the line before it when that
    /// one introduces it ("…by visiting:"). Made plain and capped like every other server line.
    static func pullRequestLinks(_ messages: [String]) -> [String] {
        let lines = messages.map(plain)
        var picked: [String] = []
        for (index, line) in lines.enumerated()
        where line.contains("https://") || line.contains("http://") {
            if index > 0, lines[index - 1].hasSuffix(":"), picked.last != lines[index - 1] {
                picked.append(lines[index - 1])
            }
            picked.append(line)
        }
        return Array(picked.prefix(maxServerLines))
    }

    private static func withServerLines(_ base: String, _ messages: [String]) -> String {
        let lines = serverLines(messages)
        guard !lines.isEmpty else { return base }
        return base + "\n" + lines.map { "remote: \($0)" }.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func commits(_ count: Int, _ owner: String) -> String {
        count == 1 ? "\(owner) 1 commit" : "\(owner) \(count) commits"
    }
}
