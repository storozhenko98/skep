// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Skep",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Skep", targets: ["SkepApp"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.5"
        ),
    ],
    targets: [
        .target(name: "SkepCore"),
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),
        .target(
            name: "SkepTerminal",
            dependencies: ["SkepCore", "GhosttyKit"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedLibrary("c++"),
            ]
        ),
        .executableTarget(
            name: "SkepApp",
            dependencies: [
                "SkepCore",
                "SkepTerminal",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(
            name: "SkepCoreTests",
            dependencies: ["SkepCore"]
        ),
        .testTarget(
            name: "SkepTerminalTests",
            dependencies: ["SkepCore", "SkepTerminal", "GhosttyKit"]
        ),
    ]
)
