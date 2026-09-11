// swift-tools-version:5.9
// shapeseq — the Shape Sequence spike (docs/shape-sequence-spike/).
//
// Offline research tool run against the macOS LetsLapse catalogue: finds
// dominant ellipses/quads in each shoot's representative image, groups the
// co-shaped ones, and renders second-per-item proof clips with the shape
// held at frame centre. Apple frameworks only; read-only on the catalogue.
//   swift build -c release
import PackageDescription

let package = Package(
    name: "shapeseq",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "shapeseq", targets: ["shapeseq"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "shapeseq",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
    ]
)
