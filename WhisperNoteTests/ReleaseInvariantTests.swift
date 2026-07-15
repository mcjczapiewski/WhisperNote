import Foundation
import XCTest

final class ReleaseInvariantTests: XCTestCase {
    private let expectedVersion = "1.4.7"

    func testUnifiedSearchIsAProjectWiredFifthTab() throws {
        try skipSourceAssertionsWhenHosted()
        let content = try sourceContents(at: "WhisperNote/ContentView.swift")
        let project = try sourceContents(at: "WhisperNote.xcodeproj/project.pbxproj")

        XCTAssertTrue(content.contains("UnifiedSearchView()"))
        XCTAssertTrue(content.contains("Label(\"Search\", systemImage: \"magnifyingglass\")"))

        let productionSources = [
            "LibraryMetadata.swift",
            "LibraryMetadataRepository.swift",
            "UnifiedSearchIndex.swift",
            "LibraryMetadataControls.swift",
            "LibrarySearchController.swift",
            "UnifiedSearchView.swift",
        ]
        let testSources = [
            "LibraryMetadataTests.swift",
            "UnifiedSearchTests.swift",
            "UnifiedSearchIntegrationTests.swift",
        ]
        for source in productionSources + testSources {
            XCTAssertTrue(project.contains("/* \(source) in Sources */"), "Missing Xcode source membership for \(source)")
        }
    }

    func testRecordingViewRoutesLifecycleThroughCommandCoordinator() throws {
        try skipSourceAssertionsWhenHosted()
        let recordingView = try sourceContents(at: "WhisperNote/RecordingView.swift")
        XCTAssertFalse(recordingView.contains("audioRecorder.startRecording("))
        XCTAssertFalse(recordingView.contains("audioRecorder.pauseRecording("))
        XCTAssertFalse(recordingView.contains("audioRecorder.resumeRecording("))
        XCTAssertFalse(recordingView.contains("audioRecorder.stopRecording("))
        XCTAssertFalse(recordingView.contains("workflowCoordinator.recordingDidSave("))
    }

    func testSummaryTemplatesAreWiredIntoXcodeTargets() throws {
        try skipSourceAssertionsWhenHosted()
        let project = try sourceContents(at: "WhisperNote.xcodeproj/project.pbxproj")
        let productionSources = [
            "SummaryTemplate.swift",
            "SummaryTemplateRepository.swift",
            "SummaryTemplateController.swift",
            "SummaryTemplateLibraryView.swift",
            "SummaryTemplateDraftState.swift",
        ]
        let testSources = [
            "SummaryTemplateRepositoryTests.swift",
            "SummaryTemplateIntegrationTests.swift",
            "SummaryTemplateStage3Tests.swift",
            "SummaryTemplateDraftStateTests.swift",
        ]
        for source in productionSources + testSources {
            XCTAssertTrue(project.contains("/* \(source) in Sources */"), "Missing Xcode source membership for \(source)")
        }
    }

    func testTelemetryAndFeedbackAreWiredIntoXcodeTargets() throws {
        try skipSourceAssertionsWhenHosted()
        let project = try sourceContents(at: "WhisperNote.xcodeproj/project.pbxproj")
        let productionSources = [
            "TelemetryEvent.swift",
            "TelemetryConsentStore.swift",
            "TelemetryQueue.swift",
            "TelemetryClient.swift",
            "TelemetryController.swift",
            "TelemetryCredentialStore.swift",
            "ProductFeedbackView.swift",
            "HealthSignalRecording.swift",
        ]
        let testSources = [
            "TelemetryEventTests.swift",
            "TelemetryQueueTests.swift",
            "TelemetryClientTests.swift",
            "TelemetryControllerTests.swift",
            "HealthSignalInstrumentationTests.swift",
        ]
        for source in productionSources + testSources {
            XCTAssertTrue(project.contains("/* \(source) in Sources */"), "Missing Xcode source membership for \(source)")
        }
    }

    func testMenuBarAndShortcutUseAppRootServices() throws {
        try skipSourceAssertionsWhenHosted()
        let app = try sourceContents(at: "WhisperNote/WhisperNoteApp.swift")
        let model = try sourceContents(at: "WhisperNote/WhisperNoteAppModel.swift")
        let shortcut = try sourceContents(at: "WhisperNote/GlobalShortcutManager.swift")
        XCTAssertTrue(app.contains("Window(\"WhisperNote\", id: \"main\")"))
        XCTAssertTrue(app.contains("MenuBarExtra"))
        XCTAssertTrue(model.contains("let commandCoordinator: RecordingCommandCoordinator"))
        XCTAssertTrue(shortcut.contains("RegisterEventHotKey"))
        XCTAssertFalse(shortcut.contains("addGlobalMonitorForEvents"))
    }

    func testShortcutCaptureResignsFocusAfterEveryCaptureAttempt() throws {
        try skipSourceAssertionsWhenHosted()
        let menu = try sourceContents(at: "WhisperNote/MenuBarRecordingView.swift")
        guard let capture = menu.range(of: "onCapture?(GlobalShortcut")?.lowerBound,
              let resign = menu.range(of: "window?.makeFirstResponder(nil)")?.lowerBound else {
            return XCTFail("Shortcut capture must deliver its result and then resign first responder")
        }
        XCTAssertLessThan(capture, resign)
    }

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
        XCTAssertEqual(try firstChangelogHeading(in: changelog), "## \(expectedVersion) — July 15, 2026")
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
        let appModel = try sourceContents(at: "WhisperNote/WhisperNoteAppModel.swift")
        let audioRecorder = try sourceContents(at: "WhisperNote/AudioRecorder.swift")
        let app = try sourceContents(at: "WhisperNote/WhisperNoteApp.swift")

        XCTAssertTrue(appModel.contains(
            "guard !didBootstrap, !WhisperNoteRuntime.isUnitTestMode else { return }"
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
