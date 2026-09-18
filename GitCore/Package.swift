// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GitCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GitCore", targets: ["GitCore"]),
    ],
    targets: [
        .target(
            name: "GitCore",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "GitCoreTests",
            dependencies: ["GitCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
