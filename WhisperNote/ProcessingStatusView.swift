import SwiftUI

struct ProcessingStatusView: View {
    @EnvironmentObject private var coordinator: PostRecordingWorkflowCoordinator
    @EnvironmentObject private var router: AppNavigationRouter
    var recordingID: UUID?
    var compact = false

    private var visibleJobs: [ProcessingJob] {
        if let recordingID { return coordinator.jobs.filter { $0.recordingID == recordingID } }
        return coordinator.jobs.filter { !$0.state.isTerminal || $0.state == .completed }.prefix(3).map { $0 }
    }

    var body: some View {
        if recordingID == nil, let storeError = coordinator.storeError {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                Text(storeError).font(.caption)
                Spacer()
                Button("Open Settings") { router.openSettings() }.controlSize(.small)
            }
            .padding(10)
            .background(Color.red.opacity(0.08))
            .cornerRadius(8)
        } else if !visibleJobs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !compact {
                    Text("Processing")
                        .font(.headline)
                }
                ForEach(visibleJobs) { job in
                    HStack(spacing: 8) {
                        if job.state == .transcribing || job.state == .summarizing || job.state == .queued {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: icon(for: job.state))
                                .foregroundColor(color(for: job.state))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            if !compact { Text(job.recordingName).font(.subheadline).fontWeight(.medium) }
                            Text(label(for: job.state)).font(.caption).foregroundColor(.secondary)
                            if !compact, let failure = job.failureMessage {
                                Text(failure).font(.caption2).foregroundColor(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        actions(for: job)
                    }
                }
            }
            .padding(compact ? 4 : 10)
            .background(Color.black.opacity(compact ? 0 : 0.06))
            .cornerRadius(8)
        }
    }

    @ViewBuilder
    private func actions(for job: ProcessingJob) -> some View {
        if job.state == .waitingForTranscriptionKey || job.state == .waitingForSummaryKey {
            Button("Settings") { router.openSettings() }.controlSize(.small)
        }
        if job.state.canRetry {
            Button("Retry") { coordinator.retry(job.id) }.controlSize(.small)
        }
        if job.state == .completed {
            Button("Open") {
                if job.snapshot.shouldSummarize { router.openSummary(job.summaryID) }
                else { router.openTranscript(job.transcriptID) }
            }.controlSize(.small)
        } else if !job.state.isTerminal {
            Button("Cancel") { Task { await coordinator.cancel(job.id) } }.controlSize(.small)
        }
    }

    private func label(for state: ProcessingJobState) -> String {
        switch state {
        case .queued: return "Queued"
        case .waitingForRecording: return "Waiting for recording"
        case .waitingForTranscriptionKey: return "Transcription key required"
        case .transcribing: return "Transcribing…"
        case .transcriptionFailed: return "Transcription failed"
        case .waitingForSummaryKey: return "Summary key required"
        case .summarizing: return "Summarizing…"
        case .summaryFailed: return "Summary failed"
        case .completed: return "Results ready"
        case .cancelled: return "Cancelled"
        }
    }

    private func icon(for state: ProcessingJobState) -> String {
        switch state {
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        case .waitingForRecording, .waitingForTranscriptionKey, .waitingForSummaryKey: return "exclamationmark.circle"
        case .transcriptionFailed, .summaryFailed: return "exclamationmark.triangle.fill"
        default: return "clock"
        }
    }

    private func color(for state: ProcessingJobState) -> Color {
        switch state {
        case .completed: return .green
        case .transcriptionFailed, .summaryFailed: return .red
        case .waitingForRecording, .waitingForTranscriptionKey, .waitingForSummaryKey: return .orange
        default: return .secondary
        }
    }
}
