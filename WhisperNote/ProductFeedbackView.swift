import SwiftUI

struct ProductFeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var telemetryController: TelemetryController

    @State private var category: TelemetryFeedbackCategory = .idea
    @State private var message = ""
    @State private var isSubmitting = false

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !isSubmitting && !trimmedMessage.isEmpty && message.count <= TelemetrySchema.maximumFeedbackCharacters
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Send Product Feedback")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close product feedback")
            }

            Text("Feedback is free text that you control. Do not paste audio, transcript or summary content, file paths, API keys, passwords, tokens, or other sensitive information.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Category", selection: $category) {
                Text("Bug").tag(TelemetryFeedbackCategory.bug)
                Text("Idea").tag(TelemetryFeedbackCategory.idea)
                Text("Usability").tag(TelemetryFeedbackCategory.usability)
                Text("Other").tag(TelemetryFeedbackCategory.other)
            }
            .accessibilityLabel("Feedback category")

            TextEditor(text: $message)
                .font(.body)
                .frame(minHeight: 150)
                .overlay(alignment: .topLeading) {
                    if message.isEmpty {
                        Text("Describe your feedback")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Feedback message")

            HStack {
                Text("\(message.count)/\(TelemetrySchema.maximumFeedbackCharacters)")
                    .font(.caption)
                    .foregroundStyle(message.count > TelemetrySchema.maximumFeedbackCharacters ? .red : .secondary)
                Spacer()
                Button(isSubmitting ? "Sending…" : "Submit Feedback") {
                    isSubmitting = true
                    Task {
                        let result = await telemetryController.submitFeedback(category: category, message: message)
                        isSubmitting = false
                        if result == .sent { dismiss() }
                    }
                }
                .disabled(!canSubmit)
                .accessibilityLabel("Submit product feedback")
            }

            if let feedbackStatusMessage = telemetryController.feedbackStatusMessage {
                Text(feedbackStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Feedback delivery status: \(feedbackStatusMessage)")
            }
        }
        .padding()
        .frame(width: 520)
    }
}
