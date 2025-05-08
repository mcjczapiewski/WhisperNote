import Foundation
import os.log

/// A class to configure and manage logging for the application
class LoggingConfiguration {
    /// Shared instance for use across the app
    static let shared = LoggingConfiguration()

    /// The subsystem identifier for the app's logs
    private let subsystem = Bundle.main.bundleIdentifier ?? "com.whispernote.app"

    /// Logger for RecordKit-related logs
    lazy var recordKitLogger = OSLog(subsystem: subsystem, category: "RecordKit")

    /// Logger for audio recording
    lazy var audioRecordingLogger = OSLog(subsystem: subsystem, category: "AudioRecording")

    /// Logger for general app logs
    lazy var appLogger = OSLog(subsystem: subsystem, category: "App")

    /// Initialize the logging configuration
    private init() {
        configureLogging()
    }

    /// Configure the logging system
    private func configureLogging() {
        // Set up environment variables to control logging
        // This will suppress AudioGapFiller logs from RecordKit
        setenv("OS_ACTIVITY_MODE", "disable", 1)

        // Set RecordKit specific logging environment variables
        setenv("RK_LOG_LEVEL", "warning", 1)  // Only log warnings and errors from RecordKit
        setenv("RK_DISABLE_AUDIOGAPFILLER_LOGS", "1", 1)  // Specifically disable AudioGapFiller logs
    }

    /// Log a message with the appropriate logger
    /// - Parameters:
    ///   - message: The message to log
    ///   - type: The log type (default, error, info, debug)
    ///   - logger: The logger to use (defaults to app logger)
    func log(_ message: String, type: OSLogType = .default, logger: OSLog? = nil) {
        let targetLogger = logger ?? appLogger
        os_log("%{public}@", log: targetLogger, type: type, message)
    }

    /// Log a RecordKit-related message
    /// - Parameters:
    ///   - message: The message to log
    ///   - type: The log type (default, error, info, debug)
    func logRecordKit(_ message: String, type: OSLogType = .default) {
        // Filter out AudioGapFiller messages and other noise
        if message.contains("AudioGapFiller") ||
           message.contains("Detected gap in audio") ||
           message.contains("Negative gap detected") ||
           message.contains("dropping this overlapping sample") {
            return
        }

        // Only log important messages
        log(message, type: type, logger: recordKitLogger)
    }
}
