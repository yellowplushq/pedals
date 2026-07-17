// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PedalsDaemon",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PedalsDaemonCore", targets: ["PedalsDaemonCore"]),
        .executable(name: "pedals", targets: ["pedals"]),
    ],
    dependencies: [
        .package(path: "../../shared/PedalsKit"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "PedalsDaemonCore",
            dependencies: [
                .product(name: "PedalsKit", package: "PedalsKit")
            ]
        ),
        .executableTarget(
            name: "pedals",
            dependencies: [
                "PedalsDaemonCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "PedalsDaemonCoreTests",
            dependencies: ["PedalsDaemonCore"]
        ),
    ]
)
