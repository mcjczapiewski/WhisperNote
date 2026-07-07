// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhisperNote",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
        .package(url: "https://github.com/nonstrict-hq/RecordKit", exact: "0.45.0")
    ],
    targets: [
        .executableTarget(
            name: "WhisperNote",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "RecordKit", package: "RecordKit")
            ],
            path: "WhisperNote",
            exclude: [
                "AppIcon.icns",
                "Assets.xcassets",
                "Info.plist",
                "WhisperNote.entitlements"
            ]
        )
    ]
)
