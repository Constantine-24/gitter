import GitCore
import SwiftUI

/// Draws the commit-graph column for a single row: the edges leaving it and the
/// node itself. Lane colours come from a fixed palette indexed by `lane % 8`.
struct CommitGraphCell: View {
    /// `nil` for the synthetic Working Copy row, which draws a dotted node in lane 0.
    let row: GraphRow?
    let isMerge: Bool

    static let laneWidth: CGFloat = 14
    static let rowHeight: CGFloat = 24

    static let palette: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .red,
    ]

    static func color(forLane lane: Int) -> Color {
        palette[((lane % palette.count) + palette.count) % palette.count]
    }

    /// Column width for a set of graph rows: the widest row's lane count.
    static func columnWidth(for rows: [GraphRow]) -> CGFloat {
        let lanes = rows.map(\.laneCount).max() ?? 1
        return max(24, CGFloat(lanes) * laneWidth + 8)
    }

    var body: some View {
        Canvas { context, size in
            guard let row else {
                drawWorkingCopyNode(in: &context, size: size)
                return
            }
            draw(row, in: &context, size: size)
        }
        .frame(height: Self.rowHeight)
        .accessibilityHidden(true)
    }

    private func x(_ lane: Int) -> CGFloat {
        CGFloat(lane) * Self.laneWidth + Self.laneWidth / 2
    }

    private func drawWorkingCopyNode(in context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: x(0), y: size.height / 2)
        let circle = Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
        context.stroke(
            circle,
            with: .color(.secondary),
            style: StrokeStyle(lineWidth: 1.5, dash: [2, 2])
        )
    }

    private func draw(_ row: GraphRow, in context: inout GraphicsContext, size: CGSize) {
        let centerY = size.height / 2

        for edge in row.edges {
            let start: CGPoint
            let end: CGPoint
            if edge.fromAbove {
                start = CGPoint(x: x(edge.fromLane), y: 0)
                end = CGPoint(x: x(row.lane), y: centerY)
            } else {
                start = CGPoint(
                    x: x(edge.fromLane),
                    y: edge.fromLane == row.lane ? centerY : 0
                )
                end = CGPoint(x: x(edge.toLane), y: size.height)
            }

            var path = Path()
            path.move(to: start)
            if abs(start.x - end.x) < 0.5 {
                path.addLine(to: end)
            } else {
                let midY = (start.y + end.y) / 2
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: start.x, y: midY),
                    control2: CGPoint(x: end.x, y: midY)
                )
            }
            let lane = edge.fromAbove ? edge.fromLane : edge.toLane
            context.stroke(path, with: .color(Self.color(forLane: lane)), lineWidth: 1.5)
        }

        let center = CGPoint(x: x(row.lane), y: centerY)
        let color = Self.color(forLane: row.lane)
        if isMerge {
            let ring = Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
            context.stroke(ring, with: .color(color), lineWidth: 2)
            let dot = Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
            context.fill(dot, with: .color(color))
        } else {
            let dot = Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
            context.fill(dot, with: .color(color))
        }
    }
}
