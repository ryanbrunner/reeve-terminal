// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ReeveKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReeveKit", targets: ["ReeveKit"]),
        .executable(name: "reeve", targets: ["reeve"]),
    ],
    targets: [
        .target(name: "ReeveKit"),
        // The command line. Xcode builds it too, from the same folder, into
        // Reeve.app (see project.yml).
        .executableTarget(name: "reeve", dependencies: ["ReeveKit"]),
        .testTarget(name: "ReeveKitTests", dependencies: ["ReeveKit"]),
    ]
)
