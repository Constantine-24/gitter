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
    }
}
