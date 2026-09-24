import Testing

@testable import GitCore

/// `PullPlan.decide` is the design document's "Pull, as the store performs it" table, one test
/// per row. It is pure, so every row is a plain value in and a plain value out — and the store
/// asks it about the tracking it re-reads **after** the fetch, never the one it had before.
@Suite struct PullPlanTests {
    @Test func noUpstreamIsNoUpstream() {
        #expect(PullPlan.decide(.none) == .noUpstream)
    }

    @Test func aGoneUpstreamIsUpstreamGone() {
        #expect(PullPlan.decide(.gone) == .upstreamGone)
    }

    /// Nothing to bring in, whether the branch is level or ahead: a pull never pushes, so
    /// "ahead only" is as finished as "level".
    @Test(arguments: [(0, 0), (2, 0)])
    func nothingBehindIsNothingToDo(ahead: Int, behind: Int) {
        #expect(PullPlan.decide(.counts(ahead: ahead, behind: behind)) == .nothingToDo)
    }

    @Test func behindOnlyIsAFastForward() {
        #expect(PullPlan.decide(.counts(ahead: 0, behind: 3)) == .fastForward)
    }

    @Test func bothSidesIsAQuestionWithTheCounts() {
        #expect(
            PullPlan.decide(.counts(ahead: 2, behind: 3)) == .askHowToIntegrate(ahead: 2, behind: 3))
    }

    /// git never prints a negative count, but `Tracking.parse` reads the number with `Int(_:)`,
    /// which accepts `-1`. A negative count is read as 0 — "nothing on that side" — which is
    /// the reading that never asks the user to integrate commits that do not exist.
    @Test(arguments: [
        (Tracking.counts(ahead: -1, behind: 3), PullPlan.fastForward),
        (.counts(ahead: 2, behind: -1), .nothingToDo),
        (.counts(ahead: -5, behind: -5), .nothingToDo),
    ])
    func aNegativeCountIsReadAsZero(tracking: Tracking, expected: PullPlan) {
        #expect(PullPlan.decide(tracking) == expected)
    }
}
