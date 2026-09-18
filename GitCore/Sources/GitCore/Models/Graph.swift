import Foundation

public struct GraphEdge: Sendable, Hashable {
    public let fromLane: Int             // lane on this row
    public let toLane: Int               // lane on the next row
    public let fromAbove: Bool           // true = the edge runs from the top of the row at `fromLane` into this row's node; false = the edge runs from this row's node down to the next row at `toLane`

    public init(fromLane: Int, toLane: Int, fromAbove: Bool) {
        self.fromLane = fromLane
        self.toLane = toLane
        self.fromAbove = fromAbove
    }
}

public struct GraphRow: Sendable, Hashable, Identifiable {
    public let sha: String
    public let lane: Int                 // lane of the commit's node
    public let edges: [GraphEdge]        // edges leaving this row downward
    public let laneCount: Int            // number of lanes active on this row (for width)

    public var id: String { sha }

    public init(sha: String, lane: Int, edges: [GraphEdge], laneCount: Int) {
        self.sha = sha
        self.lane = lane
        self.edges = edges
        self.laneCount = laneCount
    }
}
