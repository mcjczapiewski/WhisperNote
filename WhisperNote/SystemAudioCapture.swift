import Foundation
import AVFoundation
import AppKit
import CoreAudio

class SystemAudioCapture: NSObject {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var isCapturing = false
    private var isPaused = false
    private var deviceChangeObserver: NSObjectProtocol?
    private var hasLoggedAudioData = false

    private let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    override init() {
        super.init()
        setupNotifications()
    }

    deinit {
        removeNotifications()
    }

    private func setupNotifications() {
        // Register for device change notifications on macOS
        deviceChangeObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "NSWorkspaceDidConfigureAudioNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAudioDeviceChange()
        }
    }

    private func removeNotifications() {
        if let observer = deviceChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func handleAudioDeviceChange() {
        print("Audio device configuration changed")

        // Log current audio devices
        logAudioDevices()

        // If we're currently recording, we might need to reconfigure
        if isCapturing && !isPaused {
            restartCaptureIfNeeded()
        }
    }

    private func logAudioDevices() {
        print("Available audio devices:")
        let devices = Self.getAvailableAudioDevices()
        for (index, device) in devices.enumerated() {
            print("[\(index)] \(device)")
        }
    }

    private func restartCaptureIfNeeded() {
        guard let audioEngine = audioEngine else { return }

        // Only restart if we're currently capturing
        if isCapturing && !isPaused {
            // Stop the engine temporarily
            audioEngine.stop()

            // Try to restart the engine
            do {
                try audioEngine.start()
                print("Successfully restarted audio engine after device change")
            } catch {
                print("Failed to restart audio engine after device change: \(error.localizedDescription)")
                // We'll keep the isCapturing flag as true since we're still technically trying to capture
            }
        }
    }

    func startCapturing(to fileURL: URL) throws {
        // Log audio device information for debugging
        print(Self.getAudioDeviceInfo())

        // Check if Bluetooth headphones are connected
        let bluetoothConnected = Self.isBluetoothHeadphonesConnected()
        if bluetoothConnected {
            print("Bluetooth headphones detected - ensuring proper configuration")
        }

        // Log current audio devices
        logAudioDevices()

        // Check if we have a virtual audio device
        let hasVirtualDevice = Self.hasVirtualAudioDevice()
        if !hasVirtualDevice {
            print("WARNING: No virtual audio device detected. System audio capture may not work.")
        } else {
            print("Virtual audio device detected. Proceeding with system audio capture.")
        }

        // Initialize the audio engine
        audioEngine = AVAudioEngine()

        guard let audioEngine = audioEngine else {
            print("Failed to initialize audio engine")
            throw SystemAudioCaptureError.engineInitializationFailed
        }

        // Try to select the virtual audio device if available
        if hasVirtualDevice {
            if !trySelectVirtualAudioDevice() {
                print("Could not select virtual audio device, using default input")
            }
        }

        // Get the input node (this will be the system audio input)
        let inputNode = audioEngine.inputNode

        // Log the current input node format for debugging
        print("Input node format: \(inputNode.outputFormat(forBus: 0).description)")
        print("Input node name: \(inputNode.name(forInputBus: 0) ?? "unknown")")

        // Configure the audio format
        let format = inputNode.outputFormat(forBus: 0)

        // Check if the format is valid (has channels)
        if format.channelCount == 0 {
            print("Invalid audio format: no channels detected")
            throw SystemAudioCaptureError.engineInitializationFailed
        }

        // Create an audio file for recording
        do {
            audioFile = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        } catch {
            print("Failed to create system audio file: \(error.localizedDescription)")
            throw SystemAudioCaptureError.fileCreationFailed
        }

        // Install a tap on the input node to capture audio
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] (buffer, time) in
            guard let self = self, let audioFile = self.audioFile else { return }

            // Check if the buffer has audio data
            let channelData = buffer.floatChannelData
            if channelData != nil {
                // Check if there's actual audio data (not just silence)
                var hasAudioData = false
                let frames = buffer.frameLength

                if frames > 0 && buffer.stride > 0 {
                    // Just check a few samples to see if there's any non-zero data
                    for channel in 0..<min(2, Int(buffer.format.channelCount)) {
                        if let data = channelData?[channel] {
                            for i in stride(from: 0, to: min(Int(frames), 100), by: 10) {
                                if abs(data[i]) > 0.001 {
                                    hasAudioData = true
                                    break
                                }
                            }
                            if hasAudioData { break }
                        }
                    }
                }

                if !hasAudioData {
                    // Log if no audio data is detected
                    if hasVirtualDevice {
                        print("Warning: No system audio data detected in buffer. Make sure your system audio is routed through the virtual audio device.")
                    } else if bluetoothConnected {
                        print("Warning: No system audio data detected in buffer while using Bluetooth")
                    }
                } else {
                    // Log when we detect audio data (only once)
                    if !self.hasLoggedAudioData {
                        print("System audio data detected in buffer - recording is working!")
                        self.hasLoggedAudioData = true
                    }
                }
            }

            do {
                try audioFile.write(from: buffer)
            } catch {
                print("Error writing to system audio file: \(error)")
            }
        }

        // Start the audio engine
        do {
            try audioEngine.start()
            isCapturing = true
            print("System audio engine started successfully")

            // Additional check for Bluetooth headphones
            if bluetoothConnected {
                // Log that we're using Bluetooth headphones
                print("Recording with Bluetooth headphones - monitoring for audio data")
            }
        } catch {
            print("Failed to start audio engine: \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)

            if bluetoothConnected {
                print("Bluetooth headphones may be causing issues with audio capture")
                throw SystemAudioCaptureError.bluetoothDeviceNotSupported
            } else if hasVirtualDevice {
                print("Virtual audio device detected but failed to start audio engine. Check your system audio configuration.")
                throw SystemAudioCaptureError.virtualDeviceConfigurationError
            } else {
                throw SystemAudioCaptureError.engineStartFailed
            }
        }
    }

    // Try to select a virtual audio device for input
    private func trySelectVirtualAudioDevice() -> Bool {
        // Get all audio devices (unused, but keeping the call for side effects)
        _ = Self.getAudioDeviceList()

        // Find a virtual audio device
        var virtualDeviceID: AudioDeviceID = 0
        var found = false

        // Get all device IDs
        var propertySize: UInt32 = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize
        )

        if status != noErr {
            print("Error getting audio device list size: \(status)")
            return false
        }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceIDs
        )

        if status != noErr {
            print("Error getting audio device IDs: \(status)")
            return false
        }

        // Find a virtual audio device
        for deviceID in deviceIDs {
            var nameSize: UInt32 = 0
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            if !AudioObjectHasProperty(deviceID, &nameAddress) {
                continue
            }

            status = AudioObjectGetPropertyDataSize(
                deviceID,
                &nameAddress,
                0,
                nil,
                &nameSize
            )

            if status != noErr {
                continue
            }

            var deviceName: CFString? = nil
            // Use UnsafeMutablePointer to handle the CFString properly
            withUnsafeMutablePointer(to: &deviceName) { ptr in
                status = AudioObjectGetPropertyData(
                    deviceID,
                    &nameAddress,
                    0,
                    nil,
                    &nameSize,
                    ptr
                )
            }

            if status == noErr, let name = deviceName as String? {
                let lowercaseName = name.lowercased()
                if lowercaseName.contains("blackhole") ||
                   lowercaseName.contains("loopback") ||
                   lowercaseName.contains("virtual") ||
                   lowercaseName.contains("soundflower") {
                    virtualDeviceID = deviceID
                    found = true
                    print("Found virtual audio device: \(name) with ID: \(deviceID)")
                    break
                }
            }
        }

        if !found {
            print("No virtual audio device found")
            return false
        }

        // Try to set the default input device to the virtual audio device
        // Note: This requires elevated permissions and may not work
        // This is just an attempt - the user should configure this manually
        propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &virtualDeviceID
        )

        if status == noErr {
            print("Successfully set virtual audio device as default input")
            return true
        } else {
            print("Could not set virtual audio device as default input: \(status)")
            print("User needs to manually configure audio routing")
            return false
        }
    }

    func pauseCapturing() {
        guard let audioEngine = audioEngine, isCapturing, !isPaused else {
            print("Cannot pause: engine not running or already paused")
            return
        }

        // Pause the audio engine
        audioEngine.pause()
        isPaused = true
        isCapturing = false
        print("System audio capture paused")
    }

    func resumeCapturing() {
        guard let audioEngine = audioEngine, !isCapturing, isPaused else {
            print("Cannot resume: engine not paused or already running")
            return
        }

        do {
            // Resume the audio engine
            try audioEngine.start()
            isCapturing = true
            isPaused = false
            print("System audio capture resumed")
        } catch {
            print("Error resuming system audio capture: \(error.localizedDescription)")
        }
    }

    func stopCapturing() -> URL? {
        guard let audioEngine = audioEngine, (isCapturing || isPaused) else {
            print("Cannot stop: no active recording")
            return nil
        }

        // Stop the audio engine
        audioEngine.stop()
        print("System audio engine stopped")

        // Remove the tap if it exists
        audioEngine.inputNode.removeTap(onBus: 0)
        print("System audio tap removed")

        // Get the file URL
        let fileURL = audioFile?.url

        // Clean up
        audioFile = nil
        self.audioEngine = nil
        isCapturing = false
        isPaused = false

        if let url = fileURL {
            print("System audio capture stopped, file saved at: \(url.path)")
        } else {
            print("System audio capture stopped, but no file was saved")
        }

        return fileURL
    }

    // Helper method to check if a virtual audio device is available
    static func hasVirtualAudioDevice() -> Bool {
        // Get the available input devices
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        ).devices

        // Check if any of the devices might be a virtual audio device
        for device in devices {
            if device.localizedName.lowercased().contains("blackhole") ||
               device.localizedName.lowercased().contains("loopback") ||
               device.localizedName.lowercased().contains("virtual") ||
               device.localizedName.lowercased().contains("soundflower") {
                return true
            }
        }

        // Also check audio devices using Core Audio API for more thorough detection
        let deviceList = getAudioDeviceList()
        for deviceName in deviceList {
            if deviceName.lowercased().contains("blackhole") ||
               deviceName.lowercased().contains("loopback") ||
               deviceName.lowercased().contains("virtual") ||
               deviceName.lowercased().contains("soundflower") {
                return true
            }
        }

        return false
    }

    // Get a list of all audio devices using Core Audio API
    static func getAudioDeviceList() -> [String] {
        var deviceList: [String] = []

        var propertySize: UInt32 = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Get the size of the device array
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize
        )

        if status != noErr {
            print("Error getting audio device list size: \(status)")
            return deviceList
        }

        // Calculate the number of devices
        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size

        // Create an array to hold the device IDs
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        // Get the device IDs
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceIDs
        )

        if status != noErr {
            print("Error getting audio device IDs: \(status)")
            return deviceList
        }

        // Get the name of each device
        for deviceID in deviceIDs {
            var nameSize: UInt32 = 0
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            // Check if the device has a name property
            if !AudioObjectHasProperty(deviceID, &nameAddress) {
                continue
            }

            // Get the size of the name
            status = AudioObjectGetPropertyDataSize(
                deviceID,
                &nameAddress,
                0,
                nil,
                &nameSize
            )

            if status != noErr {
                continue
            }

            // Get the name
            var deviceName: CFString? = nil
            // Use UnsafeMutablePointer to handle the CFString properly
            withUnsafeMutablePointer(to: &deviceName) { ptr in
                status = AudioObjectGetPropertyData(
                    deviceID,
                    &nameAddress,
                    0,
                    nil,
                    &nameSize,
                    ptr
                )
            }

            if status == noErr, let name = deviceName as String? {
                deviceList.append(name)
            }
        }

        return deviceList
    }

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

    // Get detailed information about all audio devices
    static func getAudioDeviceInfo() -> String {
        var info = "Audio Device Information:\n"

        // Get input devices
        let inputDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        ).devices

        info += "\nInput Devices:\n"
        for (index, device) in inputDevices.enumerated() {
            info += "[\(index)] \(device.localizedName) - \(device.uniqueID)\n"
        }

        // On macOS, we can't access AVAudioSession, so we'll just list the devices
        info += "\nAudio Engine Information:\n"
        let engine = AVAudioEngine()
        info += "Input node format: \(engine.inputNode.outputFormat(forBus: 0).description)\n"
        info += "Input node name: \(engine.inputNode.name(forInputBus: 0) ?? "unknown")\n"

        return info
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

    // Helper method to log the current audio routing
    func logAudioRouting() {
        print("Current audio routing:")

        // Get the available devices
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        ).devices

        print("Input devices:")
        for device in devices {
            print("- \(device.localizedName)")
        }

        if let engine = audioEngine {
            print("Audio engine input node: \(engine.inputNode.name(forInputBus: 0) ?? "unknown")")
            print("Audio engine output node: \(engine.outputNode.name(forOutputBus: 0) ?? "unknown")")
        }
    }
}

enum SystemAudioCaptureError: Error, LocalizedError {
    case engineInitializationFailed
    case fileCreationFailed
    case engineStartFailed
    case bluetoothDeviceNotSupported
    case noAudioData
    case virtualDeviceConfigurationError
    case virtualDeviceNotFound

    var errorDescription: String? {
        switch self {
        case .engineInitializationFailed:
            return "Failed to initialize audio engine."
        case .fileCreationFailed:
            return "Failed to create audio file for recording."
        case .engineStartFailed:
            return "Failed to start audio engine. RecordKit will be used for recording."
        case .bluetoothDeviceNotSupported:
            return "Bluetooth device not properly supported by the legacy audio engine. RecordKit will be used instead for recording."
        case .noAudioData:
            return "No audio data detected in legacy audio engine. RecordKit will be used for recording instead."
        case .virtualDeviceConfigurationError:
            return "Audio device not properly configured. RecordKit will be used for recording."
        case .virtualDeviceNotFound:
            return "Audio device not found. RecordKit will be used for recording."
        }
    }
}
