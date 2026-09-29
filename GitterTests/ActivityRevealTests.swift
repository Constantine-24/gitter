import Foundation
import Testing

@testable import Gitter

/// `ActivityReveal`: a network item draws its lane's Stop, spinner and progress line only once
/// the lane has run for `delay`, so a lane that ends sooner never resizes the toolbar at all.
/// (The toolbar-crash fix: a lane that grew the item and shrank it again inside the toolbar's
/// own resize animation made AppKit's layout loop until it threw.)
@Suite struct ActivityRevealTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private static let earlier = Date(timeIntervalSinceReferenceDate: 990)

    @Test func aLaneThatHasJustStartedShowsNothingYet() {
        #expect(!ActivityReveal.shows(laneStartedAt: Self.start, revealed: nil))
    }

    @Test func aLaneShowsOnceItsDelayHasPassed() {
        #expect(ActivityReveal.shows(laneStartedAt: Self.start, revealed: Self.start))
    }

    /// The item's reveal is for one lane: the next lane waits its own delay.
    @Test func aRevealForAnEarlierLaneDoesNotShowTheNextOne() {
        #expect(!ActivityReveal.shows(laneStartedAt: Self.start, revealed: Self.earlier))
    }

    @Test func withNoLaneNothingShowsEvenIfARevealLingers() {
        #expect(!ActivityReveal.shows(laneStartedAt: nil, revealed: Self.start))
        #expect(!ActivityReveal.shows(laneStartedAt: nil, revealed: nil))
    }

    /// Longer than the toolbar's resize animation (measured at about 0.3 s), and shorter than the
    /// default double-click interval (0.5 s), during which Stop ignores a click anyway.
    @Test func theDelayOutlastsTheToolbarsResizeAnimation() {
        #expect(ActivityReveal.delay == .milliseconds(400))
    }
}
