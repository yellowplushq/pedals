// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PedalsGhostty",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
        .macCatalyst(.v15),
    ],
    products: [
        .library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"]),
        .library(name: "GhosttyTheme", targets: ["GhosttyTheme"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/Lakr233/MSDisplayLink.git",
            from: "2.1.0"
        ),
    ],
    targets: [
        .target(
            name: "GhosttyKit",
            dependencies: ["libghostty"],
            path: "Sources/GhosttyKit",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "GhosttyTerminal",
            dependencies: [
                "GhosttyKit",
                .product(name: "MSDisplayLink", package: "MSDisplayLink"),
            ],
            path: "Sources/GhosttyTerminal"
        ),
        .target(
            name: "GhosttyTheme",
            dependencies: ["GhosttyTerminal"],
            path: "Sources/GhosttyTheme",
            exclude: ["LICENSE"]
        ),
        .binaryTarget(
            name: "libghostty",
            url: "https://github.com/Lakr233/libghostty-spm/releases/download/storage.1.3.1/GhosttyKit.xcframework.zip",
            checksum: "cfb3fbbfe1365e4c90e01969e2576b4dfa33f04975bcafd84c6368514f791fe9"
        ),
        .testTarget(
            name: "PedalsGhosttyTests",
            dependencies: [
                "GhosttyTerminal",
                "GhosttyKit",
            ]
        ),
    ]
)
