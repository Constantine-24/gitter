import Foundation

/// Assigns commits to lanes for a gitk-style commit graph.
public enum GraphLayout {
    /// Lays out `commits` into graph rows, one row per commit, in the given order.
    ///
    /// Commits must be in topo order (children before parents), as `git log --topo-order` gives.
    ///
    /// The algorithm keeps a lane table `lanes: [String?]`, where `lanes[i]` is the SHA that lane
    /// `i` is currently waiting to reach (`nil` = the lane is free). For each commit it picks the
    /// lane that awaits it (or a free one), routes each parent into a lane of the next row, and
    /// emits the edges that connect this row to the next one.
    ///
    /// Lane-picking policy: when a SHA is not yet awaited by any lane, reuse the **lowest free
    /// lane**, else append a new one. This keeps the graph narrow but lets a branch drift between
    /// lanes. This function is the one place to change if a "keep branches in their own lane"
    /// look is wanted later: pick a fresh lane instead of reusing a freed one.
    public static func layout(_ commits: [Commit]) -> [GraphRow] {
        var lanes: [String?] = []
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)

        for commit in commits {
            // 1. Pick this commit's lane: the first lane awaiting it, else the lowest free lane,
            //    else a new lane at the end.
            let lane: Int
            if let awaiting = lanes.firstIndex(where: { $0 == commit.sha }) {
                lane = awaiting
            } else if let free = lanes.firstIndex(where: { $0 == nil }) {
                lane = free
                lanes[free] = commit.sha
            } else {
                lane = lanes.count
                lanes.append(commit.sha)
            }

            var next = lanes
            var edges: [GraphEdge] = []

            // 2. Other lanes that also await this SHA merge into `lane` from above and are freed.
            //    In practice this never happens, because step 3 reuses an already-awaiting lane
            //    rather than creating a second one for the same SHA; the branch is kept for
            //    robustness in case a caller ever seeds lanes inconsistently.
            for index in lanes.indices where index != lane && lanes[index] == commit.sha {
                edges.append(GraphEdge(fromLane: index, toLane: lane, fromAbove: true))
                next[index] = nil
            }

            // 3. Route the parents into lanes of the next row.
            next[lane] = nil
            for parent in commit.parents {
                let parentLane: Int
                if let awaiting = next.firstIndex(where: { $0 == parent }) {
                    parentLane = awaiting
                } else if next[lane] == nil {
                    parentLane = lane
                } else if let free = next.firstIndex(where: { $0 == nil }) {
                    parentLane = free
                } else {
                    parentLane = next.count
                    next.append(nil)
                }
                next[parentLane] = parent
                edges.append(GraphEdge(fromLane: lane, toLane: parentLane, fromAbove: false))
            }

            // 4. Lanes waiting for some other commit carry straight through to the next row.
            for index in lanes.indices where index != lane {
                guard let waiting = lanes[index], waiting != commit.sha else { continue }
                if next.indices.contains(index), next[index] == waiting {
                    edges.append(GraphEdge(fromLane: index, toLane: index, fromAbove: false))
                }
            }

            let rowLaneCount = lanes.count
            while next.last == .some(nil) { next.removeLast() }

            rows.append(GraphRow(
                sha: commit.sha,
                lane: lane,
                edges: edges,
                laneCount: max(rowLaneCount, next.count)
            ))

            lanes = next
        }

        return rows
    }
}
