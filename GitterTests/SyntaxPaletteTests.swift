import AppKit
import GitterSyntax
import Testing

@testable import Gitter

/// Syntax colours Task 2: the palette reads Xcode's Default theme values from the asset catalog,
/// toned down only where a colour is under 4.5:1 on a background code sits on.
@Suite struct SyntaxPaletteTests {

    typealias RGB = [Double]
    nonisolated(unsafe) static let light = NSAppearance(named: .aqua)!
    nonisolated(unsafe) static let dark = NSAppearance(named: .darkAqua)!

    /// The spec's table (Xcode's Default Light and Default Dark themes), sRGB.
    static let spec: [SyntaxKind: (light: RGB, dark: RGB)] = [
        .keyword: ([0.608, 0.138, 0.576], [0.988, 0.374, 0.638]),
        .string: ([0.770, 0.102, 0.086], [0.989, 0.416, 0.366]),
        .character: ([0.110, 0.000, 0.810], [0.816, 0.749, 0.412]),
        .comment: ([0.365, 0.422, 0.475], [0.424, 0.475, 0.525]),
        .number: ([0.110, 0.000, 0.810], [0.815, 0.749, 0.412]),
        .type: ([0.225, 0.000, 0.628], [0.817, 0.657, 0.999]),
        .function: ([0.422, 0.213, 0.664], [0.631, 0.404, 0.902]),
        .constant: ([0.422, 0.213, 0.664], [0.632, 0.402, 0.901]),
        .attribute: ([0.506, 0.371, 0.012], [0.749, 0.522, 0.333]),
        .preprocessor: ([0.391, 0.220, 0.124], [0.991, 0.561, 0.246]),
        .url: ([0.055, 0.055, 1.000], [0.330, 0.511, 0.999]),
        .markupCode: ([0.665, 0.052, 0.569], [0.665, 0.052, 0.569]),
    ]

    /// Kinds moved toward Resolver/Text in 0.02 steps until 4.5:1 on every background: the final
    /// value in each appearance and what forced it. Filled in by the contrast step.
    static let adjusted: [SyntaxKind: (light: RGB?, dark: RGB?, why: String)] = [
        .keyword: ([0.608, 0.138, 0.576], [0.971, 0.627, 0.783], "Green 0.30 diff background, 3.08 original"),
        .string: ([0.691, 0.103, 0.090], [0.972, 0.640, 0.619], "Red 0.30 in light (3.95), green 0.30 in dark (3.11)"),
        .comment: ([0.314, 0.360, 0.404], [0.708, 0.731, 0.765], "Red 0.30 in light (3.59), green 0.30 in dark (1.99)"),
        .function: ([0.422, 0.213, 0.664], [0.796, 0.687, 0.937], "Green 0.30 diff background, 2.36 original"),
        .constant: ([0.422, 0.213, 0.664], [0.797, 0.686, 0.936], "Green 0.30 diff background, 2.35 original"),
        .attribute: ([0.451, 0.334, 0.027], [0.833, 0.701, 0.600], "Red 0.30 in light (3.90), green 0.30 in dark (2.83)"),
        .preprocessor: ([0.391, 0.220, 0.124], [0.981, 0.654, 0.419], "Green 0.30 diff background, 3.86 original"),
        .url: ([0.055, 0.055, 1.000], [0.627, 0.721, 0.984], "Green 0.30 diff background, 2.54 original"),
        .markupCode: ([0.643, 0.054, 0.551], [0.864, 0.680, 0.849], "Red 0.30 in light (4.38), green 0.30 in dark (1.33; the dark value was the unlightened light value)"),
    ]

    static func components(_ colour: NSColor, in appearance: NSAppearance) -> RGB {
        var out: RGB = []
        appearance.performAsCurrentDrawingAppearance {
            let c = colour.usingColorSpace(.sRGB)!
            out = [c.redComponent, c.greenComponent, c.blueComponent]
        }
        return out
    }

    @Test func everyKindHasAnAsset() {
        for kind in SyntaxKind.allCases {
            #expect(NSColor(named: "Syntax/\(kind.rawValue)") != nil, "\(kind)")
            #expect(Self.components(SyntaxPalette.standard.color(kind), in: Self.light) != Self.components(.magenta, in: Self.light), "\(kind)")
        }
        #expect(Self.spec.count == SyntaxKind.allCases.count)
    }

    @Test func valuesMatchXcodeDefaults() {
        for kind in SyntaxKind.allCases {
            let expected = Self.spec[kind]!
            for (name, appearance, value) in [("light", Self.light, expected.light), ("dark", Self.dark, expected.dark)] {
                let adjustedValue = Self.adjusted[kind].flatMap { name == "light" ? $0.light : $0.dark }
                let want = adjustedValue ?? value
                let got = Self.components(SyntaxPalette.standard.color(kind), in: appearance)
                for i in 0..<3 {
                    #expect(abs(got[i] - want[i]) <= 0.002, "\(kind) \(name) \(got) vs \(want)")
                }
            }
        }
    }

    /// One background as drawn, in an appearance.
    struct Background { let name: String; let colour: (NSAppearance) -> NSColor }

    static func resolver(_ role: ResolverRole) -> NSColor { NSColor(named: role.assetName) ?? .magenta }

    /// The diff rows draw `Color.green/red.opacity(…)` over the pane (`DiffLineRow.background`).
    /// The resolver columns fill each opaque tint over the window and then an opaque word mark
    /// over that (`ResolverTextView.drawBackground`), so each is its own background.
    nonisolated(unsafe) static let backgrounds: [Background] = {
        func diff(_ name: String, _ base: NSColor, _ alpha: Double) -> Background {
            Background(name: name) { appearance in
                SyntaxPalette.composite(base.withAlphaComponent(alpha), over: .textBackgroundColor, in: appearance)
            }
        }
        var list = [
            diff("green 0.15", .systemGreen, 0.15), diff("green 0.30", .systemGreen, 0.30),
            diff("red 0.15", .systemRed, 0.15), diff("red 0.30", .systemRed, 0.30),
        ]
        for role in [ResolverRole.oursTint, .theirsTint, .resolvedTint, .oursWord, .theirsWord, .filler] {
            list.append(Background(name: role.assetName) { appearance in
                SyntaxPalette.composite(resolver(role), over: resolver(.window), in: appearance)
            })
        }
        return list
    }()

    @Test func legibleOnEveryBackground() {
        for kind in SyntaxKind.allCases {
            for (name, appearance) in [("light", Self.light), ("dark", Self.dark)] {
                for background in Self.backgrounds {
                    let ratio = SyntaxPalette.contrast(
                        SyntaxPalette.standard.color(kind), background.colour(appearance), in: appearance)
                    #expect(ratio >= 4.5, "\(kind) \(name) on \(background.name): \(ratio)")
                }
            }
        }
    }

    @Test func contrastIsWCAG() {
        #expect(abs(SyntaxPalette.contrast(.black, .white, in: Self.light) - 21) < 0.001)
        #expect(abs(SyntaxPalette.contrast(.white, .white, in: Self.light) - 1) < 0.001)
    }

    @Test func compositeBlendsInSRGB() {
        let c = SyntaxPalette.composite(NSColor.black.withAlphaComponent(0.5), over: .white, in: Self.light)
        let v = Self.components(c, in: Self.light)
        #expect(abs(v[0] - 0.5) < 0.002 && abs(v[1] - 0.5) < 0.002 && abs(v[2] - 0.5) < 0.002)
    }
}
