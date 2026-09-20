import Foundation
import Observation

/// The live name check both branch-name sheets run: a debounce, one call into the store, and a
/// verdict that is only ever believed for the exact text it was asked about.
///
/// The staleness rule is the reason this is a type and not two `.task` modifiers. Every answer
/// carries the name it judged (`checkedName`); callers ask `isReady(for:)` with what is in the
/// field *now*, so an answer that arrives after the user has typed another character can neither
/// enable a button nor caption a field it was not about. Cancelling the in-flight check is the
/// first line of defence; naming the text is the one that cannot be raced.
@Observable @MainActor
final class BranchNameValidator {

    /// How long the field has to be quiet before git is asked. Long enough that a name typed at
    /// speed costs one `check-ref-format` rather than one per keystroke, short enough to read as
    /// live feedback.
    private static let debounce = Duration.milliseconds(250)

    /// What is wrong with `checkedName`, or nil when nothing is.
    private(set) var problem: BranchNameProblem?

    /// The trimmed text `problem` is about, or nil while a check is in flight (or before the
    /// first one). Nil means "nothing is known about what is in the field", which is not the
    /// same as "the name is fine" — hence every caller compares rather than tests for nil.
    private(set) var checkedName: String?

    /// Whether the user has typed since the sheet opened. An empty field nobody has touched is
    /// not a mistake yet, so it gets no message; the button is disabled either way.
    private(set) var hasEdited = false

    /// The name the sheet is renaming. git counts it as taken, but telling someone their branch
    /// is called what it is called is noise, so it is answered here as "fine" and the sheet
    /// disables Rename on the separate ground that nothing has changed. Nil for a new branch,
    /// where every existing name really is taken.
    private let ownName: String?

    private var check: Task<Void, Never>?

    init(ownName: String? = nil) {
        self.ownName = ownName
    }

    // MARK: - Driving it

    /// The sheet has appeared with this text in the field. Does not count as an edit.
    func start(with text: String, using store: RepositoryStore) {
        update(text, using: store)
    }

    /// The user changed the field.
    func edited(_ text: String, using store: RepositoryStore) {
        hasEdited = true
        update(text, using: store)
    }

    // MARK: - Reading it

    /// A verdict is in for exactly this text, and it is a name that can be acted on.
    func isReady(for text: String) -> Bool {
        checkedName == Self.trim(text) && problem == nil
    }

    /// The line under the field, or nil when there is nothing to say about the text that is
    /// actually in it right now.
    func message(for text: String) -> String? {
        guard let problem, checkedName == Self.trim(text) else { return nil }
        guard problem != .empty || hasEdited else { return nil }
        return problem.message
    }

    /// What git is asked about, and what the sheets create: git takes no leading or trailing
    /// whitespace in a ref name, and a name that only differs by it is not a different name.
    static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Running the check

    private func update(_ text: String, using store: RepositoryStore) {
        check?.cancel()
        let trimmed = Self.trim(text)
        // Two answers need neither git nor a wait, and answering them here is what keeps the
        // field from captioning its own prefilled name a quarter of a second after it opens.
        if trimmed.isEmpty {
            settle(trimmed, .empty)
            return
        }
        if trimmed == ownName {
            settle(trimmed, nil)
            return
        }
        // Nothing is known about this text until the answer lands: whatever the last one said
        // was about other text, and must stop counting the moment this one differs from it.
        checkedName = nil
        check = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            let problem = await store.validateNewBranchName(trimmed)
            guard !Task.isCancelled else { return }
            settle(trimmed, problem)
        }
    }

    private func settle(_ name: String, _ problem: BranchNameProblem?) {
        checkedName = name
        self.problem = problem
    }
}
