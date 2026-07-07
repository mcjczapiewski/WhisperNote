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

    @discardableResult
    static func requestPermissionPrompt() -> Bool {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispernote_system_audio_permission_\(UUID().uuidString).m4a")
        let tap = SystemAudioTap()
        defer {
            tap.stop()
            try? FileManager.default.removeItem(at: tempURL)
        }

        do {
            try tap.start(outputURL: tempURL)
            logger.info("System audio permission warm-up succeeded")
            return true
        } catch {
            logger.info("System audio permission warm-up failed: \(error.localizedDescription)")
            return false
        }
    }

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var audioFile: AVAudioFile?
    private var captureFormat: AVAudioFormat?
    private var captureSampleRate: Double = 0
    private var segmentStartUptime: TimeInterval = 0
    private var segmentStartFrame: AVAudioFramePosition = 0
    private var writtenFrameCount: AVAudioFramePosition = 0
    private var capturedAudioFrameCount: AVAudioFramePosition = 0
    var levelHandler: ((Double) -> Void)?

    func start(outputURL: URL) throws {
        let excludedProcesses = Self.ownProcessObjectID().map { [$0] } ?? []
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses)
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var tap: AudioObjectID = kAudioObjectUnknown
        var status = AudioHardwareCreateProcessTap(tapDescription, &tap)
        guard status == noErr else { throw TapError.osStatus("creating tap", status) }
        tapID = tap

        // A tap-only aggregate device has no hardware clock of its own, so Core Audio can start
        // pumping late. Use a stable physical output for timing, but avoid Bluetooth/HFP devices:
        // they can report a 48kHz tap while the aggregate is effectively clocked much slower,
        // producing sped-up, high-pitched files.
        let clockDevice = try Self.stableOutputClockDevice()
        Self.logger.info("System audio aggregate clock: name=\(clockDevice.name, privacy: .public) uid=\(clockDevice.uid, privacy: .public) sampleRate=\(clockDevice.sampleRate) transport=\(clockDevice.transportType)")

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "WhisperNote System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: clockDevice.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: clockDevice.uid]
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
        captureFormat = format
        captureSampleRate = format.sampleRate
        segmentStartUptime = ProcessInfo.processInfo.systemUptime
        segmentStartFrame = 0
        writtenFrameCount = 0
        capturedAudioFrameCount = 0

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
            self.padSilenceBefore(bufferFrameLength: buffer.frameLength)
            self.capturedAudioFrameCount += AVAudioFramePosition(buffer.frameLength)
            self.writtenFrameCount += AVAudioFramePosition(buffer.frameLength)
            try? self.audioFile?.write(from: buffer)
            self.publishLevel(from: buffer)
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
        let targetFrame = currentTimelineFrame()
        AudioDeviceStop(aggregateDeviceID, procID)
        padSilence(toFrame: targetFrame)
    }

    func resume() {
        guard let procID = ioProcID else { return }
        segmentStartUptime = ProcessInfo.processInfo.systemUptime
        segmentStartFrame = writtenFrameCount
        AudioDeviceStart(aggregateDeviceID, procID)
    }

    func stop() {
        if let procID = ioProcID {
            let targetFrame = currentTimelineFrame()
            AudioDeviceStop(aggregateDeviceID, procID)
            padSilence(toFrame: targetFrame)
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
        if captureSampleRate > 0 {
            let writtenDuration = Double(writtenFrameCount) / captureSampleRate
            let capturedAudioDuration = Double(capturedAudioFrameCount) / captureSampleRate
            Self.logger.info("System audio capture stopped: writtenFrames=\(self.writtenFrameCount) audioFrames=\(self.capturedAudioFrameCount) sampleRate=\(self.captureSampleRate) writtenDuration=\(writtenDuration) audioDuration=\(capturedAudioDuration)")
        }
        captureFormat = nil
        captureSampleRate = 0
        segmentStartUptime = 0
        segmentStartFrame = 0
        writtenFrameCount = 0
        capturedAudioFrameCount = 0
        audioFile = nil
    }

    private func publishLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return }

        var sum: Float = 0
        if buffer.format.isInterleaved {
            let samples = channelData[0]
            let sampleCount = channelCount * frameLength
            for sampleIndex in 0..<sampleCount {
                let sample = samples[sampleIndex]
                sum += sample * sample
            }
        } else {
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for frame in 0..<frameLength {
                    let sample = samples[frame]
                    sum += sample * sample
                }
            }
        }

        let rms = sqrt(sum / Float(channelCount * frameLength))
        let decibels = 20 * log10(max(rms, 0.000_001))
        let normalizedLevel = max(0, min(1, (Double(decibels) + 60) / 60))
        levelHandler?(normalizedLevel)
    }

    private func padSilenceBefore(bufferFrameLength: AVAudioFrameCount) {
        guard captureSampleRate > 0 else { return }
        let elapsedFrames = AVAudioFramePosition((ProcessInfo.processInfo.systemUptime - segmentStartUptime) * captureSampleRate)
        let bufferFrames = AVAudioFramePosition(bufferFrameLength)
        let bufferStartFrame = max(segmentStartFrame, segmentStartFrame + elapsedFrames - bufferFrames)
        padSilence(toFrame: bufferStartFrame)
    }

    private func padSilenceToCurrentTimeline() {
        padSilence(toFrame: currentTimelineFrame())
    }

    private func currentTimelineFrame() -> AVAudioFramePosition {
        guard captureSampleRate > 0 else { return writtenFrameCount }
        let elapsedFrames = AVAudioFramePosition((ProcessInfo.processInfo.systemUptime - segmentStartUptime) * captureSampleRate)
        return segmentStartFrame + elapsedFrames
    }

    private func padSilence(toFrame targetFrame: AVAudioFramePosition) {
        guard let format = captureFormat, targetFrame > writtenFrameCount else { return }

        var remainingFrames = targetFrame - writtenFrameCount
        if writtenFrameCount == 0 {
            Self.logger.info("System audio first data offset: insertedSilenceFrames=\(remainingFrames) sampleRate=\(self.captureSampleRate) offset=\(Double(remainingFrames) / self.captureSampleRate)")
        }

        while remainingFrames > 0 {
            let frameCount = AVAudioFrameCount(min(remainingFrames, 8192))
            guard let silentBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
            silentBuffer.frameLength = frameCount

            for buffer in UnsafeMutableAudioBufferListPointer(silentBuffer.mutableAudioBufferList) {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }

            do {
                try audioFile?.write(from: silentBuffer)
                writtenFrameCount += AVAudioFramePosition(frameCount)
                remainingFrames -= AVAudioFramePosition(frameCount)
            } catch {
                Self.logger.error("Failed to write system-audio timeline silence: \(error.localizedDescription)")
                return
            }
        }
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

    private struct ClockDevice {
        let uid: String
        let name: String
        let transportType: UInt32
        let sampleRate: Double
        let outputChannelCount: UInt32
    }

    /// Chooses a hardware clock for the aggregate device. Prefer built-in output even when the
    /// user listens on Bluetooth; the subdevice is only a timing source for the tap.
    private static func stableOutputClockDevice() throws -> ClockDevice {
        let devices = allClockDevices().filter { $0.outputChannelCount > 0 }
        if let builtIn = devices.first(where: { $0.transportType == kAudioDeviceTransportTypeBuiltIn }) {
            return builtIn
        }
        if let nonBluetooth = devices.first(where: { !isBluetoothTransport($0.transportType) }) {
            return nonBluetooth
        }
        return try defaultSystemOutputDevice()
    }

    private static func defaultSystemOutputDevice() throws -> ClockDevice {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceSize, &deviceID)
        guard status == noErr else { throw TapError.osStatus("getting default output device", status) }

        guard let device = clockDevice(for: deviceID) else {
            throw TapError.formatUnavailable
        }
        return device
    }

    private static func allClockDevices() -> [ClockDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs) == noErr else {
            return []
        }

        return deviceIDs.compactMap(clockDevice(for:))
    }

    private static func clockDevice(for deviceID: AudioDeviceID) -> ClockDevice? {
        guard let uid = stringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID) else {
            return nil
        }

        return ClockDevice(
            uid: uid,
            name: stringProperty(deviceID: deviceID, selector: kAudioObjectPropertyName) ?? "Unknown Audio Device",
            transportType: uint32Property(deviceID: deviceID, selector: kAudioDevicePropertyTransportType) ?? 0,
            sampleRate: doubleProperty(deviceID: deviceID, selector: kAudioDevicePropertyNominalSampleRate) ?? 0,
            outputChannelCount: outputChannelCount(for: deviceID)
        )
    }

    private static func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &uidSize, ptr)
        }
        guard status == noErr else { return nil }
        return value as String
    }

    private static func uint32Property(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }

    private static func doubleProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }

    private static func outputChannelCount(for deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawPointer.deallocate() }

        let bufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        var mutableSize = size
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &mutableSize, bufferList) == noErr else {
            return 0
        }

        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) { $0 + $1.mNumberChannels }
    }

    private static func isBluetoothTransport(_ transportType: UInt32) -> Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
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
