import Testing

import GitterSyntax

/// How a file's path, and its first line when the name says nothing, choose a grammar.
@Suite struct SyntaxLanguageTests {

    /// Every extension in the spec's detection table, each with the language it must give.
    static let extensions: [(String, SyntaxLanguage)] = [
        ("swift", .swift),
        ("py", .python), ("pyi", .python), ("pyw", .python),
        ("js", .javascript), ("mjs", .javascript), ("cjs", .javascript), ("jsx", .javascript),
        ("ts", .typescript), ("mts", .typescript), ("cts", .typescript),
        ("tsx", .tsx),
        ("json", .json), ("jsonc", .json), ("json5", .json),
        ("html", .html), ("htm", .html), ("xhtml", .html),
        ("css", .css),
        ("scss", .scss),
        ("md", .markdown), ("markdown", .markdown), ("mdown", .markdown),
        ("yml", .yaml), ("yaml", .yaml),
        ("sh", .shell), ("bash", .shell), ("zsh", .shell), ("command", .shell),
        ("c", .c), ("h", .c),
        ("cc", .cpp), ("cpp", .cpp), ("cxx", .cpp), ("c++", .cpp), ("hh", .cpp), ("hpp", .cpp),
        ("hxx", .cpp), ("h++", .cpp), ("ipp", .cpp), ("tpp", .cpp),
        ("go", .go),
        ("rs", .rust),
        ("rb", .ruby), ("rake", .ruby), ("gemspec", .ruby), ("ru", .ruby),
        ("java", .java),
        ("kt", .kotlin), ("kts", .kotlin),
    ]

    /// The extension decides, in any case, and whatever directories the path has.
    @Test(arguments: extensions)
    func detectsEveryExtension(ext: String, language: SyntaxLanguage) {
        #expect(SyntaxLanguage.detect(path: "src/file.\(ext)", firstLine: nil) == language)
        #expect(SyntaxLanguage.detect(path: "FILE.\(ext.uppercased())", firstLine: nil) == language)
        #expect(SyntaxLanguage.detect(path: "a.b/file.\(ext)", firstLine: "#!/bin/sh") == language)
    }

    @Test func detectsUpperCaseReadme() {
        #expect(SyntaxLanguage.detect(path: "README.MD", firstLine: nil) == .markdown)
    }

    /// Scripts with no extension go by their shebang (directly or through `env`, with a CRLF
    /// line's `\r` ignored), and a few well-known names go by the name.
    @Test(arguments: [
        ("deploy", "#!/usr/bin/env bash" as String?, SyntaxLanguage.shell),
        ("tool", "#!/usr/bin/python3", .python),
        ("x", "#!/usr/bin/env node", .javascript),
        ("run", "#!/bin/zsh\r", .shell),
        ("build", "#! /usr/bin/env -S ruby -w", .ruby),
        ("Gemfile", nil, .ruby),
        (".zshrc", nil, .shell),
        ("dir/.babelrc", nil, .json),
        ("home/.bash_profile", nil, .shell),
        ("Podfile", nil, .ruby),
    ])
    func detectsShebangAndSpecialNames(path: String, firstLine: String?, language: SyntaxLanguage) {
        #expect(SyntaxLanguage.detect(path: path, firstLine: firstLine?[...]) == language)
    }

    /// Anything not in the table stays plain: the last extension is the one that counts, and a
    /// first line that isn't a known shebang says nothing.
    @Test(arguments: [
        ("a.kts.bak", nil as String?),
        ("Makefile", nil),
        ("notes", "hello"),
        ("script", "#!/usr/bin/env perl"),
        ("noext", nil),
    ])
    func unknownIsNil(path: String, firstLine: String?) {
        #expect(SyntaxLanguage.detect(path: path, firstLine: firstLine?[...]) == nil)
    }
}
