import AppCore
import ModelRouting
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case shortcuts
    case recording
    case cleanup
    case corrections
    case models
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shortcuts:
            "Shortcuts"
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
        case .shortcuts:
            "keyboard"
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

    @State private var selectedSection: SettingsSection? = .shortcuts
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
        switch selectedSection ?? .shortcuts {
        case .shortcuts:
            shortcutsDetail
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

    private var shortcutsDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                detailHeader(
                    title: "Shortcuts",
                    subtitle: "Global recording controls."
                )

                if let shortcutAttentionMessage = coordinator.shortcutAttentionMessage {
                    inlineNotice(
                        shortcutAttentionMessage,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }

                settingsCard("Global Recording Shortcuts") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(HotkeyAction.allCases.enumerated()), id: \.element) { index, action in
                            shortcutManagementRow(action)

                            if index < HotkeyAction.allCases.count - 1 {
                                Divider()
                            }
                        }

                        HStack(spacing: 10) {
                            Button {
                                coordinator.restoreDefaultShortcuts()
                            } label: {
                                Label("Restore All", systemImage: "arrow.counterclockwise")
                            }
                            .buttonStyle(.bordered)

                            Spacer()

                            Label(coordinator.shortcutSummary, systemImage: "keyboard")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                settingsCard("Hold Behavior") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            "Double-tap Hold to Record to lock recording",
                            isOn: recordingBinding(for: \.enableDoubleTapHoldToToggle)
                        )
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var recordingDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                detailHeader(
                    title: "Recording",
                    subtitle: "Configure permissions and focused-field insertion."
                )

                settingsCard("Behavior") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            "Automatically paste into the focused text field after transcription",
                            isOn: recordingBinding(for: \.autoInsertIntoFocusedField)
                        )

                        Picker("Floating HUD", selection: recordingBinding(for: \.dictationHUDStyle)) {
                            ForEach(DictationHUDStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360)

                        Text(coordinator.recordingPreferences.dictationHUDStyle.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("Quick dictation cleanup is currently set to \(coordinator.recordingPreferences.quickDictationCleanupMode.title). Change this in the Cleanup tab.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(coordinator.recordingPreferences.quickDictationCleanupMode.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                settingsCard("Permissions") {
                    VStack(alignment: .leading, spacing: 12) {
                        permissionSummaryRow(.microphone, state: permissionCenter.microphone)
                        permissionSummaryRow(.accessibility, state: permissionCenter.accessibility)

                        HStack(spacing: 10) {
                            Button("Refresh Permissions") {
                                coordinator.refreshPermissions()
                            }
                            .buttonStyle(.bordered)
                            .help("Check Microphone and Accessibility permission again")

                            Button(coordinator.isRecording ? "Stop Test Dictation" : "Start Test Dictation") {
                                coordinator.toggleRecordingFromUI()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(coordinator.isProcessingCapture)
                            .help(testDictationHelp)
                        }
                    }
                }

                settingsCard("Insertion Probe") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Button("Insert Probe in 5 Seconds") {
                                coordinator.scheduleFocusedInsertionProbe()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                coordinator.isRecording ||
                                coordinator.isProcessingCapture ||
                                coordinator.isFocusedInsertionProbePending
                            )
                            .help(insertionProbeHelp)

                            if coordinator.isFocusedInsertionProbePending {
                                ProgressView()
                                    .controlSize(.small)
                            }
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
                    subtitle: "Choose how local cleanup behaves. Long Session waits for cleanup when it is enabled, while Quick Dictation can clean up before or after paste."
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

                        Text("Long Session uses the same cleanup prompt and formatting model whenever cleanup is enabled. This picker only changes Quick Dictation timing.")
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
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

                        Text("The selected local cleanup model uses this prompt for Long Session whenever cleanup is enabled, and for Quick Dictation when cleanup is set to Background or Before Paste.")
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
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

                        Text("Example: `Qwen3`, `Gemma 4`, `WhisperKit`, `Jen`.")
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
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

                        Text("Example: `queue in three => Qwen3`, `gemma four => Gemma 4`, `whisper kit => WhisperKit`.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("When auto-learning is on, the app watches the focused text field for a few seconds after paste and saves small edits like `queue in three` to `Qwen3` as future correction rules.")
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
                    subtitle: "Set up speech and cleanup models, then inspect the exact per-task routing."
                )

                settingsCard("Runtime Status") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Cleanup Runtime")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(coordinator.localModelRuntimeStatus)
                            .foregroundStyle(.secondary)

                        if !coordinator.missingRuntimeModels.isEmpty {
                            Text("Missing: \(coordinator.missingRuntimeModels.joined(separator: ", "))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        if !coordinator.installedRuntimeModels.isEmpty {
                            Text(coordinator.installedRuntimeModels.joined(separator: ", "))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }

                        Divider()

                        Text("Speech Runtime")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(coordinator.speechRecognitionRuntimeStatus)
                            .foregroundStyle(.secondary)

                        Text("Speech transcription uses WhisperKit. The first setup downloads the selected Core ML model. whisper-cli is optional and only used as a fallback when it is already installed with a local model file.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

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

                            Button("Set Up Speech Model") {
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
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(visibleModelTasks) { task in
                            VStack(alignment: .leading, spacing: 4) {
                                Picker(modelTaskPickerTitle(for: task), selection: modelSelectionBinding(for: task)) {
                                    Text(coordinator.automaticModelLabel(for: task)).tag(automaticSelectionTag)

                                    ForEach(coordinator.availableModels(for: task)) { model in
                                        Text(model.displayName).tag(model.id)
                                    }
                                }

                                Text(modelTaskHelp(for: task))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
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
                                .disabled(!coordinator.canModifyHistoryNow)
                                .help(historyMutationHelp("Clear saved transcript history"))
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
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func inlineNotice(_ message: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        )
    }

    private func shortcutManagementRow(_ action: HotkeyAction) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(action.displayName)
                        .font(.headline)

                    shortcutStatusBadge(for: action)
                }

                Text(action.managementDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Label(
                    coordinator.shortcutStatusMessage(for: action),
                    systemImage: coordinator.shortcutNeedsAttention(for: action)
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                    .font(.caption)
                    .foregroundStyle(coordinator.shortcutNeedsAttention(for: action) ? .orange : .secondary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                ShortcutRecorderField(
                    shortcut: coordinator.shortcut(for: action)
                ) { shortcut in
                    coordinator.applyShortcut(shortcut, for: action)
                }
                .frame(width: 230, height: 40)
                .background(shortcutFieldTint(for: action).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(shortcutFieldTint(for: action).opacity(0.26), lineWidth: 1)
                )

                Button {
                    coordinator.restoreDefaultShortcut(for: action)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .disabled(coordinator.isDefaultShortcut(for: action))
                .help("Restore \(action.displayName) default")
            }
        }
    }

    private func shortcutStatusBadge(for action: HotkeyAction) -> some View {
        let needsAttention = coordinator.shortcutNeedsAttention(for: action)

        return Text(needsAttention ? "Conflict" : "Ready")
            .font(.caption.weight(.semibold))
            .foregroundStyle(needsAttention ? .orange : .green)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((needsAttention ? Color.orange : Color.green).opacity(0.12), in: Capsule())
    }

    private func shortcutFieldTint(for action: HotkeyAction) -> Color {
        coordinator.shortcutNeedsAttention(for: action) ? .orange : .accentColor
    }

    private func permissionSummaryRow(_ kind: PermissionKind, state: PermissionState) -> some View {
        HStack {
            Label(kind.displayName, systemImage: permissionSystemImage(for: kind))
            Spacer()
            Text(state.displayName)
                .foregroundStyle(state.isGranted ? .green : .orange)

            if !state.isGranted {
                Button {
                    coordinator.requestPermission(kind)
                } label: {
                    Label(permissionActionTitle(for: kind, state: state), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .help(permissionHelp(for: kind, state: state))
            }
        }
        .font(.subheadline)
    }

    private func permissionSystemImage(for kind: PermissionKind) -> String {
        switch kind {
        case .microphone:
            "mic.fill"
        case .accessibility:
            "accessibility"
        case .screenCapture:
            "rectangle.on.rectangle"
        }
    }

    private func permissionActionTitle(for kind: PermissionKind, state: PermissionState) -> String {
        switch (kind, state) {
        case (.microphone, .unknown):
            "Allow"
        case (.microphone, .denied):
            "Open"
        case (.accessibility, _), (.screenCapture, _):
            "Open"
        case (_, .granted):
            "Granted"
        }
    }

    private func permissionHelp(for kind: PermissionKind, state: PermissionState) -> String {
        switch (kind, state) {
        case (_, .granted):
            return "\(kind.displayName) permission is already granted"
        case (.microphone, .unknown):
            return "Ask macOS for Microphone permission"
        case (.microphone, .denied):
            return "Open Microphone privacy settings"
        case (.accessibility, _):
            return "Open Accessibility privacy settings for focused-field insertion"
        case (.screenCapture, _):
            return "Open Screen Recording privacy settings"
        }
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

            if let insertionTarget = transcript.insertionTarget {
                Text("Target: \(insertionTarget.displayName)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 10) {
                if coordinator.canCopyTranscript(transcript) {
                    Button("Copy") {
                        coordinator.copyTranscript(transcript)
                    }
                    .buttonStyle(.bordered)
                    .help("Copy this transcript to the clipboard")
                }

                if coordinator.canInsertTranscript(transcript) {
                    Button("Insert") {
                        coordinator.insertTranscript(transcript)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!coordinator.canInsertSavedTranscriptNow)
                    .help(historyInsertionHelp)
                }

                Button("Open Session Folder") {
                    coordinator.openTranscriptSessionFolder(transcript)
                }
                .buttonStyle(.bordered)

                if coordinator.canTranscribeRecoveredSession(transcript) {
                    Button("Transcribe") {
                        coordinator.transcribeRecoveredSession(transcript)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(coordinator.isRecording || coordinator.isProcessingCapture)
                    .help(recoveredTranscriptionHelp)
                }

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
                .disabled(!coordinator.canModifyHistoryNow)
                .help(historyMutationHelp("Remove this transcript from History"))
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var historyInsertionHelp: String {
        if coordinator.canInsertSavedTranscriptNow {
            return "Insert this transcript into the focused field"
        }

        return "Finish the current capture before inserting a saved transcript"
    }

    private var recoveredTranscriptionHelp: String {
        if coordinator.isRecording || coordinator.isProcessingCapture {
            return "Finish the current capture before retrying transcription"
        }

        return "Retry local transcription for this recovered audio session"
    }

    private func historyMutationHelp(_ readyMessage: String) -> String {
        if coordinator.canModifyHistoryNow {
            return readyMessage
        }

        return "Finish the current capture before changing History"
    }

    private var testDictationHelp: String {
        if coordinator.isProcessingCapture {
            return "Wait for transcription to finish before starting another test"
        }

        if coordinator.isRecording {
            return "Stop the current test dictation"
        }

        return "Start a short app-owned recording test"
    }

    private var insertionProbeHelp: String {
        if coordinator.isRecording || coordinator.isProcessingCapture {
            return "Finish the current capture before running an insertion probe"
        }

        if coordinator.isFocusedInsertionProbePending {
            return "Insertion probe is already waiting; focus a target text field"
        }

        if !permissionCenter.accessibility.isGranted {
            return "Run a focused-field probe; without Accessibility it should exercise clipboard recovery"
        }

        return "Run a focused-field insertion probe after a short countdown"
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

    private func modelTaskPickerTitle(for task: ModelTask) -> String {
        switch task {
        case .streamingDictation:
            "Quick Dictation Speech"
        case .longSessionTranscription:
            "Long Session Speech"
        case .meetingTranscription:
            "Meeting Transcript Speech"
        case .formatting:
            "Cleanup Formatting"
        case .commands:
            "Voice Command Formatting"
        case .meetingSummary:
            "Meeting Speaker Pass"
        }
    }

    private func modelTaskHelp(for task: ModelTask) -> String {
        switch task {
        case .streamingDictation:
            "Transcribes short dictation. Cleanup is controlled by the Cleanup Formatting row."
        case .longSessionTranscription:
            "Transcribes long recordings before optional cleanup runs."
        case .meetingTranscription:
            "Transcribes meeting audio and produces timing data for the speaker pass."
        case .formatting:
            "Cleans up Quick Dictation and Long Session text when cleanup is enabled."
        case .commands:
            "Interprets command-style dictation."
        case .meetingSummary:
            "Runs the optional meeting speaker-label pass after transcription."
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
