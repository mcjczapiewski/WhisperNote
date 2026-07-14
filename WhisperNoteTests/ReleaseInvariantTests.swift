import Foundation
import XCTest

final class ReleaseInvariantTests: XCTestCase {
    private let expectedVersion = "1.4.0"

    func testReleaseVersionIsAlignedAcrossProjectSettingsAndChangelog() throws {
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
        let scheme = try sourceContents(
            at: "WhisperNote.xcodeproj/xcshareddata/xcschemes/WhisperNote.xcscheme"
        )

        XCTAssertTrue(scheme.contains("key = \"CFFIXED_USER_HOME\""))
        XCTAssertTrue(scheme.contains("value = \"$(TEMP_DIR)/WhisperNoteTestsHome\""))
    }

    func testHostedXcodeTestsSkipLaunchPermissionWarmup() throws {
        let contentView = try sourceContents(at: "WhisperNote/ContentView.swift")

        XCTAssertTrue(contentView.contains(
            "guard ProcessInfo.processInfo.environment[\"XCTestConfigurationFilePath\"] == nil else { return }"
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
