import AppKit
import GitCore
import SwiftUI
import Testing

@testable import Gitter

/// E2 Task 5: the harness's sheet controls (`HarnessControls`). A sheet registers its own buttons,
/// toggles, fields and pickers by visible label, and the `press:`, `tick:`, `fill:` and `choose:`
/// steps run the view's own action or write through its own binding.
///
/// The registry is driven directly, on a registry of the test's own and a key no store shares;
/// the hosted tests go through the real modifier, which registers into `HarnessControls.shared`
/// under a store made for the test.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct HarnessControlsTests {
    /// A `@State`-like box: what a binding reads and writes, and what the test then asserts on.
    /// Unchecked: a binding's closures are `@Sendable`, and every test touches it on the main actor.
    final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
        var binding: Binding<Value> { Binding(get: { self.value }, set: { self.value = $0 }) }
    }

    typealias Control = HarnessControls.Control

    /// A registry and a store key of the test's own.
    static func registry() -> (HarnessControls, ObjectIdentifier, keepAlive: NSObject) {
        let owner = NSObject()
        return (HarnessControls(), ObjectIdentifier(owner), owner)
    }

    // MARK: - The registry

    @Test func pressRunsTheButtonsOwnAction() {
        let (controls, key, owner) = Self.registry()
        var pressed = 0
        controls.update(.button("Keep None") { pressed += 1 }, store: key)

        #expect(controls.act("Keep None", value: nil, kind: .button, store: key) == nil)
        #expect(pressed == 1)
        withExtendedLifetime(owner) {}
    }

    @Test func tickAndFillWriteThroughTheBinding() {
        let (controls, key, owner) = Self.registry()
        let ticked = Box(false)
        let text = Box("")
        controls.update(.toggle("Include untracked files", isOn: ticked.binding), store: key)
        controls.update(.field("Folder", text: text.binding), store: key)

        #expect(controls.act("Include untracked files", value: "on", kind: .toggle, store: key) == nil)
        #expect(ticked.value)
        #expect(controls.controls(store: key)[0].state() == "on")
        #expect(controls.act("Include untracked files", value: "off", kind: .toggle, store: key) == nil)
        #expect(!ticked.value)
        #expect(controls.controls(store: key)[0].state() == "off")
        #expect(
            controls.act("Include untracked files", value: "yes", kind: .toggle, store: key)
                == .invalid("Include untracked files", "yes"))
        #expect(!ticked.value, "an invalid value writes nothing")

        #expect(controls.act("Folder", value: "/tmp/a=b", kind: .field, store: key) == nil)
        #expect(text.value == "/tmp/a=b")
        #expect(controls.controls(store: key)[1].state() == "/tmp/a=b")
        #expect(controls.act("Folder", value: "", kind: .field, store: key) == nil, "an empty text is a text")
        #expect(text.value == "")
        withExtendedLifetime(owner) {}
    }

    @Test func chooseSetsTheSelectionAndAnOptionNotOfferedIsInvalid() {
        let (controls, key, owner) = Self.registry()
        let selection = Box<String?>(nil)
        controls.update(
            .picker(
                "Branch A", selection: selection.binding,
                options: [(label: "main", value: "refs/heads/main"), (label: "feature", value: "refs/heads/feature")]),
            store: key)
        let picker = controls.controls(store: key)[0]
        #expect(picker.options == ["main", "feature"])
        #expect(picker.state() == HarnessControls.noOption)

        #expect(controls.act("Branch A", value: "feature", kind: .picker, store: key) == nil)
        #expect(selection.value == "refs/heads/feature")
        #expect(picker.state() == "feature")
        #expect(controls.act("Branch A", value: "nope", kind: .picker, store: key) == .invalid("Branch A", "nope"))
        #expect(selection.value == "refs/heads/feature", "an option not offered changes nothing")
        withExtendedLifetime(owner) {}
    }

    @Test func aDisabledControlIsRefusedAndNotRun() {
        let (controls, key, owner) = Self.registry()
        var pressed = 0
        let ticked = Box(false)
        controls.update(.button("Add Worktree", isEnabled: false) { pressed += 1 }, store: key)
        controls.update(.toggle("Keep \"x\" as", isOn: ticked.binding, isEnabled: false), store: key)

        #expect(controls.act("Add Worktree", value: nil, kind: .button, store: key) == .disabled("Add Worktree"))
        #expect(pressed == 0)
        #expect(controls.act("Keep \"x\" as", value: "on", kind: .toggle, store: key) == .disabled("Keep \"x\" as"))
        #expect(!ticked.value)
        withExtendedLifetime(owner) {}
    }

    @Test func twoControlsWithOneLabelAreADuplicateAndNeitherRuns() {
        let (controls, key, owner) = Self.registry()
        var pressed = 0
        controls.update(.button("Cancel") { pressed += 1 }, store: key)
        controls.update(.button("Cancel") { pressed += 10 }, store: key)

        #expect(controls.act("Cancel", value: nil, kind: .button, store: key) == .duplicate("Cancel"))
        #expect(pressed == 0)
        withExtendedLifetime(owner) {}
    }

    @Test func aLabelIsLookedUpWithinItsKindAndItsStore() {
        let (controls, key, owner) = Self.registry()
        let other = NSObject()
        var pressed = 0
        let onlySelected = Box(false)
        // Stash's picker and its button share the label "Stash".
        controls.update(
            .picker("Stash", selection: onlySelected.binding, options: [(label: "All changes", value: false)]),
            store: key)
        controls.update(.button("Stash") { pressed += 1 }, store: key)

        #expect(controls.act("Stash", value: nil, kind: .button, store: key) == nil)
        #expect(pressed == 1)
        #expect(controls.act("Stash", value: "on", kind: .toggle, store: key) == .missing("Stash"))
        #expect(controls.act("Stash", value: nil, kind: .button, store: ObjectIdentifier(other)) == .missing("Stash"))
        #expect(controls.act("Nope", value: nil, kind: .button, store: key) == .missing("Nope"))
        withExtendedLifetime((owner, other)) {}
    }

    /// RF4: an entry leaves with its own token only, and a token's next registration replaces it.
    @Test func aRemovedTokenIsMissingAndTheSameTokenReplacesItsAction() {
        let (controls, key, owner) = Self.registry()
        var ran: [String] = []
        let a = UUID()
        let b = UUID()
        controls.update(.button("Keep All", token: a) { ran.append("A") }, store: key)
        controls.remove(token: a, store: key)
        controls.update(.button("Keep None", token: b) { ran.append("B1") }, store: key)

        #expect(controls.act("Keep All", value: nil, kind: .button, store: key) == .missing("Keep All"))
        #expect(ran.isEmpty)

        controls.update(.button("Keep None", token: b) { ran.append("B2") }, store: key)
        #expect(controls.controls(store: key).count == 1)
        #expect(controls.act("Keep None", value: nil, kind: .button, store: key) == nil)
        #expect(ran == ["B2"], "the action registered last, not the first one")

        controls.remove(token: UUID(), store: key)
        #expect(controls.controls(store: key).count == 1, "another token removes nothing")
        withExtendedLifetime(owner) {}
    }

    // MARK: - The steps' grammar and lines

    @Test func theStepsSplitTheLabelFromTheValueAtTheFirstEquals() {
        typealias Request = DebugLaunchHooks.ControlRequest
        #expect(DebugLaunchHooks.controlRequest("press", "Add Worktree") == Request(kind: .button, label: "Add Worktree", value: nil))
        #expect(DebugLaunchHooks.controlRequest("tick", "Keep \"x\" as") == Request(kind: .toggle, label: "Keep \"x\" as", value: "on"))
        #expect(DebugLaunchHooks.controlRequest("tick", "Include untracked files=off") == Request(kind: .toggle, label: "Include untracked files", value: "off"))
        #expect(DebugLaunchHooks.controlRequest("fill", "Folder=/tmp/a=b") == Request(kind: .field, label: "Folder", value: "/tmp/a=b"))
        #expect(DebugLaunchHooks.controlRequest("fill", "Message=") == Request(kind: .field, label: "Message", value: ""))
        #expect(DebugLaunchHooks.controlRequest("choose", "Kind=New branch") == Request(kind: .picker, label: "Kind", value: "New branch"))
        #expect(DebugLaunchHooks.controlRequest("fill", "Folder") == nil, "a fill names its text")
        #expect(DebugLaunchHooks.controlRequest("choose", "Kind") == nil, "a choose names its option")
        #expect(DebugLaunchHooks.controlRequest("press", "") == nil)
        #expect(DebugLaunchHooks.controlRequest("pick", "Kind=x") == nil, "pick: is cherry-pick")
    }

    @Test func theControlsLineSaysKindLabelStateEnabledAndOptions() {
        let ticked = Box(true)
        let kind = Box(1)
        #expect(
            DebugLaunchHooks.controlLine(.toggle("Keep \"x\" as", isOn: ticked.binding, isEnabled: false))
                == "control: toggle \"Keep \"x\" as\" = \"on\" [disabled]")
        #expect(DebugLaunchHooks.controlLine(.button("Cancel") {}) == "control: button \"Cancel\" = \"\" [enabled]")
        #expect(
            DebugLaunchHooks.controlLine(
                .picker("Kind", selection: kind.binding, options: [(label: "Existing branch", value: 0), (label: "New branch", value: 1)]))
                == "control: picker \"Kind\" = \"New branch\" [enabled] [options: Existing branch|New branch]")
    }

    // MARK: - The modifier, hosted

    /// A hosted view's controls, once its body has run, in a window of its own.
    @MainActor final class Hosted {
        let window: NSWindow
        let store: RepositoryStore
        let cleanup: () -> Void

        init(_ view: some View) {
            let (store, _, cleanup) = makeTestStore()
            self.store = store
            self.cleanup = cleanup
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered,
                defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view.environment(store))
            window.contentView?.layoutSubtreeIfNeeded()
        }

        var controls: [Control] { HarnessControls.shared.controls(store: ObjectIdentifier(store)) }

        func close() {
            window.contentView = nil
            window.close()
            cleanup()
        }
    }

    @Test(.timeLimit(.minutes(10))) func theModifierInsideDisabledRegistersTheControlAsDisabled() async {
        let hosted = Hosted(
            VStack {
                Button("Off") {}.harnessButton("Off") {}.disabled(true)
                Button("On") {}.harnessButton("On") {}
            })
        defer { hosted.close() }
        await waitUntil("both buttons registered") { hosted.controls.count == 2 }

        #expect(hosted.controls.first { $0.label == "Off" }?.isEnabled == false)
        #expect(hosted.controls.first { $0.label == "On" }?.isEnabled == true)
        #expect(
            HarnessControls.shared.act("Off", value: nil, kind: .button, store: ObjectIdentifier(hosted.store))
                == .disabled("Off"))
    }

    /// The control for the test above: applied outside `.disabled`, the modifier cannot see it.
    @Test(.timeLimit(.minutes(10))) func theModifierOutsideDisabledReadsEnabled() async {
        let hosted = Hosted(Button("Off") {}.disabled(true).harnessButton("Off") {})
        defer { hosted.close() }
        await waitUntil("the button registered") { hosted.controls.count == 1 }

        withKnownIssue("outside .disabled the environment the modifier reads is enabled") {
            #expect(hosted.controls.first?.isEnabled == false)
        }
    }

    @Test(.timeLimit(.minutes(10))) func aHostedControlLeavesTheRegistryWhenItsViewGoes() async {
        let hosted = Hosted(Button("Go") {}.harnessButton("Go") {})
        defer { hosted.close() }
        await waitUntil("the button registered") { hosted.controls.count == 1 }

        hosted.window.contentView = nil
        await waitUntil("the button gone") { hosted.controls.isEmpty }
        #expect(hosted.controls.isEmpty)
    }

    /// Keep All, Keep None, each box and each name field of the shared keep list, by the labels
    /// the steps use — driven through the registry, which writes the sheet's own bindings. (The
    /// boxes here are not SwiftUI state, so a write is not drawn again: each row is checked as
    /// the list first drew it.)
    @Test(.timeLimit(.minutes(10))) func theKeepListRegistersItsButtonsBoxesAndNames() async {
        let kept = RefTip(ref: "refs/remotes/origin/feature", id: String(repeating: "a", count: 40))
        let dropped = RefTip(ref: "refs/remotes/origin/old", id: String(repeating: "b", count: 40))
        let ticked = Box<[String: Bool]>([kept.ref: true, dropped.ref: false])
        let names = Box<[String: String]>([kept.ref: "feature", dropped.ref: "old"])
        let hosted = Hosted(
            KeepBranchList(
                holders: [kept, dropped], loaded: true, ticked: ticked.binding, names: names.binding,
                problems: [:], checked: nil))
        defer { hosted.close() }
        let key = ObjectIdentifier(hosted.store)
        let keptBox = RemoteAdminWording.keepLabel(kept.ref)
        let keptName = RemoteAdminWording.keepNameLabel(kept.ref)
        let droppedBox = RemoteAdminWording.keepLabel(dropped.ref)
        let droppedName = RemoteAdminWording.keepNameLabel(dropped.ref)
        #expect(keptBox == "Keep \"origin/feature\" as")
        #expect(keptName == "Name for \"origin/feature\"")
        await waitUntil("the keep list's six controls") { hosted.controls.count == 6 }

        #expect(
            hosted.controls.map(\.label).sorted()
                == ["Keep All", "Keep None", keptBox, keptName, droppedBox, droppedName].sorted())
        #expect(hosted.controls.first { $0.label == droppedName }?.isEnabled == false, "an unticked row's name is off")
        #expect(hosted.controls.first { $0.label == keptName }?.state() == "feature")
        #expect(HarnessControls.shared.act(keptName, value: "kept", kind: .field, store: key) == nil)
        #expect(names.value[kept.ref] == "kept")
        #expect(HarnessControls.shared.act(droppedBox, value: "on", kind: .toggle, store: key) == nil)
        #expect(ticked.value[dropped.ref] == true)
        #expect(HarnessControls.shared.act(droppedName, value: "x", kind: .field, store: key) == .disabled(droppedName))
        #expect(names.value[dropped.ref] == "old")
    }
}
