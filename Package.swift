// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhisperNote",
    platforms: [
        .macOS("14.2")
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1")
    ],
    targets: [
        .executableTarget(
            name: "WhisperNote",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ],
            path: "WhisperNote",
            exclude: [
                "AppIcon.icns",
                "Assets.xcassets",
                "Info.plist",
                "WhisperNote.entitlements"
            ]
        ),
        .testTarget(
            name: "WhisperNoteTests",
            dependencies: ["WhisperNote"],
            path: "WhisperNoteTests"
        )
    ]
)
