/// A role in code that gets its own colour. Everything else is drawn in the plain text colour.
///
/// The raw values are the names of the app's asset-catalog colours (`Syntax/<raw value>`).
public enum SyntaxKind: String, CaseIterable, Sendable {
    case keyword = "Keyword"
    case string = "String"
    case character = "Character"
    case comment = "Comment"
    case number = "Number"
    case type = "Type"
    case function = "Function"
    case constant = "Constant"
    case attribute = "Attribute"
    case preprocessor = "Preprocessor"
    case url = "URL"
    case markupCode = "MarkupCode"

    /// The kind for a highlight query's capture name, or nil for one drawn plain.
    ///
    /// The longest dotted prefix in the table decides: `keyword.function` is a keyword through
    /// `keyword`, while `string.escape` is a character although `string` is a string. A name
    /// starting with `_` is a query's private helper capture and never colours anything.
    public init?(capture: String) {
        guard !capture.hasPrefix("_") else { return nil }
        var name = Substring(capture)
        while true {
            if let entry = Self.byCapture[name] {
                guard let kind = entry else { return nil }
                self = kind
                return
            }
            guard let dot = name.lastIndex(of: ".") else { return nil }
            name = name[..<dot]
        }
    }

    /// The spec's capture table, with its "Measured" mapping where the two differ (ledger
    /// Ruling 1), and the old-style names Kotlin's query still uses (`conditional`, `repeat`,
    /// `include`, `exception`, `float`). A name not here, and with no prefix here, is plain:
    /// `variable`, `property`, `punctuation`, `operator`, `label`, `namespace`, `parameter`,
    /// `embedded`, `spell` and `none` among them. A nil entry is plain although a shorter prefix
    /// has a colour: Swift's ternary `?` and `:` are `keyword.conditional.ternary`, and Xcode
    /// draws them plain.
    private static let byCapture: [Substring: SyntaxKind?] = [
        "keyword": .keyword, "keyword.conditional.ternary": nil, "conditional": .keyword, "repeat": .keyword, "include": .keyword,
        "exception": .keyword, "storageclass": .keyword, "boolean": .keyword,
        "constant.builtin": .keyword, "variable.builtin": .keyword, "tag": .keyword,
        "text.title": .keyword,

        "string": .string,

        "string.escape": .character, "character": .character, "escape": .character,

        "comment": .comment,

        "number": .number, "float": .number, "constant.numeric": .number,

        "type": .type, "constructor": .type,

        "function": .function, "method": .function,

        "constant": .constant, "string.special.symbol": .constant,

        "attribute": .attribute, "decorator": .attribute, "tag.attribute": .attribute,

        "preproc": .preprocessor, "define": .preprocessor, "macro": .preprocessor,
        "function.macro": .preprocessor, "constant.macro": .preprocessor,

        "string.special.url": .url, "text.uri": .url, "text.reference": .url,

        "text.literal": .markupCode,
    ]
}
