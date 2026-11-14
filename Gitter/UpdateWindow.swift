import AppKit
import SwiftUI

/// How the update window opens a URL: the default browser (`NSWorkspace.open`) — and, in DEBUG, in
/// a scripted launch, only the log line `UPDATE would open <url>`, so the harness never starts a
/// browser (any real open would reach github.com).
struct UpdateOpener {
    let open: @MainActor (URL) -> Void

    static func live(environment: [String: String], log: EventLog) -> UpdateOpener {
        live(environment: environment, log: log, workspace: { _ = NSWorkspace.shared.open($0) })
    }

    /// `live`, with the workspace's open as a seam (internal for tests, which never pass the real one).
    static func live(
        environment: [String: String], log: EventLog, workspace: @escaping @MainActor (URL) -> Void
    ) -> UpdateOpener {
        #if DEBUG
            if DebugLaunchGuard.isScripted(environment) {
                return UpdateOpener { url in log.write("UPDATE would open \(url.absoluteString)") }
            }
        #endif
        return UpdateOpener(open: workspace)
    }
}

/// The update window's buttons, by the names the harness's `update:press:` steps use.
enum UpdateButton: String, CaseIterable {
    case download, later, skip, releasePage = "page", close
}

/// The update window (spec, "The update window"): a small non-modal `NSPanel`, outside the
/// `WindowGroup`, that the repository windows are used beside — the checker's presenter
/// (`AppModel.updates`), and the manual check's alerts.
///
/// - **Not a main window.** An `NSPanel` cannot become main, so `visibleMainWindows()` and the
///   windowless-launch check never count it; it is not restorable, and outlives its close.
/// - **An automatic result does not take the keyboard:** it is ordered to the front without
///   becoming key, and the panel becomes key only when the user clicks into it,
///   so typing, Return and ⌘W stay in the repository window. A manual result is made key, and the
///   app active: the user just asked.
/// - **One at a time.** A second result updates the open window.
/// - **When an automatic result may show** (`canShowAutomatic`): the app is active, no visible
///   window has a sheet attached, no modal window is up and no quit is under way. The checker holds
///   it otherwise and tries it again on a timer (`UpdateChecker`); this controller also asks for it
///   at once when the app becomes active or a sheet ends.
@MainActor final class UpdatePanelController: NSObject, UpdatePresenting, NSWindowDelegate {
    private let checker: @MainActor () -> UpdateChecker?
    private let opener: UpdateOpener
    private let log: EventLog

    /// Built at the first `show`, kept after a close (internal for tests and the harness).
    private(set) var panel: UpdatePanel?
    private var hosting: NSHostingView<UpdateView>?
    private var shown: (release: LatestRelease, running: ReleaseVersion)?
    /// The button a close came from, for its log line; a close with none is the close button's.
    private var closingBy: UpdateButton?

    /// `checker` is read only when a button or an observer needs it — never here, where
    /// `AppModel.updates` may still be being built.
    init(checker: @escaping @MainActor () -> UpdateChecker?, opener: UpdateOpener, log: EventLog) {
        self.checker = checker
        self.opener = opener
        self.log = log
        super.init()
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(mayShowHeld(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(mayShowHeld(_:)), name: NSWindow.didEndSheetNotification, object: nil)
    }

    var isShowing: Bool { panel?.isVisible == true }

    var shownVersion: ReleaseVersion? { isShowing ? shown?.release.version : nil }

    // MARK: - UpdatePresenting

    var canShowAutomatic: Bool {
        NSApp.isActive && !NSApp.windows.contains { $0.isVisible && $0.attachedSheet != nil }
            && NSApp.modalWindow == nil && !QuitFlow.isUnderWay
    }

    func show(_ release: LatestRelease, running: ReleaseVersion, manual: Bool) {
        shown = (release, running)
        let view = UpdateView(release: release, running: running) { [weak self] in self?.press($0) }
        let panel: UpdatePanel
        if let existing = self.panel, let hosting {
            hosting.rootView = view
            panel = existing
        } else {
            panel = makePanel(view)
        }
        if let hosting { panel.setContentSize(hosting.fittingSize) }
        if !manual {
            panel.orderFront(nil)
        } else {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func tell(_ outcome: UpdateOutcome) {
        guard let text = UpdateWording.alert(for: outcome) else { return }
        let alert = NSAlert()
        alert.messageText = text
        switch outcome {
        case .upToDate, .noRelease, .newer: alert.alertStyle = .informational
        default: alert.alertStyle = .warning
        }
        ModalAlert.raise(alert) { _ in }
    }

    // MARK: - The buttons

    /// What each button does; the view's buttons and the harness's `update:press:` call this.
    /// Nothing without a window on screen.
    func press(_ button: UpdateButton) {
        guard isShowing, let panel, let release = shown?.release else { return }
        switch button {
        case .download:
            opener.open(release.downloadURL)
            close(panel, by: .download)
        case .later:
            close(panel, by: .later)
        case .skip:
            checker()?.skip(release.version)
            close(panel, by: .skip)
        case .releasePage:
            log.write(UpdateWording.windowLogLine(UpdateWording.releasePage, tag: release.tag))
            opener.open(release.pageURL)
        case .close:
            // What the close button and ⌘W send.
            panel.performClose(nil)
        }
    }

    private func close(_ panel: UpdatePanel, by button: UpdateButton) {
        closingBy = button
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        let title: String
        switch closingBy {
        case .download: title = UpdateWording.download
        case .skip: title = UpdateWording.skip
        case .later: title = UpdateWording.later
        default: title = "closed"
        }
        if let release = shown?.release { log.write(UpdateWording.windowLogLine(title, tag: release.tag)) }
        closingBy = nil
        shown = nil
    }

    // MARK: - The held result

    /// The app became active or a sheet ended: the held automatic result may show now. A turn
    /// later, so the sheet that ended is detached by then.
    @objc private func mayShowHeld(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.checker()?.showHeldIfPossible() }
    }

    // MARK: - The panel

    private func makePanel(_ view: UpdateView) -> UpdatePanel {
        let panel = UpdatePanel(
            contentRect: NSRect(x: 0, y: 0, width: UpdateView.width, height: 300), styleMask: [.titled, .closable],
            backing: .buffered, defer: true)
        panel.title = UpdateWording.windowTitle
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.hidesOnDeactivate = false
        // A click into the panel makes it key, so Return reaches Download and ⌘W closes it
        // (Ruling 5); an automatic result is still only ordered to the front.
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        // The first time only: afterwards it opens where the user left it.
        panel.center()
        self.panel = panel
        self.hosting = hosting
        return panel
    }
}

/// The update window's `NSPanel`, which records each ordering call made on it — `orderFront` or
/// `makeKeyAndOrderFront` — so a test can tell an automatic result's ordering from a manual one's
/// by the call itself, whether the test host is active or not.
final class UpdatePanel: NSPanel {
    enum Ordering: Equatable { case orderFront, makeKeyAndOrderFront }

    private(set) var orderingCalls: [Ordering] = []
    /// While `makeKeyAndOrderFront` runs: an `orderFront` AppKit makes inside it is not a call of its own.
    private var inMakeKey = false

    override func orderFront(_ sender: Any?) {
        if !inMakeKey { orderingCalls.append(.orderFront) }
        super.orderFront(sender)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        orderingCalls.append(.makeKeyAndOrderFront)
        inMakeKey = true
        defer { inMakeKey = false }
        super.makeKeyAndOrderFront(sender)
    }
}

/// The update window's content, after the spec's sketch: the icon, the headline and the running
/// version, the notes (plain, selectable, scrolling), the release page link, and the three buttons.
struct UpdateView: View {
    static let width: CGFloat = 480

    let release: LatestRelease
    let running: ReleaseVersion
    let press: @MainActor (UpdateButton) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: UpdateWording.headline(release.version))
                        .font(.headline)
                    Text(verbatim: UpdateWording.youHave(running))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
            ScrollView {
                Text(verbatim: release.notes)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 120, maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Button {
                press(.releasePage)
            } label: {
                HStack(spacing: 2) {
                    Text(verbatim: UpdateWording.releasePage)
                    Image(systemName: "arrow.up.right")
                }
            }
            .buttonStyle(.link)
            HStack {
                Button(UpdateWording.skip) { press(.skip) }
                Spacer()
                Button(UpdateWording.later) { press(.later) }
                Button(UpdateWording.download) { press(.download) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: Self.width)
    }
}
