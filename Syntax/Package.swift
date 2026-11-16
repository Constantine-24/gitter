// swift-tools-version: 6.2
import PackageDescription

// Gitter's syntax colours (milestone S1): Tree-sitter, through the Swift binding and one package
// per grammar. Every version is exact, so a resolve gives the same code without a committed
// Package.resolved. Nothing outside this package imports SwiftTreeSitter.
let grammars: [(url: String, version: Version, products: [(name: String, package: String)])] = [
    ("https://github.com/alex-pinkus/tree-sitter-swift", "0.7.4-with-generated-files", [("TreeSitterSwift", "tree-sitter-swift")]),
    ("https://github.com/tree-sitter/tree-sitter-python", "0.23.6", [("TreeSitterPython", "tree-sitter-python")]),
    ("https://github.com/tree-sitter/tree-sitter-javascript", "0.23.1", [("TreeSitterJavaScript", "tree-sitter-javascript")]),
    ("https://github.com/tree-sitter/tree-sitter-typescript", "0.23.2", [("TreeSitterTypeScript", "tree-sitter-typescript")]),
    ("https://github.com/tree-sitter/tree-sitter-json", "0.24.8", [("TreeSitterJSON", "tree-sitter-json")]),
    ("https://github.com/tree-sitter/tree-sitter-html", "0.23.2", [("TreeSitterHTML", "tree-sitter-html")]),
    ("https://github.com/tree-sitter/tree-sitter-css", "0.23.2", [("TreeSitterCSS", "tree-sitter-css")]),
    ("https://github.com/tree-sitter-grammars/tree-sitter-markdown", "0.5.4", [("TreeSitterMarkdown", "tree-sitter-markdown")]),
    ("https://github.com/tree-sitter-grammars/tree-sitter-yaml", "0.7.0", [("TreeSitterYAML", "tree-sitter-yaml")]),
    ("https://github.com/tree-sitter/tree-sitter-bash", "0.25.1", [("TreeSitterBash", "tree-sitter-bash")]),
    ("https://github.com/tree-sitter/tree-sitter-c", "0.24.2", [("TreeSitterC", "tree-sitter-c")]),
    ("https://github.com/tree-sitter/tree-sitter-cpp", "0.23.4", [("TreeSitterCPP", "tree-sitter-cpp")]),
    ("https://github.com/tree-sitter/tree-sitter-go", "0.25.0", [("TreeSitterGo", "tree-sitter-go")]),
    ("https://github.com/tree-sitter/tree-sitter-rust", "0.24.2", [("TreeSitterRust", "tree-sitter-rust")]),
    ("https://github.com/tree-sitter/tree-sitter-ruby", "0.23.1", [("TreeSitterRuby", "tree-sitter-ruby")]),
    ("https://github.com/tree-sitter/tree-sitter-java", "0.23.5", [("TreeSitterJava", "tree-sitter-java")]),
]

let package = Package(
    name: "Syntax",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GitterSyntax", targets: ["GitterSyntax"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter", exact: "0.25.10"),
    ] + grammars.map { .package(url: $0.url, exact: $0.version) },
    targets: [
        .target(
            name: "GitterSyntax",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitter", package: "tree-sitter"),
            ] + grammars.flatMap { grammar in
                grammar.products.map { Target.Dependency.product(name: $0.name, package: $0.package) }
            },
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "GitterSyntaxTests",
            dependencies: ["GitterSyntax"]
        ),
    ]
)
