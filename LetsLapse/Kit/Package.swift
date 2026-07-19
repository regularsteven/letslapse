// swift-tools-version:5.9
// Let's Lapse — GPU frame blending engine (LetsLapseKit) + macOS CLI (lapse).
import PackageDescription

let package = Package(
    name: "LetsLapseKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "LetsLapseKit", targets: ["LetsLapseKit"]),
        .executable(name: "lapse", targets: ["lapse"]),
    ],
    targets: [
        .target(
            name: "LetsLapseKit",
            resources: [
                // Copied verbatim and compiled at runtime so the same kernel
                // source works under both `swift build` and Xcode app builds.
                .copy("Metal/BlendKernels.metal")
            ]
        ),
        .executableTarget(
            name: "lapse",
            dependencies: ["LetsLapseKit"]
        ),
        .testTarget(
            name: "LetsLapseKitTests",
            dependencies: ["LetsLapseKit"]
        ),
    ]
)
