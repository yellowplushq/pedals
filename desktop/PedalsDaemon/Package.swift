// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PedalsDaemon",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PedalsDaemonCore", targets: ["PedalsDaemonCore"]),
        // Internal debugging only — not part of external releases.
        .executable(name: "pedals", targets: ["pedals"]),
        // Coding-agent hook reporter, installed to ~/.pedals/bin by
        // `pedals hooks install` / the menu bar app.
        .executable(name: "pedals-hook", targets: ["pedals-hook"]),
    ],
    dependencies: [
        .package(path: "../../shared/PedalsKit"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "CPedalsPTY",
            publicHeadersPath: "include"
        ),
        .target(
            name: "PedalsDaemonCore",
            dependencies: [
                "CPedalsPTY",
                .product(name: "PedalsKit", package: "PedalsKit")
            ]
        ),
        // Foundation-only logic for the hook reporter (stdin mapping,
        // transcript scan, lineage walk, wire encoding). No PedalsKit, no
        // AppKit: the reporter binary must stay lean and dependency-free.
        .target(
            name: "PedalsHookKit"
        ),
        .executableTarget(
            name: "pedals",
            dependencies: [
                "PedalsDaemonCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "pedals-hook",
            dependencies: ["PedalsHookKit"]
        ),
        .testTarget(
            name: "PedalsDaemonCoreTests",
            dependencies: ["PedalsDaemonCore", "PedalsHookKit"]
        ),
        .testTarget(
            name: "PedalsHookKitTests",
            dependencies: ["PedalsHookKit"]
        ),
    ]
)
