import Foundation
import Observation

/// The commit message being written, plus the amend toggle.
///
/// Deliberately dumb: it holds text and formats it the way git does, and knows nothing about
/// the repository. `RepositoryStore` decides when it is filled, reset, or committed.
@Observable @MainActor
final class CommitDraft {
    var subject = ""
    var body = ""
    var amend = false

    /// What `prefill` last put in the two fields, kept so that switching amending off again can
    /// tell "the message Gitter offered" from "the message the user wrote".
    private(set) var prefilled: (subject: String, body: String)?

    /// Subject and body as one message: a blank line between them, and no trailing paragraph
    /// at all when the body is empty. Both sides are trimmed, so stray whitespace from the
    /// text fields never reaches the commit.
    var message: String {
        let subject = self.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = self.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? subject : subject + "\n\n" + body
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
    }
}
