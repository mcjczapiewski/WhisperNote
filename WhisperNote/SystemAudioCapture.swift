import Foundation
import AVFoundation
import CoreAudio

enum SystemAudioCapture {
    // Helper method to get a list of available audio devices
    static func getAvailableAudioDevices() -> [String] {
        // Get the available input devices
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        ).devices

        return devices.map { $0.localizedName }
    }

    // Helper method to check if Bluetooth headphones are connected
    static func isBluetoothHeadphonesConnected() -> Bool {
        // On macOS, we can't directly check if Bluetooth headphones are connected
        // through AVAudioSession like on iOS, so we'll use a different approach

        // Get the available output devices
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        ).devices

        // Check if any of the devices might be Bluetooth
        for device in devices {
            let name = device.localizedName.lowercased()
            if name.contains("bluetooth") ||
               name.contains("airpods") ||
               name.contains("wireless") {
                return true
            }
        }

        return false
    }
}

/// Captures system audio to a file using a Core Audio process tap (macOS 14.2+).
/// Requires no Screen Recording permission — just the audio-input entitlement.
/// ponytail: taps every process except our own (no per-app picker); add one if users ask.
final class SystemAudioTap {
    enum TapError: LocalizedError {
        case osStatus(String, OSStatus)
        case formatUnavailable

        var errorDescription: String? {
            switch self {
            case .osStatus(let step, let status):
                return "System audio capture failed at \(step) (status \(status))."
            case .formatUnavailable:
                return "Could not determine the system audio format."
            }
        }
    }

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var audioFile: AVAudioFile?

    func start(outputURL: URL) throws {
        let excludedProcesses = Self.ownProcessObjectID().map { [$0] } ?? []
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses)
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var tap: AudioObjectID = kAudioObjectUnknown
        var status = AudioHardwareCreateProcessTap(tapDescription, &tap)
        guard status == noErr else { throw TapError.osStatus("creating tap", status) }
        tapID = tap

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "WhisperNote System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                 kAudioSubTapDriftCompensationKey: true]
            ]
        ]

        var aggregateID: AudioObjectID = kAudioObjectUnknown
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard status == noErr else { throw TapError.osStatus("creating aggregate device", status) }
        aggregateDeviceID = aggregateID

        guard let format = Self.tapStreamFormat(tapID: tap) else {
            throw TapError.formatUnavailable
        }

        let file = try AVAudioFile(
            forWriting: outputURL,
            settings: Self.aacSettings(sampleRate: format.sampleRate, channels: format.channelCount),
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        audioFile = file

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [weak self] _, inputData, _, _, _ in
            guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData) else { return }
            try? self.audioFile?.write(from: buffer)
        }
        guard status == noErr, let procID else { throw TapError.osStatus("creating IO proc", status) }
        ioProcID = procID

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw TapError.osStatus("starting aggregate device", status) }
    }

    /// Stops hardware IO without tearing down the tap/aggregate device, so `resume()` can
    /// pick back up on the same objects. No audio is captured while paused.
    func pause() {
        guard let procID = ioProcID else { return }
        AudioDeviceStop(aggregateDeviceID, procID)
    }

    func resume() {
        guard let procID = ioProcID else { return }
        AudioDeviceStart(aggregateDeviceID, procID)
    }

    func stop() {
        if let procID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        audioFile = nil
    }

    /// AAC-in-.m4a settings for a PCM source of the given sample rate/channel count.
    /// Shared with AudioRecorder's mic capture so both intermediate files encode the same way.
    static func aacSettings(sampleRate: Double, channels: AVAudioChannelCount, bitRate: Int = 128_000) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate
        ]
    }

    /// Core Audio's process tap works with its own "process object" IDs, not raw PIDs —
    /// look up the AudioObjectID that corresponds to our own process.
    private static func ownProcessObjectID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return nil
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processIDs) == noErr else {
            return nil
        }

        let myPID = ProcessInfo.processInfo.processIdentifier
        for processID in processIDs {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(processID, &pidAddress, 0, nil, &pidSize, &pid) == noErr else { continue }
            if pid == myPID { return processID }
        }
        return nil
    }

    private static func tapStreamFormat(tapID: AudioObjectID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }
}
