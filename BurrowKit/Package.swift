// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BurrowKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BurrowKit", targets: ["BurrowKit"]),
        .executable(name: "burrowctl", targets: ["burrowctl"]),
    ],
    targets: [
        .target(name: "BurrowKit"),
        .executableTarget(name: "burrowctl", dependencies: ["BurrowKit"]),
        .testTarget(name: "BurrowKitTests", dependencies: ["BurrowKit"]),
    ]
)
