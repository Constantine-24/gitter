#if DEBUG

    import Foundation
    import GitCore

    /// Driving the branch actions and sheets from the environment, for the same reason as the
    /// rest of these hooks: the sidebar's context menus are AppKit menus that in-process clicks
    /// cannot open, so without this there is no way to reach `switchTo`, `merge` or a
    /// confirmation sheet from a script.
    ///
    ///   GITTER_DEBUG_BRANCH_ACTION=<step>[;<step>…]
    ///
    ///     switch:<branch>              track:<remote>/<branch>      detach:<revision>
    ///     create:<name>[:<start>]      createswitch:<name>[:<start>]
    ///     rename:<old>:<new>           delete:<branch>              forcedelete:<branch>
    ///     merge:<branch>:<ff|noff|squash>
    ///     abort                        confirmleave
    ///     sheet:new | sheet:rename:<b> | sheet:merge:<b> | sheet:delete:<b> | sheet:abort
    ///
    /// Steps run in order, each waiting for the mutation the one before it started. `abort` and
    /// `confirmleave` answer the sheet the previous step opened, which is why several steps in
    /// one launch matter: a confirmation cannot be reached any other way.
    ///
    /// After every step one line goes to stderr:
    ///
    ///   BRANCH_ACTION result: <sheet or nil> | notice: <…> | error: <…>
    extension DebugLaunchHooks {

        static var branchActionSpec: String? {
            ProcessInfo.processInfo.environment["GITTER_DEBUG_BRANCH_ACTION"]
        }

        static func runBranchActions(_ spec: String, store: RepositoryStore) async {
            for step in spec.split(separator: ";") {
                log("step: \(step)")
                perform(String(step), store: store)
                // `mutate` claims the store synchronously, so by now `isMutating` is already
                // true for anything that runs git; a step that only opens a sheet never sets it
                // and this returns at once.
                _ = await wait({ !store.isMutating })
                log(
                    "result: \(describe(store.activeSheet)) | notice: \(store.notice ?? "nil") "
                        + "| error: \(store.lastError?.replacingOccurrences(of: "\n", with: " ") ?? "nil")")
            }
        }

        // MARK: - One step

        private static func perform(_ step: String, store: RepositoryStore) {
            // `maxSplits` so a branch name may contain a colon-free remainder only where the
            // grammar says so: `merge:<b>:<mode>` has exactly three fields, `rename` three,
            // `create` two or three.
            let fields = step.split(separator: ":").map(String.init)
            guard let command = fields.first else { return }
            let first = fields.count > 1 ? fields[1] : nil
            let second = fields.count > 2 ? fields[2] : nil

            switch command {
            case "switch": first.map { store.switchTo(branch: $0) }
            // A remote branch is spelled `origin/x`, which has no colon, so re-joining is only
            // needed for the ones that take two names.
            case "track": first.map { store.track(remoteBranch: $0) }
            case "detach": first.map { store.detach(at: $0) }
            case "create":
                first.map {
                    store.createBranch(named: $0, startPoint: second, switchTo: false)
                }
            case "createswitch":
                first.map {
                    store.createBranch(named: $0, startPoint: second, switchTo: true)
                }
            case "rename":
                if let first, let second { store.rename(first, to: second) }
            case "delete": first.map { store.requestDelete($0) }
            case "forcedelete": first.map { store.confirmForceDelete($0) }
            case "merge":
                if let first, let mode = mergeMode(second) { store.merge(first, mode: mode) }
            case "abort":
                // The sheet first, then its answer: the same two steps a user takes, and the
                // only way to exercise `confirmAbort`'s "which operation" argument honestly.
                store.requestAbort()
                if case .abort(let operation) = store.activeSheet {
                    store.confirmAbort(operation)
                }
            case "confirmleave": store.confirmLeaveDetached()
            case "sheet": sheet(first, second, store: store)
            default: log("unknown step: \(step)")
            }
        }

        private static func sheet(_ which: String?, _ name: String?, store: RepositoryStore) {
            switch which {
            case "new": store.requestNewBranch()
            case "rename": name.map { store.requestRename($0) }
            case "merge": name.map { store.requestMerge($0) }
            case "delete": name.map { store.requestDelete($0) }
            case "abort": store.requestAbort()
            default: log("unknown sheet: \(which ?? "")")
            }
        }

        private static func mergeMode(_ name: String?) -> MergeMode? {
            switch name {
            case "ff": .fastForwardIfPossible
            case "noff": .alwaysMergeCommit
            case "squash": .squash
            default: nil
            }
        }

        // MARK: - Reporting

        /// Every field a shell might want to assert on, including the ones that make a
        /// confirmation meaningful (the unmerged count and tip, the stranded-commit count).
        private static func describe(_ sheet: BranchSheet?) -> String {
            switch sheet {
            case nil: "nil"
            case .newBranch(let startPoint, let label):
                "newBranch(startPoint: \(startPoint ?? "HEAD"), label: \(label))"
            case .rename(let name): "rename(\(name))"
            case .merge(let name): "merge(\(name))"
            case .deleteUnmerged(let name, let count, let tip):
                "deleteUnmerged(\(name), uniqueCommits: \(count), tip: \(tip.prefix(7)))"
            case .abort(let operation): "abort(\(operation))"
            case .leaveDetached(let count, let sha, let action):
                "leaveDetached(unreferencedCommits: \(count), head: \(sha.prefix(7)), "
                    + "then: \(action))"
            }
        }

        private static func log(_ message: String) {
            FileHandle.standardError.write(Data("BRANCH_ACTION \(message)\n".utf8))
        }
    }

#endif
