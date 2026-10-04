import Foundation

/// The quiet periodic fetch: once when a repository has opened, then every `interval` for as
/// long as it stays open.
///
/// The schedule only says *when*. Whether a tick fetches, and what the fetch does with its
/// outcome, is the store's (`RepositoryStore.autoFetchTick`): a tick is skipped when "Fetch
/// Automatically" is off, the lane is busy, an operation is in progress or there is no remote,
/// and the fetch itself is stopped after `timeout`. A skipped tick is not retried early — the
/// next one comes a whole interval later.
///
/// One schedule per repository: `RepositoryStore.open()` stops the previous one before
/// anything else and starts the new one once the first snapshot is in. The loop also checks the
/// store's `generation` before each tick, so a loop that outlived its repository ticks never.
///
/// The toggle is read at every tick rather than observed: turning it on waits for the next
/// tick, turning it off stops a fetch that is running (`autoFetchSettingChanged`).
@MainActor
final class AutoFetchScheduler {
    /// The defaults key "Fetch Automatically" is bound to. Absent means on.
    static let enabledKey = "autoFetchEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Ten minutes and two minutes: the design's numbers.
    static let defaultInterval: Duration = .seconds(600)
    static let defaultTimeout: Duration = .seconds(120)

    let interval: Duration
    let timeout: Duration

    private var loop: Task<Void, Never>?

    init(interval: Duration = defaultInterval, timeout: Duration = defaultTimeout) {
        self.interval = interval
        self.timeout = timeout
    }

    /// The production schedule — or, in a DEBUG build, `GITTER_DEBUG_AUTOFETCH=<interval>[,<timeout>]`
    /// in seconds, so the harness can watch several ticks in a minute.
    static func fromEnvironment() -> AutoFetchScheduler {
        #if DEBUG
            if let spec = ProcessInfo.processInfo.environment["GITTER_DEBUG_AUTOFETCH"] {
                let numbers = spec.split(separator: ",").compactMap { Double($0) }
                if let seconds = numbers.first, seconds > 0 {
                    let timeout = numbers.count > 1 && numbers[1] > 0 ? numbers[1] : 120
                    return AutoFetchScheduler(
                        interval: .milliseconds(Int(seconds * 1000)),
                        timeout: .milliseconds(Int(timeout * 1000)))
                }
            }
        #endif
        return AutoFetchScheduler()
    }

    /// Starts `store`'s schedule for the repository open right now, replacing any other. The
    /// first tick is immediate: "on open". Never under a test host (`TestHost`): a test run
    /// fetches nothing. Nor in a scripted DEBUG launch, unless it sets `GITTER_DEBUG_AUTOFETCH`
    /// (`DebugLaunchGuard`).
    func start(for store: RepositoryStore) {
        stop()
        guard !TestHost.isRunningTests else { return }
        #if DEBUG
            guard DebugLaunchGuard.startsAutomaticFetch(ProcessInfo.processInfo.environment) else {
                RepositoryStore.logAutoFetch("launch guard: no schedule in a scripted launch")
                return
            }
            RepositoryStore.logAutoFetch(
                "schedule: every \(interval), stopped after \(timeout) (store \(store.debugSerial))")
        #endif
        let generation = store.generation
        let interval = interval
        let timeout = timeout
        loop = Task { [weak store] in
            while !Task.isCancelled {
                guard let store, store.generation == generation else { return }
                store.autoFetchTick(timeout: timeout)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }
}
