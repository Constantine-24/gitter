import AppKit
import Foundation

/// The two notice slots and the notices' buttons.
///
/// **Two slots.** `notice` is transient: "Fetched", "Created branch" — read or not, it fades
/// after four seconds. `stickyNotice` stays until it is dismissed (×) or replaced by another
/// sticky one, and it is also ended by opening another repository (`open()`) and, for a notice
/// with links, by the next push, publish or force push starting (`beginRemote`). A transient
/// notice never clears the sticky one; both can be on screen, the transient one above.
///
/// **Which slot** is the notice's to say, through `show(_:)` and its one rule
/// (`NoticeSlot.choose`): a button or a link stays; so does a notice that is the only copy of a
/// way back (`keep`) or a success with a warning in it (`.warning`), unless the sticky notice up
/// has a button; everything else fades.
extension RepositoryStore {

    /// Shows `notice` in the slot `NoticeSlot.choose` picks for it over the sticky notice on
    /// screen.
    func show(_ notice: Notice) {
        switch NoticeSlot.choose(for: notice, replacing: stickyNotice) {
        case .sticky: setStickyNotice(notice)
        case .fading: fade(notice)
        }
    }

    // MARK: - Transient

    /// Shows a transient, non-error message and schedules its own removal.
    func showNotice(_ message: String) {
        fade(Notice(text: message))
    }

    /// Shows `notice` in the transient slot and schedules its removal.
    ///
    /// The timer is cancelled by the next notice and by `open()`, and it re-checks `generation`
    /// before clearing, so a notice raised for a repository opened since is not cleared by an
    /// older one's timer.
    private func fade(_ notice: Notice) {
        noticeTask?.cancel()
        setNotice(notice)
        let generation = self.generation
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            setNotice(nil)
        }
    }

    func dismissNotice() {
        noticeTask?.cancel()
        setNotice(nil)
    }

    // MARK: - Sticky

    /// Shows `notice` until it is dismissed or replaced; replaces the sticky one on screen,
    /// whatever it is. For a notice whose stay is the rule's to decide, `show(_:)`.
    func showStickyNotice(_ notice: Notice) {
        setStickyNotice(notice)
    }

    func dismissStickyNotice() {
        setStickyNotice(nil)
    }

    // MARK: - Buttons

    /// Does what a notice's button says.
    ///
    /// - Open hands the link to the system's browser — `http` and `https` only
    ///   (`NoticeLinks.canOpen`); anything else is refused without a word, since no notice this
    ///   app builds carries one.
    /// - Copy Link puts the whole address on the pasteboard.
    /// - Pop Stash pops the entry the notice names, found again by sha (`popOfferedStash`),
    ///   with `popStash`'s own gates.
    /// - Undo Discard puts back what the discard took (`undoDiscard`).
    /// - Show Copy selects the entry a conflict write filed (`showOfferedStash`).
    /// - Restore Tag(s) recreates the tags Delete Tag took (`restoreTags`).
    /// - Open (Add Worktree's notice) switches this window to the new worktree
    ///   (`openAddedWorktree`).
    ///
    /// `pasteboard` and `openURL` are the seams: a test and the DEBUG harness pass a private
    /// pasteboard and an opener that records, so neither ever touches the user's clipboard or
    /// starts a browser.
    func perform(
        _ action: NoticeAction, pasteboard: NSPasteboard = .general,
        openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        switch action {
        case .openLink(let url):
            guard NoticeLinks.canOpen(url) else { return }
            openURL(url)
        case .copyLink(let url):
            Clipboard.copy(url.absoluteString, to: pasteboard)
        case .popStash(let stash):
            popOfferedStash(stash)
        case .undoDiscard(let receipts):
            undoDiscard(receipts)
        case .showStash(let stash):
            showOfferedStash(stash)
        case .restoreTag(let receipts):
            restoreTags(receipts)
        case .openWorktree(let path):
            openAddedWorktree(path)
        }
    }
}
