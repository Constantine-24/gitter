import Foundation
import GitCore
import Testing

@testable import Gitter

/// The commit list's multi-select rules (`CommitSelection`): commits as a set, ordered as shown;
/// the working copy and a stash single; the detail pane on the first selected commit. And the
/// store keeping `selectedCommits` in step with `selection` whoever writes it.
@MainActor @Suite struct CommitSelectionTests {

    static let a = String(repeating: "a", count: 40)
    static let b = String(repeating: "b", count: 40)
    static let c = String(repeating: "c", count: 40)
    static let d = String(repeating: "d", count: 40)
    static let shown: [Selection] = [.workingCopy, .commit(a), .commit(b), .commit(c), .commit(d)]

    private func resolve(_ new: Set<Selection>, from previous: Set<Selection>)
        -> CommitSelection.Resolved?
    {
        CommitSelection.resolve(new, previous: previous, shown: Self.shown)
    }

    @Test func aClickOnACommitSelectsItAlone() {
        #expect(
            resolve([.commit(Self.b)], from: [.workingCopy])
                == .init(detail: .commit(Self.b), commits: [Self.b]))
    }

    @Test func commandClickAddsACommitAndKeepsTheOrderShown() {
        #expect(
            resolve([.commit(Self.b), .commit(Self.d)], from: [.commit(Self.b)])
                == .init(detail: .commit(Self.b), commits: [Self.b, Self.d]))
        // Added above the first: the detail moves to the topmost.
        #expect(
            resolve([.commit(Self.a), .commit(Self.b), .commit(Self.d)], from: [.commit(Self.b), .commit(Self.d)])
                == .init(detail: .commit(Self.a), commits: [Self.a, Self.b, Self.d]))
    }

    @Test func shiftClickSelectsARangeInTheOrderShown() {
        #expect(
            resolve([.commit(Self.d), .commit(Self.c), .commit(Self.b)], from: [.commit(Self.b)])
                == .init(detail: .commit(Self.b), commits: [Self.b, Self.c, Self.d]))
    }

    @Test func deselectingOneKeepsTheRest() {
        #expect(
            resolve([.commit(Self.b)], from: [.commit(Self.a), .commit(Self.b)])
                == .init(detail: .commit(Self.b), commits: [Self.b]))
    }

    /// The working copy keeps single selection: added to commits, it replaces them.
    @Test func theWorkingCopyIsNeverPartOfASet() {
        #expect(
            resolve([.commit(Self.b), .commit(Self.d), .workingCopy], from: [.commit(Self.b), .commit(Self.d)])
                == .init(detail: .workingCopy, commits: []))
        // A commit added to the working copy replaces it.
        #expect(
            resolve([.workingCopy, .commit(Self.c)], from: [.workingCopy])
                == .init(detail: .commit(Self.c), commits: [Self.c]))
        #expect(resolve([.workingCopy], from: [.commit(Self.a)]) == .init(detail: .workingCopy, commits: []))
    }

    @Test func aStashIsSingleToo() {
        let stash = Selection.stash(String(repeating: "e", count: 40))
        #expect(
            CommitSelection.resolve([.commit(Self.a), stash], previous: [.commit(Self.a)], shown: Self.shown)
                == .init(detail: stash, commits: []))
    }

    @Test func anEmptySelectionChangesNothing() {
        #expect(resolve([], from: [.commit(Self.a)]) == nil)
    }

    /// The log is capped: a selected commit the list no longer shows stays selected, after the
    /// ones shown.
    @Test func aCommitNotShownComesAfterTheOnesShown() {
        let z = String(repeating: "f", count: 40)
        #expect(
            resolve([.commit(z), .commit(Self.c)], from: [.commit(z)])
                == .init(detail: .commit(Self.c), commits: [Self.c, z]))
    }

    @Test func theTableShowsTheSetOrTheSingleSelection() {
        #expect(CommitSelection.table(selection: .workingCopy, commits: []) == [.workingCopy])
        #expect(
            CommitSelection.table(selection: .commit(Self.b), commits: [Self.b, Self.d])
                == [.commit(Self.b), .commit(Self.d)])
        #expect(CommitSelection.table(selection: .commit(Self.b), commits: []) == [.commit(Self.b)])
        #expect(CommitSelection.table(selection: .stash(Self.c), commits: []) == [])
    }

    // MARK: - The store

    @Test func theStoreKeepsSelectedCommitsInStepWithTheSelection() {
        let (store, _, cleanup) = makeTestStore()
        defer { cleanup() }
        #expect(store.selectedCommits == [])
        store.selectRows([.commit(Self.c), .commit(Self.a)], shown: Self.shown)
        #expect(store.selection == .commit(Self.a))
        #expect(store.selectedCommits == [Self.a, Self.c])
        // Any other writer of the selection — a sidebar click, a fallback, `open()` — ends the set.
        store.select(.commit(Self.d))
        #expect(store.selectedCommits == [Self.d])
        store.select(.workingCopy)
        #expect(store.selectedCommits == [])
        store.selectRows([.commit(Self.b), .commit(Self.c)], shown: Self.shown)
        store.selection = .workingCopy
        #expect(store.selectedCommits == [])
    }

    /// Compare mode draws the comparison over the history, which stays in the tree so the commit
    /// list / detail divider is not thrown to its minimum (final fix wave, I1): a key that still
    /// reaches the hidden table must not move the selection off the comparison.
    @Test func whileComparingTheHistoryTableSelectsNothing() {
        let (store, _, cleanup) = makeTestStore()
        defer { cleanup() }
        store.setComparison(CompareWordingTests.comparison())
        store.select(.comparisonChanges)
        store.selectRows([.commit(Self.a)], shown: Self.shown)
        #expect(store.selection == .comparisonChanges)
        #expect(store.selectedCommits == [])
    }

    /// Control: with no comparison the same write selects the row, so the check above can fail.
    @Test func theCheckFailsWithNoComparison() {
        let (store, _, cleanup) = makeTestStore()
        defer { cleanup() }
        store.select(.workingCopy)
        store.selectRows([.commit(Self.a)], shown: Self.shown)
        withKnownIssue("with no comparison the table's write selects the row") {
            #expect(store.selection == .workingCopy)
        }
    }

    @Test func theStoreOrdersAGivenListAsShown() {
        let (store, _, cleanup) = makeTestStore()
        defer { cleanup() }
        store.selectCommits([Self.d, Self.b], shown: [Self.a, Self.b, Self.c, Self.d])
        #expect(store.selectedCommits == [Self.b, Self.d])
        #expect(store.selection == .commit(Self.b))
    }
}
