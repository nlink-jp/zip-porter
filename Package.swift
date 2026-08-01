// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZipPorter",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        // System zlib for deflate (ADR-014); inflate stays on the
        // Compression framework.
        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib"
        ),
        // UI-independent ZIP engine: reader/writer, file-name encoding
        // (NFC / CP932), junk filtering, crypto. No AppKit imports allowed.
        .target(
            name: "ZipPorterCore",
            dependencies: ["CZlib"],
            path: "Sources/ZipPorterCore"
        ),
        .executableTarget(
            name: "ZipPorter",
            dependencies: ["ZipPorterCore"],
            path: "Sources/ZipPorter",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ZipPorterCoreTests",
            dependencies: ["ZipPorterCore"],
            path: "Tests/ZipPorterCoreTests",
            resources: [.copy("testdata")]
        ),
        .testTarget(
            name: "ZipPorterTests",
            dependencies: ["ZipPorter"],
            path: "Tests/ZipPorterTests"
        ),
    ]
)
