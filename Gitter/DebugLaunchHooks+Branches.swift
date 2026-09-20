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
    /// Steps run in order, each waiting for the mutation the one before it started. `abort`,
    /// `forcedelete` and `confirmleave` answer a confirmation, which is why several steps in one
    /// launch matter: those sheets cannot be reached any other way.
    ///
    /// `delete:` and `forcedelete:` **act** — they run `git branch -d`/`-D`. Every `sheet:` step
    /// only opens a sheet; `sheet:delete:<b>` in particular reads the warning's numbers instead
    /// of letting `-d` refuse, so it cannot delete a branch git considers merged.
    ///
    /// After every step one line goes to stderr. `head` and `selection` ride along because the
    /// store's own answer to "where are we now" cannot be read from git, and "the selection
    /// returns to the working copy" is part of what these actions promise:
    ///
    ///   BRANCH_ACTION result: <sheet or nil> | notice: <…> | error: <…> | head: <…> |
    ///   selection: <…>
    extension DebugLaunchHooks {

        static var branchActionSpec: String? {
            ProcessInfo.processInfo.environment["GITTER_DEBUG_BRANCH_ACTION"]
        }

        static func runBranchActions(_ spec: String, store: RepositoryStore) async {
            for step in spec.split(separator: ";") {
                log("step: \(step)")
                await perform(String(step), store: store)
                // `mutate` claims the store synchronously, so by now `isMutating` is already
                // true for anything that runs git; a step that only opens a sheet never sets it
                // and this returns at once.
                _ = await wait({ !store.isMutating })
                log(
                    "result: \(describe(store.activeSheet, store)) | notice: \(store.notice ?? "nil") "
                        + "| error: \(store.lastError?.replacingOccurrences(of: "\n", with: " ") ?? "nil") "
                        + "| head: \(store.headLabel) | selection: \(store.selection)")
            }
        }

        // MARK: - One step

        private static func perform(_ step: String, store: RepositoryStore) async {
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
            case "forcedelete":
                // The warning first, then its answer — the same two steps a user takes, and the
                // only way in: `confirmForceDelete` refuses without a matching sheet on screen.
                // A branch `-d` deletes cleanly never reaches the second half, which is right.
                if let first {
                    store.requestDelete(first)
                    _ = await wait({ !store.isMutating })
                    // Reached for unconditionally, on purpose: the store's own guard is the only
                    // thing that may stop it. For a branch `-d` deleted cleanly no warning was
                    // ever shown, and a `confirmForceDelete` that ran anyway would be visible —
                    // it would put "There is no branch named …" in the banner.
                    store.confirmForceDelete(first)
                    _ = await wait({ !store.isMutating })
                }
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
            case "sheet": await sheet(first, second, store: store)
            default: log("unknown step: \(step)")
            }
        }

        private static func sheet(_ which: String?, _ name: String?, store: RepositoryStore)
            async
        {
            switch which {
            case "new": store.requestNewBranch()
            case "rename": name.map { store.requestRename($0) }
            case "merge": name.map { store.requestMerge($0) }
            // `previewDeleteWarning`, never `requestDelete`: this step says it opens a sheet, and
            // `requestDelete` runs `git branch -d`, which would silently delete a merged branch.
            // It reads the count in its own task and takes no mutation lock, so wait for the
            // sheet itself rather than for `isMutating`.
            case "delete":
                // Cleared first so the wait below cannot be satisfied by a sheet an earlier step
                // left up, which would print the previous step's answer for this one.
                store.activeSheet = nil
                name.map { store.previewDeleteWarning($0) }
                _ = await wait({ store.activeSheet != nil })
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
        private static func describe(_ sheet: BranchSheet?, _ store: RepositoryStore) -> String {
            switch sheet {
            case nil: "nil"
            case .newBranch(let startPoint, let label):
                "newBranch(startPoint: \(startPoint ?? "HEAD"), label: \(label))"
            case .rename(let name): "rename(\(name))"
            case .merge(let name): "merge(\(name))"
            case .deleteUnmerged(let name, let count, let tip):
                "deleteUnmerged(\(name), uniqueCommits: \(count), tip: \(tip.prefix(7)))"
            // The files matter more than the operation's name: they are what the sheet promises
            // to list, and what a rebase takes and the other five keep differs between them.
            case .abort(let operation):
                "abort(\(operation), reverts: \(store.filesRevertedByAbort.map(\.path)), "
                    + "unstagedToo: \(store.abortAlsoDiscardsUnstagedEdits), "
                    + "rewinds: \(store.abortRewindsCommits))"
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
