import Foundation

@MainActor
protocol RecordingCommandHandling: AnyObject {
    var currentRecording: Recording? { get }
    var isRecording: Bool { get }
    var isPaused: Bool { get }
    func startRecording(name: String, microphoneId: String) async throws -> RecordingStartOutcome
    func pauseRecording() async
    func resumeRecording() async throws
    func stopRecording() async -> RecordingStopOutcome
}

extension AudioRecorder: RecordingCommandHandling { }

@MainActor
protocol SavedRecordingWorkflowHandling: AnyObject {
    func recordingDidSave(_ recording: Recording) async
}

extension PostRecordingWorkflowCoordinator: SavedRecordingWorkflowHandling { }

/// The sole lifecycle-command entry point shared by the window, menu bar, and hot key.
/// AudioRecorder keeps its lower-level gate; this coordinator also prevents competing UI
/// commands and guarantees exactly one post-save workflow handoff.
@MainActor
final class RecordingCommandCoordinator: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?

    private let recorder: any RecordingCommandHandling
    private let workflow: any SavedRecordingWorkflowHandling
    private let quickName: () -> String

    init(
        recorder: any RecordingCommandHandling,
        workflow: any SavedRecordingWorkflowHandling,
        quickName: (() -> String)? = nil
    ) {
        self.recorder = recorder
        self.workflow = workflow
        self.quickName = quickName ?? { RecordingCommandCoordinator.defaultQuickName() }
    }

    @discardableResult
    func start(name: String, microphoneId: String = "") async throws -> RecordingStartOutcome {
        guard !isBusy else { return .alreadyActive(recorder.currentRecording) }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            return try await recorder.startRecording(name: name, microphoneId: microphoneId)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func quickToggle() async {
        guard !isBusy else { return }
        if recorder.currentRecording == nil {
            do { _ = try await start(name: quickName()) }
            catch { }
        } else {
            _ = await stop()
        }
    }

    func pause() async {
        guard !isBusy, recorder.currentRecording != nil, recorder.isRecording else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        await recorder.pauseRecording()
    }

    func resume() async {
        guard !isBusy, recorder.currentRecording != nil, recorder.isPaused else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try await recorder.resumeRecording()
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func stop() async -> RecordingStopOutcome {
        guard !isBusy else { return .alreadyStopping }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        let outcome = await recorder.stopRecording()
        if case .saved(let recording) = outcome {
            await workflow.recordingDidSave(recording)
        }
        return outcome
    }

    func clearError() { lastError = nil }

    static func defaultQuickName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return "Quick Recording — \(formatter.string(from: now))"
    }
}
