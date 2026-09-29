import Foundation
import Testing

@testable import Gitter

/// `ActivityReveal`: when a network item draws its lane's Stop, spinner and progress line. It
/// draws them only once the lane has run for `delay`, and once drawn it keeps them for at least
/// `delay`, so no toolbar item grows and shrinks again within the toolbar's own resize animation.
/// That pattern made AppKit's layout loop until it threw (the toolbar crash, A1 inserted fix 6).
@Suite struct ActivityRevealTests {
    private typealias Reveal = ActivityReveal
    private static let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private static func lane(_ start: TimeInterval, _ owner: RemoteToolbarItem.Action)
        -> ActivityReveal.Lane
    {
        ActivityReveal.Lane(startedAt: at(start), owner: owner)
    }

    /// Revealed at 0.4 s, for the lane that started at 0.
    private static let shown = ActivityReveal.Revealed(lane: at(0), at: at(0.4))

    @Test func aLaneShorterThanTheDelayNeverReveals() {
        // Running, not yet long enough: nothing drawn, look again when the delay is up.
        #expect(
            Reveal.step(lane: Self.lane(0, .fetch), item: .fetch, revealed: nil, now: Self.at(0.3))
                == .init(revealed: nil, drawn: .button, wakeAt: Self.at(0.4)))
        // Ended before then: still nothing, and nothing to wait for.
        #expect(
            Reveal.step(lane: nil, item: .fetch, revealed: nil, now: Self.at(0.35))
                == .init(revealed: nil, drawn: .button, wakeAt: nil))
    }

    @Test func aLaneRevealsOnceItHasRunForTheDelay() {
        #expect(
            Reveal.step(lane: Self.lane(0, .fetch), item: .fetch, revealed: nil, now: Self.at(0.4))
                == .init(revealed: Self.shown, drawn: .lane, wakeAt: nil))
        #expect(
            Reveal.step(
                lane: Self.lane(0, .fetch), item: .fetch, revealed: Self.shown, now: Self.at(3))
                == .init(revealed: Self.shown, drawn: .lane, wakeAt: nil))
    }

    /// A lane of 0.45 s: revealed at 0.4, ended at 0.45. The activity stays until 0.8 — never
    /// shrinking inside the animation its own growth started.
    @Test func aRevealedActivityStaysForTheDelayAfterItsLaneEnds() {
        #expect(
            Reveal.step(lane: nil, item: .fetch, revealed: Self.shown, now: Self.at(0.45))
                == .init(revealed: Self.shown, drawn: .lingering, wakeAt: Self.at(0.8)))
        #expect(
            Reveal.step(lane: nil, item: .fetch, revealed: Self.shown, now: Self.at(0.8))
                == .init(revealed: nil, drawn: .button, wakeAt: nil))
    }

    @Test func aLaneThatOutlastsTheMinimumGoesAtOnce() {
        #expect(
            Reveal.step(lane: nil, item: .fetch, revealed: Self.shown, now: Self.at(2))
                == .init(revealed: nil, drawn: .button, wakeAt: nil))
    }

    /// Fetch pressed during a revealed automatic fetch: the same item, a new lane, no gap. It
    /// stays drawn, with no shrink and regrow, and keeps its reveal time.
    @Test func aReplacedLaneOfTheSameItemStaysRevealed() {
        #expect(
            Reveal.step(
                lane: Self.lane(0.5, .fetch), item: .fetch, revealed: Self.shown,
                now: Self.at(0.5))
                == .init(
                    revealed: .init(lane: Self.at(0.5), at: Self.at(0.4)), drawn: .lane,
                    wakeAt: nil))
    }

    /// Pull pressed during a revealed automatic fetch: Pull waits its own delay, and Fetch keeps
    /// its activity for its own minimum rather than taking the pull's.
    @Test func aLaneOfAnotherItemStartsItsOwnTiming() {
        #expect(
            Reveal.step(lane: Self.lane(0.5, .pull), item: .pull, revealed: nil, now: Self.at(0.5))
                == .init(revealed: nil, drawn: .button, wakeAt: Self.at(0.9)))
        #expect(
            Reveal.step(
                lane: Self.lane(0.5, .pull), item: .fetch, revealed: Self.shown, now: Self.at(0.5))
                == .init(revealed: Self.shown, drawn: .lingering, wakeAt: Self.at(0.8)))
    }

    /// A lingering Stop is drawn for a lane that has ended. It must never stop the one running
    /// now, which may belong to another item.
    @Test func aLingeringStopStopsOnlyTheLaneItShows() {
        #expect(Reveal.stopActs(shownLane: Self.at(0), runningLane: Self.at(0)))
        #expect(!Reveal.stopActs(shownLane: Self.at(0), runningLane: Self.at(0.5)))
        #expect(!Reveal.stopActs(shownLane: Self.at(0), runningLane: nil))
    }

    /// Longer than the toolbar's resize animation (the probe measured about 0.3 s), and shorter
    /// than the default double-click interval (0.5 s), during which Stop ignores a click anyway.
    @Test func theDelayLiesBetweenTheAnimationAndADoubleClick() {
        #expect(ActivityReveal.delay > .milliseconds(300))
        #expect(ActivityReveal.delay < .milliseconds(500))
    }
}
