import AppKit
import Carbon
import SwiftUI

struct MenuBarRecordingView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var audioRecorder: AudioRecorder
    @EnvironmentObject private var workflowCoordinator: PostRecordingWorkflowCoordinator
    @EnvironmentObject private var navigationRouter: AppNavigationRouter
    @EnvironmentObject private var commandCoordinator: RecordingCommandCoordinator
    @EnvironmentObject private var shortcutManager: GlobalShortcutManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let recording = audioRecorder.currentRecording {
                Text(recording.name).font(.headline).lineLimit(1)
                Text(duration(audioRecorder.recordingDuration))
                    .font(.system(.title3, design: .monospaced))
                Text(audioRecorder.isRecording ? "Recording" : "Paused")
                    .foregroundColor(audioRecorder.isRecording ? .red : .orange)

                HStack {
                    Button(audioRecorder.isRecording ? "Pause" : "Resume") {
                        Task {
                            if audioRecorder.isRecording { await commandCoordinator.pause() }
                            else { await commandCoordinator.resume() }
                        }
                    }
                    Button("Stop") { Task { await commandCoordinator.stop() } }
                }
                .disabled(commandCoordinator.isBusy)
            } else {
                Text("Ready to Record").font(.headline)
                Button("Quick Record") { Task { await commandCoordinator.quickToggle() } }
                    .disabled(commandCoordinator.isBusy || !audioRecorder.isInitialRecoveryComplete)
            }

            if commandCoordinator.isBusy { ProgressView().controlSize(.small) }
            if let error = commandCoordinator.lastError ?? audioRecorder.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            }
            if !audioRecorder.hasMicrophonePermission() || !audioRecorder.hasSystemAudioPermission() {
                Label("Recording permissions need attention", systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.caption).foregroundColor(.orange)
            }
            if let job = activeJob {
                Label(processingLabel(job.state), systemImage: "gearshape.2")
                    .font(.caption)
            }
            if shortcutManager.isEnabled {
                Text("Shortcut: \(shortcutManager.shortcut.displayName)")
                    .font(.caption).foregroundColor(.secondary)
            }

            Divider()
            Button("Open WhisperNote") { show(tab: 0) }
            Button("Open Settings") { show(tab: 3) }
            if let job = workflowCoordinator.jobs.last(where: { $0.state == .completed }) {
                Button("Open Latest Results") {
                    if job.snapshot.shouldSummarize { navigationRouter.openSummary(job.summaryID) }
                    else { navigationRouter.openTranscript(job.transcriptID) }
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            Divider()
            Button("Quit WhisperNote") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 270)
    }

    private var activeJob: ProcessingJob? {
        workflowCoordinator.jobs.last(where: { !$0.state.isTerminal })
    }

    private func show(tab: Int) {
        navigationRouter.selectedTab = tab
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func duration(_ interval: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(interval) / 60, Int(interval) % 60)
    }

    private func processingLabel(_ state: ProcessingJobState) -> String {
        switch state {
        case .queued: return "Results queued"
        case .transcribing: return "Transcribing…"
        case .summarizing: return "Summarizing…"
        case .waitingForRecording: return "Waiting for recording"
        case .waitingForTranscriptionKey: return "Transcription key required"
        case .waitingForSummaryKey: return "Summary key required"
        case .transcriptionFailed: return "Transcription failed"
        case .summaryFailed: return "Summary failed"
        case .completed: return "Results ready"
        case .cancelled: return "Processing cancelled"
        }
    }
}

struct ShortcutCaptureView: NSViewRepresentable {
    var shortcut: GlobalShortcut
    var onCapture: (GlobalShortcut) -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.onCapture = onCapture
        view.display = shortcut.displayName
        return view
    }

    func updateNSView(_ view: ShortcutCaptureNSView, context: Context) {
        view.onCapture = onCapture
        view.display = shortcut.displayName
        view.needsDisplay = true
    }
}

final class ShortcutCaptureNSView: NSView {
    var onCapture: ((GlobalShortcut) -> Void)?
    var display = ""
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        onCapture?(GlobalShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers))
        window?.makeFirstResponder(nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let text = window?.firstResponder === self ? "Press shortcut…" : display
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).stroke()
    }
}
