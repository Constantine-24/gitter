import Foundation
import GitCore

/// Every sentence the tags put on screen: the sidebar's tag rows and their menu, the commit
/// list's tag pills, the New Tag, Delete Tag and Delete-on-a-remote sheets, their notices and
/// every refusal (B1, Task 4). Pure, so `TagWordingTests` pins each one.
///
/// Tag names follow git's ref-name rules but may still hold any non-ASCII character, and a
/// tagger or a message is somebody else's text: all of it goes through `RemoteWording.plain`
/// before it is shown.
enum TagWording {

    // MARK: - Names

    /// `"v1.0"`, made plain.
    static func quoted(_ name: String) -> String {
        "\"\(RemoteWording.plain(name))\""
    }

    static func short(_ id: String) -> String {
        String(id.prefix(7))
    }

    /// `name` as one word for a command to paste into a shell: as it is when it holds only
    /// characters no shell reads specially, single-quoted otherwise. A ref name may hold `$`,
    /// `;`, `&`, `'`, `(`… — git refuses only controls, space, `~^:?*[\` and a few sequences.
    static func shellWord(_ name: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-+@,=")
        let plain = RemoteWording.plain(name)
        if !plain.isEmpty, plain.unicodeScalars.allSatisfy(safe.contains) { return plain }
        return "'" + plain.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Name problems

    /// The New Tag sheet's line under the field, and the second half of a refusal at the
    /// confirm (`failure`).
    static func problem(_ problem: TagNameProblem) -> String {
        switch problem {
        case .empty: "Enter a tag name."
        case .invalid: "That is not a valid tag name."
        case .exists:
            "A tag with that name already exists, or one git can't keep beside it (\"V1\" beside "
                + "\"v1\", \"a\" beside \"a/b\")."
        case .isBranchName:
            "A branch or remote has that name. git would read the tag in its place in every "
                + "command that names it."
        case .looksLikeObjectID: "That name looks like a commit id, and git would read it as one."
        case .reserved:
            "git keeps that name for itself (HEAD, ORIG_HEAD and the like), or it starts with \"-\"."
        case .tooLong: "That name is too long for git to store."
        }
    }

    /// What the field says for the verdict on the text in it: nothing for a fine name, and
    /// nothing for an empty field nobody has typed in yet — that is not a mistake.
    static func fieldMessage(_ problem: TagNameProblem?, edited: Bool) -> String? {
        guard let problem else { return nil }
        if problem == .empty && !edited { return nil }
        return self.problem(problem)
    }

    // MARK: - Sidebar rows and menu

    /// The row's tooltip: what kind of tag, on which commit, and for an annotated one who tagged
    /// it, when, and its message's subject. `date` formats the tag's date (a parameter so a test
    /// does not depend on the clock's locale and zone).
    static func rowHelp(_ tag: Tag, date: (Date) -> String = defaultDate) -> String {
        let commit = short(tag.sha)
        if tag.isSymbolic {
            return "A symbolic ref under refs/tags, resolving to \(commit) now. Gitter does not "
                + "delete or push it."
        }
        guard tag.isAnnotated else {
            return "Lightweight tag on \(commit): a name for the commit, with no message, tagger "
                + "or date."
        }
        var lines = ["Annotated tag on \(commit)"]
        switch (tag.tagger.map(RemoteWording.plain), tag.date.map(date)) {
        case (let who?, let when?): lines.append("Tagged by \(who), \(when)")
        case (let who?, nil): lines.append("Tagged by \(who)")
        case (nil, let when?): lines.append("Tagged \(when)")
        case (nil, nil): break
        }
        if let subject = tag.subject {
            let plain = RemoteWording.plain(subject)
            lines.append(plain.isEmpty ? "(no message)" : plain)
        }
        return lines.joined(separator: "\n")
    }

    static func defaultDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// What VoiceOver reads for the row: the name, then the kind the icon shows.
    static func rowAccessibility(_ tag: Tag) -> String {
        "\(RemoteWording.plain(tag.name)), \(kind(tag))"
    }

    private static func kind(_ tag: Tag) -> String {
        if tag.isSymbolic { return "symbolic ref" }
        return tag.isAnnotated ? "annotated tag" : "lightweight tag"
    }

    /// The row's SF Symbol: filled for an annotated tag — an object of its own — outlined for a
    /// lightweight one, an arrow for a symbolic ref.
    static func rowIcon(_ tag: Tag) -> String {
        if tag.isSymbolic { return "arrow.turn.down.right" }
        return tag.isAnnotated ? "tag.fill" : "tag"
    }

    /// A tag the menu offered is not in the list any more (deleted in a terminal meanwhile).
    static func noSuchTag(_ name: String) -> String {
        "There is no tag \(quoted(name)) — it may have been deleted since this list was loaded."
    }

    static let newTagTitle = "New Tag…"
    static let deleteTagTitle = "Delete Tag…"

    static func pushTitle(remote: String) -> String {
        "Push Tag to \(quoted(remote))"
    }

    static func deleteFromRemoteTitle(remote: String) -> String {
        "Delete from \(quoted(remote))…"
    }

    /// Why Delete Tag, Push Tag and Delete from <remote> are off for a symbolic ref: a delete
    /// that followed it would delete the branch it names, and a push would send that branch's
    /// commit as a tag.
    static func symbolicReason(_ name: String) -> String {
        "\(quoted(name)) is a symbolic ref naming another ref, not an ordinary tag: Gitter does "
            + "not delete or push it. Use a terminal for it."
    }

    // MARK: - Pills

    /// The log's own decorations without its tag entries. `%D` spells tags differently under
    /// `log.decorate=full` (`tag: refs/tags/v1`) and leaves them out under
    /// `log.excludeDecoration` (B18), so the pills come from the tag list (`tagsByCommit`).
    static func branchDecorations(_ refs: [String]) -> [String] {
        refs.filter { !$0.hasPrefix("tag: ") }
    }

    /// The tags each commit row draws as pills, in the list's order (`for-each-ref`, by name),
    /// keyed by the commit they peel to.
    static func tagsByCommit(_ tags: [Tag]) -> [String: [Tag]] {
        Dictionary(grouping: tags, by: \.sha)
    }

    // MARK: - New Tag sheet

    static let newTagSheetTitle = "New Tag"

    /// The commit the tag goes on: its short sha and subject (when the list shows it).
    static func newTagOn(_ sha: String, subject: String?) -> String {
        guard let subject else { return "On: \(short(sha))" }
        return "On: \(short(sha)) \(RemoteWording.plain(subject))"
    }

    static func kindTitle(annotated: Bool) -> String {
        annotated ? "Annotated" : "Lightweight"
    }

    static func kindExplanation(annotated: Bool) -> String {
        annotated
            ? "Records who tagged it, when, and a message. Never signed."
            : "Only a name for the commit: no message, tagger or date."
    }

    static let messageLabel = "Message:"
    static let messageNeeded = "Enter a message, or make it a lightweight tag."
    static let createButton = "Create Tag"

    static func created(_ name: String, at sha: String, annotated: Bool) -> String {
        "Created \(annotated ? "annotated tag" : "tag") \(quoted(name)) on \(short(sha))."
    }

    // MARK: - Delete Tag sheet

    static func deleteTitle(_ name: String) -> String {
        "Delete tag \(quoted(name))?"
    }

    /// The tag and its commit: `"v1" is an annotated tag on 1a2b3c4 Add parser.`
    static func deleteTarget(_ tag: Tag, subject: String?) -> String {
        let commit = subject.map { "\(short(tag.sha)) \(RemoteWording.plain($0))" } ?? short(tag.sha)
        return "\(quoted(tag.name)) is \(tag.isAnnotated ? "an annotated" : "a lightweight") tag on "
            + "\(commit)."
    }

    /// Restore Tag recreates the ref at the tag **object**, so an annotated tag comes back
    /// whole (B19).
    static func deleteRestore(_ tag: Tag) -> String {
        tag.isAnnotated
            ? "Restore Tag in the notice afterwards puts the identical tag back: its message, "
                + "tagger and date too."
            : "Restore Tag in the notice afterwards puts it back."
    }

    /// What a fetch does after the delete (B22). Opening the sheet reads no network, so
    /// nothing is claimed about remotes — unless this session saw them with the tag (a push,
    /// or the remote delete's read, `RemoteTagsSeen`): Ruling 2.
    static func comesBack(from remotes: [String]) -> String {
        guard !remotes.isEmpty else {
            return "If a remote still has this tag, the next fetch brings it back."
        }
        let names = remotes.map(quoted)
        let list: String
        let which: String
        switch names.count {
        case 1:
            list = names[0]
            which = "it"
        case 2:
            list = "\(names[0]) and \(names[1])"
            which = "either"
        default:
            list = names.dropLast().joined(separator: ", ") + " and \(names[names.count - 1])"
            which = "any of them"
        }
        return "\(list) had this tag when Gitter last looked, so the next fetch from \(which) "
            + "brings it back, unless it is deleted there too."
    }

    static let deleteButton = "Delete Tag"

    /// The sheet's live line: the tag in the list no longer holds what the sheet shows.
    static func deleteSheetStale(_ name: String, isGone: Bool) -> String {
        isGone
            ? "\(quoted(name)) is gone since this warning. Close this and look again."
            : "\(quoted(name)) has changed since this warning, so Delete Tag would refuse. Close "
                + "this and look again."
    }

    /// The sticky notice after a delete — the only way back, tags keep no reflog — with Restore
    /// Tag beside it and the same in a terminal, naming the tag **object** for an annotated tag.
    static func deleted(_ receipt: TagReceipt) -> String {
        "Deleted tag \(quoted(receipt.name)), which was on \(short(receipt.target)). Restore Tag "
            + "puts it back; so does, in a terminal: git tag \(shellWord(receipt.name)) \(receipt.objectID)"
    }

    static let restoreButton = "Restore Tag"

    static func restored(_ receipt: TagReceipt) -> String {
        "Restored tag \(quoted(receipt.name)) on \(short(receipt.target))."
    }

    // MARK: - Push

    /// The notice for a push the remote took, or nil when it did not (`pushFailure`).
    static func pushNotice(_ outcome: TagPushOutcome, _ name: String, remote: String) -> String? {
        switch outcome {
        case .pushed: "Pushed tag \(quoted(name)) to \(quoted(remote))."
        case .alreadyThere: "\(quoted(remote)) already has this tag \(quoted(name)): nothing to push."
        case .rejectedExists, .failed: nil
        }
    }

    /// The banner for a push the remote did not take, or nil when it did. Never forced: a
    /// different tag on the remote stays (B20).
    static func pushFailure(_ outcome: TagPushOutcome, _ name: String, remote: String) -> String? {
        switch outcome {
        case .pushed, .alreadyThere: nil
        case .rejectedExists:
            "\(quoted(remote)) already has a different tag named \(quoted(name)), so nothing was "
                + "pushed. Gitter never replaces a tag on a remote: delete it there first if this "
                + "one should take its place."
        case .failed(let words):
            "The push of tag \(quoted(name)) to \(quoted(remote)) did not go through. git "
                + "reported: \(gitsWords(words))"
        }
    }

    private static func gitsWords(_ text: String) -> String {
        RemoteWording.plainJoined(text.split(whereSeparator: \.isNewline).map(String.init))
    }

    // MARK: - Delete on a remote

    static func deleteRemoteTitle(_ name: String, remote: String) -> String {
        "Delete tag \(quoted(name)) on \(quoted(remote))?"
    }

    /// Deleting a remote tag never removes anyone's local copy (B22).
    static func deleteRemoteBody(remote: String) -> String {
        "This deletes the tag on the server itself, for everyone who uses \(quoted(remote)). "
            + "Clones that already fetched it keep their copies."
    }

    static let deleteRemoteIDLabel = "Its id there, which the deletion is leased on:"
    static let deleteRemoteRecreate = "The notice after the deletion shows the command that puts it back."

    static func deleteOnRemoteButton(_ remote: String) -> String {
        "Delete on \(quoted(remote))"
    }

    /// Whether the remote's tag is the one here, compared by the unpeeled id (`Tag.objectID`).
    static func remoteRelation(_ name: String, local: Tag?, remoteID: String) -> String {
        guard let local else { return "There is no tag \(quoted(name)) here." }
        return local.objectID == remoteID
            ? "It is the same tag as \(quoted(name)) here, which is kept."
            : "It is not the same tag as \(quoted(name)) here (\(short(local.objectID))), which is kept."
    }

    static func noRemoteTagTitle(_ name: String, remote: String) -> String {
        "\(quoted(remote)) has no tag \(quoted(name))"
    }

    static let noRemoteTagBody = "There is nothing to delete there."
    static let closeButton = "Close"

    static func deletedOnRemote(_ name: String, remote: String, id: String) -> String {
        "Deleted tag \(quoted(name)) on \(quoted(remote)); the tag here is kept. Put it back there "
            + "with: git push \(shellWord(remote)) \(id):refs/tags/\(shellWord(name))"
    }

    // MARK: - Refusals and failures

    /// What was being attempted, for the sentence a failure gets.
    enum Attempt: Equatable {
        case create(String)
        case delete(String)
        case restore(String)
        case push(String, remote: String)
        case readRemote(String, remote: String)
        case deleteRemote(String, remote: String)

        var name: String {
            switch self {
            case .create(let n), .delete(let n), .restore(let n), .push(let n, _),
                .readRemote(let n, _), .deleteRemote(let n, _):
                n
            }
        }

        /// Reads on from "Can't …" / "Couldn't …".
        var phrase: String {
            switch self {
            case .create(let n): "create tag \(quoted(n))"
            case .delete(let n): "delete tag \(quoted(n))"
            case .restore(let n): "restore tag \(quoted(n))"
            case .push(let n, let r): "push tag \(quoted(n)) to \(quoted(r))"
            case .readRemote(let n, let r): "read tag \(quoted(n)) on \(quoted(r))"
            case .deleteRemote(let n, let r): "delete tag \(quoted(n)) on \(quoted(r))"
            }
        }

        /// A push or a remote delete: a git failure may have happened part-way.
        var writesARemote: Bool {
            switch self {
            case .push, .deleteRemote: true
            case .create, .delete, .restore, .readRemote: false
            }
        }
    }

    /// `error` as a banner sentence for `attempt`. Gitter's own refusals (`TagOperationError`)
    /// changed nothing and say so; a network failure is the lane's sentence; git's own refusal
    /// keeps git's words — with "may or may not" for a write to a remote.
    static func failure(_ error: Error, _ attempt: Attempt) -> String {
        guard let refusal = error as? TagOperationError else {
            return RemoteWording.failure(error, attempt: attempt.phrase, isWrite: attempt.writesARemote)
        }
        switch refusal {
        case .nameProblem(.exists) where attempt == .restore(attempt.name):
            return "A tag named \(quoted(attempt.name)) exists again, so nothing was restored. "
                + "Delete that one first to bring this one back."
        case .nameProblem(let problem):
            return "Can't \(attempt.phrase). \(self.problem(problem))"
        case .invalidObjectID(let id):
            return "Can't \(attempt.phrase): \"\(RemoteWording.plain(id))\" is not a full object "
                + "id, so nothing was changed."
        case .tagMoved(let name):
            return "\(quoted(name)) changed since this warning, or is gone, so nothing was "
                + "deleted. Ask again to see what it holds now."
        case .remoteTagMoved(let name, let remote):
            return "Tag \(quoted(name)) on \(quoted(remote)) changed since this warning, or is "
                + "already gone; nothing was deleted. \(deleteFromRemoteTitle(remote: remote)) "
                + "again to see what is there now."
        case .symbolicTag(let name):
            return symbolicReason(name)
        }
    }

    /// Stop pressed during a push or a remote delete: cancelling kills git wherever it was, so
    /// nobody knows yet. No fetch follows — a fetch does not tell whether a tag arrived — so
    /// the sentence says how to find out instead. Stopped during the read before the remote
    /// delete's sheet, nothing was sent.
    static func stopped(_ attempt: Attempt) -> String {
        switch attempt {
        case .push(let n, let r):
            "Stopped pushing tag \(quoted(n)) to \(quoted(r)). It may or may not be there now; "
                + "Push Tag again finds out, and never replaces a tag, so it changes nothing if it "
                + "arrived."
        case .deleteRemote(let n, let r):
            "Stopped deleting tag \(quoted(n)) on \(quoted(r)). It may or may not have been "
                + "deleted there; \(deleteFromRemoteTitle(remote: r)) again shows what is there now."
        case .readRemote, .create, .delete, .restore:
            RemoteWording.deleteWarningStopped
        }
    }
}

/// A sentence `TagWording` already wrote, thrown out of `mutate` so the banner shows it as it
/// is (`RepositoryStore.describe` reads `errorDescription`).
struct TagActionFailed: LocalizedError {
    let sentence: String

    var errorDescription: String? { sentence }
}

/// Which remotes this session has seen holding a tag, by name (Ruling 2): a push the remote
/// took or already had, a push it refused because it has another tag of that name, and the
/// remote delete's read say "has it"; a remote delete and a read that found none say "has not".
/// Nothing else is known without the network, so the Delete Tag sheet names only these.
struct RemoteTagsSeen: Equatable {
    private var byTag: [String: Set<String>] = [:]

    mutating func note(_ name: String, on remote: String, present: Bool) {
        if present {
            byTag[name, default: []].insert(remote)
        } else {
            byTag[name]?.remove(remote)
            if byTag[name]?.isEmpty == true { byTag[name] = nil }
        }
    }

    /// Sorted, so the sentence reads the same every time.
    func remotes(having name: String) -> [String] {
        (byTag[name] ?? []).sorted()
    }
}
