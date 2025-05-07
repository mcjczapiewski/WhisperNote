// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhisperNote",
    platforms: [
        .macOS(.v12)
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
        .package(url: "https://github.com/nonstrict-hq/RecordKit", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "WhisperNote",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "RecordKit", package: "RecordKit")
            ],
            path: "WhisperNote"
        )
    ]
)
