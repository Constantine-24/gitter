import Foundation

/// `GitRemoteBackend`'s read-only half: fetch. See the protocol for the contract; this file is
/// about how the two argument vectors are spelled and how a failure is turned into words.
extension CLIGitBackend: GitRemoteBackend {
    public func fetch(
        remote: String?, at root: URL, progress: @escaping @Sendable (String) -> Void
    ) async throws {
        // Each vector is a COMPLETE array literal beginning with `"fetch"`, chosen by this
        // branch rather than assembled — `ForceFlagScannerTests` classifies a vector by its
        // first literal element and reads the rest against `fetch`'s deny table, and an
        // `append` or a `+` would hide the arguments from it entirely. Both are pinned there,
        // character for character, by `allowsTheRemoteOperationsThisMilestoneNeeds`.
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
        let arguments: [String]
        if let remote {
            try requireRemoteName(remote)
            arguments = ["fetch", "--progress", "--no-prune", "--end-of-options", remote]
        } else {
            arguments = ["fetch", "--progress", "--no-prune", "--all"]
        }

        do {
            _ = try await runStreaming(arguments, cwd: root, progress: progress)
        } catch let error as GitError {
            // Two exit codes, measured on git 2.54, and neither is read as a diagnosis: a
            // single-remote failure exits 128, a partial `--all` exits 1. Only the words are
            // consulted, and anything the parser does not recognise is rethrown as git's own.
            guard case .commandFailed(_, let stderr) = error else { throw error }
            guard let failure = RemoteFailureParser.parse(stderr: stderr) else { throw error }
            throw failure
        }
    }

    /// Refuses a remote name before git runs. See `GitRemoteBackend.fetch` for what git does
    /// with each of the three shapes and why `"."` is the one that earns this check its keep.
    ///
    /// It is deliberately *not* `requireName`: that one throws a `BranchOperationError`, which
    /// belongs to a different protocol, and it does not know about `"."` — a perfectly good
    /// branch name and a thoroughly bad remote.
    private func requireRemoteName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !name.hasPrefix("-"), trimmed != "." else {
            throw RemoteOperationError.noRemote
        }
    }
}
