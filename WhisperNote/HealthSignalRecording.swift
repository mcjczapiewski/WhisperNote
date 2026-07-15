import Foundation

/// A deliberately small boundary between product workflows and optional telemetry.
/// Callers provide only the closed-schema outcome metadata; no user content or errors
/// can cross this boundary.
@MainActor
protocol HealthSignalRecording: AnyObject {
    func recordHealthSignal(
        stage: TelemetryStage,
        outcome: TelemetryOutcome,
        startedAt: Date,
        failure: TelemetryFailureBucket?
    ) async
}

@MainActor
final class NoopHealthSignalRecorder: HealthSignalRecording {
    func recordHealthSignal(
        stage: TelemetryStage,
        outcome: TelemetryOutcome,
        startedAt: Date,
        failure: TelemetryFailureBucket?
    ) async { }
}

func telemetryFailureBucket(for error: Error) -> TelemetryFailureBucket {
    if error is CancellationError { return .cancelled }
    if let error = error as? TranscriptionError {
        switch error {
        case .missingApiKey: return .authentication
        case .fileReadError: return .noAudio
        case .invalidResponse: return .decode
        case .apiError(let statusCode, _): return telemetryFailureBucket(httpStatus: statusCode)
        case .staleLibrary: return .cancelled
        case .unknown: return .unknown
        }
    }
    if let error = error as? SummaryError {
        switch error {
        case .missingApiKey: return .authentication
        case .emptyPrompt, .emptyResponse, .invalidResponse: return .decode
        case .apiError(let statusCode): return telemetryFailureBucket(httpStatus: statusCode)
        case .staleLibrary: return .cancelled
        case .unknown: return .unknown
        }
    }
    if error is ArtifactPersistenceError { return .persistence }
    return .unknown
}

private func telemetryFailureBucket(httpStatus: Int) -> TelemetryFailureBucket {
    switch httpStatus {
    case 401, 403: return .authentication
    case 408: return .timeout
    case 429: return .rateLimited
    case 500...599: return .service
    default: return .network
    }
}
