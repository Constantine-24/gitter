import Foundation
import GitCore
import Synchronization

/// The one network operation running right now: what it is, which remote it talks to, and the
/// last progress line git printed for it.
///
/// There is at most one (`RepositoryStore.remoteActivity`): the store has a single **network
/// lane**, and a second fetch, pull or push while one runs is refused with a reason rather than
/// queued. Two transfers against the same remote gain nothing and would interleave their
/// progress lines on one toolbar item; a queued push would run against a branch the user has
/// since moved.
///
/// The task handle is not in here, so the value stays `Equatable` for SwiftUI; the store keeps
/// it beside this in `remoteTask`.
struct RemoteActivity: Equatable {
    enum Kind: Equatable {
        case fetch
        /// Reserved for Task 11's scheduler: quiet, never a banner.
        case autoFetch
        case pull
        case push
        case publish
        case forcePush
        case deleteRemoteBranch
    }

    let kind: Kind

    /// Whether this operation writes on the server — the four that hold the mutation slot too,
    /// and whose cancellation leaves the remote in an unknown state.
    var isWrite: Bool {
        switch kind {
        case .push, .publish, .forcePush, .deleteRemoteBranch: true
        case .fetch, .autoFetch, .pull: false
        }
    }

    /// The remote being talked to, or nil for `fetch --all`.
    let remote: String?
    /// git's latest progress segment ("Receiving objects:  57% (4/7)"), made plain
    /// (`RemoteWording.plain`: no escapes or controls, credentials redacted, one capped line);
    /// nil until git has printed one. The last segment wins — git redraws one counter in place
    /// with `\r`.
    var progress: String?
}

/// A claim on the network lane, handed back to `RepositoryStore.finishRemote`. The token and
/// generation make a late release or progress line from an earlier lane — or from a repository
/// since closed — a no-op.
struct RemoteLane: Sendable {
    let token: Int
    let generation: Int
    /// Set when the lane also holds the mutation slot (push, publish, force push, delete).
    let mutationGeneration: Int?
}

/// A push the server refused because it has commits this branch does not — the one state from
/// which "Force Push…" is reachable.
///
/// Cleared by the next mutation or network action. `banner` is the exact text the error banner
/// was given, so the banner's two actions are only drawn beside *that* message and never beside
/// a later, unrelated one that replaced it.
struct RejectedPush: Equatable {
    let branch: String
    let remote: String
    /// The destination on the server, `refs/heads/<name>`.
    let remoteRef: String
    let rejection: PushRejection
    let banner: String
}

/// How the pull sheet integrates diverged histories. Remembered in defaults after it ran.
enum PullMode: String {
    case merge
    case rebase
}

/// Hands git's progress segments from the pipe's background queue to the main actor, at most
/// ten times a second, keeping only the newest.
///
/// `runStreaming` calls `onStderr` on the pipe's readability queue and does not drain the pipe
/// while the callback runs, so the callback must be cheap: it stores one string under a lock
/// and, if no delivery is pending, schedules one. Everything that touches store state happens
/// in `deliver`, on the main actor.
final class ProgressRelay: Sendable {
    private struct State {
        var latest: String?
        var scheduled = false
    }

    private let state = Mutex(State())
    private let deliver: @MainActor @Sendable (String) -> Void

    init(deliver: @escaping @MainActor @Sendable (String) -> Void) {
        self.deliver = deliver
    }

    /// Called on a background queue. Never blocks beyond the lock.
    func send(_ segment: String) {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let needsSchedule = state.withLock { state in
            state.latest = trimmed
            defer { state.scheduled = true }
            return !state.scheduled
        }
        guard needsSchedule else { return }
        Task { @MainActor [self] in
            try? await Task.sleep(for: .milliseconds(100))
            let value = state.withLock { state in
                state.scheduled = false
                return state.latest
            }
            if let value { deliver(value) }
        }
    }
}
