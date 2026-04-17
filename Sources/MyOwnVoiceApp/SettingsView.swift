import AppCore
import ModelRouting
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case recording
    case cleanup
    case corrections
    case models
    case history
    case meetingTranscript
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recording:
            "Recording"
        case .cleanup:
            "Cleanup"
        case .corrections:
            "Corrections"
        case .models:
            "Models"
        case .history:
            "History"
        case .meetingTranscript:
            "Meeting Transcript"
        case .general:
            "General"
        }
    }

    var subtitle: String {
        switch self {
        case .recording:
            "Shortcuts, permissions, and dictation testing."
        case .cleanup:
            "Prompt cleanup for quick dictation."
        case .corrections:
            "Words and replacements to preserve."
        case .models:
            "Local model routing and runtime status."
        case .history:
            "Saved transcripts and recording folders."
        case .meetingTranscript:
            "Timestamped local exports with best-effort speaker labels."
        case .general:
            "App-wide direction and shell-first defaults."
        }
    }

    var systemImage: String {
        switch self {
        case .recording:
            "waveform.badge.mic"
        case .cleanup:
            "sparkles"
        case .corrections:
            "text.badge.checkmark"
        case .models:
            "brain"
        case .history:
            "clock.arrow.circlepath"
        case .meetingTranscript:
            "person.2.wave.2"
        case .general:
            "gearshape"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var coordinator: DictationCoordinator
    @ObservedObject private var permissionCenter: PermissionCenter

    @State private var selectedSection: SettingsSection? = .recording

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        _permissionCenter = ObservedObject(wrappedValue: coordinator.permissionCenter)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                sectionRow(section)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 250, ideal: 280)
        } detail: {
            detailView
        }
        .background(SettingsWindowAccessor())
    }

    private func sectionRow(_ section: SettingsSection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: section.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.headline)

                Text(section.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection ?? .recording {
        case .recording:
            recordingDetail
        case .cleanup:
            cleanupDetail
        case .corrections:
            correctionsDetail
        case .models:
            modelsDetail
        case .history:
            historyDetail
        case .meetingTranscript:
            meetingTranscriptDetail
        case .general:
            generalDetail
        }
    }

    private var recordingDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                detailHeader(
                    title: "Recording",
                    subtitle: "Configure hold-to-record, toggle recording, permissions, and the focused-field insertion loop."
                )

                settingsCard("Shortcuts") {
                    VStack(alignment: .leading, spacing: 12) {
                        shortcutRow(title: HotkeyAction.holdToRecord.displayName, action: .holdToRecord)
                        shortcutRow(title: HotkeyAction.toggleRecording.displayName, action: .toggleRecording)

                        Text("Click a shortcut field, then press the new chord. Modifier-only shortcuts like bare Right Command, Left Control, Option, Shift, or Function are supported.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("Restore Default Shortcuts") {
                            coordinator.restoreDefaultShortcuts()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                settingsCard("Behavior") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            "Automatically paste into the focused text field after transcription",
                            isOn: recordingBinding(for: \.autoInsertIntoFocusedField)
                        )

                        Toggle(
                            "Double-tap Hold to Record to toggle recording on or off",
                            isOn: recordingBinding(for: \.enableDoubleTapHoldToToggle)
                        )

                        Text("Quick dictation cleanup is currently set to \(coordinator.recordingPreferences.quickDictationCleanupMode.title). Change this in the Cleanup tab.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(coordinator.recordingPreferences.quickDictationCleanupMode.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("With double-tap enabled, a quick double-tap on the Hold to Record shortcut latches recording so it stays on after you release the keys, and one more tap stops it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                settingsCard("Permissions") {
                    VStack(alignment: .leading, spacing: 12) {
                        permissionSummaryRow("Microphone", state: permissionCenter.microphone)
                        permissionSummaryRow("Accessibility", state: permissionCenter.accessibility)
                        permissionSummaryRow("Screen Capture", state: permissionCenter.screenCapture)

                        HStack(spacing: 10) {
                            Button("Refresh Permissions") {
                                coordinator.refreshPermissions()
                            }
                            .buttonStyle(.bordered)

                            Button(coordinator.isRecording ? "Stop Test Dictation" : "Start Test Dictation") {
                                coordinator.toggleRecordingFromUI()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(coordinator.isProcessingCapture)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cleanupDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                detailHeader(
                    title: "Cleanup",
                    subtitle: "Choose exactly what quick dictation should do with Gemma cleanup before or after paste."
                )

                settingsCard("Quick Dictation Cleanup") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Mode", selection: quickDictationCleanupModeBinding) {
                            ForEach(QuickDictationCleanupMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(coordinator.recordingPreferences.quickDictationCleanupMode.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                settingsCard("Cleanup Prompt") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextEditor(text: recordingBinding(for: \.cleanupPrompt))
                            .font(.body.monospaced())
                            .frame(minHeight: 220)
                            .padding(8)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))

                        Text("Gemma uses this prompt only when Quick Dictation Cleanup is set to Background or Before Paste.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var correctionsDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                detailHeader(
                    title: "Corrections",
                    subtitle: "Teach the app your important words so dictation stays accurate even without full cleanup."
                )

                settingsCard("Important Terms") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Add one preferred term per line. These terms keep their exact spelling and capitalization when the app sees them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextEditor(text: recordingBinding(for: \.preferredTermsText))
                            .font(.body.monospaced())
                            .frame(minHeight: 160)
                            .padding(8)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))

                        Text("Example: `Gemma`, `Gemma 4`, `WhisperKit`, `Jen`.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                settingsCard("Common Mishears") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            "Auto-learn short corrections after paste",
                            isOn: recordingBinding(for: \.enablePostPasteCorrectionLearning)
                        )

                        Text("Use one rule per line in the format `wrong => right`. These fixes run quickly even when cleanup is turned off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextEditor(text: recordingBinding(for: \.misheardReplacementsText))
                            .font(.body.monospaced())
                            .frame(minHeight: 180)
                            .padding(8)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))

                        Text("Example: `gamma => Gemma`, `gemma four => Gemma 4`, `whisper kit => WhisperKit`.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("When auto-learning is on, the app watches the focused text field for a few seconds after paste and saves small edits like `gamma` to `Gemma` as future correction rules.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var modelsDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                detailHeader(
                    title: "Models",
                    subtitle: "Keep the package-first routing architecture, but make the runtime and per-task choices easier to inspect."
                )

                settingsCard("Runtime Status") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(coordinator.localModelRuntimeStatus)
                            .foregroundStyle(.secondary)

                        if !coordinator.missingRuntimeModels.isEmpty {
                            Text("Missing: \(coordinator.missingRuntimeModels.joined(separator: ", "))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        Divider()

                        Text(coordinator.speechRecognitionRuntimeStatus)
                            .foregroundStyle(.secondary)

                        if !coordinator.installedRuntimeModels.isEmpty {
                            Text(coordinator.installedRuntimeModels.joined(separator: ", "))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }

                        HStack(spacing: 10) {
                            Button(coordinator.isPreparingLocalRuntime ? "Setting Up..." : "Set Up Runtime") {
                                Task {
                                    await coordinator.setUpLocalModelRuntime()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(coordinator.isPreparingLocalRuntime)

                            Button("Refresh Runtime") {
                                Task {
                                    await coordinator.refreshLocalModelRuntime()
                                }
                            }
                            .buttonStyle(.bordered)

                            Button("Prepare WhisperKit") {
                                Task {
                                    await coordinator.prepareSpeechRecognitionEngine()
                                }
                            }
                            .buttonStyle(.bordered)

                            Button("Test Gemma 4") {
                                Task {
                                    await coordinator.runGemmaFormattingCheck()
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(!coordinator.canUseGemmaRuntime || coordinator.isPreparingLocalRuntime)
                        }
                    }
                }

                settingsCard("Routing") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Use automatic model routing", isOn: modelPreferencesBinding(for: \.useAutomaticRouting))

                        Text("Automatic routing keeps quick dictation fast, long sessions stable, and formatting on the strongest local instruction model available.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                settingsCard("Per-Task Model Preferences") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(ModelTask.allCases) { task in
                            Picker(task.displayName, selection: binding(for: task)) {
                                Text("System Default").tag("system-default")

                                ForEach(coordinator.availableModels(for: task)) { model in
                                    Text(model.displayName).tag(model.id)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var historyDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                detailHeader(
                    title: "History",
                    subtitle: "Saved transcripts now persist locally, and each entry links back to the recording folder on disk."
                )

                settingsCard("Saved Recordings") {
                    VStack(alignment: .leading, spacing: 12) {
                        if coordinator.recentTranscripts.isEmpty {
                            Text("Nothing has been saved yet. Record something with the menu bar app or a global shortcut to populate local history.")
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Clear History") {
                                coordinator.clearRecentTranscripts()
                            }
                            .buttonStyle(.bordered)

                            ForEach(coordinator.recentTranscripts) { transcript in
                                transcriptHistoryRow(transcript)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var meetingTranscriptDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                detailHeader(
                    title: "Meeting Transcript",
                    subtitle: "Meeting mode now saves a local markdown transcript with timestamps and a best-effort speaker pass."
                )

                settingsCard("Current Behavior") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Switch Session to Meeting Transcript before you record from the menu bar app.")
                        Text("When you stop, the app saves `meeting-transcript.md` and `meeting-transcript.json` in that session folder.")
                        Text("WhisperKit timings drive the transcript timeline, and Gemma 4 assigns speaker labels when the Ollama runtime is ready.")
                        Text("If Gemma 4 is unavailable, the export still succeeds with a single-speaker fallback instead of failing the whole recording.")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var generalDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                detailHeader(
                    title: "General",
                    subtitle: "Keep the product shell-first, local-first, and package-first while we fill in the rest of settings over time."
                )

                settingsCard("Current Shape") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Menu bar extra app with a dedicated Settings window.")
                        Text("Automatic paste into the focused text field stays first-class.")
                        Text("Context Bundler is intentionally omitted from this build.")
                        Text("General app preferences like launch-at-login can slot into this pane next without disturbing the dictation architecture.")
                    }
                    .foregroundStyle(.secondary)
                }

                settingsCard("Current Shortcuts") {
                    Text(coordinator.shortcutSummary)
                        .font(.body.monospaced())
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detailHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 36, weight: .bold))

            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)

            Text(coordinator.statusMessage)
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }

    private func settingsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))

            content()
        }
        .padding(18)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private func shortcutRow(title: String, action: HotkeyAction) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(action == .holdToRecord ? "Press and hold this chord to record, then release to transcribe." : "Press once to start recording and press again to stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ShortcutRecorderField(
                shortcut: shortcut(for: action)
            ) { shortcut in
                coordinator.applyShortcut(shortcut, for: action)
            }
            .frame(width: 230, height: 36)
        }
    }

    private func permissionSummaryRow(_ title: String, state: PermissionState) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(state.displayName)
                .foregroundStyle(state.isGranted ? .green : .orange)
        }
        .font(.subheadline)
    }

    private func transcriptHistoryRow(_ transcript: RecentTranscript) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(transcript.mode.displayName)
                    .font(.headline)

                Spacer()

                Text(transcript.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(transcript.text)
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .textSelection(.enabled)

            if let speakerLabels = transcript.speakerLabels, !speakerLabels.isEmpty {
                Text("Speakers: \(speakerLabels.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("\(transcript.chunkCount) chunk(s) • \(transcript.insertionMessage)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            HStack(spacing: 10) {
                Button("Copy") {
                    coordinator.copyTranscript(transcript)
                }
                .buttonStyle(.bordered)

                Button("Insert") {
                    coordinator.insertTranscript(transcript)
                }
                .buttonStyle(.bordered)

                Button("Reveal Files") {
                    coordinator.revealTranscriptFiles(transcript)
                }
                .buttonStyle(.bordered)

                if transcript.exportedArtifactPath != nil {
                    Button("Open Export") {
                        coordinator.openTranscriptArtifact(transcript)
                    }
                    .buttonStyle(.bordered)
                }

                Button("Remove") {
                    coordinator.removeTranscript(transcript)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func shortcut(for action: HotkeyAction) -> AppCore.KeyboardShortcut {
        switch action {
        case .holdToRecord:
            coordinator.recordingPreferences.holdToRecordShortcut
        case .toggleRecording:
            coordinator.recordingPreferences.toggleRecordingShortcut
        }
    }

    private func recordingBinding<Value>(for keyPath: WritableKeyPath<RecordingPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { coordinator.recordingPreferences[keyPath: keyPath] },
            set: { coordinator.recordingPreferences[keyPath: keyPath] = $0 }
        )
    }

    private var quickDictationCleanupModeBinding: Binding<QuickDictationCleanupMode> {
        Binding(
            get: { coordinator.recordingPreferences.quickDictationCleanupMode },
            set: { newValue in
                var preferences = coordinator.recordingPreferences
                preferences.quickDictationCleanupMode = newValue
                coordinator.recordingPreferences = preferences
            }
        )
    }

    private func modelPreferencesBinding<Value>(for keyPath: WritableKeyPath<ModelPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { coordinator.preferences[keyPath: keyPath] },
            set: { coordinator.preferences[keyPath: keyPath] = $0 }
        )
    }

    private func binding(for task: ModelTask) -> Binding<String> {
        Binding(
            get: {
                coordinator.preferences.pinnedModelID(for: task) ?? "system-default"
            },
            set: { newValue in
                if newValue == "system-default" {
                    coordinator.preferences.setPinnedModelID(nil, for: task)
                } else {
                    coordinator.preferences.setPinnedModelID(newValue, for: task)
                }
            }
        )
    }
}
