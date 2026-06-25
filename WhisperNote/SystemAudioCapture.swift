import Foundation
import AVFoundation

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
