import Foundation
import AVFoundation
import CoreAudio
import os.log

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

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.whispernote.app", category: "SystemAudioTap")

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

        // ponytail: a tap-only aggregate device has no hardware clock of its own, so Core
        // Audio only pumps its IO proc once a tapped process is actually emitting audio —
        // recording silently starts late (reproduced: system audio only began once a YouTube
        // video started playing, well after the mic track). Anchoring the aggregate device to
        // the real default output device as its main subdevice gives it a continuously running
        // clock from the moment it starts. The subdevice is never selected as system output, so
        // this doesn't route or duplicate any audio — it's purely a timing source.
        let outputUID = try Self.defaultOutputDeviceUID()

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "WhisperNote System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
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
        Self.logger.info("System audio tap format: sampleRate=\(format.sampleRate) channels=\(format.channelCount) commonFormat=\(format.commonFormat.rawValue) interleaved=\(format.isInterleaved)")

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
    /// ponytail: quality key instead of a fixed bit rate — some mics (e.g. voice-optimized
    /// USB/Bluetooth devices) report unusual sample rates like 16kHz, and a flat 128kbps
    /// bit rate isn't valid for every sample rate/channel combo (AudioConverterSetProperty
    /// rejects it outright). Letting the encoder pick its own bit rate for the given format
    /// avoids hardcoding a table of valid combos ourselves.
    static func aacSettings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
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

    /// UID of the system's current default output device, used to give the tap's aggregate
    /// device a real hardware clock (see comment at the call site in `start(outputURL:)`).
    private static func defaultOutputDeviceUID() throws -> String {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceSize, &deviceID)
        guard status == noErr else { throw TapError.osStatus("getting default output device", status) }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        status = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
        }
        guard status == noErr else { throw TapError.osStatus("getting default output device UID", status) }
        return uid as String
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
