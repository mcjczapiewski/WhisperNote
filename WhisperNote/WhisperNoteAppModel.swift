import Foundation

@MainActor
final class WhisperNoteAppModel: ObservableObject {
    let audioRecorder: AudioRecorder
    let transcriptionManager: TranscriptionManager
    let summaryManager: SummaryManager
    let summaryTemplateController: SummaryTemplateController
    let workflowCoordinator: PostRecordingWorkflowCoordinator
    let navigationRouter: AppNavigationRouter
    let commandCoordinator: RecordingCommandCoordinator
    let shortcutManager: GlobalShortcutManager
    let librarySearch: LibrarySearchController

    private var didBootstrap = false

    init(
        audioRecorder: AudioRecorder? = nil,
        transcriptionManager: TranscriptionManager? = nil,
        summaryManager: SummaryManager? = nil,
        summaryTemplateController: SummaryTemplateController? = nil,
        workflowCoordinator: PostRecordingWorkflowCoordinator? = nil,
        navigationRouter: AppNavigationRouter? = nil,
        shortcutManager: GlobalShortcutManager? = nil
    ) {
        let audioRecorder = audioRecorder ?? AudioRecorder()
        let transcriptionManager = transcriptionManager ?? TranscriptionManager()
        let summaryManager = summaryManager ?? SummaryManager()
        let summaryTemplateController = summaryTemplateController ?? SummaryTemplateController()
        let workflowCoordinator = workflowCoordinator ?? PostRecordingWorkflowCoordinator()
        let navigationRouter = navigationRouter ?? AppNavigationRouter()
        let shortcutManager = shortcutManager ?? GlobalShortcutManager()
        self.audioRecorder = audioRecorder
        self.transcriptionManager = transcriptionManager
        self.summaryManager = summaryManager
        self.summaryTemplateController = summaryTemplateController
        self.workflowCoordinator = workflowCoordinator
        self.navigationRouter = navigationRouter
        self.commandCoordinator = RecordingCommandCoordinator(
            recorder: audioRecorder,
            workflow: workflowCoordinator
        )
        self.shortcutManager = shortcutManager
        self.librarySearch = LibrarySearchController(
            audioRecorder: audioRecorder,
            transcriptionManager: transcriptionManager,
            summaryManager: summaryManager,
            workflowCoordinator: workflowCoordinator,
            summaryTemplateController: summaryTemplateController
        )
        shortcutManager.setAction { [weak commandCoordinator] in
            Task { await commandCoordinator?.quickToggle() }
        }
    }

    func bootstrap() async {
        guard !didBootstrap, !WhisperNoteRuntime.isUnitTestMode else { return }
        didBootstrap = true
        await summaryTemplateController.load()
        workflowCoordinator.attachTemplateProvider(summaryTemplateController)
        await workflowCoordinator.attach(
            transcriptionManager: transcriptionManager,
            summaryManager: summaryManager,
            recordings: { [weak audioRecorder] in audioRecorder?.recordings ?? [] }
        )
        shortcutManager.activatePersistedSetting()
        try? await Task.sleep(nanoseconds: 300_000_000)
        _ = await audioRecorder.checkAndRequestPermissions()
    }
}
