import SwiftUI

struct AudioSetupGuideView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var currentStep = 0

    let steps = [
        SetupStep(
            title: "Install a Virtual Audio Device",
            description: "To record system audio, you need to install a virtual audio device like BlackHole or Loopback.",
            instructions: [
                "1. Download BlackHole from https://existential.audio/blackhole/ (free)",
                "2. Install the package by double-clicking and following the prompts",
                "3. Restart your Mac after installation"
            ],
            image: "speaker.wave.3.fill"
        ),
        SetupStep(
            title: "Create a Multi-Output Device",
            description: "This allows you to hear audio while also routing it to the virtual device for recording.",
            instructions: [
                "1. Open Audio MIDI Setup (from Applications > Utilities)",
                "2. Click the + button in the bottom left corner",
                "3. Select 'Create Multi-Output Device'",
                "4. Check both your regular output device (e.g., Built-in Output) and BlackHole 2ch",
                "5. Make sure your regular output device is at the top of the list (drag if needed)",
                "6. Make sure 'Drift Correction' is checked for BlackHole"
            ],
            image: "rectangle.on.rectangle"
        ),
        SetupStep(
            title: "Set System Audio Output",
            description: "Now you need to set your system to use the Multi-Output Device.",
            instructions: [
                "1. In Audio MIDI Setup, right-click on the Multi-Output Device",
                "2. Select 'Use This Device For Sound Output'",
                "3. Alternatively, select it from the volume control in the menu bar"
            ],
            image: "speaker.wave.2.circle.fill"
        ),
        SetupStep(
            title: "Configure WhisperNote",
            description: "WhisperNote will now be able to record both your microphone and system audio.",
            instructions: [
                "1. When recording in WhisperNote, your microphone will capture your voice",
                "2. System audio (like music, videos, or other participants in calls) will be captured through BlackHole",
                "3. You can mute your microphone during recording if needed"
            ],
            image: "checkmark.circle.fill"
        )
    ]

    var body: some View {
        VStack {
            Text("System Audio Recording Setup")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.top)

            Text("Follow these steps to enable system audio recording")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.bottom)

            // Use a simple TabView for macOS
            TabView(selection: $currentStep) {
                ForEach(0..<steps.count, id: \.self) { index in
                    StepView(step: steps[index])
                        .tag(index)
                }
            }
            .tabViewStyle(DefaultTabViewStyle())
            .frame(height: 400)

            HStack {
                Button(action: {
                    if currentStep > 0 {
                        currentStep -= 1
                    }
                }) {
                    HStack {
                        Image(systemName: "chevron.left")
                        Text("Previous")
                    }
                    .padding()
                    .background(currentStep > 0 ? Color.blue : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(currentStep == 0)

                Spacer()

                Button(action: {
                    if currentStep < steps.count - 1 {
                        currentStep += 1
                    } else {
                        presentationMode.wrappedValue.dismiss()
                    }
                }) {
                    HStack {
                        Text(currentStep < steps.count - 1 ? "Next" : "Finish")
                        Image(systemName: currentStep < steps.count - 1 ? "chevron.right" : "checkmark")
                    }
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
            }
            .padding()

            if currentStep == 0 {
                HStack {
                    Button(action: {
                        NSWorkspace.shared.open(URL(string: "https://existential.audio/blackhole/")!)
                    }) {
                        Text("Download BlackHole")
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }

                    Button(action: {
                        NSWorkspace.shared.open(URL(string: "https://rogueamoeba.com/loopback/")!)
                    }) {
                        Text("Loopback (Paid Alternative)")
                            .padding()
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }
                .padding(.bottom)
            }

            if currentStep == 1 {
                Button(action: {
                    // Open Audio MIDI Setup
                    let path = "/Applications/Utilities/Audio MIDI Setup.app"
                    let url = URL(fileURLWithPath: path)
                    NSWorkspace.shared.open(url)
                }) {
                    Text("Open Audio MIDI Setup")
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding(.bottom)
            }
        }
        .padding()
        .frame(width: 600, height: 600)
    }
}

struct StepView: View {
    let step: SetupStep

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Image(systemName: step.image)
                    .font(.largeTitle)
                    .foregroundColor(.blue)

                Text(step.title)
                    .font(.title)
                    .fontWeight(.bold)
            }
            .padding(.bottom, 5)

            Text(step.description)
                .font(.headline)
                .foregroundColor(.secondary)
                .padding(.bottom, 5)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(step.instructions, id: \.self) { instruction in
                    Text(instruction)
                        .font(.body)
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(10)

            Spacer()
        }
        .padding()
    }
}

struct SetupStep {
    let title: String
    let description: String
    let instructions: [String]
    let image: String
}

struct AudioSetupGuideView_Previews: PreviewProvider {
    static var previews: some View {
        AudioSetupGuideView()
    }
}
