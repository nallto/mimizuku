// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MimizukuCore",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "MimizukuCore", targets: ["MimizukuCore"])
    ],
    targets: [
        .target(name: "MimizukuCore"),
        .testTarget(
            name: "MimizukuCoreTests",
            dependencies: ["MimizukuCore"]
        )
    ]
)
