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

    /// Kinds moved toward Resolver/Text in 0.02 steps until 4.5:1 on every background (3:1 on the
    /// selected diff rows): the final
    /// value in each appearance and what forced it. Filled in by the contrast step.
    static let adjusted: [SyntaxKind: (light: RGB?, dark: RGB?, why: String)] = [
        .keyword: ([0.608, 0.138, 0.576], [0.976, 0.547, 0.737], "TheirsWord, 3.53 in dark"),
        .string: ([0.717, 0.103, 0.089], [0.978, 0.565, 0.535], "TheirsWord, 4.10 in light and 3.56 in dark"),
        .comment: ([0.319, 0.366, 0.411], [0.655, 0.684, 0.720], "TheirsWord, 3.72 in light and 2.28 in dark"),
        .function: ([0.422, 0.213, 0.664], [0.758, 0.622, 0.929], "TheirsWord, 2.71 in dark"),
        .constant: ([0.422, 0.213, 0.664], [0.759, 0.621, 0.928], "TheirsWord, 2.70 in dark"),
        .attribute: ([0.466, 0.345, 0.023], [0.809, 0.650, 0.524], "TheirsWord, 4.05 in light and 3.24 in dark"),
        .preprocessor: ([0.391, 0.220, 0.124], [0.989, 0.577, 0.275], "TheirsWord, 4.43 in dark"),
        .url: ([0.055, 0.055, 1.000], [0.553, 0.669, 0.988], "TheirsWord, 2.91 in dark"),
        .markupCode: ([0.665, 0.052, 0.569], [0.841, 0.608, 0.817], "TheirsWord, 1.53 in dark (the dark value was the unlightened light value)"),
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
    /// Needs 4.5:1, or 3:1 for the selected diff rows (`selected`).
    static func diff(_ name: String, _ base: NSColor, _ alpha: Double) -> Background {
        Background(name: name) { appearance in
            SyntaxPalette.composite(base.withAlphaComponent(alpha), over: .textBackgroundColor, in: appearance)
        }
    }

    static func resolver(_ role: ResolverRole) -> NSColor { NSColor(named: role.assetName) ?? .magenta }

    /// The diff rows draw `Color.green/red.opacity(…)` over the pane (`DiffLineRow.background`).
    /// The resolver columns fill each opaque tint over the window and then an opaque word mark
    /// over that (`ResolverTextView.drawBackground`), so each is its own background.
    /// Verified equal to SwiftUI's `Color.green` and `Color.red` in both appearances on macOS 26.
    nonisolated(unsafe) static let backgrounds: [Background] = {
        var list = [diff("green 0.15", .systemGreen, 0.15), diff("red 0.15", .systemRed, 0.15)]
        for role in [ResolverRole.oursTint, .theirsTint, .resolvedTint, .oursWord, .theirsWord, .filler] {
            list.append(Background(name: role.assetName) { appearance in
                SyntaxPalette.composite(resolver(role), over: resolver(.window), in: appearance)
            })
        }
        return list
    }()

    /// Lines selected for staging draw at 0.30.
    nonisolated(unsafe) static let selectedBackgrounds = [diff("green 0.30", .systemGreen, 0.30), diff("red 0.30", .systemRed, 0.30)]

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

    @Test func legibleWhileSelected() {
        for kind in SyntaxKind.allCases {
            for (name, appearance) in [("light", Self.light), ("dark", Self.dark)] {
                for background in Self.selectedBackgrounds {
                    let ratio = SyntaxPalette.contrast(
                        SyntaxPalette.standard.color(kind), background.colour(appearance), in: appearance)
                    #expect(ratio >= 3.0, "\(kind) \(name) on \(background.name): \(ratio)")
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
