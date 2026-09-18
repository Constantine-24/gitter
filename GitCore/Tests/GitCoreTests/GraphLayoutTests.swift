import Foundation
import Testing

@testable import GitCore

@Suite struct GraphLayoutTests {
    // MARK: - Helpers

    static func c(_ sha: String, _ parents: [String]) -> Commit {
        Commit(
            sha: sha,
            parents: parents,
            authorName: "Tester",
            authorEmail: "t@t",
            authorDate: Date(timeIntervalSince1970: 0),
            summary: "Summary for \(sha)",
            refs: []
        )
    }

    static func edges(_ row: GraphRow) -> Set<GraphEdge> { Set(row.edges) }

    static func down(_ from: Int, _ to: Int) -> GraphEdge {
        GraphEdge(fromLane: from, toLane: to, fromAbove: false)
    }

    static func fixtureCommits() throws -> [Commit] {
        let url = try #require(
            Bundle.module.url(forResource: "log", withExtension: "bin", subdirectory: "Fixtures")
        )
        return LogParser.parse(try Data(contentsOf: url))
    }

    /// Every downward edge must land in a lane that exists on the next row.
    static func assertEdgesLandInsideNextRow(_ rows: [GraphRow], sourceLocation: SourceLocation = #_sourceLocation) {
        for (index, row) in rows.enumerated() {
            for edge in row.edges where !edge.fromAbove {
                let nextLaneCount = index + 1 < rows.count ? rows[index + 1].laneCount : 0
                #expect(edge.toLane < nextLaneCount, "row \(index) edge \(edge)", sourceLocation: sourceLocation)
            }
        }
    }

    // MARK: - Linear history

    @Test func linearHistoryStaysInLaneZero() {
        let rows = GraphLayout.layout([
            Self.c("A", ["B"]),
            Self.c("B", ["C"]),
            Self.c("C", []),
        ])

        #expect(rows.map(\.sha) == ["A", "B", "C"])
        #expect(rows.map(\.lane) == [0, 0, 0])
        #expect(rows[0].edges == [Self.down(0, 0)])
        #expect(rows[1].edges == [Self.down(0, 0)])
        #expect(rows[2].edges.isEmpty)
        #expect(rows.map(\.laneCount) == [1, 1, 1])
        Self.assertEdgesLandInsideNextRow(rows)
    }

    // MARK: - Branch and merge

    @Test func mergeWithFirstParentFirstKeepsMergeInLaneZero() {
        let rows = GraphLayout.layout([
            Self.c("M", ["A", "B"]),
            Self.c("A", ["R"]),
            Self.c("B", ["R"]),
            Self.c("R", []),
        ])

        #expect(rows.map(\.sha) == ["M", "A", "B", "R"])
        #expect(rows.map(\.lane) == [0, 0, 1, 0])

        #expect(Self.edges(rows[0]) == [Self.down(0, 0), Self.down(0, 1)])
        #expect(rows[0].laneCount == 2)

        // A's parent R takes A's own lane; B's lane passes through.
        #expect(Self.edges(rows[1]) == [Self.down(0, 0), Self.down(1, 1)])
        #expect(rows[1].laneCount == 2)

        // Lane 0 already awaits R, so B's parent reuses it and lane 1 is freed.
        #expect(Self.edges(rows[2]) == [Self.down(0, 0), Self.down(1, 0)])
        #expect(rows[2].laneCount == 2)

        #expect(rows[3].edges.isEmpty)
        #expect(rows[3].laneCount == 1)

        #expect(rows.allSatisfy { $0.edges.allSatisfy { !$0.fromAbove } })
        Self.assertEdgesLandInsideNextRow(rows)
    }

    @Test func mergeWithSecondParentFirstResolvesRootInLaneOne() {
        let rows = GraphLayout.layout([
            Self.c("M", ["A", "B"]),
            Self.c("B", ["R"]),
            Self.c("A", ["R"]),
            Self.c("R", []),
        ])

        #expect(rows.map(\.sha) == ["M", "B", "A", "R"])
        #expect(rows.map(\.lane) == [0, 1, 0, 1])

        #expect(Self.edges(rows[1]) == [Self.down(0, 0), Self.down(1, 1)])
        // A's parent R is already awaited by lane 1, so A's lane 0 is freed.
        #expect(Self.edges(rows[2]) == [Self.down(0, 1), Self.down(1, 1)])
        #expect(rows[3].edges.isEmpty)

        #expect(rows.allSatisfy { $0.edges.allSatisfy { !$0.fromAbove } })
        Self.assertEdgesLandInsideNextRow(rows)
    }

    @Test func twoChildrenOfOneParentShareTheParentLane() {
        let rows = GraphLayout.layout([
            Self.c("X", ["P"]),
            Self.c("Y", ["P"]),
            Self.c("P", []),
        ])

        #expect(rows.map(\.lane) == [0, 1, 0])
        #expect(Self.edges(rows[0]) == [Self.down(0, 0)])
        // Lane 0 already awaits P, so Y's edge crosses into it and lane 1 is freed.
        #expect(Self.edges(rows[1]) == [Self.down(0, 0), Self.down(1, 0)])
        #expect(rows[2].edges.isEmpty)

        // Reusing the awaiting lane means merges are drawn on the child's row,
        // so no `fromAbove` edge is ever produced here.
        #expect(rows.allSatisfy { $0.edges.allSatisfy { !$0.fromAbove } })
        Self.assertEdgesLandInsideNextRow(rows)
    }

    // MARK: - Roots

    @Test func twoIndependentRootsBothUseLaneZero() {
        let rows = GraphLayout.layout([
            Self.c("A", []),
            Self.c("B", []),
        ])

        #expect(rows.map(\.lane) == [0, 0])
        #expect(rows.allSatisfy { $0.edges.isEmpty })
        #expect(rows.map(\.laneCount) == [1, 1])
        Self.assertEdgesLandInsideNextRow(rows)
    }

    @Test func emptyInputProducesNoRows() {
        #expect(GraphLayout.layout([]).isEmpty)
    }

    // MARK: - Octopus

    @Test func octopusMergeFansOutToThreeLanes() {
        let rows = GraphLayout.layout([
            Self.c("M", ["A", "B", "C"]),
            Self.c("A", []),
            Self.c("B", []),
            Self.c("C", []),
        ])

        #expect(rows[0].lane == 0)
        #expect(Self.edges(rows[0]) == [Self.down(0, 0), Self.down(0, 1), Self.down(0, 2)])
        #expect(rows[0].laneCount == 3)
        #expect(rows.map(\.lane) == [0, 0, 1, 2])
        Self.assertEdgesLandInsideNextRow(rows)
    }

    // MARK: - Fixture

    @Test func fixtureLayoutMatchesCommitOrderAndUsesTwoLanes() throws {
        let commits = try Self.fixtureCommits()
        let rows = GraphLayout.layout(commits)

        #expect(rows.count == 6)
        #expect(rows.map(\.sha) == commits.map(\.sha))
        #expect(rows.map(\.laneCount).max() == 2)

        let mergeSha = "66e749e9705f08ca6bc833aab6a587f59736bcc8"
        let mergeRow = try #require(rows.first { $0.sha == mergeSha })
        #expect(mergeRow.edges.count == 2)
        #expect(mergeRow.edges.allSatisfy { !$0.fromAbove })
        #expect(Self.edges(mergeRow) == [Self.down(0, 0), Self.down(0, 1)])

        #expect(rows.allSatisfy { $0.edges.allSatisfy { !$0.fromAbove } })
        Self.assertEdgesLandInsideNextRow(rows)
    }
}
