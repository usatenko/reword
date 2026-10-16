// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Reword",
    platforms: [.macOS(.v26)],
    targets: [
        // llama.cpp prebuilt framework (ggml-org/llama.cpp release b11655); fetched by scripts/fetch_llama.sh.
        .binaryTarget(name: "llama", path: "Vendor/build-apple/llama.xcframework"),
        .executableTarget(
            name: "Reword",
            dependencies: ["llama"],
            path: "Sources/Reword",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
