// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ReeveKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReeveKit", targets: ["ReeveKit"]),
    ],
    targets: [
        .target(name: "ReeveKit"),
        .testTarget(name: "ReeveKitTests", dependencies: ["ReeveKit"]),
    ]
)
