import Testing

import GitterSyntax

/// How the capture names the pinned highlight queries emit become colour roles.
@Suite struct SyntaxKindTests {

    /// One name per row of the spec's capture table (its "Measured" mapping where the two
    /// differ, ledger Ruling 1), including the old-style names Kotlin's query still uses.
    @Test(arguments: [
        ("keyword.function", SyntaxKind.keyword),
        ("boolean", .keyword),
        ("text.title", .keyword),
        ("conditional", .keyword),
        ("include", .keyword),
        ("string.special.key", .string),
        ("string.escape", .character),
        ("character.special", .character),
        ("comment.documentation", .comment),
        ("float", .number),
        ("type.builtin", .type),
        ("constructor", .type),
        ("function.builtin", .function),
        ("function.macro", .preprocessor),
        ("string.special.symbol", .constant),
        ("text.uri", .url),
        ("text.reference", .url),
        ("text.literal", .markupCode),
    ])
    func mapsCaptureNames(capture: String, kind: SyntaxKind) {
        #expect(SyntaxKind(capture: capture) == kind)
    }

    /// Names that Xcode would leave uncoloured map to nothing.
    @Test(arguments: [
        "variable.member", "property", "punctuation.bracket", "operator", "spell", "embedded",
        "none", "label", "namespace", "parameter", "keyword.conditional.ternary",
    ])
    func plainCaptures(capture: String) {
        #expect(SyntaxKind(capture: capture) == nil)
    }

    /// The raw values are the asset-catalog colour names the app reads.
    @Test func rawValuesAreAssetNames() {
        #expect(SyntaxKind.allCases.map(\.rawValue) == [
            "Keyword", "String", "Character", "Comment", "Number", "Type", "Function", "Constant",
            "Attribute", "Preprocessor", "URL", "MarkupCode",
        ])
    }
}
