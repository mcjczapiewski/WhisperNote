import Foundation
import XCTest

final class ReleaseInvariantTests: XCTestCase {
    private let expectedVersion = "1.4.2"

    func testReleaseVersionIsAlignedAcrossProjectSettingsAndChangelog() throws {
        try skipSourceAssertionsWhenHosted()
        let project = try sourceContents(at: "WhisperNote.xcodeproj/project.pbxproj")
        let settings = try sourceContents(at: "WhisperNote/SettingsView.swift")
        let changelog = try sourceContents(at: "CHANGELOG.md")

        let marketingVersions = project
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.contains("MARKETING_VERSION =") else { return nil }
                return line
                    .split(separator: "=", maxSplits: 1)[1]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            }

        XCTAssertEqual(marketingVersions.count, 2, "Expected Debug and Release MARKETING_VERSION values")
        XCTAssertEqual(Set(marketingVersions), [expectedVersion])
        XCTAssertEqual(try settingsFallbackVersion(in: settings), expectedVersion)
        XCTAssertEqual(try firstChangelogHeading(in: changelog), "## \(expectedVersion) — July 14, 2026")
    }

    func testHostedXcodeTestsUseIsolatedUserHome() throws {
        try skipSourceAssertionsWhenHosted()
        let scheme = try sourceContents(
            at: "WhisperNote.xcodeproj/xcshareddata/xcschemes/WhisperNote.xcscheme"
        )

        XCTAssertTrue(scheme.contains("key = \"CFFIXED_USER_HOME\""))
        XCTAssertTrue(scheme.contains("value = \"$(TEMP_DIR)/WhisperNoteTestsHome\""))
        XCTAssertTrue(scheme.contains("key = \"WHISPERNOTE_TEST_MODE\""))
        XCTAssertTrue(scheme.contains("value = \"unit\""))
        XCTAssertTrue(scheme.contains("argument = \"-WHISPERNOTE_TEST_MODE unit\""))
    }

    func testHostedXcodeTestsSkipLaunchPermissionWarmup() throws {
        try skipSourceAssertionsWhenHosted()
        let contentView = try sourceContents(at: "WhisperNote/ContentView.swift")
        let audioRecorder = try sourceContents(at: "WhisperNote/AudioRecorder.swift")
        let app = try sourceContents(at: "WhisperNote/WhisperNoteApp.swift")

        XCTAssertTrue(contentView.contains(
            "guard !WhisperNoteRuntime.isUnitTestMode else { return }"
        ))
        XCTAssertTrue(audioRecorder.contains(
            "guard !WhisperNoteRuntime.isUnitTestMode else { return }"
        ))
        XCTAssertTrue(app.contains(
            "if WhisperNoteRuntime.isUnitTestMode"
        ))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceContents(at relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func skipSourceAssertionsWhenHosted() throws {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            throw XCTSkip("The sandboxed app test host cannot access repository source files; SwiftPM covers these invariants.")
        }
    }

    private func settingsFallbackVersion(in source: String) throws -> String {
        guard let line = source.split(separator: "\n").first(where: {
            $0.contains("CFBundleShortVersionString") && $0.contains("??")
        }),
        let fallback = line.split(separator: "\"").last else {
            throw InvariantError.missingSettingsFallback
        }
        return String(fallback)
    }

    private func firstChangelogHeading(in source: String) throws -> String {
        guard let heading = source.split(separator: "\n").first(where: { $0.hasPrefix("## ") }) else {
            throw InvariantError.missingChangelogHeading
        }
        return String(heading)
    }
}

private enum InvariantError: Error {
    case missingSettingsFallback
    case missingChangelogHeading
}
