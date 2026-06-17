import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var viewModel: VoiceDictationViewModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .center, spacing: 14) {
                            Button(action: viewModel.toggleRecording) {
                                Label(
                                    viewModel.isRecording ? "Stop" : "Record",
                                    systemImage: viewModel.isRecording ? "stop.fill" : "mic.fill"
                                )
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .tint(viewModel.isRecording ? .red : .blue)
                            .disabled(viewModel.isTranscribing)

                            if viewModel.isTranscribing {
                                ProgressView()
                                    .controlSize(.regular)
                            }
                        }

                        Text(viewModel.statusMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }

                Section("Local model") {
                    Picker("Whisper model", selection: $viewModel.selectedModelName) {
                        ForEach(WhisperKitTranscriber.availableModels, id: \.name) { model in
                            Text(model.label).tag(model.name)
                        }
                    }
                    .disabled(viewModel.isRecording || viewModel.isTranscribing)

                    Text("Models run on device with WhisperKit. The first run downloads the selected Core ML model into this app's sandbox.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Latest transcript") {
                    if let latestTranscript = viewModel.latestTranscript {
                        Text(latestTranscript.text)
                            .textSelection(.enabled)

                        HStack {
                            Label(latestTranscript.modelName, systemImage: "cpu")
                            Spacer()
                            Text(latestTranscript.createdAt, style: .time)
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                        Button {
                            viewModel.copyLatestTranscript()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    } else {
                        Text("No transcript yet.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Keyboard setup") {
                    LabeledContent("Keyboard", value: "My Own Voice")
                    Text("Enable the keyboard in Settings > General > Keyboard > Keyboards. Turn on Full Access so the keyboard and recorder can use the shared App Group transcript.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("My Own Voice")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.refreshLatestTranscript()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isRecording || viewModel.isTranscribing)
                }
            }
            .task {
                viewModel.refreshLatestTranscript()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    viewModel.refreshLatestTranscript()
                }
            }
        }
    }
}

#Preview {
    ContentView(viewModel: VoiceDictationViewModel())
}
