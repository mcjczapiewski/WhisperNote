import SwiftUI

struct AudioSetupGuideView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var currentStep = 0

    let steps = [
        SetupStep(
            title: "Grant Required Permissions",
            description: "WhisperNote needs certain permissions to record audio properly.",
            instructions: [
                "1. When prompted, allow WhisperNote to access your microphone",
                "2. When prompted, allow WhisperNote to access system audio (needed for system audio recording)",
                "3. You may need to restart the app after granting permissions"
            ],
            image: "lock.shield"
        ),
        SetupStep(
            title: "Microphone Setup",
            description: "Make sure your microphone is properly configured.",
            instructions: [
                "1. Check that your preferred microphone is connected",
                "2. WhisperNote will automatically use your system's default microphone",
                "3. You can change your default microphone in System Settings > Sound"
            ],
            image: "mic.fill"
        ),
        SetupStep(
            title: "System Audio Setup",
            description: "WhisperNote can record system audio directly if your system audio is not muted.",
            instructions: [
                "1. Make sure your system audio is not muted",
                "2. Adjust the volume to an appropriate level",
                "3. Test your audio setup before important recordings"
            ],
            image: "speaker.wave.2.circle.fill"
        ),
        SetupStep(
            title: "Configure WhisperNote",
            description: "WhisperNote will now be able to record both your microphone and system audio.",
            instructions: [
                "1. When recording in WhisperNote, your microphone will capture your voice",
                "2. System audio (like music, videos, or other participants in calls) will be captured directly",
                "3. You can mute your microphone during recording if needed",
                "4. Both microphone and system audio will be saved in a single file"
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

            Text("Follow these steps to set up audio recording")
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

            // No additional buttons needed for step 0

            if currentStep == 1 {
                Button(action: {
                    // Open Sound preferences
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.sound")!)
                }) {
                    Text("Open Sound Settings")
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
