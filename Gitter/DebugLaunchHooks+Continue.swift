#if DEBUG

    import Foundation
    import GitCore

    /// The operation bar's and the composer's steps of `GITTER_DEBUG_BRANCH_ACTION` (see
    /// `DebugLaunchHooks+Branches` for the grammar and the waiting):
    ///
    ///   bar                  logs the bar: its sentence, Continue's and Skip's state, the line
    ///                        under it, the stop as read, the draft and the composer's note.
    ///   message:<text>       replaces the draft with <text> (`\n` for a line break): the first
    ///                        line is the subject, the rest after a blank line the body.
    ///   continue             the bar's Continue (the composer's is the same call); logs the bar
    ///                        first. Runs, or opens the sheet the stop needs.
    ///   confirmempty         the empty-result sheet's button.
    ///   confirmothers        the other-staged sheet's button.
    ///   skip                 Skip This Commit…: waits for its sheet (nothing more).
    ///   confirmskip          the Skip sheet's destructive button, for the commit it shows.
    ///   stageall             the Stage All button: stages at once, or (during an operation with
    ///                        files outside it) waits for its sheet.
    ///   confirmstageall      the Stage All sheet's button.
    ///   commitdraft          the composer's Commit with the draft as it is (`commit:` replaces
    ///                        the subject): a merge's or squash's prefilled message.
    ///   usemessage           the composer note's "Use <sha>'s Message" (a draft written for
    ///                        another commit).
    ///   keepmessage          the composer note's "Keep This Message".
    ///
    /// Each step goes through the store's own entry point, which does nothing where the button is
    /// off; `bar` and the `continue`/`skip` lines say why.
    extension DebugLaunchHooks {

        static let continueCommands: Set<String> = [
            "bar", "message", "continue", "confirmempty", "confirmothers", "skip", "confirmskip", "stageall",
            "confirmstageall", "commitdraft", "usemessage", "keepmessage",
        ]

        static func continueStep(_ command: String, step: String, store: RepositoryStore) async {
            switch command {
            case "bar":
                logBar(store)
            case "message":
                let text = String(step.dropFirst("message:".count)).replacingOccurrences(of: "\\n", with: "\n")
                var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                store.draft.subject = lines.isEmpty ? "" : lines.removeFirst()
                if lines.first?.isEmpty == true { lines.removeFirst() }
                store.draft.body = lines.joined(separator: "\n")
                log("message: subject \(store.draft.subject.debugDescription) body \(store.draft.body.debugDescription)")
            case "continue":
                logBar(store)
                store.continueOperation()
            case "confirmempty":
                guard case .continueEmpty = store.activeSheet else {
                    log("confirmempty: no empty-result sheet")
                    return
                }
                store.confirmContinueEmpty()
            case "confirmothers":
                guard case .continueOthers = store.activeSheet else {
                    log("confirmothers: no other-staged sheet")
                    return
                }
                store.confirmContinueOthers()
            case "skip":
                logBar(store)
                store.requestSkip()
                if !(await wait({ store.activeSheet != nil || store.lastError != nil }, seconds: 10)) {
                    log("skip: no sheet | state: \(describe(store.skipState))")
                }
            case "confirmskip":
                guard case .skip(_, let current, _) = store.activeSheet else {
                    log("confirmskip: no skip sheet")
                    return
                }
                store.confirmSkip(stoppedAt: current.sha)
            case "stageall":
                store.requestStageAll()
                // During an operation the sheet (or the mutation) starts after a read.
                _ = await wait({ store.activeSheet != nil || store.isMutating }, seconds: 5)
            case "confirmstageall":
                guard case .stageAll = store.activeSheet else {
                    log("confirmstageall: no stage all sheet")
                    return
                }
                store.confirmStageAll()
            case "usemessage":
                store.useOperationMessage()
                log("usemessage: draft \(store.draft.subject.debugDescription) \(store.draft.body.debugDescription)")
            case "keepmessage":
                store.keepDraftMessage()
                log("keepmessage: foreign \(store.draft.foreign.map { "\($0)" } ?? "nil")")
            case "commitdraft":
                log("commitdraft: \(store.draft.message.debugDescription)")
                store.commit()
            default:
                log("unknown step: \(step)")
            }
        }

        private static func describe(_ state: BarActionState) -> String {
            switch state {
            case .enabled: "enabled"
            case .disabled(let reason): "disabled(\(reason))"
            }
        }

        static func logBar(_ store: RepositoryStore) {
            guard let operation = store.operationInProgress else {
                let halted = store.haltedSequence.map {
                    "\($0.operation) total \($0.total) notApplied \($0.notApplied.map { "\($0.sha.prefix(7)) \($0.subject)" }) "
                        + "| \(ContinueWording.halted($0)) | \(ContinueWording.haltedWayForward($0))"
                }
                log("bar: none | halted: \(halted ?? "nil") | draft: \(store.draft.subject.debugDescription) "
                    + "\(store.draft.body.debugDescription)")
                return
            }
            let stop = store.operationStop
            let progress = stop?.progress
            log("bar: \(operation) \"\(store.operationBarSentence)\"")
            log("bar continue: \(store.continueTitle) \(describe(store.continueState)) "
                + "| skip: \(describe(store.skipState)) | line: \(store.continueReasonLine ?? "nil")")
            let current = progress?.current.map { "\($0.sha.prefix(7)) \($0.subject)" } ?? "nil"
            log("bar stop: step \(progress?.step.map(String.init) ?? "nil")/\(progress?.total.map(String.init) ?? "nil") "
                + "remaining \(progress?.remaining.map(String.init) ?? "nil") current \(current) "
                + "| readiness: \(stop?.continueReadiness.map { "\($0)" } ?? "nil") "
                + "| skipReadiness: \(stop?.skipReadiness.map { "\($0)" } ?? "nil") "
                + "| otherStagedAtEmpty: \(stop?.otherStagedAtEmpty ?? []) | unstagedAtEmpty: \(stop?.unstagedAtEmpty ?? []) "
                + "| failure: \(stop?.readFailure ?? "nil")")
            log("bar message: \(stop?.pendingMessage.map { "\($0.commentChar) \($0.text.debugDescription)" } ?? "nil") "
                + "| draft: \(store.draft.subject.debugDescription) \(store.draft.body.debugDescription) "
                + "| note: \(store.composerCommentNote ?? "nil") "
                + "| foreign: \(store.composerForeignDraft.map { "written for \($0.writtenFor.map { String($0.sha.prefix(7)) } ?? "nil")" } ?? "nil") "
                + "| untouched prefill: \(store.draft.isUntouchedPrefill)")
        }

        static func describeContinueSheet(_ sheet: BranchSheet?) -> String? {
            switch sheet {
            case .continueEmpty(let current, let otherStaged)?:
                "continueEmpty(\(current.sha.prefix(7)) \(current.subject), otherStaged: \(otherStaged), "
                    + "title: \(ContinueWording.emptyTitle(current, otherStaged: otherStaged)), "
                    + "body: \(ContinueWording.emptyBody(current, otherStaged: otherStaged)), "
                    + "button: \(ContinueWording.emptyButton(otherStaged: otherStaged)))"
            case .continueOthers(let operation, let current, let paths)?:
                "continueOthers(\(operation), \(current.map { String($0.sha.prefix(7)) } ?? "nil"), paths: \(paths), "
                    + "body: \(ContinueWording.othersBody(operation, current, paths)))"
            case .skip(let operation, let current, let paths)?:
                "skip(\(operation), \(current.sha) \(current.subject), paths: \(paths), "
                    + "body: \(ContinueWording.skipBody(operation)) \(ContinueWording.skipFiles(paths)) "
                    + "\(ContinueWording.skipDestination(current, paths: paths) ?? ""))"
            case .stageAll(let operation, let sweep, let known)?:
                "stageAll(\(operation), sweep: \(sweep), known: \(known), "
                    + "body: \(ContinueWording.stageAllBody(operation, count: sweep.count, known: known)))"
            default: nil
            }
        }
    }

#endif
