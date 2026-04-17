import AppCore
import ModelRouting
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case recording
    case cleanup
    case corrections
    case models
    case history

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
        }
    }
}

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case meetings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            "All"
        case .meetings:
            "Meetings"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var coordinator: DictationCoordinator
    @ObservedObject private var permissionCenter: PermissionCenter

    @State private var selectedSection: SettingsSection? = .recording
    @State private var historyFilter: HistoryFilter = .all

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
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            detailView
        }
        .background(SettingsWindowAccessor())
    }

    private func sectionRow(_ section: SettingsSection) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .font(.body.weight(.medium))
            .lineLimit(1)
            .padding(.vertical, 4)
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

                            Button("Test Selected Model") {
                                Task {
                                    await coordinator.runSelectedFormattingModelCheck()
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(!coordinator.canUseSelectedFormattingRuntime || coordinator.isPreparingLocalRuntime)
                        }
                    }
                }

                settingsCard("Routing") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Use automatic model routing", isOn: modelPreferencesBinding(for: \.useAutomaticRouting))

                        Text("Automatic routing keeps quick dictation fast, long sessions stable, and routes each task to the strongest compatible available model.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                settingsCard("Per-Task Model Preferences") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(visibleModelTasks) { task in
                            Picker(task.displayName, selection: modelSelectionBinding(for: task)) {
                                Text(coordinator.automaticModelLabel(for: task)).tag(automaticSelectionTag)

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
                    subtitle: "Browse saved transcripts, session folders, and meeting exports in one place."
                )

                settingsCard("Meeting Exports") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Meeting Transcript saves dated markdown and JSON files inside each session folder.")
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Button("Open Sessions Folder") {
                                coordinator.openSessionsFolder()
                            }
                            .buttonStyle(.borderedProminent)

                            if let latestMeetingTranscript {
                                Button("Open Latest Session Folder") {
                                    coordinator.openTranscriptSessionFolder(latestMeetingTranscript)
                                }
                                .buttonStyle(.bordered)

                                if latestMeetingTranscript.exportedArtifactPath != nil {
                                    Button("Open Latest Export") {
                                        coordinator.openTranscriptArtifact(latestMeetingTranscript)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }

                        if latestMeetingTranscript == nil {
                            Text("Switch Session to Meeting Transcript and record once to create the first export.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                settingsCard("Saved Recordings") {
                    VStack(alignment: .leading, spacing: 12) {
                        if coordinator.recentTranscripts.isEmpty {
                            Text("Nothing has been saved yet. Record something with the menu bar app or a global shortcut to populate local history.")
                                .foregroundStyle(.secondary)
                        } else {
                            HStack {
                                Picker("Show", selection: $historyFilter) {
                                    ForEach(HistoryFilter.allCases) { filter in
                                        Text(filter.title).tag(filter)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 180)

                                Spacer()

                                Button("Clear History") {
                                    coordinator.clearRecentTranscripts()
                                }
                                .buttonStyle(.bordered)
                            }

                            ForEach(filteredTranscripts) { transcript in
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
            .frame(width: 230, height: 40)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1)
            )
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

                Button("Open Session Folder") {
                    coordinator.openTranscriptSessionFolder(transcript)
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

    private var latestMeetingTranscript: RecentTranscript? {
        coordinator.recentTranscripts.first { $0.mode == .meetingTranscript }
    }

    private var filteredTranscripts: [RecentTranscript] {
        switch historyFilter {
        case .all:
            coordinator.recentTranscripts
        case .meetings:
            coordinator.recentTranscripts.filter { $0.mode == .meetingTranscript }
        }
    }

    private var visibleModelTasks: [ModelTask] {
        ModelTask.allCases.filter { $0 != .commands }
    }

    private var automaticSelectionTag: String { "__automatic__" }

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

    private func modelSelectionBinding(for task: ModelTask) -> Binding<String> {
        Binding(
            get: {
                coordinator.preferences.pinnedModelID(for: task)
                    ?? coordinator.selectedModelID(for: task)
                    ?? automaticSelectionTag
            },
            set: { newValue in
                if newValue == automaticSelectionTag {
                    coordinator.preferences.setPinnedModelID(nil, for: task)
                } else {
                    coordinator.preferences.setPinnedModelID(newValue, for: task)
                }
            }
        )
    }
}
