import Carbon
import Foundation
import XCTest
@testable import WhisperNote

@MainActor
final class RecordingCommandCoordinatorTests: XCTestCase {
    func testQuickToggleStartsWithSuggestedNameAndSystemMicrophone() async {
        let recorder = CommandRecorderFake()
        let workflow = CommandWorkflowFake()
        let coordinator = RecordingCommandCoordinator(
            recorder: recorder, workflow: workflow, quickName: { "Quick Recording — 2026-07-14 12-30-45" }
        )

        await coordinator.quickToggle()

        XCTAssertEqual(recorder.startNames, ["Quick Recording — 2026-07-14 12-30-45"])
        XCTAssertEqual(recorder.microphoneIDs, [""])
        XCTAssertTrue(workflow.saved.isEmpty)
    }

    func testDefaultQuickNameUsesLockedTimestampFormat() {
        let name = RecordingCommandCoordinator.defaultQuickName()
        XCTAssertNotNil(name.range(
            of: #"^Quick Recording — \d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}$"#,
            options: .regularExpression
        ))
    }

    func testOnlySavedStopHandsOffExactlyOnce() async {
        let recording = fixtureRecording()
        let recorder = CommandRecorderFake(current: recording)
        recorder.stopOutcomes = [.saved(recording), .alreadyStopped]
        let workflow = CommandWorkflowFake()
        let coordinator = RecordingCommandCoordinator(recorder: recorder, workflow: workflow)

        _ = await coordinator.stop()
        _ = await coordinator.stop()

        XCTAssertEqual(workflow.saved.map(\.id), [recording.id])
    }

    func testPausedQuickToggleStopsOnceAndHandsOffSavedResult() async {
        let recording = fixtureRecording()
        let recorder = CommandRecorderFake(current: recording)
        recorder.isPaused = true
        recorder.stopOutcomes = [.saved(recording)]
        let workflow = CommandWorkflowFake()
        let coordinator = RecordingCommandCoordinator(recorder: recorder, workflow: workflow)

        await coordinator.quickToggle()

        XCTAssertEqual(recorder.stopCalls, 1)
        XCTAssertEqual(workflow.saved.map(\.id), [recording.id])
    }

    func testConcurrentStopsCallRecorderAndWorkflowExactlyOnce() async {
        let recording = fixtureRecording()
        let recorder = CommandRecorderFake(current: recording)
        recorder.stopDelayNanoseconds = 80_000_000
        recorder.stopOutcomes = [.saved(recording)]
        let workflow = CommandWorkflowFake()
        let coordinator = RecordingCommandCoordinator(recorder: recorder, workflow: workflow)

        async let first: RecordingStopOutcome = coordinator.stop()
        try? await Task.sleep(nanoseconds: 10_000_000)
        async let second: RecordingStopOutcome = coordinator.stop()
        _ = await (first, second)

        XCTAssertEqual(recorder.stopCalls, 1)
        XCTAssertEqual(workflow.saved.map(\.id), [recording.id])
    }

    func testHealthSignalOnlyFollowsOneDurablySavedStop() async {
        let recording = fixtureRecording()
        let recorder = CommandRecorderFake(current: recording)
        recorder.stopOutcomes = [.saved(recording), .alreadyStopped]
        let signals = CommandHealthSignalSpy()
        let coordinator = RecordingCommandCoordinator(
            recorder: recorder, workflow: CommandWorkflowFake(), healthSignals: signals
        )

        _ = await coordinator.stop()
        _ = await coordinator.stop()

        XCTAssertEqual(signals.calls.count, 1)
        XCTAssertEqual(signals.calls.first?.0, .recordingFinalize)
        XCTAssertEqual(signals.calls.first?.1, .success)
        XCTAssertNil(signals.calls.first?.2)
    }

    func testHealthSignalIsNotEmittedForNonSavedOrConcurrentStop() async {
        let recorder = CommandRecorderFake(current: fixtureRecording())
        recorder.stopDelayNanoseconds = 80_000_000
        recorder.stopOutcomes = [.alreadyStopped]
        let signals = CommandHealthSignalSpy()
        let coordinator = RecordingCommandCoordinator(
            recorder: recorder, workflow: CommandWorkflowFake(), healthSignals: signals
        )

        async let first: RecordingStopOutcome = coordinator.stop()
        try? await Task.sleep(nanoseconds: 10_000_000)
        async let second: RecordingStopOutcome = coordinator.stop()
        _ = await (first, second)

        XCTAssertTrue(signals.calls.isEmpty)
    }

    func testConcurrentStartIsSerialized() async {
        let recorder = CommandRecorderFake()
        recorder.startDelayNanoseconds = 80_000_000
        let coordinator = RecordingCommandCoordinator(recorder: recorder, workflow: CommandWorkflowFake())

        async let first = coordinator.start(name: "First")
        try? await Task.sleep(nanoseconds: 10_000_000)
        async let second = coordinator.start(name: "Second")
        _ = try? await (first, second)

        XCTAssertEqual(recorder.startNames, ["First"])
    }

    func testPauseAndResumeIgnoreInapplicableOrBusyCommands() async {
        let recorder = CommandRecorderFake(current: fixtureRecording())
        recorder.isRecording = true
        let coordinator = RecordingCommandCoordinator(recorder: recorder, workflow: CommandWorkflowFake())
        await coordinator.pause()
        recorder.isRecording = false
        recorder.isPaused = true
        await coordinator.resume()
        XCTAssertEqual(recorder.pauseCalls, 1)
        XCTAssertEqual(recorder.resumeCalls, 1)
    }
}

@MainActor
final class GlobalShortcutManagerTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "GlobalShortcutManagerTests-\(UUID().uuidString)")!
    }

    func testDefaultIsSuggestedButDisabledAndUnregistered() {
        let registrar = HotKeyRegistrarFake()
        let manager = GlobalShortcutManager(defaults: defaults, registrar: registrar)
        manager.activatePersistedSetting()
        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(manager.shortcut, .suggested)
        XCTAssertTrue(registrar.registered.isEmpty)
    }

    func testSerializationRoundTrip() {
        let chosen = GlobalShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | controlKey))
        let first = GlobalShortcutManager(defaults: defaults, registrar: HotKeyRegistrarFake())
        first.updateShortcut(chosen)
        let second = GlobalShortcutManager(defaults: defaults, registrar: HotKeyRegistrarFake())
        XCTAssertEqual(second.shortcut, chosen)
    }

    func testValidationRejectsEverySingleModifierAndCommonEditingShortcut() {
        let keys = [
            kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
            kVK_ANSI_S, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z
        ].map(UInt32.init)
        let singleModifiers = [cmdKey, optionKey, controlKey, shiftKey].map(UInt32.init)
        for key in keys {
            XCTAssertThrowsError(try GlobalShortcut(keyCode: key, modifiers: 0).validate())
            for modifiers in singleModifiers {
                XCTAssertThrowsError(try GlobalShortcut(keyCode: key, modifiers: modifiers).validate())
            }
        }
    }

    func testValidationAcceptsTwoOrMoreModifiersAndRejectsReservedMultiModifierChords() {
        XCTAssertNoThrow(try GlobalShortcut.suggested.validate())
        XCTAssertNoThrow(try GlobalShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey | controlKey)).validate())
        XCTAssertNoThrow(try GlobalShortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | optionKey | shiftKey)).validate())
        let reserved = [
            GlobalShortcut(keyCode: UInt32(kVK_Escape), modifiers: UInt32(cmdKey | optionKey)),
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey | controlKey)),
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey | shiftKey)),
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey | optionKey)),
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey | optionKey)),
            GlobalShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | optionKey)),
            GlobalShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | controlKey)),
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey)),
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey)),
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey))
        ]
        for shortcut in reserved { XCTAssertThrowsError(try shortcut.validate()) }
    }

    func testInvalidCapturedBindingSurfacesErrorAndPreservesBinding() {
        let manager = GlobalShortcutManager(defaults: defaults, registrar: HotKeyRegistrarFake())
        manager.updateShortcut(GlobalShortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey)))
        XCTAssertEqual(manager.shortcut, .suggested)
        XCTAssertEqual(manager.errorMessage, "Choose a key with at least two modifiers, including Command, Option, or Control.")
    }

    func testRegistrationCollisionDisablesShortcutAndSurfacesError() {
        let registrar = HotKeyRegistrarFake()
        registrar.failNext = .registrationFailed(OSStatus(eventHotKeyExistsErr))
        let manager = GlobalShortcutManager(defaults: defaults, registrar: registrar)
        manager.setEnabled(true)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(manager.errorMessage, "That shortcut is already used by another app.")
        XCTAssertFalse(defaults.bool(forKey: GlobalShortcutManager.enabledKey))
    }

    func testRebindFailureRestoresPriorRegistrationAndBinding() {
        let registrar = HotKeyRegistrarFake()
        let manager = GlobalShortcutManager(defaults: defaults, registrar: registrar)
        manager.setEnabled(true)
        registrar.failNext = .registrationFailed(OSStatus(eventHotKeyExistsErr))
        let proposed = GlobalShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | optionKey))
        manager.updateShortcut(proposed)
        XCTAssertEqual(manager.shortcut, .suggested)
        XCTAssertEqual(registrar.registered.last, .suggested)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertNotNil(manager.errorMessage)
    }

    func testDisablingUnregistersAndRepeatedEnableIsSafe() {
        let registrar = HotKeyRegistrarFake()
        let manager = GlobalShortcutManager(defaults: defaults, registrar: registrar)
        manager.setEnabled(true)
        manager.setEnabled(true)
        manager.setEnabled(false)
        manager.setEnabled(false)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(registrar.registered.count, 1)
        XCTAssertEqual(registrar.unregisterCalls, 1)
    }

    func testRebindDisablesPreferenceIfPriorRegistrationCannotBeRestored() {
        let registrar = HotKeyRegistrarFake()
        let manager = GlobalShortcutManager(defaults: defaults, registrar: registrar)
        manager.setEnabled(true)
        registrar.failures = [
            .registrationFailed(OSStatus(eventHotKeyExistsErr)),
            .registrationFailed(OSStatus(eventInternalErr))
        ]
        manager.updateShortcut(GlobalShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | optionKey)))
        XCTAssertFalse(manager.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: GlobalShortcutManager.enabledKey))
        XCTAssertEqual(manager.shortcut, .suggested)
    }

    func testRegistrarCallbackInvokesMainActorAction() async {
        let registrar = HotKeyRegistrarFake()
        let manager = GlobalShortcutManager(defaults: defaults, registrar: registrar)
        var calls = 0
        manager.setAction { calls += 1 }
        manager.setEnabled(true)
        registrar.fire()
        await Task.yield()
        XCTAssertEqual(calls, 1)
    }
}

@MainActor
private final class CommandRecorderFake: RecordingCommandHandling {
    var currentRecording: Recording?
    var isRecording = false
    var isPaused = false
    var startNames: [String] = []
    var microphoneIDs: [String] = []
    var pauseCalls = 0
    var resumeCalls = 0
    var stopOutcomes: [RecordingStopOutcome] = []
    var startDelayNanoseconds: UInt64 = 0
    var stopDelayNanoseconds: UInt64 = 0
    var stopCalls = 0

    init(current: Recording? = nil) { currentRecording = current }

    func startRecording(name: String, microphoneId: String) async throws -> RecordingStartOutcome {
        startNames.append(name)
        microphoneIDs.append(microphoneId)
        if startDelayNanoseconds > 0 { try? await Task.sleep(nanoseconds: startDelayNanoseconds) }
        let recording = fixtureRecording(name: name)
        currentRecording = recording
        isRecording = true
        return .started(recording)
    }

    func pauseRecording() async { pauseCalls += 1 }
    func resumeRecording() async throws { resumeCalls += 1 }
    func stopRecording() async -> RecordingStopOutcome {
        stopCalls += 1
        if stopDelayNanoseconds > 0 { try? await Task.sleep(nanoseconds: stopDelayNanoseconds) }
        currentRecording = nil
        isRecording = false
        return stopOutcomes.isEmpty ? .alreadyStopped : stopOutcomes.removeFirst()
    }
}

@MainActor
private final class CommandWorkflowFake: SavedRecordingWorkflowHandling {
    var saved: [Recording] = []
    func recordingDidSave(_ recording: Recording) async { saved.append(recording) }
}

@MainActor
private final class CommandHealthSignalSpy: HealthSignalRecording {
    private(set) var calls: [(TelemetryStage, TelemetryOutcome, TelemetryFailureBucket?)] = []

    func recordHealthSignal(
        stage: TelemetryStage,
        outcome: TelemetryOutcome,
        startedAt: Date,
        failure: TelemetryFailureBucket?
    ) async {
        calls.append((stage, outcome, failure))
    }
}

@MainActor
private final class HotKeyRegistrarFake: GlobalHotKeyRegistering {
    var registered: [GlobalShortcut] = []
    var unregisterCalls = 0
    var failures: [GlobalShortcutError] = []
    var failNext: GlobalShortcutError? {
        get { failures.first }
        set { failures = newValue.map { [$0] } ?? [] }
    }
    private var action: (@Sendable () -> Void)?

    func register(_ shortcut: GlobalShortcut, action: @escaping @Sendable () -> Void) throws {
        if !failures.isEmpty { throw failures.removeFirst() }
        registered.append(shortcut)
        self.action = action
    }

    func unregister() { unregisterCalls += 1; action = nil }
    func fire() { action?() }
}

@MainActor
private func fixtureRecording(name: String = "Recording") -> Recording {
    Recording(name: name, date: Date(), duration: 1, filePath: URL(fileURLWithPath: "/tmp/recording.m4a"))
}
