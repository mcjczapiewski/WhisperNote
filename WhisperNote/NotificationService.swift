import Foundation
import UserNotifications

enum ProcessingNotificationResult: Equatable, Sendable {
    case delivered
    case unavailable
    case denied
    case failed
}

protocol ProcessingNotifying: Sendable {
    func notifyCompletion(for job: ProcessingJob) async -> ProcessingNotificationResult
}

struct NotificationService: ProcessingNotifying {
    func notifyCompletion(for job: ProcessingJob) async -> ProcessingNotificationResult {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        var status = settings.authorizationStatus
        if status == .notDetermined {
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else { return .denied }
                status = .authorized
            } catch {
                return .unavailable
            }
        }
        guard status == .authorized || status == .provisional else { return .denied }

        let content = UNMutableNotificationContent()
        content.title = "WhisperNote finished processing"
        content.body = job.snapshot.shouldSummarize
            ? "Transcript and summary are ready for \(job.recordingName)."
            : "Transcript is ready for \(job.recordingName)."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "whispernote.processing.\(job.id.uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            return .delivered
        } catch {
            return .failed
        }
    }
}
