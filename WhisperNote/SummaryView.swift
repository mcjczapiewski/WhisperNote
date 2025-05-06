import SwiftUI

struct SummaryView: View {
    @EnvironmentObject var summaryManager: SummaryManager
    @State private var selectedSummary: Summary?
    @State private var isGenerating = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var customPrompt = ""
    @State private var showingPromptEditor = false

    var body: some View {
        VStack {
            Text("Summaries")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.bottom, 20)

            if summaryManager.summaries.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "list.bullet.clipboard")
                        .resizable()
                        .frame(width: 80, height: 100)
                        .foregroundColor(.blue)

                    Text("No Summaries Yet")
                        .font(.title)

                    Text("Generate a summary from a transcript to get started")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding()
            } else {
                HStack(spacing: 0) {
                    // Sidebar with summary list
                    List {
                        ForEach(summaryManager.summaries) { summary in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(summary.name)
                                        .font(.headline)

                                    Text(summary.date, style: .date)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if summary.status == .inProgress {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                } else if summary.status == .completed {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                } else if summary.status == .failed {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundColor(.red)
                                }
                            }
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedSummary = summary
                            }
                            .background(selectedSummary?.id == summary.id ? Color.blue.opacity(0.1) : Color.clear)
                        }
                    }
                    .frame(width: 250)
                    .listStyle(SidebarListStyle())

                    // Divider
                    Divider()

                    // Summary content
                    if let selectedSummary = selectedSummary {
                        VStack {
                            HStack {
                                Text(selectedSummary.name)
                                    .font(.headline)

                                Spacer()

                                Button(action: {
                                    // Export summary
                                }) {
                                    Label("Export", systemImage: "square.and.arrow.up")
                                }

                                Button(action: {
                                    customPrompt = summaryManager.getDefaultPrompt()
                                    showingPromptEditor = true
                                }) {
                                    Label("Regenerate", systemImage: "arrow.clockwise")
                                }
                            }
                            .padding()

                            if selectedSummary.status == .inProgress {
                                VStack {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                        .scaleEffect(2)

                                    Text("Generating Summary...")
                                        .font(.headline)
                                        .padding(.top, 20)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else if selectedSummary.status == .completed {
                                ScrollView {
                                    Text(selectedSummary.content)
                                        .padding()
                                }
                            } else if selectedSummary.status == .failed {
                                VStack {
                                    Image(systemName: "exclamationmark.circle")
                                        .resizable()
                                        .frame(width: 50, height: 50)
                                        .foregroundColor(.red)

                                    Text("Summary Generation Failed")
                                        .font(.headline)
                                        .padding(.top, 10)

                                    Button("Retry") {
                                        // Retry summary generation
                                    }
                                    .padding(.top, 10)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    } else {
                        Text("Select a summary to view")
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .padding()
        .alert(isPresented: $showingError) {
            Alert(
                title: Text("Summary Generation Error"),
                message: Text(errorMessage),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(isPresented: $showingPromptEditor) {
            VStack(spacing: 20) {
                Text("Customize Summary Prompt")
                    .font(.headline)

                TextEditor(text: $customPrompt)
                    .frame(minHeight: 200)
                    .border(Color.gray.opacity(0.2))
                    .padding()

                HStack {
                    Button("Cancel") {
                        showingPromptEditor = false
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Generate Summary") {
                        if !customPrompt.isEmpty {
                            // Generate summary with custom prompt
                            showingPromptEditor = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(customPrompt.isEmpty)
                }
                .padding()
            }
            .frame(width: 500, height: 400)
            .padding()
        }
    }
}
