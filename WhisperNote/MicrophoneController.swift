import Foundation
import CoreAudio

class MicrophoneController {
    
    enum MicrophoneError: Error, LocalizedError {
        case deviceNotFound
        case cannotGetProperty
        case cannotSetProperty
        
        var errorDescription: String? {
            switch self {
            case .deviceNotFound:
                return "Could not find the default input device."
            case .cannotGetProperty:
                return "Failed to get audio device property."
            case .cannotSetProperty:
                return "Failed to set audio device property."
            }
        }
    }
    
    // Singleton instance
    static let shared = MicrophoneController()
    
    private init() {}
    
    // Get the default input device ID
    private func getDefaultInputDevice() throws -> AudioDeviceID {
        var deviceID: AudioDeviceID = 0
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        
        if status != noErr {
            throw MicrophoneError.deviceNotFound
        }
        
        return deviceID
    }
    
    // Check if the microphone is currently muted
    func isMicrophoneMuted() throws -> Bool {
        let deviceID = try getDefaultInputDevice()
        var muted: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        // Check if the device supports the mute property
        if !AudioObjectHasProperty(deviceID, &propertyAddress) {
            return false
        }
        
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &muted
        )
        
        if status != noErr {
            throw MicrophoneError.cannotGetProperty
        }
        
        return muted == 1
    }
    
    // Mute or unmute the microphone
    func setMicrophoneMute(muted: Bool) throws {
        let deviceID = try getDefaultInputDevice()
        var mutedValue: UInt32 = muted ? 1 : 0
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        // Check if the device supports the mute property
        if !AudioObjectHasProperty(deviceID, &propertyAddress) {
            throw MicrophoneError.cannotSetProperty
        }
        
        let status = AudioObjectSetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &mutedValue
        )
        
        if status != noErr {
            throw MicrophoneError.cannotSetProperty
        }
    }
    
    // Toggle the microphone mute state
    func toggleMicrophoneMute() throws -> Bool {
        let currentlyMuted = try isMicrophoneMuted()
        try setMicrophoneMute(muted: !currentlyMuted)
        return !currentlyMuted
    }
}
