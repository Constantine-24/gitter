import AppKit
import GitterSyntax
import SwiftUI

/// The syntax colours (spec, "Colours"): one asset-catalog colour per `SyntaxKind`,
/// `Syntax/<raw value>`, each with its light and dark value, read through `SyntaxPalette` for
/// AppKit and `SyntaxColor` for SwiftUI.
struct SyntaxPalette: @unchecked Sendable {
    private let colors: [SyntaxKind: NSColor]

    /// From the asset catalog.
    static let standard = SyntaxPalette()

    private init() {
        var colors: [SyntaxKind: NSColor] = [:]
        for kind in SyntaxKind.allCases {
            colors[kind] = NSColor(named: "Syntax/\(kind.rawValue)") ?? .magenta
        }
        self.colors = colors
    }

    /// A dynamic colour, resolved in the appearance it is drawn in.
    func color(_ kind: SyntaxKind) -> NSColor { colors[kind] ?? .magenta }

    // MARK: Contrast

    private static func srgb(_ colour: NSColor, in appearance: NSAppearance) -> (r: Double, g: Double, b: Double, a: Double) {
        var out = (r: 0.0, g: 0.0, b: 0.0, a: 1.0)
        appearance.performAsCurrentDrawingAppearance {
            if let c = colour.usingColorSpace(.sRGB) {
                out = (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
            }
        }
        return out
    }

    /// `top` over `bottom` as drawn in `appearance`: source-over on sRGB components.
    static func composite(_ top: NSColor, over bottom: NSColor, in appearance: NSAppearance) -> NSColor {
        let t = srgb(top, in: appearance), b = srgb(bottom, in: appearance)
        let a = t.a + b.a * (1 - t.a)
        guard a > 0 else { return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0) }
        func mix(_ x: Double, _ y: Double) -> Double { (x * t.a + y * b.a * (1 - t.a)) / a }
        return NSColor(srgbRed: mix(t.r, b.r), green: mix(t.g, b.g), blue: mix(t.b, b.b), alpha: a)
    }

    /// The WCAG 2.x contrast ratio of two colours in `appearance`, from 1 to 21.
    static func contrast(_ a: NSColor, _ b: NSColor, in appearance: NSAppearance) -> Double {
        func luminance(_ colour: NSColor) -> Double {
            let c = srgb(colour, in: appearance)
            func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

/// The palette for SwiftUI views.
enum SyntaxColor {
    static func color(_ kind: SyntaxKind) -> Color { Color("Syntax/\(kind.rawValue)") }
}
