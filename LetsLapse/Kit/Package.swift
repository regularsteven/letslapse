// swift-tools-version:5.9
// LetsLapse — GPU frame blending engine (LetsLapseKit) + macOS CLI (lapse).
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
        // libjxl (BSD-3, with highway/brotli/skcms) and LibRaw (CDDL-1.0) as
        // static XCFrameworks for iOS, the simulator and macOS, built from
        // their release sources by tools/dng-spike/scripts/build-xcframeworks.sh.
        // They are the encoder and the third-party-raw decoder of the DNG
        // archive path (Archive/); Apple ships no JPEG XL encoder anywhere.
        // One xcframework, one module map, two modules (`CJXL`, `CLibRaw`):
        // Xcode flattens every static xcframework's headers into a single
        // include folder, so two frameworks cannot both carry a module map.
        .binaryTarget(name: "CLetsLapseCodecs", path: "Binaries/CLetsLapseCodecs.xcframework"),
        .target(
            name: "LetsLapseKit",
            dependencies: ["CLetsLapseCodecs"],
            resources: [
                // Copied verbatim and compiled at runtime so the same kernel
                // source works under both `swift build` and Xcode app builds.
                .copy("Metal/BlendKernels.metal")
            ],
            linkerSettings: [
                // LibRaw is C++.
                .linkedLibrary("c++"),
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
