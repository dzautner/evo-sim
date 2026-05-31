// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "evo-sim",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EvoSimCore", targets: ["EvoSimCore"]),
        .library(name: "EvoSimRender", targets: ["EvoSimRender"]),
        .executable(name: "EvoSimMac", targets: ["EvoSimMac"]),
        .executable(name: "EvoSimSnapshot", targets: ["EvoSimSnapshot"]),
    ],
    targets: [
        .target(
            name: "EvoSimCore",
            path: "Sources/EvoSimCore"
        ),
        .target(
            name: "EvoSimRender",
            dependencies: ["EvoSimCore"],
            path: "Sources/EvoSimRender"
        ),
        .executableTarget(
            name: "EvoSimMac",
            dependencies: ["EvoSimCore", "EvoSimRender"],
            path: "Apps/EvoSimMac"
        ),
        .executableTarget(
            name: "EvoSimSnapshot",
            dependencies: ["EvoSimCore", "EvoSimRender"],
            path: "Apps/EvoSimSnapshot"
        ),
        .testTarget(
            name: "EvoSimCoreTests",
            dependencies: ["EvoSimCore"],
            path: "Tests/EvoSimCoreTests"
        ),
    ]
)
