// Draws Gitter's app icon and writes it into an asset catalog's AppIcon set.
//
// A blue rounded square on Apple's macOS icon grid (an 824 px body centred in 1024, corner radius 185,
// a soft shadow), lighter at the top like the commit graph's blue. On it a white git-branch mark: a
// main line with two white commits, and a branch that leaves it and ends in an orange commit (Gitter's
// accent) on a white rim.
//
// The icon is drawn once per pixel size, not scaled down from one big PNG, so the small sizes stay
// crisp. For 64 px and below the mark's strokes, commits and rim are thickened a little so it still
// reads in the Dock's and the Finder's smallest sizes. It writes the ten macOS files
// (16, 32, 128, 256, 512 pt at 1x and 2x) and rewrites the folder's Contents.json to list them.
//
// Re-run it from the repository root after changing the drawing, and commit what it writes:
//
//     swift scripts/make-icon.swift Gitter/Assets.xcassets/AppIcon.appiconset
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift <appiconset-folder>\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

/// Draws the icon at `px` x `px` pixels and returns it as PNG data.
func render(px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // Everything below is drawn on the 1024 canvas.
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)

    // Apple's macOS grid: an 824 body centred in 1024, corner radius about 185.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    // Shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.30).cgColor)
    NSColor(srgbRed: 0.12, green: 0.20, blue: 0.55, alpha: 1).setFill()
    shape.fill()
    ctx.restoreGState()

    // Blue body, lighter at the top: the commit graph's blue.
    ctx.saveGState()
    shape.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 0.27, green: 0.56, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.28, blue: 0.78, alpha: 1),
    ])!.draw(in: body, angle: -90)
    // A soft glass highlight over the top half.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0.0)])!
        .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    ctx.restoreGState()

    // The small sizes thicken the strokes, commits and rim so the mark still reads.
    let boost: CGFloat = px >= 128 ? 1 : px >= 64 ? 1.12 : px >= 32 ? 1.25 : 1.4

    // The glyph, centred: its extent runs 314 to 710 across and 220 to 804 up the canvas, so the
    // centre is on 512 both ways.
    let white = NSColor.white
    let orange = NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1)
    let line = 58 * boost
    let commit = 70 * boost
    let rim = 86 * boost            // the orange commit's white rim, outer radius
    let tipFill = 70 * boost        // the orange commit itself
    let mainX: CGFloat = 384
    let bottom = CGPoint(x: mainX, y: 290), top = CGPoint(x: mainX, y: 734)
    let tip = CGPoint(x: 624, y: 640)

    white.setStroke()
    let main = NSBezierPath(); main.move(to: bottom); main.line(to: top)
    main.lineWidth = line; main.lineCapStyle = .round; main.stroke()

    // The branch runs on into the orange commit's centre; the rim is drawn over its end, so the
    // stroke goes under the rim with no seam.
    let branch = NSBezierPath()
    branch.move(to: CGPoint(x: mainX, y: 400))
    branch.curve(to: CGPoint(x: tip.x, y: tip.y - 80),
                 controlPoint1: CGPoint(x: mainX, y: 520),
                 controlPoint2: CGPoint(x: tip.x, y: 470))
    branch.line(to: tip)
    branch.lineWidth = line; branch.lineCapStyle = .round; branch.stroke()

    func disc(_ c: CGPoint, _ r: CGFloat, _ fill: NSColor) {
        fill.setFill()
        NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
    }
    disc(bottom, commit, white)
    disc(top, commit, white)
    disc(tip, rim, white)
    disc(tip, tipFill, orange)

    return rep.representation(using: .png, properties: [:])!
}

// (points, scale) for each file the macOS AppIcon set lists.
let slots: [(pt: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

var pngs: [Int: Data] = [:]      // one drawing per pixel size
var images: [[String: String]] = []
for slot in slots {
    let px = slot.pt * slot.scale
    if pngs[px] == nil { pngs[px] = render(px: px) }
    let name = "icon_\(slot.pt)x\(slot.pt)" + (slot.scale == 2 ? "@2x" : "") + ".png"
    try pngs[px]!.write(to: folder.appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(slot.scale)x", "size": "\(slot.pt)x\(slot.pt)"])
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: folder.appendingPathComponent("Contents.json"))
print("wrote \(slots.count) icons for \(pngs.count) pixel sizes into \(folder.path)")
