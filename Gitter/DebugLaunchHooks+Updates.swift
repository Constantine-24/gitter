#if DEBUG

    import AppKit
    import Foundation

    /// The update notices' steps, in the `GITTER_DEBUG_BRANCH_ACTION` / `GITTER_DEBUG_THEN` list.
    /// Each runs under the launch guard like every step (`runBranchActions`), and only in a launch
    /// whose `GITTER_DEBUG_UPDATE_FEED` names a `file://` or `http://127.0.0.1` feed — otherwise
    /// `AppModel.updates` is nil, and the step says so and does nothing.
    ///
    ///     update:check     the manual check (Check for Updates…): started, or joined, and not
    ///                      waited for — the steps after it run while it is in flight
    ///     update:look      one automatic look, due or not (the toggle still counts), waited for,
    ///                      then the held result shown if it may be — the loop's own two calls
    ///     update:wait      wait (up to 40 s, past the 30 s resource timeout) for no check in flight
    ///     update:press:<download|later|skip|page|close>
    ///                      that button of the update window, through its own call; `close` is
    ///                      the close button's `performClose`
    ///     update:state     `UPDATE state: showing <v|none>, key <yes|no>, checking <yes|no>,
    ///                      skipped <v|none>, last <iso|none>`, then `UPDATE held: <v|none>`
    ///
    /// A Download or Release page press opens nothing: a scripted launch's opener only logs
    /// `UPDATE would open <url>` to the event log (`UpdateOpener.live`).
    extension DebugLaunchHooks {

        static func updateStep(_ step: String) async {
            let fields = step.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let action = fields.count > 1 ? fields[1] : ""
            guard let checker = AppModel.updates else {
                return log(
                    "UPDATE \(action): no update checker (\(UpdateChecker.feedVariable) names no file:// or "
                        + "http://127.0.0.1 feed)")
            }
            let panel = AppModel.updatePanel
            switch action {
            case "check":
                checker.checkNow()
                log("UPDATE check: started, checking \(yesNo(checker.isChecking))")
            case "look":
                let checked = await checker.look(force: true)
                checker.showHeldIfPossible()
                log("UPDATE look: \(checked ? "checked" : "nothing to do (no running version, or the toggle off)")")
            case "wait":
                _ = await wait({ !checker.isChecking }, seconds: 40, what: "update:wait: the check in flight")
                log("UPDATE wait: checking \(yesNo(checker.isChecking))")
            case "press":
                guard fields.count == 3, let button = UpdateButton(rawValue: fields[2]) else {
                    return log("UPDATE press: no button \"\(fields.dropFirst(2).joined(separator: ":"))\"")
                }
                guard panel.isShowing else { return log("UPDATE press \(button.rawValue): no update window on screen") }
                panel.press(button)
                // A frame, so a close has landed.
                try? await Task.sleep(for: .milliseconds(200))
                log("UPDATE press \(button.rawValue): showing \(panel.shownVersion?.description ?? "none")")
            case "state":
                let defaults = UserDefaults.standard
                let last = (defaults.object(forKey: UpdateChecker.lastCheckKey) as? Date)
                    .map { ISO8601DateFormatter().string(from: $0) }
                log(
                    "UPDATE state: showing \(panel.shownVersion?.description ?? "none"), "
                        + "key \(yesNo(panel.panel?.isKeyWindow == true)), checking \(yesNo(checker.isChecking)), "
                        + "skipped \(defaults.string(forKey: UpdateChecker.skippedKey) ?? "none"), last \(last ?? "none")")
                log("UPDATE held: \(checker.debugHeldVersion?.description ?? "none")")
            default:
                log("unknown step: \(step)")
            }
        }

        private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
    }

#endif
