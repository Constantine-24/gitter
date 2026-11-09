// Draws Gitter's app icon and writes it into an asset catalog's AppIcon set.
//
// A flat indigo (#5B4DFF) rounded square on Apple's macOS icon grid (an 824 px body centred in 1024,
// corner radius 185, continuous corners), no gradient, highlight or shadow. On it a white G drawn as
// one round-capped stroke: an arc that runs from the upper right the long way round through the top,
// left and bottom, then a bar back in toward the centre. The G doubles as a commit graph: a white
// commit sits where the arc starts and a yellow (#FFC83D) commit where the bar ends.
//
// The coordinates are the Figma master's, on a 1024 canvas with the y axis pointing down; the context
// is flipped once. It draws into an sRGB bitmap so the colours in the PNG are the ones written here.
//
// The icon is drawn once per pixel size, not scaled down from one big PNG, so the small sizes stay
// crisp. For 64 px and below the stroke and both commits are thickened a little so the G still
// reads in the Dock's and the Finder's smallest sizes. It writes the ten macOS files
// (16, 32, 128, 256, 512 pt at 1x and 2x) and rewrites the folder's Contents.json to list them.
//
// Re-run it from the repository root after changing the drawing, and commit what it writes:
//
//     swift scripts/make-icon.swift Gitter/Assets.xcassets/AppIcon.appiconset
import AppKit
import SwiftUI

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift <appiconset-folder>\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

/// Draws the icon at `px` x `px` pixels and returns it as PNG data.
func render(px: Int) -> Data {
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Flip once and scale: everything below is on the 1024 canvas, y down, as in Figma.
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: CGFloat(px) / 1024, y: -CGFloat(px) / 1024)
    func color(_ hex: UInt32) -> CGColor {
        CGColor(colorSpace: srgb, components: [CGFloat(hex >> 16 & 255) / 255, CGFloat(hex >> 8 & 255) / 255,
                                               CGFloat(hex & 255) / 255, 1])!
    }

    // Apple's macOS grid: an 824 body centred in 1024, corner radius 185, solid indigo.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.setFillColor(color(0x5B4DFF))
    ctx.addPath(RoundedRectangle(cornerRadius: 185, style: .continuous).path(in: body).cgPath)
    ctx.fillPath()

    // The small sizes thicken the stroke and the commits so the G still reads.
    let boost: CGFloat = px >= 128 ? 1 : px >= 64 ? 1.12 : px >= 32 ? 1.25 : 1.4

    let centre = CGPoint(x: 512, y: 512)
    let start = CGPoint(x: 689.7, y: 362.9)
    let barEnd = CGPoint(x: 540, y: 512)
    let startAngle = atan2(start.y - centre.y, start.x - centre.x)   // about -40 degrees, upper right

    // The G: from the start the long way round through the top, left and bottom (angles falling from
    // -40 to -360 degrees), then a straight bar in toward the centre.
    let g = CGMutablePath()
    g.move(to: start)
    g.addArc(center: centre, radius: 232, startAngle: startAngle, endAngle: -2 * .pi, clockwise: true)
    g.addLine(to: barEnd)
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineWidth(76 * boost)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(g)
    ctx.strokePath()

    func disc(_ c: CGPoint, _ r: CGFloat, _ fill: CGColor) {
        ctx.setFillColor(fill)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }
    disc(start, 66 * boost, color(0xFFFFFF))
    disc(CGPoint(x: 532, y: 512), 78 * boost, color(0xFFC83D))

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
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
