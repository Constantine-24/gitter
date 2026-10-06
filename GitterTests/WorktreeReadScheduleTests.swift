import Testing

@testable import Gitter

/// B3 final review, I2: the worktree state is read in its own task, after the snapshot has landed,
/// never awaited by it (`RepositoryStore.scheduleWorktreeStateRead`). `WorktreeReadSchedule` is
/// that task's rule: one read at a time; a request while one runs is kept and run once it lands,
/// so a reload every 300 ms still gets a fresh state (cancelling instead would starve it); a read
/// is written only for the generation it was started under — never once `open()` has moved on.
@Suite struct WorktreeReadScheduleTests {
    typealias Outcome = WorktreeReadSchedule.Outcome

    @Test func oneReadAtATimeAndARequestDuringItRunsOnceItLands() {
        var schedule = WorktreeReadSchedule()
        #expect(!schedule.isReading)
        let first = schedule.request(generation: 1)
        #expect(first, "the first starts at once")
        #expect(schedule.isReading)
        let second = schedule.request(generation: 1)
        let third = schedule.request(generation: 1)
        #expect(!second, "a second waits for the first")
        #expect(!third, "and a third is the same one more read")

        let landed = schedule.finish(generation: 1, current: 1)
        #expect(landed == Outcome(write: true, again: true))
        #expect(!schedule.isReading)
        let again = schedule.request(generation: 1)
        #expect(again)
        let last = schedule.finish(generation: 1, current: 1)
        #expect(last == Outcome(write: true, again: false))
        #expect(!schedule.isReading)
    }

    /// `open()` resets it: the old read's answer is not written and starts nothing, and the new
    /// repository's first read starts at once although the old one has not come back.
    @Test func aReadFromBeforeOpenIsNeverWritten() {
        var schedule = WorktreeReadSchedule()
        let old = schedule.request(generation: 1)
        let oldAgain = schedule.request(generation: 1)
        #expect(old && !oldAgain)
        schedule.reset()
        let new = schedule.request(generation: 2)
        #expect(new, "the new repository's read does not wait for the old one")

        let stale = schedule.finish(generation: 1, current: 2)
        #expect(stale == Outcome(write: false, again: false))
        #expect(schedule.isReading, "the new read is still the one in flight")
        let fresh = schedule.finish(generation: 2, current: 2)
        #expect(fresh == Outcome(write: true, again: false))
    }

    /// The generation is checked even without a reset: a read whose generation is no longer the
    /// store's is dropped.
    @Test func aReadForAnotherGenerationIsDropped() {
        var schedule = WorktreeReadSchedule()
        let started = schedule.request(generation: 3)
        #expect(started)
        let outcome = schedule.finish(generation: 3, current: 4)
        #expect(outcome == Outcome(write: false, again: false))
    }
}
