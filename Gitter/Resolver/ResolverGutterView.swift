import AppKit
import GitCore

/// A strip between two columns, scrolled with them: each conflict's band in its side's colour
/// over the conflict's rows, and on its first row the arrow button that takes that side — blue →
/// into the Result between Ours and the Result, purple ← between the Result and Theirs. A band
/// and its button dim once the conflict is no longer waiting; a conflict an edit merged has no
/// button (a take would replace what it took in).
final class ResolverGutterView: NSView {
    let side: ConflictSide
    var palette = ResolverPalette.standard
    var model = ResolverColumnsModel()
    var labels = SideLabels(ours: "", theirs: "")
    /// The take (`ResolverColumnsHost`).
    var take: ((BlockChoice, Int) -> Void)?

    private var buttons: [Int: ResolverTakeButton] = [:]

    init(side: ConflictSide) {
        self.side = side
        super.init(frame: .zero)
        // Since macOS 14 a view may draw outside its bounds unless it clips.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        palette.sidebar.setFill()
        dirtyRect.intersection(bounds).fill()
        let colour = side == .ours ? palette.ours : palette.theirs
        for id in model.conflicts {
            guard let range = model.chunkRows[id] else { continue }
            let top = ResolverGeometry.y(ofRow: range.lowerBound), bottom = ResolverGeometry.y(ofRow: range.upperBound)
            let band = NSRect(x: 0, y: top, width: bounds.width, height: bottom - top)
            guard band.intersects(dirtyRect) else { continue }
            colour.withAlphaComponent(model.waiting.contains(id) ? 0.16 : 0.07).setFill()
            band.fill()
        }
    }

    /// One button per takeable conflict, on its first row.
    func layoutButtons() {
        let wanted = model.canTake ? model.takeable : []
        for (id, button) in buttons where !wanted.contains(id) {
            button.removeFromSuperview()
            buttons[id] = nil
        }
        let size: CGFloat = 18
        let count = model.conflicts.count
        for id in wanted {
            guard let row = model.firstRow[id], let index = model.conflictIndex(id) else { continue }
            let button = buttons[id] ?? makeButton(id)
            buttons[id] = button
            let frame = NSRect(
                x: (bounds.width - size) / 2, y: ResolverGeometry.y(ofRow: row) + (ResolverGeometry.rowHeight - size) / 2,
                width: size, height: size)
            if button.frame != frame { button.frame = frame }
            let alpha: CGFloat = model.waiting.contains(id) ? 1 : 0.4
            if button.alphaValue != alpha { button.alphaValue = alpha }
            let label = ConflictWording.takeLabel(side == .ours ? .ours : .theirs, conflict: index, of: count)
            if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
            let help = ConflictWording.takeHelp(side, labels)
            if button.toolTip != help { button.toolTip = help }
        }
        needsDisplay = true
    }

    private func makeButton(_ id: Int) -> ResolverTakeButton {
        let button = ResolverTakeButton(side: side)
        button.palette = palette
        button.onPress = { [weak self] in
            guard let self else { return }
            self.take?(self.side == .ours ? .ours : .theirs, id)
        }
        addSubview(button)
        return button
    }
}

/// The arrow in a ring that takes a side for a conflict: → in Ours' blue, ← in Theirs' purple.
final class ResolverTakeButton: NSView {
    let side: ConflictSide
    var palette = ResolverPalette.standard
    var onPress: (() -> Void)?
    private var pressed = false

    init(side: ConflictSide) {
        self.side = side
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let colour = side == .ours ? palette.ours : palette.theirs
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        (pressed ? colour.withAlphaComponent(0.25) : palette.window).setFill()
        ring.fill()
        colour.setStroke()
        ring.lineWidth = 1.25
        ring.stroke()
        // The arrow, pointing at the Result.
        let mid = NSPoint(x: bounds.midX, y: bounds.midY)
        let half = bounds.width * 0.22
        let direction: CGFloat = side == .ours ? 1 : -1
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: mid.x - half * direction, y: mid.y))
        arrow.line(to: NSPoint(x: mid.x + half * direction, y: mid.y))
        arrow.move(to: NSPoint(x: mid.x + half * direction - half * 0.8 * direction, y: mid.y - half * 0.8))
        arrow.line(to: NSPoint(x: mid.x + half * direction, y: mid.y))
        arrow.line(to: NSPoint(x: mid.x + half * direction - half * 0.8 * direction, y: mid.y + half * 0.8))
        arrow.lineWidth = 1.4
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
        guard let window else { return }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                pressed = false
                needsDisplay = true
                if inside { onPress?() }
                return
            }
            if inside != pressed {
                pressed = inside
                needsDisplay = true
            }
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
