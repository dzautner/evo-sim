// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "evo-sim",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EvoSimCore", targets: ["EvoSimCore"]),
        .executable(name: "EvoSimMac", targets: ["EvoSimMac"]),
    ],
    targets: [
        .target(
            name: "EvoSimCore",
            path: "Sources/EvoSimCore"
        ),
        .executableTarget(
            name: "EvoSimMac",
            dependencies: ["EvoSimCore"],
            path: "Apps/EvoSimMac"
        ),
        .testTarget(
            name: "EvoSimCoreTests",
            dependencies: ["EvoSimCore"],
            path: "Tests/EvoSimCoreTests"
        ),
    ]
)
