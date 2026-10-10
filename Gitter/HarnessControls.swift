import SwiftUI

#if DEBUG

    /// The controls on screen in each window's sheet, for the harness (E2 Task 5): what the
    /// `controls`, `press:`, `tick:`, `fill:` and `choose:` steps read and drive
    /// (`DebugLaunchHooks+Controls`). A script cannot click or type inside a SwiftUI sheet —
    /// `alertbutton:` only finds `NSButton`s, and a SwiftUI button is none — so a sheet registers
    /// its own buttons, toggles, fields and pickers here by their visible label, each with the
    /// view's own action or binding: a step runs exactly what the control runs.
    ///
    /// A plain class, not `@Observable`: the modifiers write it from their bodies (each body's
    /// evaluation refreshes its entry, so the entry holds the current action and `isEnabled`), and
    /// nothing draws from it. Keyed by the store whose sheet it is; an entry leaves on its view's
    /// `onDisappear`, by its own token only (RF4).
    @MainActor final class HarnessControls {
        static let shared = HarnessControls()

        /// One control as its view last drew it.
        struct Control {
            enum Kind: String { case button, toggle, field, picker }

            let kind: Kind
            let label: String
            /// From the environment at the control: the modifier sits inside the control's own
            /// `.disabled(…)`, so it sees it.
            let isEnabled: Bool
            /// A toggle's "on" / "off", a field's text, a picker's option label (`noOption` for a
            /// selection none of its options has), a button's "".
            let state: @MainActor () -> String
            /// A picker's option labels, in order; empty for the others.
            let options: [String]
            /// Press (nil), set "on" / "off", the text, the option label. False: not a value this
            /// control takes, and nothing was written.
            let perform: @MainActor (String?) -> Bool
            /// One per modifier instance.
            let token: UUID
            /// The `BranchSheet.id` of the sheet it was drawn in (`harnessSheet`), nil outside one.
            /// A sheet replaced or closed stays in the tree until its dismissal ends (~0.28 s,
            /// M1.5), its entries with it: only the entries of the sheet on screen are acted on.
            let sheet: AnyHashable?
        }

        /// Why a step did not act.
        enum Refusal: Equatable, CustomStringConvertible {
            case missing(String)
            case duplicate(String)
            case disabled(String)
            case invalid(String, String)
            /// A picker's option label that more than one of its options shows.
            case ambiguous(String, String)

            var description: String {
                switch self {
                case .missing(let label): "\"\(label)\" is not on screen"
                case .duplicate(let label): "\"\(label)\" names more than one control"
                case .disabled(let label): "\"\(label)\" is disabled"
                case .invalid(let label, let value): "\"\(label)\" does not take \"\(value)\""
                case .ambiguous(let label, let value): "\"\(label)\" offers \"\(value)\" more than once"
                }
            }
        }

        /// A picker's state when the selection is none of its options.
        static let noOption = "(none)"

        private var entries: [ObjectIdentifier: [Control]] = [:]

        /// Inserts `control`, or replaces the entry with its token in place.
        func update(_ control: Control, store: ObjectIdentifier) {
            var list = entries[store, default: []]
            if let index = list.firstIndex(where: { $0.token == control.token }) {
                list[index] = control
            } else {
                list.append(control)
            }
            entries[store] = list
        }

        func remove(token: UUID, store: ObjectIdentifier) {
            entries[store]?.removeAll { $0.token == token }
            if entries[store]?.isEmpty == true { entries[store] = nil }
        }

        /// In the order they were first registered — the order SwiftUI evaluated their views,
        /// which is not always top to bottom.
        func controls(store: ObjectIdentifier) -> [Control] { entries[store] ?? [] }

        /// The entries drawn in the sheet `sheet` (a `BranchSheet.id`; nil: in none).
        func controls(store: ObjectIdentifier, sheet: AnyHashable?) -> [Control] {
            controls(store: store).filter { $0.sheet == sheet }
        }

        /// The one enabled control of `kind` labelled `label` in the sheet `sheet` performs
        /// `value`, or why not. An entry of any other sheet — one being dismissed — is not there.
        /// A refused step runs nothing.
        func act(
            _ label: String, value: String?, kind: Control.Kind, store: ObjectIdentifier, sheet: AnyHashable? = nil
        ) -> Refusal? {
            let matches = controls(store: store, sheet: sheet).filter { $0.kind == kind && $0.label == label }
            guard let control = matches.first else { return .missing(label) }
            guard matches.count == 1 else { return .duplicate(label) }
            guard control.isEnabled else { return .disabled(label) }
            if kind == .picker, control.options.filter({ $0 == value }).count > 1 {
                return .ambiguous(label, value ?? "")
            }
            return control.perform(value) ? nil : .invalid(label, value ?? "")
        }
    }

    // On the main actor, as the views that call them: a picker's options and selection need not
    // be `Sendable` to be captured by its main-actor closures.
    @MainActor extension HarnessControls.Control {
        static func button(
            _ label: String, isEnabled: Bool = true, token: UUID = UUID(), sheet: AnyHashable? = nil,
            action: @escaping @MainActor () -> Void
        ) -> Self {
            Self(
                kind: .button, label: label, isEnabled: isEnabled, state: { "" }, options: [],
                perform: { _ in
                    action()
                    return true
                }, token: token, sheet: sheet)
        }

        static func toggle(
            _ label: String, isOn: Binding<Bool>, isEnabled: Bool = true, token: UUID = UUID(), sheet: AnyHashable? = nil
        ) -> Self {
            Self(
                kind: .toggle, label: label, isEnabled: isEnabled, state: { isOn.wrappedValue ? "on" : "off" },
                options: [],
                perform: { value in
                    switch value {
                    case "on": isOn.wrappedValue = true
                    case "off": isOn.wrappedValue = false
                    default: return false
                    }
                    return true
                }, token: token, sheet: sheet)
        }

        static func field(
            _ label: String, text: Binding<String>, isEnabled: Bool = true, token: UUID = UUID(), sheet: AnyHashable? = nil
        ) -> Self {
            Self(
                kind: .field, label: label, isEnabled: isEnabled, state: { text.wrappedValue }, options: [],
                perform: { value in
                    guard let value else { return false }
                    text.wrappedValue = value
                    return true
                }, token: token, sheet: sheet)
        }

        static func picker<T: Hashable>(
            _ label: String, selection: Binding<T>, options: [(label: String, value: T)], isEnabled: Bool = true,
            token: UUID = UUID(), sheet: AnyHashable? = nil
        ) -> Self {
            Self(
                kind: .picker, label: label, isEnabled: isEnabled,
                state: { options.first { $0.value == selection.wrappedValue }?.label ?? HarnessControls.noOption },
                options: options.map(\.label),
                perform: { value in
                    // Exactly one: a label two options share names neither (Ruling 15).
                    let chosen = options.filter { $0.label == value }
                    guard chosen.count == 1 else { return false }
                    selection.wrappedValue = chosen[0].value
                    return true
                }, token: token, sheet: sheet)
        }
    }

    /// Registers the control it is applied to under the sheet's store, from its body — refreshing
    /// the action and `isEnabled` each time it is evaluated — and removes it on disappear.
    private struct HarnessControlModifier: ViewModifier {
        let make: @MainActor (_ isEnabled: Bool, _ token: UUID, _ sheet: AnyHashable?) -> HarnessControls.Control

        @Environment(RepositoryStore.self) private var store
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.harnessSheet) private var sheet
        @State private var token = UUID()

        func body(content: Content) -> some View {
            let key = ObjectIdentifier(store)
            let control = make(isEnabled, token, sheet)
            // A write to an unobserved class: it invalidates nothing, so it is harmless in body.
            let _ = HarnessControls.shared.update(control, store: key)
            content
                // Back after a disappear that no new evaluation followed.
                .onAppear { HarnessControls.shared.update(control, store: key) }
                .onDisappear { [token] in HarnessControls.shared.remove(token: token, store: key) }
        }
    }

    extension EnvironmentValues {
        /// The `BranchSheet.id` of the sheet a control is drawn in (`BranchSheetHost`).
        @Entry var harnessSheet: AnyHashable? = nil
    }

#endif

/// The harness's registration of a sheet's controls (`HarnessControls`). Each is applied to the
/// control itself and **inside** its `.disabled(…)` — `Button(…).harnessButton(…).disabled(x)` —
/// so the entry sees whether it is enabled. A button's modifier takes the very closure the button
/// runs. In Release each is the view itself.
extension View {
    /// Marks the controls below as drawn in the sheet `id` (a `BranchSheet.id`), so a step acts
    /// only on the sheet on screen, never on one still being dismissed (`HarnessControls.act`).
    func harnessSheet(_ id: AnyHashable) -> some View {
        #if DEBUG
            environment(\.harnessSheet, id)
        #else
            self
        #endif
    }

    func harnessButton(_ label: String, action: @escaping @MainActor () -> Void) -> some View {
        #if DEBUG
            modifier(
                HarnessControlModifier { isEnabled, token, sheet in
                    .button(label, isEnabled: isEnabled, token: token, sheet: sheet, action: action)
                })
        #else
            self
        #endif
    }

    func harnessToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        #if DEBUG
            modifier(
                HarnessControlModifier { isEnabled, token, sheet in
                    .toggle(label, isOn: isOn, isEnabled: isEnabled, token: token, sheet: sheet)
                })
        #else
            self
        #endif
    }

    func harnessField(_ label: String, text: Binding<String>) -> some View {
        #if DEBUG
            modifier(
                HarnessControlModifier { isEnabled, token, sheet in
                    .field(label, text: text, isEnabled: isEnabled, token: token, sheet: sheet)
                })
        #else
            self
        #endif
    }

    func harnessPicker<T: Hashable>(
        _ label: String, selection: Binding<T>, options: [(label: String, value: T)]
    ) -> some View {
        #if DEBUG
            modifier(
                HarnessControlModifier { isEnabled, token, sheet in
                    .picker(label, selection: selection, options: options, isEnabled: isEnabled, token: token, sheet: sheet)
                })
        #else
            self
        #endif
    }
}
