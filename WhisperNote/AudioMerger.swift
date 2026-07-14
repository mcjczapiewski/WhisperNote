import AVFoundation
import Foundation

struct AudioFileProbe: Equatable, Sendable {
    let isValid: Bool
    let duration: TimeInterval

    static let invalid = AudioFileProbe(isValid: false, duration: 0)
}

protocol AudioMerging: Sendable {
    func probeAudio(at url: URL) async -> AudioFileProbe
    func merge(microphoneURL: URL, systemAudioURL: URL, outputURL: URL) async throws -> URL
}

final class AVFoundationAudioMerger: AudioMerging, @unchecked Sendable {
    private let fileManager: FileManager
    private let sampleRate = 48_000.0
    private let bitRate = 64_000
    private let channels = 1

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func probeAudio(at url: URL) async -> AudioFileProbe {
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0 else {
            return .invalid
        }

        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let duration = try? await asset.load(.duration) else {
            return .invalid
        }

        let seconds = duration.seconds
        guard duration.isValid, seconds.isFinite, seconds > 0 else { return .invalid }
        return AudioFileProbe(isValid: true, duration: seconds)
    }

    func merge(microphoneURL: URL, systemAudioURL: URL, outputURL: URL) async throws -> URL {
        guard (await probeAudio(at: microphoneURL)).isValid,
              (await probeAudio(at: systemAudioURL)).isValid else {
            throw AudioRecorderError.fileNotFound
        }

        let microphoneAsset = AVURLAsset(url: microphoneURL)
        let systemAudioAsset = AVURLAsset(url: systemAudioURL)

        guard let microphoneTrack = try await microphoneAsset.loadTracks(withMediaType: .audio).first,
              let systemAudioTrack = try await systemAudioAsset.loadTracks(withMediaType: .audio).first else {
            throw AudioRecorderError.recordingFailed
        }

        let microphoneDuration = try await microphoneAsset.load(.duration)
        let systemAudioDuration = try await systemAudioAsset.load(.duration)
        let composition = AVMutableComposition()

        guard let microphoneCompositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let systemCompositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioRecorderError.recordingFailed
        }

        do {
            // Each source keeps its full duration. A short system track must not truncate
            // a longer microphone track (and vice versa).
            try microphoneCompositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: microphoneDuration),
                of: microphoneTrack,
                at: .zero
            )
            try systemCompositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: systemAudioDuration),
                of: systemAudioTrack,
                at: .zero
            )
        } catch {
            throw AudioRecorderError.recordingFailed
        }

        let microphoneParameters = AVMutableAudioMixInputParameters(track: microphoneCompositionTrack)
        microphoneParameters.setVolume(1, at: .zero)
        let systemParameters = AVMutableAudioMixInputParameters(track: systemCompositionTrack)
        systemParameters.setVolume(1, at: .zero)

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [microphoneParameters, systemParameters]

        if fileManager.fileExists(atPath: outputURL.path) {
            do {
                try fileManager.removeItem(at: outputURL)
            } catch {
                throw AudioRecorderError.fileOperationFailed
            }
        }

        try await export(composition: composition, audioMix: audioMix, outputURL: outputURL)

        guard (await probeAudio(at: outputURL)).isValid else {
            try? fileManager.removeItem(at: outputURL)
            throw AudioRecorderError.recordingFailed
        }
        return outputURL
    }

    private func export(
        composition: AVMutableComposition,
        audioMix: AVMutableAudioMix,
        outputURL: URL
    ) async throws {
        let reader = try AVAssetReader(asset: composition)
        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let readerOutput = AVAssetReaderAudioMixOutput(
            audioTracks: composition.tracks(withMediaType: .audio),
            audioSettings: readerSettings
        )
        readerOutput.audioMix = audioMix
        guard reader.canAdd(readerOutput) else { throw AudioRecorderError.recordingFailed }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitRate
            ]
        )
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw AudioRecorderError.recordingFailed }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw reader.error ?? AudioRecorderError.recordingFailed
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? AudioRecorderError.recordingFailed
        }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "WhisperNote.AudioMergeWriter")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        guard writerInput.append(sampleBuffer) else {
                            reader.cancelReading()
                            writerInput.markAsFinished()
                            continuation.resume(throwing: writer.error ?? AudioRecorderError.recordingFailed)
                            return
                        }
                    } else {
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            if reader.status == .failed || reader.status == .cancelled {
                                continuation.resume(throwing: reader.error ?? AudioRecorderError.recordingFailed)
                            } else if writer.status == .failed || writer.status == .cancelled {
                                continuation.resume(throwing: writer.error ?? AudioRecorderError.recordingFailed)
                            } else {
                                continuation.resume()
                            }
                        }
                        return
                    }
                }
            }
        }
    }
}
