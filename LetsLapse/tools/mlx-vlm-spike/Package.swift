// swift-tools-version: 5.10
// Phase 0 verification spike — NOT part of the app target.
// Pins recorded in LetsLapse/docs/ai/phase0-findings.md. Do not float these.
import PackageDescription

let package = Package(
    name: "mlx-vlm-spike",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 0.31.5+ needs a Swift 6.3 toolchain; Xcode 26.1.1 is Swift 6.2, so 0.31.4 is the ceiling here.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),
        // Vendored 3.31.4 + the PR #384 Gemma4.swift hunks (num_kv_shared_layers loader fix).
        // Release 3.31.4 cannot load current gemma-4 E-series checkpoints, and every upstream
        // revision carrying the fix needs mlx-swift 0.31.5+ (Swift 6.3 toolchain) — unbuildable
        // on Xcode 26.1.1. Recipe in vendor/README.md.
        .package(path: "vendor/mlx-swift-lm"),
        // Hub + tokenizer come from Hugging Face packages in the 3.x "bring your own hub" design.
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "vlm-spike",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/vlm-spike"
        ),
    ]
)
