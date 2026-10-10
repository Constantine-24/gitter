#if DEBUG

    import Foundation

    /// E2 Task 5's steps of `GITTER_DEBUG_BRANCH_ACTION` (see `DebugLaunchHooks+Branches` for the
    /// grammar and the waiting): the target window's sheet, driven through its own controls
    /// (`HarnessControls`) — the action its button runs, the binding its toggle, field or picker
    /// writes — rather than through the store's `confirm…`:
    ///
    ///   controls                   every control the sheet registered, in the order their
    ///                              views first registered (SwiftUI's, not top to bottom):
    ///                              `control: <kind> "<label>" = "<state>" [enabled|disabled]`,
    ///                              a picker's with `[options: a|b]`.
    ///   press:<label>              that button.
    ///   tick:<label>[=on|off]      that toggle; bare, on.
    ///   fill:<label>=<text>        that field's text (the rest, `=` and `:` included; never a `;`).
    ///   choose:<label>=<option>    that picker's option, by the label it shows.
    ///
    /// The label is the one on screen (a field's or picker's without its colon), and the value is
    /// split from it at the first `=`. Each step first lets the window draw what the step before
    /// it changed, then waits up to five seconds for its control to be the only one of that kind
    /// and label and to be enabled — a sheet still appearing, a name still being checked — and
    /// then acts, or logs `control refused: <kind> <why>` (not on screen, more than one, disabled,
    /// a value it does not take) and runs nothing. The wait after it is the step list's own.
    extension DebugLaunchHooks {

        static let controlCommands: Set<String> = ["controls", "press", "tick", "fill", "choose"]

        /// One `press:`, `tick:`, `fill:` or `choose:`, read.
        struct ControlRequest: Equatable {
            let kind: HarnessControls.Control.Kind
            let label: String
            let value: String?
        }

        /// `rest` (everything after the step's first `:`) split at its first `=`; nil for a step
        /// that names no label, or a `fill:` or `choose:` that names no value.
        static func controlRequest(_ command: String, _ rest: String) -> ControlRequest? {
            let parts = rest.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let label = parts[0]
            let value = parts.count > 1 ? parts[1] : nil
            guard !label.isEmpty else { return nil }
            switch command {
            case "press": return ControlRequest(kind: .button, label: rest, value: nil)
            case "tick": return ControlRequest(kind: .toggle, label: label, value: value ?? "on")
            case "fill": return value.map { ControlRequest(kind: .field, label: label, value: $0) }
            case "choose": return value.map { ControlRequest(kind: .picker, label: label, value: $0) }
            default: return nil
            }
        }

        static func controlLine(_ control: HarnessControls.Control) -> String {
            "control: \(control.kind.rawValue) \"\(control.label)\" = \"\(control.state())\" "
                + "[\(control.isEnabled ? "enabled" : "disabled")]"
                + (control.kind == .picker ? " [options: \(control.options.joined(separator: "|"))]" : "")
        }

        /// The target's registered controls in the sheet it shows now (`activeSheet`), never those
        /// of a sheet still being dismissed.
        static func liveControls(_ store: RepositoryStore) -> [HarnessControls.Control] {
            HarnessControls.shared.controls(store: ObjectIdentifier(store), sheet: store.activeSheet?.id)
        }

        /// `request` on `store`'s sheet on screen (`HarnessControls.act`), or why not.
        static func controlAct(_ request: ControlRequest, store: RepositoryStore) -> HarnessControls.Refusal? {
            HarnessControls.shared.act(
                request.label, value: request.value, kind: request.kind, store: ObjectIdentifier(store),
                sheet: store.activeSheet?.id)
        }

        static func controlStep(_ command: String, step: String, store: RepositoryStore) async {
            let rest = step.count > command.count ? String(step.dropFirst(command.count + 1)) : ""
            // Time for the sheet to draw — and register — what the step before changed: a new
            // sheet's controls, a binding's effect on another control's `isEnabled`. (Which sheet
            // an entry belongs to is not left to this: `liveControls` takes the one on screen.)
            try? await Task.sleep(for: .milliseconds(300))

            guard command != "controls" else {
                _ = await settled({ !liveControls(store).isEmpty })
                let controls = liveControls(store)
                if controls.isEmpty { log("control: none (store \(store.debugSerial))") }
                for control in controls { log(controlLine(control)) }
                return
            }
            guard let request = controlRequest(command, rest) else {
                return log("control refused: \(step) needs <label>\(command == "press" || command == "tick" ? "" : "=<value>")")
            }
            // Present once, and enabled: what a user waits for before clicking.
            _ = await settled({
                let matches = liveControls(store).filter { $0.kind == request.kind && $0.label == request.label }
                return matches.count == 1 && matches[0].isEnabled
            })
            if let refusal = controlAct(request, store: store) {
                let offered =
                    if case .invalid = refusal, request.kind == .picker {
                        liveControls(store).first { $0.kind == .picker && $0.label == request.label }
                            .map { " [options: \($0.options.joined(separator: "|"))]" } ?? ""
                    } else { "" }
                return log("control refused: \(request.kind.rawValue) \(refusal)\(offered)")
            }
            switch request.kind {
            case .button: log("control: pressed \"\(request.label)\"")
            case .toggle: log("control: ticked \"\(request.label)\" \(request.value ?? "")")
            case .field: log("control: filled \"\(request.label)\" = \"\(request.value ?? "")\"")
            case .picker: log("control: chose \"\(request.label)\" = \"\(request.value ?? "")\"")
            }
        }

        /// Polls `condition` for up to five seconds and says nothing when it runs out: the step's
        /// own refusal line says what was not there.
        private static func settled(_ condition: @MainActor () -> Bool) async -> Bool {
            for _ in 0..<50 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return condition()
        }
    }

#endif
