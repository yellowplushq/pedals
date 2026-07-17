// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PedalsKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "PedalsKit", targets: ["PedalsKit"])
    ],
    targets: [
        .target(name: "PedalsKit"),
        .testTarget(name: "PedalsKitTests", dependencies: ["PedalsKit"]),
    ]
)
