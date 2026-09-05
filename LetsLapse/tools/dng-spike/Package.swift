// swift-tools-version:5.9
// dngspike — the DNG archive-conversion spike (docs/dng-archive-spike-brief.md).
//
// The pipeline lives in the Kit (Kit/Sources/LetsLapseKit/Archive/), with
// libjxl and LibRaw as the Kit's static binary targets; this package is the
// measuring instrument around it:   swift build -c release
import PackageDescription

let package = Package(
    name: "dng-spike",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "dngspike", targets: ["dngspike"]),
    ],
    dependencies: [
        .package(name: "LetsLapseKit", path: "../../Kit"),
    ],
    targets: [
        .executableTarget(
            name: "dngspike",
            dependencies: [.product(name: "LetsLapseKit", package: "LetsLapseKit")]
        ),
        .testTarget(
            name: "dngspikeTests",
            dependencies: ["dngspike"]
        ),
    ]
)
