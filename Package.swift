// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "evo-sim",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "EvoSimCore", targets: ["EvoSimCore"]),
        .library(name: "EvoSimRender", targets: ["EvoSimRender"]),
        .library(name: "EvoSimAppKit", targets: ["EvoSimAppKit"]),
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
        // Cross-platform (macOS + iOS) SwiftUI views that wrap the
        // simulation + renderer. Used by both the macOS executable here and
        // an Xcode-side iOS app target (or a future SwiftPM-side iOS app
        // once SwiftPM iOS app executables are first-class).
        .target(
            name: "EvoSimAppKit",
            dependencies: ["EvoSimCore", "EvoSimRender"],
            path: "Sources/EvoSimAppKit"
        ),
        .executableTarget(
            name: "EvoSimMac",
            dependencies: ["EvoSimCore", "EvoSimRender", "EvoSimAppKit"],
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
