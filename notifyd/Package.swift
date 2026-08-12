// swift-tools-version: 6.0
import PackageDescription

// Pin discipline (verified against the remotes on 2026-08-11):
//   holler  -- only tag is v0.10.0; `from: "1.0.0"` does not resolve.
//   dots    -- has NO tags at all, so it must be pinned by revision.
// The two share mlx-swift and swift-transformers, and the satisfying window is
// narrow (swift-transformers is effectively exactly 1.3.3). Package.resolved is
// committed and treated as a lockfile; if the window ever closes, the fallback
// is two executables behind the same socket.
let package = Package(
    name: "notifyd",
    platforms: [.macOS(.v15)], // dots requires 15; holler only needs 14
    products: [
        .executable(name: "notifyd", targets: ["notifyd"])
    ],
    dependencies: [
        .package(url: "https://github.com/sentiuminc/holler.git", .upToNextMinor(from: "0.10.0")),
        .package(
            url: "https://github.com/sammcj/mlx-swift-dots-tts.git",
            revision: "2370317dcfb834682bd2aaed890b1fd6c090a219"
        ),
        // dots needs a Qwen2 BPE tokenizer handed to it explicitly. Identity is
        // still `swift-transformers` even though the repo now redirects to
        // swift-huggingface; both end up in the graph.
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.3"),
    ],
    targets: [
        .executableTarget(
            name: "notifyd",
            dependencies: [
                .product(name: "HollerKit", package: "holler"),
                .product(name: "DotsTTS", package: "mlx-swift-dots-tts"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        )
    ]
)
