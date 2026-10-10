// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GitCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GitCore", targets: ["GitCore"]),
        // The test helpers GitCoreTests and GitterTests share (E3 Task 2). It must never depend
        // on GitCore: through such a dependency Xcode links a second, static copy of GitCore into
        // GitterTests' bundle, beside the app's (E3 measurement B2.2).
        .library(name: "GitCoreTestSupport", targets: ["GitCoreTestSupport"]),
    ],
    targets: [
        .target(
            name: "GitCore",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "GitCoreTestSupport",
            dependencies: [],
            path: "Sources/GitCoreTestSupport",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "GitCoreTests",
            dependencies: ["GitCore", "GitCoreTestSupport"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
