import Foundation
import GitCore

/// Checking for `git` itself, and reopening the repositories that were open at launch.
///
/// Neither needs anything `private` to `RepositoryStore.swift`: `gitPath`, `defaults` and
/// `lastRepositoryPathKey` are internal for exactly these functions, and every write here
/// goes through a mutator defined next to the state it touches.
extension RepositoryStore {

    // MARK: - Git availability

    /// The banner text shown while `git` can't be found. Kept in one place so
    /// `checkGitAvailability()` can recognize it as "still showing the git-missing banner"
    /// before clearing it, without duplicating the literal string.
    // internal (not private): used by RepositoryStore.swift's `open()`
    static func gitMissingMessage(at gitPath: String) -> String {
        "Git was not found at \(gitPath). Install the Xcode Command Line Tools."
    }

    /// Surfaces a missing `git` as an error banner at launch, before anything tries to run a
    /// command and fails with a less helpful "failed to launch" message per request. Also
    /// re-checkable later: if git was missing and has since become available, this clears the
    /// banner (but only if it's still showing the git-missing message, not some other error).
    func checkGitAvailability() async {
        let available = await CLIGitBackend.isGitAvailable(at: gitPath)
        setGitMissing(!available)
        let message = Self.gitMissingMessage(at: gitPath)
        if available {
            if lastError == message {
                setError(nil)
                // `open()` made this message sticky; with it gone, nothing is being protected
                // from the next reload any more.
                clearSticky()
            }
        } else {
            setError(message)
        }
    }

    // MARK: - Reopening

    /// Why this launch leaves the user's own state alone: a test host (`TestHost`), or a scripted
    /// DEBUG launch (`DebugLaunchGuard`). Never `.scriptedLaunch` in Release, where launches are
    /// never scripted.
    enum LaunchRefusal: Equatable {
        case testHost
        case scriptedLaunch
    }

    /// Never under a test host: the path is the user's, and a test run must not open it. Nor in
    /// a scripted DEBUG launch, which opens its own fixture instead. Pure: the answer comes from
    /// the flag and the environment it is handed.
    static func reopenRefusal(testHost: Bool, environment: [String: String]) -> LaunchRefusal? {
        if testHost { return .testHost }
        #if DEBUG
            if !DebugLaunchGuard.reopensLastRepository(environment) { return .scriptedLaunch }
        #endif
        return nil
    }

    /// Whether `open(_:)` adds what it opens to Open Recent: not under a test host, whose folders
    /// are scratch ones, nor in a scripted DEBUG launch (B3 Ruling 7). That list is the user's,
    /// kept outside the defaults, so no scratch suite stands in for it.
    static func openRecentRefusal(testHost: Bool, environment: [String: String]) -> LaunchRefusal? {
        if testHost { return .testHost }
        #if DEBUG
            if !DebugLaunchGuard.notesRecentDocuments(environment) { return .scriptedLaunch }
        #endif
        return nil
    }

    /// The repository `reopenLastRepository` would open: the last path in `defaults`, if it is
    /// still a folder.
    static func lastRepositoryToReopen(in defaults: UserDefaults) -> URL? {
        guard let path = defaults.string(forKey: lastRepositoryPathKey) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// Opens the first of `launchPaths` — the window registry's (`WindowRegistry.launchPaths`):
    /// the open-repositories list, else `lastRepositoryToReopen` — and returns the rest, for windows
    /// of their own, in order. Under a test host and in a scripted launch nothing is opened and
    /// `launchPaths` is never called, so the list it would rewrite is not read either.
    @discardableResult
    func reopenLastRepository(launchPaths: () -> [URL]) -> [URL] {
        let environment = ProcessInfo.processInfo.environment
        switch Self.reopenRefusal(testHost: TestHost.isRunningTests, environment: environment) {
        case nil: break
        case .testHost: return []
        case .scriptedLaunch:
            #if DEBUG
                DebugLaunchHooks.log("launch guard: the last repository is not reopened")
            #endif
            return []
        }
        let urls = launchPaths()
        guard let first = urls.first else { return [] }
        open(first)
        return Array(urls.dropFirst())
    }
}
