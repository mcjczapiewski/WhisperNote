import Foundation
import AVFoundation
import os.log

/// A utility class for merging audio files
public class AudioMerger {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.whispernote.app", category: "AudioMerger")

    /// Merge two audio files into a single file
    /// - Parameters:
    ///   - microphoneURL: URL of the microphone audio file
    ///   - systemAudioURL: URL of the system audio file
    ///   - outputURL: URL where the merged file will be saved
    /// - Returns: URL of the merged file
    public static func mergeAudioFiles(microphoneURL: URL, systemAudioURL: URL, outputURL: URL) async throws -> URL {
        logger.info("Merging audio files: \(microphoneURL.lastPathComponent) and \(systemAudioURL.lastPathComponent)")

        // Check if both files exist
        guard FileManager.default.fileExists(atPath: microphoneURL.path) else {
            logger.error("Microphone audio file not found at: \(microphoneURL.path)")
            throw AudioMergerError.fileNotFound
        }

        guard FileManager.default.fileExists(atPath: systemAudioURL.path) else {
            logger.error("System audio file not found at: \(systemAudioURL.path)")
            throw AudioMergerError.fileNotFound
        }

        // Create AVAssets for both files
        let microphoneAsset = AVAsset(url: microphoneURL)
        let systemAudioAsset = AVAsset(url: systemAudioURL)

        // Create a composition
        let composition = AVMutableComposition()

        // Create audio tracks in the composition
        guard let compositionTrack1 = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid),
              let compositionTrack2 = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid) else {
            logger.error("Failed to create composition tracks")
            throw AudioMergerError.compositionFailed
        }

        // Get audio tracks from the assets
        guard let microphoneTrack = try? await microphoneAsset.loadTracks(withMediaType: .audio).first,
              let systemAudioTrack = try? await systemAudioAsset.loadTracks(withMediaType: .audio).first else {
            logger.error("Failed to get audio tracks from assets")
            throw AudioMergerError.trackNotFound
        }

        // Get the time ranges for both tracks
        let microphoneDuration = try await microphoneAsset.load(.duration)
        let systemAudioDuration = try await systemAudioAsset.load(.duration)

        logger.info("Microphone duration: \(microphoneDuration.seconds) seconds")
        logger.info("System audio duration: \(systemAudioDuration.seconds) seconds")

        // Create time ranges for both tracks
        let microphoneTimeRange = CMTimeRange(start: .zero, duration: microphoneDuration)
        let systemAudioTimeRange = CMTimeRange(start: .zero, duration: systemAudioDuration)

        // Insert the audio tracks into the composition
        do {
            try compositionTrack1.insertTimeRange(microphoneTimeRange, of: microphoneTrack, at: .zero)
            try compositionTrack2.insertTimeRange(systemAudioTimeRange, of: systemAudioTrack, at: .zero)
        } catch {
            logger.error("Failed to insert time ranges: \(error.localizedDescription)")
            throw AudioMergerError.insertionFailed
        }

        // Create an export session
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            logger.error("Failed to create export session")
            throw AudioMergerError.exportSessionFailed
        }

        // Configure the export session
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.shouldOptimizeForNetworkUse = true

        // Remove the output file if it already exists
        if FileManager.default.fileExists(atPath: outputURL.path) {
            do {
                try FileManager.default.removeItem(at: outputURL)
                logger.info("Removed existing file at: \(outputURL.path)")
            } catch {
                logger.error("Failed to remove existing file: \(error.localizedDescription)")
                throw AudioMergerError.fileOperationFailed
            }
        }

        // Export the composition
        await exportSession.export()

        // Check for export errors
        if let error = exportSession.error {
            logger.error("Export failed: \(error.localizedDescription)")
            throw AudioMergerError.exportFailed
        }

        logger.info("Audio files successfully merged to: \(outputURL.path)")
        return outputURL
    }
}

/// Errors that can occur during audio merging
public enum AudioMergerError: Error, LocalizedError {
    case fileNotFound
    case compositionFailed
    case trackNotFound
    case insertionFailed
    case exportSessionFailed
    case exportFailed
    case fileOperationFailed

    public var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "One or more audio files could not be found"
        case .compositionFailed:
            return "Failed to create audio composition"
        case .trackNotFound:
            return "Failed to find audio tracks in the files"
        case .insertionFailed:
            return "Failed to insert audio tracks into composition"
        case .exportSessionFailed:
            return "Failed to create export session"
        case .exportFailed:
            return "Failed to export merged audio file"
        case .fileOperationFailed:
            return "Failed to perform file operation"
        }
    }
}
