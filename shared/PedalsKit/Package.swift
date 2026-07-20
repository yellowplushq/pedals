// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PedalsKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v26),
        .watchOS(.v26),
    ],
    products: [
        .library(name: "PedalsKit", targets: ["PedalsKit"])
    ],
    targets: [
        .target(name: "PedalsKit"),
        .testTarget(name: "PedalsKitTests", dependencies: ["PedalsKit"]),
    ]
)
