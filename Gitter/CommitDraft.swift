import Foundation
import GitCore
import Observation

/// The commit message being written, plus the amend toggle.
///
/// Deliberately dumb: it holds text and formats it the way git does, and knows nothing about
/// the repository. `RepositoryStore` decides when it is filled, reset, or committed.
/// Where a draft's text came from, when it was not written for the operation's current stop
/// (`ComposerPrefill`): a message edited at an earlier stop (`writtenFor` that stop's commit), or
/// text that was there before the operation stopped here (`writtenFor` nil). Continue and an
/// operation's Commit do not send such a draft until the user chooses (A2 Task 6 fix round 1).
struct ForeignDraft: Hashable {
    let writtenFor: CommitRef?
}

@Observable @MainActor
final class CommitDraft {
    var subject = "" {
        didSet { forgetForeignIfEmpty() }
    }
    var body = "" {
        didSet { forgetForeignIfEmpty() }
    }
    var amend = false

    /// What `prefill` last put in the two fields, kept so that switching amending off again can
    /// tell "the message Gitter offered" from "the message the user wrote".
    private(set) var prefilled: (subject: String, body: String)?

    /// The whole message `prefill` was given (trailing blank lines dropped): what `message` is
    /// while the fields still hold exactly what it put there. Splitting into a one-line subject
    /// and a body is lossy — "Fix A\nand B\n\nBody" has a two-line first paragraph — so an
    /// untouched prefill is sent as it came.
    private(set) var prefilledMessage: String?

    /// Set by `ComposerPrefill` when the text was not written for the stop now on screen; nil
    /// again once the draft is emptied or the user keeps it (`keepForeign`).
    private(set) var foreign: ForeignDraft?

    /// The fields hold exactly what `prefill` put there.
    var isUntouchedPrefill: Bool {
        guard let prefilled, prefilledMessage != nil else { return false }
        return subject == prefilled.subject && body == prefilled.body
    }

    /// Subject and body as one message: a blank line between them, and no trailing paragraph
    /// at all when the body is empty. Both sides are trimmed, so stray whitespace from the
    /// text fields never reaches the commit. An untouched prefill is the message it came from.
    var message: String {
        if isUntouchedPrefill, let prefilledMessage { return prefilledMessage }
        let subject = self.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = self.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? subject : subject + "\n\n" + body
    }

    /// Marks non-empty text as written elsewhere; an empty draft is never marked.
    func markForeign(_ origin: ForeignDraft) {
        guard !subject.isEmpty || !body.isEmpty else { return }
        foreign = origin
    }

    /// The user keeps the text for the stop on screen.
    func keepForeign() {
        foreign = nil
    }

    private func forgetForeignIfEmpty() {
        if foreign != nil, subject.isEmpty, body.isEmpty { foreign = nil }
    }

    /// A commit needs a subject; everything else is optional.
    var canCommit: Bool {
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func reset() {
        subject = ""
        body = ""
        amend = false
        prefilled = nil
        prefilledMessage = nil
        foreign = nil
    }

    /// Offers an existing commit message for editing (amending HEAD), split into subject and
    /// body at the blank line git puts between them.
    ///
    /// Only fills an untouched draft: whatever the user has already typed outranks HEAD.
    func prefill(from headMessage: String) {
        guard subject.isEmpty, body.isEmpty else { return }
        var lines = headMessage.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else { return }

        subject = String(lines.removeFirst())
        // A well-formed message separates the body with a blank line, which is dropped rather
        // than shown. A message without one (an unwrapped second line) keeps every remaining
        // line instead of losing it.
        if lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeFirst()
        }
        body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        prefilled = (subject, body)
        prefilledMessage = String(headMessage.reversed().drop(while: \.isWhitespace).reversed())
    }

    /// Takes back a prefill the user never touched — what turning amending off should do.
    ///
    /// Anything typed over it outranks the offer and stays: a draft is the user's text, and
    /// unticking a checkbox is not a good enough reason to throw writing away. Comparing
    /// against what was actually offered is the whole point of remembering it; "non-empty"
    /// would not tell the two cases apart.
    func clearPrefillIfUntouched() {
        guard let prefilled, subject == prefilled.subject, body == prefilled.body else { return }
        subject = ""
        body = ""
        self.prefilled = nil
        prefilledMessage = nil
    }
}
