#if DEBUG

    import AppKit
    import CryptoKit
    import Foundation
    import GitCore

    /// The resolver's steps of `GITTER_DEBUG_BRANCH_ACTION` (see `DebugLaunchHooks+Branches` for
    /// the grammar and the waiting):
    ///
    ///   select:<path>           selects the working copy's file (the unstaged row of a conflicted
    ///                           one, the staged row of a resolved one) and waits for the
    ///                           resolver's read; logs `resolver: …`.
    ///   blocks:<path>:<O|T|B|b…>  selects the file if needed and chooses each block in turn: O
    ///                           ours, T theirs, B both (ours first), b both (theirs first), `.`
    ///                           leaves one unchosen. Writes nothing; logs the choices and the
    ///                           composed file (`ResolverPreview.file`), or `incomplete`.
    ///   resolve                 Resolve File, for the choices made.
    ///   take:ours|theirs:<path> Take Ours / Take Theirs (or the whole-file kind's own title).
    ///   deletefile:<path>       Delete the File. (`delete:` is the branch step.)
    ///   keep:<path>             Keep Their / Our Version.
    ///   confirmreplace          the Replace sheet's destructive button, for what the sheet shows.
    ///   markresolved:<path>     Mark Resolved.
    ///   confirmmarkers          the Mark Resolved sheet's destructive button.
    ///   reopen:<path>           selects the resolved file, waits for `canReopen`, and opens
    ///                           Reopen Conflict… (nothing more); logs `reopen: not offered` when
    ///                           it is not.
    ///   confirmreopen           the Reopen sheet's destructive button.
    ///   resolver                logs the resolver's state without doing anything.
    ///   noticeshow              the sticky notice's Show Copy, as its button runs it.
    ///   cancelsheet             what a sheet's Cancel does (`activeSheet = nil`): a sheet up
    ///                           keeps `quit` from quitting.
    ///
    /// Each write step goes through the store's own entry point, which does nothing where the
    /// resolver offers no such button; the step logs the offer first, so a refusal is visible.
    extension DebugLaunchHooks {

        static let conflictCommands: Set<String> = [
            "select", "blocks", "resolve", "take", "deletefile", "keep", "confirmreplace", "markresolved",
            "confirmmarkers", "reopen", "confirmreopen", "resolver", "noticeshow", "cancelsheet",
        ]

        static func conflictStep(_ command: String, step: String, store: RepositoryStore) async {
            let rest = String(step.dropFirst(command.count + 1))
            switch command {
            case "select":
                await select(rest, store: store)
            case "blocks":
                // The path may hold colons; the choices are after the last one.
                guard let colon = rest.lastIndex(of: ":") else {
                    log("blocks: expected <path>:<choices>")
                    return
                }
                let path = String(rest[..<colon])
                guard await select(path, store: store) else { return }
                for (index, letter) in rest[rest.index(after: colon)...].enumerated() {
                    let choice: BlockChoice? =
                        switch letter {
                        case "O": .ours
                        case "T": .theirs
                        case "B": .oursThenTheirs
                        case "b": .theirsThenOurs
                        default: nil
                        }
                    if let choice { store.chooseBlock(index, choice) }
                }
                let preview: String =
                    if case .blocks(let segments)? = store.selectedConflict?.presentation,
                        let data = ResolverPreview.file(segments, store.resolverChoices)
                    {
                        "\(data.count) bytes sha256 \(ConflictSnapshotHash.hex(data)) "
                            + "\(String(decoding: data, as: UTF8.self).debugDescription)"
                    } else {
                        "incomplete"
                    }
                log("blocks: choices \(store.blockChoices.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }) "
                    + "remaining: \(store.resolverChoices.remaining) preview: \(preview)")
            case "resolve":
                logOffer(.resolveFile, store)
                store.resolveSelectedFile()
            case "take":
                let parts = rest.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let side: ConflictSide = parts[0] == "ours" ? .ours : parts[0] == "theirs" ? .theirs : nil
                else {
                    log("take: expected ours|theirs:<path>")
                    return
                }
                guard await select(parts[1], store: store) else { return }
                logOffer(side == .ours ? .takeOurs : .takeTheirs, store)
                store.takeSide(side)
            case "deletefile":
                guard await select(rest, store: store) else { return }
                logOffer(.delete, store)
                store.deleteConflictedFile()
            case "keep":
                guard await select(rest, store: store) else { return }
                logOffer(.keep, store)
                store.keepConflictedFile()
            case "confirmreplace":
                guard case .replaceHandEdited(let snapshot, let pending) = store.activeSheet else {
                    log("confirmreplace: no replace sheet")
                    return
                }
                store.confirmReplaceHandEdited(snapshot, pending)
            case "markresolved":
                guard await select(rest, store: store) else { return }
                logOffer(.markResolved, store)
                store.markSelectedResolved()
            case "confirmmarkers":
                guard case .markResolved(let snapshot, _) = store.activeSheet else {
                    log("confirmmarkers: no mark resolved sheet")
                    return
                }
                store.confirmMarkResolved(snapshot)
            case "reopen":
                guard store.snapshot?.status.files.contains(where: { $0.path == rest }) == true else {
                    log("reopen: no file \(rest)")
                    return
                }
                store.stagedView = true
                store.selectPath(rest)
                guard await wait({ store.reopenablePath == rest }) else {
                    log("reopen: not offered for \(rest)")
                    return
                }
                store.requestReopen(rest)
                if case .reopen(rest, _)? = store.activeSheet {} else {
                    log("reopen: no sheet for \(rest) | blocked: \(store.conflictActionBlockedReason ?? "nil")")
                }
            case "confirmreopen":
                guard case .reopen(let path, _) = store.activeSheet else {
                    log("confirmreopen: no reopen sheet")
                    return
                }
                store.confirmReopen(path)
            case "resolver":
                logResolver(store)
            case "cancelsheet":
                store.activeSheet = nil
            case "noticeshow":
                let show = store.stickyNotice?.actions.first {
                    if case .showStash = $0 { true } else { false }
                }
                guard let show, case .showStash(let stash) = show else {
                    log("noticeshow: no Show Copy")
                    return
                }
                log("noticeshow: \(stash.sha) \"\(stash.message)\"")
                let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.debug-noticeshow"))
                defer { pasteboard.releaseGlobally() }
                store.perform(show, pasteboard: pasteboard) { _ in }
                _ = await wait({ store.stashContents != nil })
                log("noticeshow: selection \(store.selection)")
            default:
                log("unknown step: \(step)")
            }
        }

        /// Selects `path` in the working copy and waits for the resolver's read; false (and a
        /// log line) when there is no such conflicted file.
        @discardableResult
        private static func select(_ path: String, store: RepositoryStore) async -> Bool {
            guard let file = store.snapshot?.status.files.first(where: { $0.path == path }) else {
                log("select: no file \(path)")
                return false
            }
            let conflicted = file.conflict != nil
            if store.selectedPath != path || (conflicted && store.stagedView) {
                store.stagedView = !conflicted && file.unstaged == nil
                store.selectPath(path)
            }
            if conflicted {
                guard await wait({ store.selectedConflict != nil }) else {
                    log("select: no resolver for \(path) after ten seconds | error: \(store.lastError ?? "nil")")
                    return false
                }
            } else {
                _ = await wait({ store.reopenablePath == path }, seconds: 3)
            }
            logResolver(store)
            return true
        }

        private static func logOffer(_ action: ResolverAction, _ store: RepositoryStore) {
            guard let document = store.selectedConflict else {
                log("offer \(action): no resolver on screen")
                return
            }
            let offered = ResolverOffer.actions(for: document).contains(action)
            log("offer \(action): \(offered ? "offered" : "NOT offered") \"\(ConflictWording.title(action, document.snapshot.file))\" "
                + "blocked: \(store.conflictActionBlockedReason ?? "nil")")
        }

        static func logResolver(_ store: RepositoryStore) {
            guard let document = store.selectedConflict else {
                log("resolver: none | selected: \(store.selectedPath ?? "nil") reopenable: \(store.reopenablePath ?? "nil")")
                return
            }
            let file = document.snapshot.file
            let shown: String =
                switch document.presentation {
                case .blocks:
                    ResolverOffer.blocks(of: document).map { "blocks(\($0.count))" } ?? "changedSinceConflict"
                case .wholeFile(let reason): "wholeFile(\(reason))"
                case .submodule: "submodule"
                }
            let sides = store.conflictSides
            log("resolver: \(file.path) \(ConflictWording.badge(file.kind)) \"\(ConflictWording.kind(file, sides: sides))\" "
                + "| \(shown) | matches: \(document.matchesGitsConflict) "
                + "| hash: \(document.snapshot.worktreeHash?.prefix(12) ?? "nil") "
                + "| sides: \(sides.ours) / \(sides.theirs) "
                + "| actions: \(ResolverOffer.actions(for: document).map { ConflictWording.title($0, file) }) "
                + "| choices: \(store.blockChoices.count)")
        }

        static func describeConflictSheet(_ sheet: BranchSheet?) -> String? {
            switch sheet {
            case .replaceHandEdited(let snapshot, let pending)?:
                "replaceHandEdited(\(snapshot.file.path), \(pending), hash: \(snapshot.worktreeHash?.prefix(12) ?? "nil"))"
            case .markResolved(let snapshot, let markers)?:
                "markResolved(\(snapshot.file.path), markers: \(markers))"
            case .reopen(let path, let hash)?:
                "reopen(\(path), hash: \(hash?.prefix(12) ?? "nil"))"
            default: nil
            }
        }
    }

    /// SHA-256 for the harness's preview line, so the shell can compare it with `shasum -a 256`.
    enum ConflictSnapshotHash {
        static func hex(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

#endif
