// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MimizukuCore",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "MimizukuCore", targets: ["MimizukuCore"]),
        // AEC 診断試行のオフライン解析 CLI(#75 / ADR-0015)。開発用で配布物ではない。
        .executable(name: "aec-diag", targets: ["AecDiagCLI"])
    ],
    targets: [
        .target(name: "MimizukuCore"),
        .executableTarget(
            name: "AecDiagCLI",
            dependencies: ["MimizukuCore"]
        ),
        .testTarget(
            name: "MimizukuCoreTests",
            dependencies: ["MimizukuCore"]
        )
    ]
)
