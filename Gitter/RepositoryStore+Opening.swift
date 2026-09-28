import Foundation
import GitCore

/// Checking for `git` itself, and reopening the last repository at launch.
///
/// Neither needs anything `private` to `RepositoryStore.swift`: `gitPath` and
/// `lastRepositoryPathKey` are internal for exactly these two functions, and every write here
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

    /// Never under a test host: the path is the user's, and a test run must not open it.
    func reopenLastRepository() {
        guard !TestHost.isRunningTests else { return }
        guard let path = UserDefaults.standard.string(forKey: Self.lastRepositoryPathKey) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }
        open(URL(fileURLWithPath: path))
    }
}
