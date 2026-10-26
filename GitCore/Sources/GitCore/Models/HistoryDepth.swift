import Foundation

/// How deep History reads (H1): a page at a time, as the end of the list scrolls in, and never
/// past `cap` — a jump to a commit further back than that gets a notice instead of a load.
public enum HistoryDepth {
    /// The commits one read adds, and the depth a repository opens at.
    public static let page = 500
    /// The deepest History loads.
    public static let cap = 50_000

    /// The depth that loads row `row` (0-based): the smallest multiple of `page` above it, so
    /// rows 0…499 need 500 and row 500 needs 1000.
    public static func depth(forRow row: Int) -> Int {
        (max(row, 0) / page + 1) * page
    }
}
