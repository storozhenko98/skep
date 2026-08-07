// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Skep",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Skep", targets: ["SkepApp"]),
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
            dependencies: ["SkepCore", "SkepTerminal"]
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
