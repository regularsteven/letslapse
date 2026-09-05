// swift-tools-version:6.1
// dngspike — the DNG archive-conversion spike (docs/dng-archive-spike-brief.md).
//
// The core (Apple decode, the Kit's lossless JPEG, the DNG 1.7 writer, the
// Metal demosaic, the quality and compatibility checks) builds with no third-
// party code:            swift build -c release
// The two open-source codecs are opt-in package traits so the iOS-ready core
// stays visible:         swift build -c release --traits JXL,LibRaw
// They link the Homebrew builds (`brew install jpeg-xl libraw`); the
// xcframework recipe for device builds is scripts/build-xcframeworks.sh.
import Foundation
import PackageDescription

let brewPrefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"] ?? "/opt/homebrew"

let package = Package(
    name: "dng-spike",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "dngspike", targets: ["dngspike"]),
    ],
    traits: [
        .trait(name: "JXL", description: "JPEG XL encoding through libjxl"),
        .trait(name: "LibRaw", description: "Camera raw decoding through LibRaw"),
    ],
    dependencies: [
        .package(name: "LetsLapseKit", path: "../../Kit"),
    ],
    targets: [
        .systemLibrary(name: "CJXL", path: "Sources/CJXL"),
        .systemLibrary(name: "CLibRaw", path: "Sources/CLibRaw"),
        .executableTarget(
            name: "dngspike",
            dependencies: [
                .product(name: "LetsLapseKit", package: "LetsLapseKit"),
                .target(name: "CJXL", condition: .when(traits: ["JXL"])),
                .target(name: "CLibRaw", condition: .when(traits: ["LibRaw"])),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-I\(brewPrefix)/include", "-I\(brewPrefix)/include/libraw"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(brewPrefix)/lib"]),
                .linkedLibrary("jxl", .when(traits: ["JXL"])),
                .linkedLibrary("jxl_threads", .when(traits: ["JXL"])),
                .linkedLibrary("raw_r", .when(traits: ["LibRaw"])),
                .linkedLibrary("c++", .when(traits: ["LibRaw"])),
            ]
        ),
        .testTarget(
            name: "dngspikeTests",
            dependencies: ["dngspike"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
