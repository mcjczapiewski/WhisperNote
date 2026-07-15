import Foundation

enum TelemetryControllerStatus: Equatable {
    case inactive
    case ready
    case sent
    case queued
    case configurationRequired
    case deliveryPaused
    case quarantined
    case capacityReached
    case unavailable

    var message: String {
        switch self {
        case .inactive: return "Telemetry is off. Optional feedback can still be sent."
        case .ready: return "Ready to send queued telemetry."
        case .sent: return "Queued telemetry was sent."
        case .queued: return "Saved locally and will be retried automatically."
        case .configurationRequired: return "Add a valid HTTPS endpoint and header token to send queued telemetry."
        case .deliveryPaused: return "Delivery is paused. Check the local telemetry configuration."
        case .quarantined: return "One incompatible item was set aside; other queued telemetry was sent."
        case .capacityReached: return "The local telemetry queue is full. Try again after queued items are sent."
        case .unavailable: return "Telemetry storage is temporarily unavailable."
        }
    }
}

enum TelemetryFeedbackSubmissionResult: Equatable {
    case sent
    case queued
    case failed
}

protocol TelemetryRetryScheduling: Sendable {
    func sleep(until date: Date) async throws
}

struct SystemTelemetryRetryScheduler: TelemetryRetryScheduling {
    func sleep(until date: Date) async throws {
        let delay = max(0, date.timeIntervalSinceNow)
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

@MainActor
final class TelemetryController: ObservableObject {
    static let endpointPreferenceKey = "telemetryWebhookEndpoint"
    private static let legacyTokenPreferenceKey = "telemetryWebhookToken"
    static let consentVersion = 1

    // Baked-in delivery default so consenting users send without configuring anything.
    // This is the public Cloudflare Worker in front of n8n, never the raw n8n webhook.
    // REPLACE before release with the real Worker route.
    static let defaultEndpoint = "https://telemetry.example.workers.dev/ingest"
    // Low-value bot filter, NOT a secret — it ships in the binary. Real protection is the
    // Worker (rate limiting + holding the n8n URL/secret server-side). REPLACE before release.
    static let defaultAppToken = "whispernote-public-ingest"

    @Published private(set) var consent = TelemetryConsentState.disabled
    @Published private(set) var queuedItemCount = 0
    @Published private(set) var status: TelemetryControllerStatus = .inactive
    @Published private(set) var isConfigured = false
    @Published private(set) var hasStoredCredential = false
    @Published private(set) var feedbackStatusMessage: String?

    private let queue: TelemetryQueue
    private let client: TelemetryClient
    private let defaults: UserDefaults
    private let credentialStore: any TelemetryCredentialStore
    private let now: @Sendable () -> Date
    private let runtimeContext: @Sendable () throws -> TelemetryRuntimeContext
    private let retryScheduler: any TelemetryRetryScheduling
    private var lifecycleGeneration: UInt64 = 0
    private var activeFlushTask: Task<TelemetryClientStatus, Never>?
    private var retryTask: Task<Void, Never>?

    init(
        queue: TelemetryQueue = TelemetryQueue(),
        client: TelemetryClient? = nil,
        defaults: UserDefaults = .standard,
        credentialStore: any TelemetryCredentialStore = KeychainTelemetryCredentialStore(),
        now: @escaping @Sendable () -> Date = { Date() },
        runtimeContext: @escaping @Sendable () throws -> TelemetryRuntimeContext = {
            try TelemetryController.defaultRuntimeContext()
        },
        retryScheduler: any TelemetryRetryScheduling = SystemTelemetryRetryScheduler()
    ) {
        self.queue = queue
        self.client = client ?? TelemetryClient(queue: queue, configuration: nil)
        self.defaults = defaults
        self.credentialStore = credentialStore
        self.now = now
        self.runtimeContext = runtimeContext
        self.retryScheduler = retryScheduler
    }

    func bootstrap() async {
        cancelScheduledRetry()
        await restoreSavedConfiguration()
        await refresh()
        if isConfigured, queuedItemCount > 0 { await flush() }
    }

    func applicationDidBecomeActive() async {
        await restoreSavedConfiguration()
        await enqueueWeeklyActivityIfNeeded()
        if queuedItemCount > 0 { await flush() }
    }

    func recordHealthSignal(
        stage: TelemetryStage,
        outcome: TelemetryOutcome,
        startedAt: Date,
        failure: TelemetryFailureBucket? = nil
    ) async {
        do {
            let snapshot = try await queue.snapshot()
            guard snapshot.consent.enabled, let installID = snapshot.installID else { return }
            let event = try TelemetryHealthEvent(
                eventID: UUID(),
                occurredAt: telemetryTimestamp(for: now()),
                runtime: try runtimeContext(),
                installID: installID,
                eventName: .stageOutcome,
                stage: stage,
                outcome: outcome,
                durationBucket: Self.durationBucket(since: startedAt, now: now()),
                failureBucket: outcome == .failure ? (failure ?? .unknown) : (outcome == .cancelled ? .cancelled : nil)
            )
            _ = try await queue.enqueueHealth(event)
            if outcome == .success, let milestone = Self.milestone(for: stage) {
                let milestoneEvent = try TelemetryHealthEvent(
                    eventID: UUID(), occurredAt: telemetryTimestamp(for: now()),
                    runtime: try runtimeContext(), installID: installID, eventName: milestone
                )
                _ = try await queue.enqueueHealth(milestoneEvent)
            }
            await refresh()
        } catch {
            // Telemetry is optional and must never change a completed user workflow.
        }
    }

    func enableTelemetry() async {
        do {
            _ = try await queue.enableConsent(version: Self.consentVersion)
            await refresh()
            if queuedItemCount > 0 { await flush() }
        } catch {
            status = .unavailable
        }
    }

    func optOutAndPurge() async {
        await invalidateDelivery()
        do {
            try await queue.optOut()
            // Drop any user override; the baked-in default remains so an explicit feedback
            // submission after opt-out still delivers. Health stays gated on consent + installID,
            // both cleared by optOut() above.
            try? credentialStore.deleteToken()
            defaults.removeObject(forKey: Self.endpointPreferenceKey)
            feedbackStatusMessage = nil
            await restoreSavedConfiguration()
            await refresh()
            status = .inactive
        } catch {
            status = .unavailable
        }
    }

    /// The endpoint remains local user configuration. The header token is kept only in
    /// the injected credential store (Keychain in production), never in UserDefaults.
    @discardableResult
    func saveConfiguration(endpoint: String, token: String) async -> Bool {
        await invalidateDelivery()
        let normalizedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let existingToken = try credentialStore.readToken()
            let effectiveToken = token.isEmpty ? existingToken : token
            guard let effectiveToken,
                  let configuration = makeConfiguration(endpoint: normalizedEndpoint, token: effectiveToken) else {
                await client.updateConfiguration(nil)
                isConfigured = false
                status = .configurationRequired
                return false
            }
            if !token.isEmpty { try credentialStore.saveToken(token) }
            defaults.set(configuration.endpoint.absoluteString, forKey: Self.endpointPreferenceKey)
            defaults.removeObject(forKey: Self.legacyTokenPreferenceKey)
            await client.updateConfiguration(configuration)
            hasStoredCredential = true
            isConfigured = true
            await refresh()
            return true
        } catch {
            await client.updateConfiguration(nil)
            isConfigured = false
            hasStoredCredential = false
            status = .unavailable
            return false
        }
    }

    /// Clears any user override and reverts to the baked-in default delivery configuration.
    func clearConfiguration() async {
        await invalidateDelivery()
        defaults.removeObject(forKey: Self.endpointPreferenceKey)
        defaults.removeObject(forKey: Self.legacyTokenPreferenceKey)
        do {
            try credentialStore.deleteToken()
            hasStoredCredential = false
        } catch {
            status = .unavailable
        }
        await restoreSavedConfiguration()
        await refresh()
    }

    func submitFeedback(category: TelemetryFeedbackCategory, message: String) async -> TelemetryFeedbackSubmissionResult {
        guard message.trimmingCharacters(in: .whitespacesAndNewlines).count <= TelemetrySchema.maximumFeedbackCharacters,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            feedbackStatusMessage = "Enter feedback of up to 2,000 characters."
            return .failed
        }

        do {
            let feedback = try TelemetryFeedback(
                eventID: UUID(),
                occurredAt: telemetryTimestamp(for: now()),
                runtime: try runtimeContext(),
                category: category,
                message: message
            )
            _ = try await queue.enqueueFeedback(feedback)
            await refresh()
            guard isConfigured else {
                status = consent.enabled ? .ready : .inactive
                feedbackStatusMessage = "Feedback is saved locally until a delivery endpoint is configured."
                return .queued
            }
            await flush()
            switch status {
            case .sent:
                feedbackStatusMessage = "Thank you. Your feedback was sent."
                return .sent
            case .queued:
                feedbackStatusMessage = "Feedback was saved locally and will be retried automatically."
                return .queued
            case .configurationRequired:
                feedbackStatusMessage = "Feedback is saved locally. Add a valid delivery configuration to send it."
                return .queued
            default:
                feedbackStatusMessage = status.message
                return .failed
            }
        } catch let error as TelemetryQueueError {
            status = status(for: error)
            feedbackStatusMessage = status.message
            return .failed
        } catch {
            status = .unavailable
            feedbackStatusMessage = status.message
            return .failed
        }
    }

    func flush() async {
        guard isConfigured else {
            if queuedItemCount > 0 { status = .configurationRequired }
            return
        }
        guard queuedItemCount > 0 else {
            status = consent.enabled ? .ready : .inactive
            return
        }
        let generation = lifecycleGeneration
        if let activeFlushTask {
            let clientStatus = await activeFlushTask.value
            guard generation == lifecycleGeneration else { return }
            await refresh(using: clientStatus)
            return
        }
        let client = client
        let task = Task { await client.flush() }
        activeFlushTask = task
        let clientStatus = await task.value
        guard generation == lifecycleGeneration else { return }
        activeFlushTask = nil
        await refresh(using: clientStatus)
    }

    private func restoreSavedConfiguration() async {
        do {
            try migrateLegacyCredentialIfNeeded()
            // Stored override wins; otherwise fall back to the baked-in Worker default so
            // delivery is configured out of the box.
            let storedEndpoint = defaults.string(forKey: Self.endpointPreferenceKey) ?? ""
            let endpoint = storedEndpoint.isEmpty ? Self.defaultEndpoint : storedEndpoint
            let storedToken = try credentialStore.readToken()
            hasStoredCredential = storedToken != nil
            let token = storedToken ?? Self.defaultAppToken
            guard let configuration = makeConfiguration(endpoint: endpoint, token: token) else {
                await client.updateConfiguration(nil)
                isConfigured = false
                return
            }
            await client.updateConfiguration(configuration)
            isConfigured = true
        } catch {
            hasStoredCredential = false
            isConfigured = false
            await client.updateConfiguration(nil)
            status = .unavailable
        }
    }

    private func migrateLegacyCredentialIfNeeded() throws {
        guard let token = defaults.string(forKey: Self.legacyTokenPreferenceKey), !token.isEmpty else { return }
        if try credentialStore.readToken() == nil { try credentialStore.saveToken(token) }
        defaults.removeObject(forKey: Self.legacyTokenPreferenceKey)
    }

    private func refresh(using clientStatus: TelemetryClientStatus? = nil) async {
        do {
            let snapshot = try await queue.snapshot()
            consent = snapshot.consent
            queuedItemCount = snapshot.items.count
            let deliveryStatus: TelemetryClientStatus
            if let clientStatus {
                deliveryStatus = clientStatus
            } else {
                deliveryStatus = await client.currentStatus()
            }
            status = presentationStatus(
                for: deliveryStatus,
                consentEnabled: snapshot.consent.enabled,
                queuedItemCount: snapshot.items.count
            )
            updateScheduledRetry(for: deliveryStatus)
        } catch {
            status = .unavailable
        }
    }

    private func updateScheduledRetry(for clientStatus: TelemetryClientStatus) {
        guard case .queued(let timestamp) = clientStatus,
              let timestamp,
              let date = telemetryDate(from: timestamp),
              isConfigured,
              queuedItemCount > 0 else {
            cancelScheduledRetry()
            return
        }
        retryTask?.cancel()
        let generation = lifecycleGeneration
        let scheduler = retryScheduler
        retryTask = Task { [weak self] in
            do {
                try await scheduler.sleep(until: date)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.runScheduledRetry(generation: generation)
        }
    }

    private func runScheduledRetry(generation: UInt64) async {
        guard generation == lifecycleGeneration, isConfigured else { return }
        do {
            let snapshot = try await queue.snapshot()
            guard !snapshot.items.isEmpty,
                  snapshot.consent.enabled || snapshot.items.contains(where: { if case .feedback = $0 { return true }; return false }) else {
                return
            }
            queuedItemCount = snapshot.items.count
            await flush()
        } catch {
            status = .unavailable
        }
    }

    private func cancelScheduledRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    private func invalidateDelivery() async {
        lifecycleGeneration &+= 1
        activeFlushTask?.cancel()
        activeFlushTask = nil
        cancelScheduledRetry()
        await client.invalidateDelivery()
    }

    private func enqueueWeeklyActivityIfNeeded() async {
        do {
            let snapshot = try await queue.snapshot()
            guard snapshot.consent.enabled, let installID = snapshot.installID else { return }
            let weekStart = try Self.weekStart(for: now())
            let event = try TelemetryHealthEvent(
                eventID: UUID(),
                occurredAt: telemetryTimestamp(for: now()),
                runtime: try runtimeContext(),
                installID: installID,
                eventName: .weeklyActive,
                weekStart: weekStart
            )
            _ = try await queue.enqueueHealth(event)
            await refresh()
        } catch {
            // Foreground delivery must never affect normal app startup or recording.
        }
    }

    private func makeConfiguration(endpoint: String, token: String) -> TelemetryTransportConfiguration? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return try? TelemetryTransportConfiguration(endpoint: url, token: token)
    }

    private func presentationStatus(
        for clientStatus: TelemetryClientStatus,
        consentEnabled: Bool,
        queuedItemCount: Int
    ) -> TelemetryControllerStatus {
        switch clientStatus {
        case .idle:
            return consentEnabled || queuedItemCount > 0 ? .ready : .inactive
        case .sent: return .sent
        case .queued: return .queued
        case .paused(.configuration): return .configurationRequired
        case .paused: return .deliveryPaused
        case .quarantined: return .quarantined
        }
    }

    private func status(for error: TelemetryQueueError) -> TelemetryControllerStatus {
        switch error {
        case .feedbackCapacityExceeded, .healthCapacityExceeded, .queueCapacityExceeded: return .capacityReached
        default: return .unavailable
        }
    }

    nonisolated private static func defaultRuntimeContext() throws -> TelemetryRuntimeContext {
        let bundle = Bundle.main
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let appBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return try TelemetryRuntimeContext(appVersion: appVersion, appBuild: appBuild, osVersion: "\(os.majorVersion).\(os.minorVersion)")
    }

    private static func weekStart(for date: Date) throws -> TelemetryWeekStart {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return try TelemetryWeekStart(rawValue: formatter.string(from: start))
    }

    private static func milestone(for stage: TelemetryStage) -> TelemetryHealthEventName? {
        switch stage {
        case .recordingFinalize: return .firstRecordingCompleted
        case .transcription: return .firstTranscriptCompleted
        case .summary: return .firstSummaryCompleted
        }
    }

    private static func durationBucket(since startedAt: Date, now: Date) -> TelemetryDurationBucket {
        let seconds = max(0, now.timeIntervalSince(startedAt))
        switch seconds {
        case ..<1: return .lessThanOneSecond
        case ..<5: return .oneToFiveSeconds
        case ..<15: return .fiveToFifteenSeconds
        case ..<60: return .fifteenToSixtySeconds
        case ..<300: return .oneToFiveMinutes
        case ..<900: return .fiveToFifteenMinutes
        case ..<1800: return .fifteenToThirtyMinutes
        case ..<3600: return .thirtyToSixtyMinutes
        default: return .atLeastSixtyMinutes
        }
    }
}

extension TelemetryController: HealthSignalRecording { }
