import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterKotlin
import TreeSitterMarkdown
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterSCSS
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

/// A language Gitter can colour, one per Tree-sitter grammar.
///
/// TypeScript and TSX are separate grammars, so they are separate cases. Markdown is the block
/// grammar only: its inline grammar would need a second parse layer, which this milestone leaves
/// out.
public enum SyntaxLanguage: String, CaseIterable, Sendable {
    case swift, python, javascript, typescript, tsx, json, html, css, scss, markdown, yaml, shell
    case c, cpp, go, rust, ruby, java, kotlin

    /// The language a file is written in, or nil when Gitter doesn't know it (and shows it plain).
    ///
    /// The file name's last extension decides first, in any case. A name with no known extension
    /// is then matched whole (`Gemfile`, `.zshrc`), and last a `#!` first line names the
    /// interpreter, directly or through `env`.
    public static func detect(path: String, firstLine: Substring?) -> SyntaxLanguage? {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let ext = name[name.index(after: dot)...].lowercased()
            if let language = byExtension[ext] { return language }
        }
        if let language = byName[name] { return language }
        if let firstLine, let interpreter = shebangInterpreter(firstLine) {
            if interpreter.hasPrefix("python") { return .python }
            return byInterpreter[interpreter]
        }
        return nil
    }

    /// The interpreter a `#!` line runs: the last path component of its command, or of the first
    /// argument that isn't an option when the command is `env`. A CRLF line's `\r` is ignored.
    private static func shebangInterpreter(_ line: Substring) -> String? {
        guard line.hasPrefix("#!") else { return nil }
        var words = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            .map { $0.split(separator: "/").last.map(String.init) ?? "" }
        if words.first == "env" {
            words = Array(words.dropFirst().drop(while: { $0.hasPrefix("-") }))
        }
        return words.first
    }

    private static let byExtension: [String: SyntaxLanguage] = {
        let table: [(SyntaxLanguage, [String])] = [
            (.swift, ["swift"]),
            (.python, ["py", "pyi", "pyw"]),
            (.javascript, ["js", "mjs", "cjs", "jsx"]),
            (.typescript, ["ts", "mts", "cts"]),
            (.tsx, ["tsx"]),
            (.json, ["json", "jsonc", "json5"]),
            (.html, ["html", "htm", "xhtml"]),
            (.css, ["css"]),
            (.scss, ["scss"]),
            (.markdown, ["md", "markdown", "mdown"]),
            (.yaml, ["yml", "yaml"]),
            (.shell, ["sh", "bash", "zsh", "command"]),
            (.c, ["c", "h"]),
            (.cpp, ["cc", "cpp", "cxx", "c++", "hh", "hpp", "hxx", "h++", "ipp", "tpp"]),
            (.go, ["go"]),
            (.rust, ["rs"]),
            (.ruby, ["rb", "rake", "gemspec", "ru"]),
            (.java, ["java"]),
            (.kotlin, ["kt", "kts"]),
        ]
        return Dictionary(uniqueKeysWithValues: table.flatMap { language, exts in exts.map { ($0, language) } })
    }()

    private static let byName: [String: SyntaxLanguage] = [
        ".babelrc": .json, ".eslintrc": .json,
        ".bashrc": .shell, ".zshrc": .shell, ".profile": .shell, ".bash_profile": .shell,
        ".zprofile": .shell,
        "Gemfile": .ruby, "Rakefile": .ruby, "Podfile": .ruby, "Fastfile": .ruby,
    ]

    /// Interpreters other than `python*`, which matches by prefix (`python3`, `python3.12`).
    private static let byInterpreter: [String: SyntaxLanguage] = [
        "node": .javascript,
        "sh": .shell, "bash": .shell, "zsh": .shell, "dash": .shell, "ksh": .shell,
        "ruby": .ruby,
    ]

    /// The grammar, from the package's C entry point.
    var grammar: Language {
        switch self {
        case .swift: Language(tree_sitter_swift())
        case .python: Language(tree_sitter_python())
        case .javascript: Language(tree_sitter_javascript())
        case .typescript: Language(tree_sitter_typescript())
        case .tsx: Language(tree_sitter_tsx())
        case .json: Language(tree_sitter_json())
        case .html: Language(tree_sitter_html())
        case .css: Language(tree_sitter_css())
        case .scss: Language(tree_sitter_scss())
        case .markdown: Language(tree_sitter_markdown())
        case .yaml: Language(tree_sitter_yaml())
        case .shell: Language(tree_sitter_bash())
        case .c: Language(tree_sitter_c())
        case .cpp: Language(tree_sitter_cpp())
        case .go: Language(tree_sitter_go())
        case .rust: Language(tree_sitter_rust())
        case .ruby: Language(tree_sitter_ruby())
        case .java: Language(tree_sitter_java())
        case .kotlin: Language(tree_sitter_kotlin())
        }
    }

    /// The highlight queries, as SwiftPM resource bundle and file name, concatenated in this
    /// order. TypeScript, TSX, C++ and SCSS only add to another grammar's highlights, so the
    /// other's file is joined in (spec, "Measured"). At the same node the later pattern wins, so
    /// TSX takes JavaScript's JSX patterns last: after JavaScript's general `(identifier)
    /// @variable` and `(property_identifier) @property`, which would otherwise leave every tag
    /// and attribute plain.
    var queryFiles: [(bundle: String, file: String)] {
        switch self {
        case .typescript:
            [("TreeSitterTypeScript_TreeSitterTypeScript", "highlights"),
             ("TreeSitterJavaScript_TreeSitterJavaScript", "highlights")]
        case .tsx:
            [("TreeSitterTypeScript_TreeSitterTSX", "highlights"),
             ("TreeSitterJavaScript_TreeSitterJavaScript", "highlights"),
             ("TreeSitterJavaScript_TreeSitterJavaScript", "highlights-jsx")]
        case .cpp:
            [("TreeSitterC_TreeSitterC", "highlights"), ("TreeSitterCPP_TreeSitterCPP", "highlights")]
        case .scss:
            [("TreeSitterCSS_TreeSitterCSS", "highlights"), ("TreeSitterSCSS_TreeSitterSCSS", "highlights")]
        default:
            [("\(packageName)_\(packageName)", "highlights")]
        }
    }

    /// The grammar package's (and target's) name, for the languages with one target.
    private var packageName: String {
        switch self {
        case .swift: "TreeSitterSwift"
        case .python: "TreeSitterPython"
        case .javascript: "TreeSitterJavaScript"
        case .typescript: "TreeSitterTypeScript"
        case .tsx: "TreeSitterTSX"
        case .json: "TreeSitterJSON"
        case .html: "TreeSitterHTML"
        case .css: "TreeSitterCSS"
        case .scss: "TreeSitterSCSS"
        case .markdown: "TreeSitterMarkdown"
        case .yaml: "TreeSitterYAML"
        case .shell: "TreeSitterBash"
        case .c: "TreeSitterC"
        case .cpp: "TreeSitterCPP"
        case .go: "TreeSitterGo"
        case .rust: "TreeSitterRust"
        case .ruby: "TreeSitterRuby"
        case .java: "TreeSitterJava"
        case .kotlin: "TreeSitterKotlin"
        }
    }
}
