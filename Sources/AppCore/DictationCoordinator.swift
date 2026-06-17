import AppKit
import Combine
import Foundation
import ModelRouting
import OSLog
import UniformTypeIdentifiers

private let pipelineLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.hungkienluu.myownvoice",
    category: "DictationPipeline"
)

private struct TranscribedCapture {
    let text: String
    let timedSegments: [TimedTranscriptSegment]
}

@MainActor
public final class DictationCoordinator: ObservableObject {
    @Published public var sessionMode: SessionMode = .quickDictation
    @Published public var preferences: ModelPreferences
    @Published public var recordingPreferences: RecordingPreferences
    @Published public private(set) var isRecording = false
    @Published public private(set) var isProcessingCapture = false
    @Published public private(set) var statusMessage = "Ready."
    @Published public private(set) var lastTranscript: String?
    @Published public private(set) var recentTranscripts: [RecentTranscript]
    @Published public private(set) var shortcutSummary: String
    @Published public private(set) var shortcutAttentionMessage: String?
    @Published public private(set) var localModelRuntimeStatus = "Checking local model runtime..."
    @Published public private(set) var speechRecognitionRuntimeStatus = "WhisperKit will prepare on first transcription."
    @Published public private(set) var installedRuntimeModels: [String] = []
    @Published public private(set) var missingRuntimeModels: [String] = []
    @Published public private(set) var lastGemmaCheckResult: String?
    @Published public private(set) var isPreparingLocalRuntime = false
    @Published public private(set) var isFocusedInsertionProbePending = false

    public let permissionCenter: PermissionCenter
    public let modelRegistry: InMemoryModelRegistry
    public let modelRouter: DefaultModelRouter

    private let hotkeyManager: HotkeyManager
    private let audioCaptureService: AudioCaptureService
    private let insertionService: FocusedTextInsertionService
    private let ollamaService: OllamaService
    private let injectedSpeechRecognitionEngine: (any SpeechRecognitionEngine)?
    private let meetingTranscriptService: MeetingTranscriptService
    private let runtimeSetupService: OllamaRuntimeSetupService
    private let recordingIndicatorPresenter: (any RecordingIndicatorPresenting)?
    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let historyFileURL: URL

    private let defaultOllamaModel = "gemma4"
    private var cancellables: Set<AnyCancellable> = []
    private var isHoldToRecordActive = false
    private var isHoldToRecordLatched = false
    private var holdShortcutPressedAt: Date?
    private var pendingHoldStopTask: Task<Void, Never>?
    private var postPasteLearningTask: Task<Void, Never>?
    private var focusedInsertionProbeTask: Task<Void, Never>?
    private var deferredCleanupTasks: [UUID: Task<Void, Never>] = [:]
    private var postInsertionVerificationTasks: [UUID: Task<Void, Never>] = [:]
    private var lastTranscriptID: UUID?
    private var lastTranscriptMode: SessionMode?
    private var activeCaptureMode: SessionMode?
    private var activeHUDRecordingStartedAt: Date?
    private var activeDictationHUDSnapshot: DictationHUDSnapshot?
    private var speechRecognitionEnginesByModelID: [String: any SpeechRecognitionEngine] = [:]

    private static let modelPreferencesKey = "MyOwnVoice.modelPreferences"
    private static let recordingPreferencesKey = "MyOwnVoice.recordingPreferences"
    private static let holdShortcutTapThreshold: TimeInterval = 0.22
    private static let holdShortcutDoubleTapWindowNanoseconds: UInt64 = 320_000_000
    nonisolated static let recentTranscriptHistoryLimit = 25
    nonisolated private static let previousTranscriptContextCharacterLimit = 4_000
    nonisolated private static let localCleanupCharacterLimit = 20_000

    private static func makeSessionsDirectoryURL(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MyOwnVoice", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
    }

    public init(
        permissionCenter: PermissionCenter = PermissionCenter(),
        modelRegistry: InMemoryModelRegistry = DefaultModelCatalog.seededRegistry(),
        hotkeyManager: HotkeyManager = HotkeyManager(),
        audioCaptureService: AudioCaptureService = AudioCaptureService(),
        insertionService: FocusedTextInsertionService = FocusedTextInsertionService(),
        ollamaService: OllamaService = OllamaService(),
        speechRecognitionEngine: (any SpeechRecognitionEngine)? = nil,
        recordingIndicatorPresenter: (any RecordingIndicatorPresenting)? = nil,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        let loadedPreferences = Self.loadValue(
            from: userDefaults,
            key: Self.modelPreferencesKey,
            fallback: ModelPreferences()
        )
        let loadedRecordingPreferences = Self.loadValue(
            from: userDefaults,
            key: Self.recordingPreferencesKey,
            fallback: RecordingPreferences()
        ).normalized()
        let historyFileURL = Self.makeHistoryFileURL(fileManager: fileManager)
        let loadedHistory = Self.normalizeHistory(Self.loadHistory(from: historyFileURL))
        let recoveredHistory = Self.recoveredHistory(
            from: audioCaptureService.recoverableCaptureSessions(),
            excluding: loadedHistory
        )

        self.permissionCenter = permissionCenter
        self.modelRegistry = modelRegistry
        self.modelRouter = DefaultModelRouter(registry: modelRegistry)
        self.hotkeyManager = hotkeyManager
        self.audioCaptureService = audioCaptureService
        self.insertionService = insertionService
        self.ollamaService = ollamaService
        self.injectedSpeechRecognitionEngine = speechRecognitionEngine
        self.meetingTranscriptService = MeetingTranscriptService(
            ollamaService: ollamaService
        )
        self.runtimeSetupService = OllamaRuntimeSetupService(
            ollamaService: ollamaService
        )
        self.recordingIndicatorPresenter = recordingIndicatorPresenter
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        self.historyFileURL = historyFileURL
        self.preferences = loadedPreferences
        self.recordingPreferences = loadedRecordingPreferences
        self.recentTranscripts = Array((recoveredHistory + loadedHistory).prefix(Self.recentTranscriptHistoryLimit))
        self.shortcutSummary = Self.makeShortcutSummary(from: loadedRecordingPreferences)

        hotkeyManager.onPress = { [weak self] action in
            Task { @MainActor in
                self?.handleHotkeyPress(action)
            }
        }

        hotkeyManager.onRelease = { [weak self] action in
            Task { @MainActor in
                self?.handleHotkeyRelease(action)
            }
        }

        bindPermissionUpdates()
        bindPersistence()
        registerConfiguredHotkeys()
        permissionCenter.refresh()
        refreshStatus()

        if !recoveredHistory.isEmpty {
            statusMessage = "Recovered \(recoveredHistory.count) interrupted audio session(s). Open History to inspect the saved chunks."
        }

        saveValue(loadedRecordingPreferences, key: Self.recordingPreferencesKey)

        if let whisperKitEngine = speechRecognitionEngine as? WhisperKitTranscriptionEngine {
            configureSpeechRecognitionStatusUpdates(for: whisperKitEngine)
        }

        Task { @MainActor in
            await refreshLocalModelRuntime()
        }

    }

    public var canUseSelectedFormattingRuntime: Bool {
        guard let modelName = resolvedOllamaModelName(for: .formatting) else {
            return false
        }

        return installedRuntimeModels.contains(where: { installedModel in
            installedModel == modelName
        })
    }

    public func refreshPermissions() {
        permissionCenter.refresh()
        refreshStatus()
    }

    public func requestPermission(_ kind: PermissionKind) {
        permissionCenter.request(kind)

        switch kind {
        case .microphone:
            refreshStatus()
        case .accessibility:
            statusMessage = "Accessibility settings opened. Return to the app after enabling it."
        case .screenCapture:
            statusMessage = "Screen Capture settings opened. This permission is reserved for a future capture flow and is not required for the current microphone-only meeting transcript mode."
        }
    }

    public func toggleRecordingFromUI() {
        guard !isProcessingCapture else {
            statusMessage = "Please wait for the current transcription to finish."
            return
        }

        if isRecording {
            stopRecording(triggerInsertion: recordingPreferences.autoInsertIntoFocusedField)
        } else {
            startRecording(trigger: "menu")
        }
    }

    public func toggleRecordingFromHotkey() {
        guard !isProcessingCapture else {
            statusMessage = "Please wait for the current transcription to finish."
            return
        }

        if isRecording {
            stopRecording(triggerInsertion: recordingPreferences.autoInsertIntoFocusedField)
        } else {
            startRecording(trigger: "toggle shortcut")
        }
    }

    public func selectAudioFileForTranscription() {
        guard !isRecording, !isProcessingCapture else {
            statusMessage = "Finish the current capture before importing an audio file."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Transcribe Audio File"
        panel.message = "Choose an existing audio file to transcribe locally."
        panel.prompt = "Transcribe"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]

        NSApplication.shared.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let fileURL = panel.url else {
            return
        }

        transcribeImportedAudioFile(at: fileURL)
    }

    public func applyShortcut(_ shortcut: KeyboardShortcut, for action: HotkeyAction) {
        let normalizedShortcut = shortcut.normalized()
        guard normalizedShortcut.isSupportedGlobalShortcut else {
            shortcutAttentionMessage = Self.unsupportedShortcutMessage(
                UnsupportedShortcut(action: action, shortcut: normalizedShortcut)
            )
            statusMessage = "\(action.displayName) needs at least one modifier key. Choose a modifier-only shortcut or a chord."
            return
        }

        var updatedPreferences = recordingPreferences

        switch action {
        case .holdToRecord:
            updatedPreferences.holdToRecordShortcut = normalizedShortcut
        case .toggleRecording:
            updatedPreferences.toggleRecordingShortcut = normalizedShortcut
        }

        if let conflict = Self.shortcutConflict(in: updatedPreferences) {
            let conflictingAction = conflict.action == action ? conflict.otherAction : conflict.action
            shortcutAttentionMessage = Self.shortcutConflictMessage(conflict)
            statusMessage = "\(normalizedShortcut.displayName) is already assigned to \(conflictingAction.displayName)."
            return
        }

        recordingPreferences = updatedPreferences
        statusMessage = "\(action.displayName) updated to \(normalizedShortcut.displayName)."
    }

    public func restoreDefaultShortcut(for action: HotkeyAction) {
        applyShortcut(action.defaultShortcut, for: action)
    }

    public func restoreDefaultShortcuts() {
        recordingPreferences.holdToRecordShortcut = .defaultHoldToRecord
        recordingPreferences.toggleRecordingShortcut = .defaultToggleRecording
        statusMessage = "Restored the default recording shortcuts."
    }

    public func isDefaultShortcut(for action: HotkeyAction) -> Bool {
        shortcut(for: action).hasSameKeyEquivalent(as: action.defaultShortcut)
    }

    public func shortcutStatusMessage(for action: HotkeyAction) -> String {
        let currentShortcut = shortcut(for: action)
        if !currentShortcut.isSupportedGlobalShortcut {
            return "Needs a modifier key"
        }

        if let conflict = Self.shortcutConflict(in: recordingPreferences),
           conflict.action == action || conflict.otherAction == action {
            let otherAction = conflict.action == action ? conflict.otherAction : conflict.action
            return "Conflict with \(otherAction.displayName)"
        }

        return currentShortcut.isModifierOnly ? "Modifier-only global shortcut" : "Registered global shortcut"
    }

    public func shortcutNeedsAttention(for action: HotkeyAction) -> Bool {
        if !shortcut(for: action).isSupportedGlobalShortcut {
            return true
        }

        guard let conflict = Self.shortcutConflict(in: recordingPreferences) else {
            return false
        }

        return conflict.action == action || conflict.otherAction == action
    }

    public func copyLastTranscript() {
        guard let lastTranscript else {
            statusMessage = "There is no transcript to copy yet."
            return
        }
        guard Self.hasUsableTranscriptText(lastTranscript) else {
            statusMessage = "The latest transcript is empty, so there is nothing to copy."
            return
        }

        copyToPasteboard(
            textForClipboard(
                transcript: lastTranscript,
                mode: lastTranscriptMode
            )
        )
        statusMessage = "Copied the latest transcript."
    }

    public func copyTranscript(_ transcript: RecentTranscript) {
        guard canCopyTranscript(transcript) else {
            statusMessage = "This History row is a capture recovery status, not transcript text to copy."
            return
        }

        copyToPasteboard(
            textForClipboard(
                transcript: transcript.text,
                mode: transcript.mode
            )
        )
        statusMessage = "Copied the selected transcript."
    }

    public func insertLastTranscript() {
        guard canInsertSavedTranscriptNow else {
            statusMessage = "Finish the current capture before inserting a saved transcript."
            return
        }

        guard let lastTranscript else {
            statusMessage = "There is no transcript to insert yet."
            return
        }
        guard Self.hasUsableTranscriptText(lastTranscript) else {
            statusMessage = "The latest transcript is empty, so there is nothing to insert."
            return
        }

        let result = insertionService.insert(
            text: textForClipboard(
                transcript: lastTranscript,
                mode: lastTranscriptMode
            )
        )
        schedulePostPasteLearningIfNeeded(from: result)
        let updatedTranscriptID = updateLatestTranscriptInsertion(
            text: lastTranscript,
            mode: lastTranscriptMode,
            insertionResult: result
        )
        if let updatedTranscriptID {
            schedulePostInsertionVerificationIfNeeded(from: result, transcriptID: updatedTranscriptID)
        }
        statusMessage = result.message
    }

    public func insertTranscript(_ transcript: RecentTranscript) {
        guard canInsertSavedTranscriptNow else {
            statusMessage = "Finish the current capture before inserting a saved transcript."
            return
        }

        guard canInsertTranscript(transcript) else {
            statusMessage = "This History row is a capture recovery status, not insertable dictation text."
            return
        }

        let result = insertionService.insert(
            text: textForClipboard(
                transcript: transcript.text,
                mode: transcript.mode
            )
        )
        schedulePostPasteLearningIfNeeded(from: result)
        updateTranscript(
            id: transcript.id,
            insertionResult: result
        )
        schedulePostInsertionVerificationIfNeeded(from: result, transcriptID: transcript.id)
        statusMessage = result.message
    }

    public func scheduleFocusedInsertionProbe() {
        guard Self.canRunFocusedInsertionProbe(
            isRecording: isRecording,
            isProcessingCapture: isProcessingCapture
        ) else {
            statusMessage = "Finish the current capture before running an insertion probe."
            return
        }

        guard !isFocusedInsertionProbePending else {
            statusMessage = "Insertion probe is already waiting. Click into a target field."
            return
        }

        let probeText = TranscriptFormatting.applyDictationCommands(
            "my own voice insertion probe new line second line"
        )

        isFocusedInsertionProbePending = true
        statusMessage = "Click into a target text field. Insertion probe runs in 5 seconds."

        focusedInsertionProbeTask?.cancel()
        focusedInsertionProbeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }

            if Task.isCancelled {
                finishPendingFocusedInsertionProbe()
                return
            }

            guard Self.canRunFocusedInsertionProbe(
                isRecording: isRecording,
                isProcessingCapture: isProcessingCapture
            ) else {
                finishPendingFocusedInsertionProbe(
                    statusMessage: "Insertion probe canceled because recording or transcription started."
                )
                return
            }

            let result = insertionService.insert(text: probeText)
            isFocusedInsertionProbePending = false
            statusMessage = result.message

            let recent = RecentTranscript(
                mode: .quickDictation,
                text: probeText,
                insertionOutcome: result.outcome,
                insertionMessage: "Focused insertion probe: \(result.message)",
                insertionTarget: result.target,
                chunkCount: 0,
                sessionDirectoryPath: Self.makeSessionsDirectoryURL(fileManager: fileManager).path
            )

            recentTranscripts.insert(recent, at: 0)
            trimRecentTranscriptsToHistoryLimit()
            setLatestTranscript(from: recent)
            schedulePostInsertionVerificationIfNeeded(from: result, transcriptID: recent.id)
            focusedInsertionProbeTask = nil
        }
    }

    nonisolated static func canRunFocusedInsertionProbe(
        isRecording: Bool,
        isProcessingCapture: Bool
    ) -> Bool {
        !isRecording && !isProcessingCapture
    }

    nonisolated static func shouldCancelFocusedInsertionProbe(
        isPending: Bool,
        isRecording: Bool,
        isProcessingCapture: Bool
    ) -> Bool {
        isPending &&
            !canRunFocusedInsertionProbe(
                isRecording: isRecording,
                isProcessingCapture: isProcessingCapture
            )
    }

    public func canTranscribeRecoveredSession(_ transcript: RecentTranscript) -> Bool {
        Self.hasAvailableRetryableCaptureFiles(transcript, fileManager: fileManager)
    }

    public func canCopyTranscript(_ transcript: RecentTranscript) -> Bool {
        Self.hasCopyableTranscriptText(transcript)
    }

    public func canInsertTranscript(_ transcript: RecentTranscript) -> Bool {
        Self.hasInsertableTranscriptText(transcript) &&
            !canTranscribeRecoveredSession(transcript)
    }

    public var canInsertSavedTranscriptNow: Bool {
        Self.canRunSavedTranscriptInsertion(
            isRecording: isRecording,
            isProcessingCapture: isProcessingCapture
        )
    }

    public var canModifyHistoryNow: Bool {
        Self.canRunHistoryMutation(
            isRecording: isRecording,
            isProcessingCapture: isProcessingCapture
        )
    }

    nonisolated static func canRunSavedTranscriptInsertion(
        isRecording: Bool,
        isProcessingCapture: Bool
    ) -> Bool {
        !isRecording && !isProcessingCapture
    }

    nonisolated static func canRunHistoryMutation(
        isRecording: Bool,
        isProcessingCapture: Bool
    ) -> Bool {
        !isRecording && !isProcessingCapture
    }

    public func transcribeRecoveredSession(_ transcript: RecentTranscript) {
        guard !isRecording, !isProcessingCapture else {
            statusMessage = "Finish the current capture before transcribing a recovered session."
            return
        }

        guard let captureResult = recoveredCaptureResult(from: transcript) else {
            statusMessage = "The recovered session manifest or audio chunks are no longer available."
            return
        }

        sessionMode = transcript.mode
        isProcessingCapture = true
        cancelFocusedInsertionProbeIfNeeded()
        showTranscribingHUD(
            mode: transcript.mode,
            completedChunks: 0,
            totalChunks: Self.recoverableAudioChunks(in: captureResult, fileManager: fileManager).count,
            detail: "Transcribing recovered audio chunks."
        )
        statusMessage = "Transcribing recovered session with \(captureResult.chunks.count) saved chunk(s)..."

        Task { @MainActor in
            await processCaptureResult(
                captureResult,
                triggerInsertion: false,
                replacingTranscriptID: transcript.id,
                mode: transcript.mode
            )
        }
    }

    public func removeTranscript(_ transcript: RecentTranscript) {
        guard canModifyHistoryNow else {
            statusMessage = "Finish the current capture before changing History."
            return
        }

        cancelDeferredHistoryTasks(for: transcript.id)
        recentTranscripts.removeAll { $0.id == transcript.id }
        reconcileLatestTranscriptAfterRemoving(transcriptID: transcript.id)
        statusMessage = "Removed the selected transcript from history."
    }

    public func clearRecentTranscripts() {
        guard canModifyHistoryNow else {
            statusMessage = "Finish the current capture before clearing History."
            return
        }

        for task in postInsertionVerificationTasks.values {
            task.cancel()
        }
        postInsertionVerificationTasks.removeAll()
        for task in deferredCleanupTasks.values {
            task.cancel()
        }
        deferredCleanupTasks.removeAll()
        cancelPostPasteLearning()
        cancelFocusedInsertionProbe()
        recentTranscripts.removeAll()
        clearLatestTranscript()
        statusMessage = "Cleared saved transcript history."
    }

    public func openSessionsFolder() {
        let url = Self.makeSessionsDirectoryURL(fileManager: fileManager)

        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            statusMessage = "Could not open the Sessions folder: \(error.localizedDescription)"
            return
        }

        NSWorkspace.shared.open(url)
        statusMessage = "Opened the Sessions folder in Finder."
    }

    public func openTranscriptSessionFolder(_ transcript: RecentTranscript) {
        let url = URL(fileURLWithPath: transcript.sessionDirectoryPath, isDirectory: true)
        guard fileManager.fileExists(atPath: url.path) else {
            statusMessage = "The saved audio chunk folder is no longer available."
            return
        }

        NSWorkspace.shared.open(url)
        statusMessage = "Opened the session folder in Finder."
    }

    public func openTranscriptArtifact(_ transcript: RecentTranscript) {
        guard let exportedArtifactPath = transcript.exportedArtifactPath else {
            statusMessage = "This transcript does not have a saved export file yet."
            return
        }

        let artifactURL = URL(fileURLWithPath: exportedArtifactPath)
        guard fileManager.fileExists(atPath: artifactURL.path) else {
            statusMessage = "The saved transcript export is no longer available."
            return
        }

        NSWorkspace.shared.open(artifactURL)
        statusMessage = "Opened the saved transcript export."
    }

    public func recommendedModelName(for task: ModelTask) -> String {
        modelRouter.recommendedModel(for: task, preferences: preferences)?.displayName ?? "Not configured"
    }

    public func automaticModelLabel(for task: ModelTask) -> String {
        "Automatic: \(recommendedModelName(for: task))"
    }

    public func availableModels(for task: ModelTask) -> [LocalModel] {
        modelRouter.availableModels(for: task)
    }

    public func shortcut(for action: HotkeyAction) -> KeyboardShortcut {
        switch action {
        case .holdToRecord:
            recordingPreferences.holdToRecordShortcut
        case .toggleRecording:
            recordingPreferences.toggleRecordingShortcut
        }
    }

    public func selectedModelID(for task: ModelTask) -> String? {
        if let pinnedModelID = preferences.pinnedModelID(for: task),
           modelRegistry.model(id: pinnedModelID) != nil {
            return pinnedModelID
        }

        return modelRouter.recommendedModel(for: task, preferences: preferences)?.id
    }

    private func resolvedSpeechRecognitionModel(for task: ModelTask) -> LocalModel {
        modelRouter.recommendedModel(for: task, preferences: preferences)
            ?? DefaultModelCatalog.seededRegistry().model(id: DefaultModelCatalog.defaultWhisperKitModelID)!
    }

    private func speechRecognitionEngine(for task: ModelTask) -> any SpeechRecognitionEngine {
        if let injectedSpeechRecognitionEngine {
            return injectedSpeechRecognitionEngine
        }

        return speechRecognitionEngine(for: resolvedSpeechRecognitionModel(for: task))
    }

    private func speechRecognitionEngine(for model: LocalModel) -> any SpeechRecognitionEngine {
        if let cachedEngine = speechRecognitionEnginesByModelID[model.id] {
            return cachedEngine
        }

        let engine = makeSpeechRecognitionEngine(for: model)
        speechRecognitionEnginesByModelID[model.id] = engine
        return engine
    }

    private func makeSpeechRecognitionEngine(for model: LocalModel) -> any SpeechRecognitionEngine {
        let whisperCPPFallback = LocalWhisperCPPTranscriptionEngine(model: model)
        let modelName = DefaultModelCatalog.whisperKitModelName(for: model.id)
            ?? DefaultModelCatalog.defaultWhisperKitModelName
        let whisperKitEngine = WhisperKitTranscriptionEngine(
            model: model,
            fallbackEngine: whisperCPPFallback,
            modelName: modelName
        )
        configureSpeechRecognitionStatusUpdates(for: whisperKitEngine)
        return whisperKitEngine
    }

    private func configureSpeechRecognitionStatusUpdates(for engine: WhisperKitTranscriptionEngine) {
        engine.onStatusChange = { [weak self] status in
            self?.speechRecognitionRuntimeStatus = status
        }
    }

    private func resolvedOllamaModel(for task: ModelTask) -> LocalModel? {
        guard let model = modelRouter.recommendedModel(for: task, preferences: preferences),
              model.localPathHint.hasPrefix("Ollama local tag:") else {
            return nil
        }

        return model
    }

    private func resolvedOllamaModelName(for task: ModelTask) -> String? {
        resolvedOllamaModel(for: task)?.id
    }

    private func resolvedMeetingSpeakerAttributionModelName() async -> String? {
        if let modelName = resolvedOllamaModelName(for: .meetingSummary) {
            return modelName
        }

        if installedRuntimeModels.isEmpty {
            await refreshLocalModelRuntime()
        }

        return resolvedOllamaModelName(for: .meetingSummary)
    }

    private func requiredOllamaModels() -> [String] {
        let explicitlyPinned = [ModelTask.formatting, .meetingSummary]
            .compactMap { preferences.pinnedModelID(for: $0) }
            .map { pinnedID in
                modelRegistry.model(id: pinnedID)?.id ?? pinnedID
            }

        if !explicitlyPinned.isEmpty {
            return Array(Set(explicitlyPinned)).sorted()
        }

        if installedRuntimeModels.isEmpty {
            return [defaultOllamaModel]
        }

        return []
    }

    public func refreshLocalModelRuntime() async {
        let diagnostics = await runtimeSetupService.inspect(requiredModels: requiredOllamaModels())

        installedRuntimeModels = diagnostics.installedModels
        modelRegistry.syncOllamaModelNames(diagnostics.installedModels)
        missingRuntimeModels = diagnostics.missingRequiredModels

        if diagnostics.serverReachable && !diagnostics.installedModels.isEmpty {
            let selectedFormattingModel = recommendedModelName(for: .formatting)
            localModelRuntimeStatus = "Ollama is running with \(diagnostics.installedModels.count) installed model(s). Cleanup is currently set to \(selectedFormattingModel)."
        } else if diagnostics.serverReachable && diagnostics.installedModels.isEmpty {
            localModelRuntimeStatus = "Ollama is running, but no local models are installed yet."
        } else if diagnostics.appInstalled || diagnostics.cliAvailable {
            localModelRuntimeStatus = "Ollama is installed, but the local runtime is not running yet. Use Set Up Runtime to open it."
        } else {
            localModelRuntimeStatus = "Ollama is not installed yet. Use Set Up Runtime to download it from the official site."
        }
    }

    public func setUpLocalModelRuntime() async {
        guard !isPreparingLocalRuntime else { return }

        isPreparingLocalRuntime = true
        defer { isPreparingLocalRuntime = false }

        do {
            _ = try await runtimeSetupService.prepareRuntime(
                requiredModels: requiredOllamaModels()
            ) { [weak self] message in
                self?.localModelRuntimeStatus = message
            }
            await refreshLocalModelRuntime()

            if canUseSelectedFormattingRuntime {
                statusMessage = "Local runtime setup is complete. \(recommendedModelName(for: .formatting)) is ready."
            } else {
                statusMessage = "Local runtime setup needs one more step. Finish the Ollama install, then run setup again."
            }
        } catch {
            statusMessage = "Local runtime setup failed: \(error.localizedDescription)"
            await refreshLocalModelRuntime()
        }
    }

    public func runSelectedFormattingModelCheck() async {
        let formattingModelName = recommendedModelName(for: .formatting)
        statusMessage = "Running a local formatting check with \(formattingModelName)..."

        if installedRuntimeModels.isEmpty {
            await refreshLocalModelRuntime()
        }

        guard let modelName = resolvedOllamaModelName(for: .formatting) else {
            statusMessage = "No compatible Ollama formatting model is available yet."
            return
        }

        let sampleDictation = "tomorrow morning remind me to send the contract and thank jen for the quick turnaround"

        do {
            let response = try await ollamaService.generate(
                model: modelName,
                system: transcriptCorrectionEngine.cleanupPrompt(
                    basePrompt: recordingPreferences.cleanupPrompt
                ),
                prompt: Self.cleanupRequestPrompt(for: sampleDictation)
            )

            lastGemmaCheckResult = applyCorrections(to: response)
            statusMessage = "\(formattingModelName) formatted a local sample successfully."
        } catch {
            statusMessage = "\(formattingModelName) formatting check failed: \(error.localizedDescription)"
        }
    }

    public func prepareSpeechRecognitionEngine() async {
        await prepareSpeechRecognitionEngine(for: transcriptionTask(for: sessionMode))
    }

    private func prepareSpeechRecognitionEngine(for task: ModelTask) async {
        if let injectedSpeechRecognitionEngine {
            do {
                try await injectedSpeechRecognitionEngine.prepare()
            } catch {
                speechRecognitionRuntimeStatus = "WhisperKit could not be prepared. The app will keep using whisper.cpp when needed."
            }
            return
        }

        let model = resolvedSpeechRecognitionModel(for: task)
        do {
            try await speechRecognitionEngine(for: model).prepare()
        } catch {
            speechRecognitionRuntimeStatus = "\(model.displayName) could not be prepared. The app will keep using whisper.cpp when needed."
        }
    }

    private func handleHotkeyPress(_ action: HotkeyAction) {
        switch action {
        case .holdToRecord:
            startHoldToRecordFromHotkey()
        case .toggleRecording:
            toggleRecordingFromHotkey()
        }
    }

    private func handleHotkeyRelease(_ action: HotkeyAction) {
        guard action == .holdToRecord else { return }
        endHoldToRecordFromHotkey()
    }

    private func startHoldToRecordFromHotkey() {
        guard !isProcessingCapture else {
            statusMessage = "Please wait for the current transcription to finish."
            return
        }

        holdShortcutPressedAt = .now

        if recordingPreferences.enableDoubleTapHoldToToggle {
            if pendingHoldStopTask != nil && isRecording {
                cancelPendingHoldStopTask()
                isHoldToRecordLatched = true
                statusMessage = "Recording locked on. Tap Hold to Record once or use Toggle Recording to stop."
                return
            }

            if isHoldToRecordLatched && isRecording {
                isHoldToRecordActive = true
                return
            }
        }

        guard !isRecording else { return }
        startRecording(trigger: "hold shortcut")
        isHoldToRecordActive = isRecording
    }

    private func endHoldToRecordFromHotkey() {
        let wasQuickTap = isQuickHoldTap(releasedAt: .now)
        holdShortcutPressedAt = nil

        if recordingPreferences.enableDoubleTapHoldToToggle && isHoldToRecordLatched {
            guard isHoldToRecordActive else { return }
            isHoldToRecordActive = false
            stopRecording(triggerInsertion: recordingPreferences.autoInsertIntoFocusedField)
            return
        }

        guard isHoldToRecordActive else { return }
        isHoldToRecordActive = false

        if recordingPreferences.enableDoubleTapHoldToToggle && wasQuickTap {
            schedulePendingHoldStop()
        } else {
            stopRecording(triggerInsertion: recordingPreferences.autoInsertIntoFocusedField)
        }
    }

    private func startRecording(trigger: String) {
        permissionCenter.refresh()

        guard permissionCenter.microphone.isGranted else {
            statusMessage = "Microphone permission is required before recording can start."
            return
        }

        let captureMode = sessionMode

        do {
            try audioCaptureService.start()
            isRecording = true
            activeCaptureMode = captureMode
            activeHUDRecordingStartedAt = .now
            cancelFocusedInsertionProbeIfNeeded()
            showRecordingHUD(
                mode: captureMode,
                trigger: trigger,
                startedAt: activeHUDRecordingStartedAt ?? .now
            )

            let transcriptionModel = recommendedModelName(for: transcriptionTask(for: captureMode))

            if captureMode == .meetingTranscript {
                statusMessage = "Meeting capture started from the \(trigger). Routing through \(transcriptionModel) and saving a timestamped transcript after you stop."
            } else {
                let formattingModel = recommendedModelName(for: .formatting)
                statusMessage = "Recording started from the \(trigger). Routing through \(transcriptionModel) with \(formattingModel) for cleanup."
            }
        } catch {
            activeCaptureMode = nil
            activeHUDRecordingStartedAt = nil
            hideDictationHUD()
            statusMessage = "Could not start audio capture: \(error.localizedDescription)"
        }
    }

    private func transcribeImportedAudioFile(at fileURL: URL) {
        guard !isRecording, !isProcessingCapture else {
            statusMessage = "Finish the current capture before importing an audio file."
            return
        }

        let importMode = sessionMode
        isProcessingCapture = true
        cancelFocusedInsertionProbeIfNeeded()
        showDictationHUD(
            DictationHUDSnapshot(
                phase: .transcribing,
                mode: importMode,
                title: "Preparing Import",
                detail: "Copying \(fileURL.lastPathComponent) into a local session."
            )
        )
        statusMessage = "Preparing \(fileURL.lastPathComponent) for local transcription..."

        Task { @MainActor in
            await processImportedAudioFile(at: fileURL, mode: importMode)
        }
    }

    private func stopRecording(triggerInsertion: Bool) {
        resetHoldShortcutState()
        guard isRecording else { return }
        let captureMode = Self.resolvedCaptureMode(
            activeCaptureMode: activeCaptureMode,
            currentMode: sessionMode
        )
        activeCaptureMode = nil
        isRecording = false
        activeHUDRecordingStartedAt = nil

        guard let captureResult = audioCaptureService.stop() else {
            showFailureHUD(
                mode: captureMode,
                message: "Recording stopped, but no capture result was produced."
            )
            statusMessage = "Recording stopped, but no capture result was produced."
            return
        }

        let recoverableChunkCount = Self.recoverableAudioChunks(
            in: captureResult,
            fileManager: fileManager
        ).count
        guard recoverableChunkCount > 0 else {
            handleEmptyCaptureResult(captureResult, mode: captureMode)
            return
        }

        isProcessingCapture = true
        showTranscribingHUD(
            mode: captureMode,
            completedChunks: 0,
            totalChunks: recoverableChunkCount,
            detail: captureMode == .meetingTranscript
                ? "Preparing local meeting transcription."
                : "Preparing local Whisper transcription."
        )
        statusMessage = captureMode == .meetingTranscript
            ? "Captured \(captureResult.chunks.count) chunk(s). Building a local meeting transcript..."
            : "Captured \(captureResult.chunks.count) chunk(s). Starting local Whisper transcription..."

        Task { @MainActor in
            await processCaptureResult(
                captureResult,
                triggerInsertion: triggerInsertion,
                mode: captureMode
            )
        }
    }

    private func processImportedAudioFile(at fileURL: URL, mode: SessionMode) async {
        do {
            let captureResult = try await audioCaptureService.importExistingAudioFile(at: fileURL)
            let importedFileName = fileURL.lastPathComponent

            statusMessage = mode == .meetingTranscript
                ? "Imported \(importedFileName). Building a local meeting transcript..."
                : "Imported \(importedFileName). Starting local Whisper transcription..."

            await processCaptureResult(captureResult, triggerInsertion: false, mode: mode)
        } catch {
            isProcessingCapture = false
            let message = "Could not import \(fileURL.lastPathComponent): \(error.localizedDescription)"
            showFailureHUD(mode: mode, message: message)
            statusMessage = message
        }
    }

    private func handleEmptyCaptureResult(
        _ captureResult: AudioCaptureResult,
        mode: SessionMode
    ) {
        try? fileManager.removeItem(at: captureResult.directoryURL)
        statusMessage = Self.emptyCaptureStatusMessage(
            captureDuration: Self.captureDuration(captureResult)
        )
        showSavedHUD(
            mode: mode,
            title: "Nothing Captured",
            detail: "Start again when you are ready.",
            previewText: nil,
            recoveryText: statusMessage
        )
    }

    private func refreshStatus() {
        if isRecording {
            statusMessage = "Recording..."
            return
        }

        guard !Self.shouldPreserveActiveStatus(
            isProcessingCapture: isProcessingCapture,
            isFocusedInsertionProbePending: isFocusedInsertionProbePending
        ) else {
            return
        }

        if !permissionCenter.microphone.isGranted {
            statusMessage = "Microphone permission is still missing."
        } else if recordingPreferences.autoInsertIntoFocusedField && !permissionCenter.accessibility.isGranted {
            statusMessage = "Accessibility is still missing, so automatic insertion will copy transcripts to the clipboard for manual paste."
        } else {
            statusMessage = "Ready."
        }
    }

    private func showDictationHUD(_ snapshot: DictationHUDSnapshot) {
        activeDictationHUDSnapshot = snapshot.isTerminal ? nil : snapshot
        recordingIndicatorPresenter?.showDictationHUD(
            snapshot,
            style: recordingPreferences.dictationHUDStyle
        )
    }

    private func hideDictationHUD() {
        activeDictationHUDSnapshot = nil
        recordingIndicatorPresenter?.hideRecordingIndicator()
    }

    private func refreshActiveDictationHUDStyle(using preferences: RecordingPreferences) {
        guard let activeDictationHUDSnapshot else { return }

        recordingIndicatorPresenter?.showDictationHUD(
            activeDictationHUDSnapshot,
            style: preferences.dictationHUDStyle
        )
    }

    private func showRecordingHUD(mode: SessionMode, trigger: String, startedAt: Date) {
        let detail: String

        switch mode {
        case .quickDictation:
            detail = "Listening from the \(trigger). Release or stop to insert."
        case .longSession:
            detail = "Listening from the \(trigger). Audio is saved in rolling chunks."
        case .meetingTranscript:
            detail = "Meeting capture is running until you stop it."
        }

        showDictationHUD(
            DictationHUDSnapshot(
                phase: .recording,
                mode: mode,
                title: "Recording",
                detail: detail,
                startedAt: startedAt,
                previewText: nil
            )
        )
    }

    private func showTranscribingHUD(
        mode: SessionMode,
        completedChunks: Int,
        totalChunks: Int,
        previewText: String? = nil,
        detail: String? = nil
    ) {
        let safeTotalChunks = max(totalChunks, 0)
        let safeCompletedChunks = min(max(completedChunks, 0), max(safeTotalChunks, 1))
        let progress = Self.hudProgress(completedChunks: safeCompletedChunks, totalChunks: safeTotalChunks)
        let progressLabel: String?

        if safeTotalChunks > 0 {
            if safeCompletedChunks >= safeTotalChunks {
                progressLabel = "\(safeTotalChunks) of \(safeTotalChunks) chunk(s) transcribed"
            } else {
                progressLabel = "Chunk \(safeCompletedChunks + 1) of \(safeTotalChunks)"
            }
        } else {
            progressLabel = nil
        }

        showDictationHUD(
            DictationHUDSnapshot(
                phase: .transcribing,
                mode: mode,
                title: mode == .meetingTranscript ? "Building Transcript" : "Transcribing",
                detail: detail ?? "Running local Whisper transcription.",
                progress: progress,
                progressLabel: progressLabel,
                previewText: previewText
            )
        )
    }

    private func showPolishingHUD(mode: SessionMode, previewText: String?) {
        showDictationHUD(
            DictationHUDSnapshot(
                phase: .polishing,
                mode: mode,
                title: "Polishing",
                detail: "Applying local cleanup and your correction rules.",
                progressLabel: "Formatting locally",
                previewText: previewText
            )
        )
    }

    private func showSavedHUD(
        mode: SessionMode,
        title: String,
        detail: String,
        previewText: String?,
        recoveryText: String? = nil
    ) {
        showDictationHUD(
            DictationHUDSnapshot(
                phase: .saved,
                mode: mode,
                title: title,
                detail: detail,
                previewText: previewText,
                recoveryText: recoveryText
            )
        )
    }

    private func showCompletionHUD(
        insertionResult: TextInsertionResult,
        transcript: String,
        mode: SessionMode,
        triggerInsertion: Bool,
        recoveryText: String? = nil
    ) {
        let phase = Self.hudTerminalPhase(
            for: insertionResult.outcome,
            triggerInsertion: triggerInsertion
        )
        let title: String
        let detail: String

        switch phase {
        case .inserted:
            title = "Inserted"
            detail = insertionResult.target.map { "Text appeared in \($0.applicationName)." }
                ?? "Text appeared in the focused field."
        case .recovery:
            title = "Recovery Ready"
            detail = insertionResult.target.map { "Saved for \($0.applicationName)." }
                ?? "Saved and copied for recovery."
        case .saved:
            title = "Saved"
            detail = "Transcript is ready in History."
        case .failed:
            title = "Needs Attention"
            detail = "The transcript could not be inserted."
        case .recording, .transcribing, .polishing, .inserting:
            title = "Ready"
            detail = insertionResult.message
        }

        showDictationHUD(
            DictationHUDSnapshot(
                phase: phase,
                mode: mode,
                title: title,
                detail: detail,
                previewText: Self.hudPreviewText(from: transcript),
                recoveryText: recoveryText ?? insertionResult.message
            )
        )
    }

    private func showFailureHUD(mode: SessionMode, message: String) {
        showDictationHUD(
            DictationHUDSnapshot(
                phase: .failed,
                mode: mode,
                title: "Needs Attention",
                detail: "Dictation could not finish.",
                recoveryText: message
            )
        )
    }

    nonisolated static func hudProgress(completedChunks: Int, totalChunks: Int) -> Double? {
        guard totalChunks > 0 else { return nil }
        return min(max(Double(completedChunks) / Double(totalChunks), 0), 1)
    }

    nonisolated static func hudPreviewText(from transcript: String, maxCharacters: Int = 180) -> String? {
        let collapsed = transcript
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        guard maxCharacters > 3 else { return String(collapsed.prefix(max(maxCharacters, 0))) }
        guard collapsed.count > maxCharacters else { return collapsed }

        return "..." + String(collapsed.suffix(maxCharacters - 3))
    }

    nonisolated static func hudTerminalPhase(
        for insertionOutcome: InsertionOutcome,
        triggerInsertion: Bool
    ) -> DictationHUDPhase {
        guard triggerInsertion else { return .saved }

        switch insertionOutcome {
        case .insertedDirectly:
            return .inserted
        case .pastedViaClipboardFallback, .failed:
            return .recovery
        case .notAttempted:
            return .saved
        }
    }

    nonisolated static func shouldPreserveActiveStatus(
        isProcessingCapture: Bool,
        isFocusedInsertionProbePending: Bool
    ) -> Bool {
        isProcessingCapture || isFocusedInsertionProbePending
    }

    private func registerConfiguredHotkeys() {
        if let unsupportedShortcut = Self.unsupportedShortcut(in: recordingPreferences) {
            hotkeyManager.unregister()
            shortcutAttentionMessage = Self.unsupportedShortcutMessage(unsupportedShortcut)
            shortcutSummary = "Shortcuts need attention"
            statusMessage = Self.unsupportedShortcutMessage(unsupportedShortcut)
            return
        }

        if let conflict = Self.shortcutConflict(in: recordingPreferences) {
            hotkeyManager.unregister()
            shortcutAttentionMessage = Self.shortcutConflictMessage(conflict)
            shortcutSummary = "Shortcuts need attention"
            statusMessage = Self.shortcutConflictMessage(conflict)
            return
        }

        let shortcuts = Self.shortcutMap(from: recordingPreferences)

        do {
            try hotkeyManager.register(shortcuts: shortcuts)
            shortcutAttentionMessage = nil
            shortcutSummary = Self.makeShortcutSummary(from: recordingPreferences)
        } catch {
            shortcutAttentionMessage = "macOS could not register one of these shortcuts. Choose another chord if it is already used by another app."
            shortcutSummary = "Shortcuts need attention"
            statusMessage = "Global shortcut registration failed: \(error.localizedDescription)"
        }
    }

    private func bindPermissionUpdates() {
        permissionCenter.$microphone
            .combineLatest(permissionCenter.$accessibility, permissionCenter.$screenCapture)
            .sink { [weak self] _, _, _ in
                self?.refreshStatus()
            }
            .store(in: &cancellables)
    }

    private func bindPersistence() {
        $preferences
            .dropFirst()
            .sink { [weak self] preferences in
                self?.saveValue(preferences, key: Self.modelPreferencesKey)
            }
            .store(in: &cancellables)

        $recordingPreferences
            .dropFirst()
            .sink { [weak self] preferences in
                guard let self else { return }
                saveValue(preferences, key: Self.recordingPreferencesKey)
                shortcutSummary = Self.makeShortcutSummary(from: preferences)

                let configuredShortcuts = Self.shortcutMap(from: preferences)
                if hotkeyManager.registeredShortcuts != configuredShortcuts {
                    registerConfiguredHotkeys()
                } else if let conflict = Self.shortcutConflict(in: preferences) {
                    shortcutAttentionMessage = Self.shortcutConflictMessage(conflict)
                } else {
                    shortcutAttentionMessage = nil
                }

                refreshStatus()
                refreshActiveDictationHUDStyle(using: preferences)
            }
            .store(in: &cancellables)

        $recentTranscripts
            .dropFirst()
            .sink { [weak self] transcripts in
                self?.saveHistory(transcripts)
            }
            .store(in: &cancellables)
    }

    private func processCaptureResult(
        _ captureResult: AudioCaptureResult,
        triggerInsertion: Bool,
        replacingTranscriptID: UUID? = nil,
        mode: SessionMode? = nil
    ) async {
        let currentSessionMode = Self.resolvedCaptureMode(
            activeCaptureMode: mode,
            currentMode: sessionMode
        )

        defer {
            isProcessingCapture = false
        }

        do {
            let pipelineStartedAt = ProcessInfo.processInfo.systemUptime
            let task = transcriptionTask(for: currentSessionMode)
            let transcribedCapture = try await transcribeCaptureResult(
                captureResult,
                task: task,
                mode: currentSessionMode
            )
            let transcriptionElapsedMs = elapsedMilliseconds(since: pipelineStartedAt)
            let initialTranscript = applyLocalFormatting(
                to: transcribedCapture.text,
                mode: currentSessionMode
            )
            guard Self.hasUsableTranscriptText(initialTranscript) else {
                throw NSError(
                    domain: "MyOwnVoice.Transcription",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Transcription produced no insertable text after formatting."]
                )
            }

            if currentSessionMode == .meetingTranscript {
                let correctedSegments = correctedTimedSegments(from: transcribedCapture.timedSegments)
                let cleanedTranscript = TranscriptFormatting.cleanMeetingTranscriptText(initialTranscript)
                let speakerAttributionModelName = await resolvedMeetingSpeakerAttributionModelName()
                let meetingTranscript = await meetingTranscriptService.buildTranscript(
                    sessionID: captureResult.sessionID,
                    startedAt: captureResult.startedAt,
                    endedAt: captureResult.endedAt,
                    rawTranscript: cleanedTranscript,
                    sourceSegments: correctedSegments,
                    speakerAttributionModelName: speakerAttributionModelName
                )
                let exportedFiles = try meetingTranscriptService.save(
                    meetingTranscript,
                    in: captureResult.directoryURL
                )

                let recent = RecentTranscript(
                    mode: currentSessionMode,
                    text: meetingTranscript.annotatedTranscript,
                    insertionOutcome: .notAttempted,
                    insertionMessage: "Meeting transcript saved locally.",
                    chunkCount: captureResult.chunks.count,
                    sessionDirectoryPath: captureResult.directoryURL.path,
                    exportedArtifactPath: exportedFiles.markdownURL.path,
                    speakerLabels: meetingTranscript.speakers.map(\.displayName)
                )

                removeTranscriptFromHistoryIfNeeded(replacingTranscriptID)
                recentTranscripts.insert(recent, at: 0)
                trimRecentTranscriptsToHistoryLimit()
                setLatestTranscript(from: recent)
                statusMessage = "Meeting transcript saved with \(meetingTranscript.speakers.count) speaker(s)."
                showSavedHUD(
                    mode: currentSessionMode,
                    title: "Meeting Saved",
                    detail: "Timestamped transcript is ready in History.",
                    previewText: Self.hudPreviewText(from: meetingTranscript.annotatedTranscript),
                    recoveryText: "Saved markdown and JSON files in the session folder."
                )

                pipelineLogger.info(
                    "Meeting transcript finished in \(self.elapsedMilliseconds(since: pipelineStartedAt), privacy: .public) ms (ASR: \(transcriptionElapsedMs, privacy: .public) ms) for session \(captureResult.sessionID.uuidString, privacy: .public)"
                )
                return
            }

            if shouldDeferCleanup(
                mode: currentSessionMode,
                transcript: initialTranscript,
                captureDuration: Self.captureDuration(captureResult)
            ) {
                let insertionResult = insertTranscript(
                    initialTranscript,
                    triggerInsertion: triggerInsertion
                )
                let recent = RecentTranscript(
                    mode: currentSessionMode,
                    text: initialTranscript,
                    insertionOutcome: insertionResult.outcome,
                    insertionMessage: insertionResult.message,
                    insertionTarget: insertionResult.target,
                    chunkCount: captureResult.chunks.count,
                    sessionDirectoryPath: captureResult.directoryURL.path
                )

                removeTranscriptFromHistoryIfNeeded(replacingTranscriptID)
                recentTranscripts.insert(recent, at: 0)
                trimRecentTranscriptsToHistoryLimit()
                setLatestTranscript(from: recent)
                schedulePostInsertionVerificationIfNeeded(from: insertionResult, transcriptID: recent.id)
                statusMessage = initialStatusMessage(
                    from: insertionResult,
                    cleanupDeferred: true,
                    triggerInsertion: triggerInsertion
                )
                showCompletionHUD(
                    insertionResult: insertionResult,
                    transcript: initialTranscript,
                    mode: currentSessionMode,
                    triggerInsertion: triggerInsertion,
                    recoveryText: statusMessage
                )

                pipelineLogger.info(
                    "Initial transcript ready in \(self.elapsedMilliseconds(since: pipelineStartedAt), privacy: .public) ms (ASR: \(transcriptionElapsedMs, privacy: .public) ms, cleanup deferred) for session \(captureResult.sessionID.uuidString, privacy: .public)"
                )

                scheduleDeferredCleanup(
                    initialTranscript,
                    mode: currentSessionMode,
                    recentTranscriptID: recent.id,
                    sessionID: captureResult.sessionID
                )
                return
            }

            let cleanupStartedAt = ProcessInfo.processInfo.systemUptime
            let formattedTranscript: String
            let cleanupFailureRecoveryText: String?
            do {
                formattedTranscript = try await maybeFormatTranscript(
                    transcribedCapture.text,
                    mode: currentSessionMode
                )
                cleanupFailureRecoveryText = nil
            } catch {
                let recoveryText = Self.cleanupFailureRecoveryText(
                    errorDescription: error.localizedDescription
                )
                pipelineLogger.error(
                    "Transcript cleanup failed for session \(captureResult.sessionID.uuidString, privacy: .public); saving raw transcript: \(error.localizedDescription, privacy: .public)"
                )
                formattedTranscript = transcribedCapture.text
                cleanupFailureRecoveryText = recoveryText
            }
            let cleanupElapsedMs = elapsedMilliseconds(since: cleanupStartedAt)
            let transcript = Self.cleanupTranscriptOrFallback(
                candidate: applyLocalFormatting(
                    to: formattedTranscript,
                    mode: currentSessionMode
                ),
                fallback: initialTranscript
            )

            let insertionResult = insertTranscript(transcript, triggerInsertion: triggerInsertion)

            let recent = RecentTranscript(
                mode: currentSessionMode,
                text: transcript,
                insertionOutcome: insertionResult.outcome,
                insertionMessage: insertionResult.message,
                insertionTarget: insertionResult.target,
                chunkCount: captureResult.chunks.count,
                sessionDirectoryPath: captureResult.directoryURL.path
            )

            removeTranscriptFromHistoryIfNeeded(replacingTranscriptID)
            recentTranscripts.insert(recent, at: 0)
            trimRecentTranscriptsToHistoryLimit()
            setLatestTranscript(from: recent)
            schedulePostInsertionVerificationIfNeeded(from: insertionResult, transcriptID: recent.id)
            statusMessage = Self.completionStatusMessage(
                insertionMessage: insertionResult.message,
                cleanupFailureRecoveryText: cleanupFailureRecoveryText
            )
            showCompletionHUD(
                insertionResult: insertionResult,
                transcript: transcript,
                mode: currentSessionMode,
                triggerInsertion: triggerInsertion,
                recoveryText: cleanupFailureRecoveryText
            )

            pipelineLogger.info(
                "Transcript pipeline finished in \(self.elapsedMilliseconds(since: pipelineStartedAt), privacy: .public) ms (ASR: \(transcriptionElapsedMs, privacy: .public) ms, cleanup: \(cleanupElapsedMs, privacy: .public) ms) for session \(captureResult.sessionID.uuidString, privacy: .public)"
            )
        } catch {
            pipelineLogger.error(
                "Transcript pipeline failed for session \(captureResult.sessionID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            saveFailedCaptureHistoryEntry(
                captureResult,
                mode: currentSessionMode,
                error: error,
                replacingTranscriptID: replacingTranscriptID
            )
            clearLatestTranscript()
            statusMessage = "Local transcription failed: \(error.localizedDescription)"
            showFailureHUD(mode: currentSessionMode, message: statusMessage)
        }
    }

    private func transcribeCaptureResult(
        _ captureResult: AudioCaptureResult,
        task: ModelTask,
        mode: SessionMode
    ) async throws -> TranscribedCapture {
        var accumulatedTranscript = ""
        var timedSegments = [TimedTranscriptSegment]()
        let chunks = Self.recoverableAudioChunks(in: captureResult, fileManager: fileManager)

        guard !chunks.isEmpty else {
            throw NSError(
                domain: "MyOwnVoice.Transcription",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "No recoverable audio chunks were captured."]
            )
        }

        let speechRecognitionEngine = speechRecognitionEngine(for: task)

        for (index, chunk) in chunks.enumerated() {
            showTranscribingHUD(
                mode: mode,
                completedChunks: index,
                totalChunks: chunks.count,
                previewText: Self.hudPreviewText(from: accumulatedTranscript)
            )
            statusMessage = "Transcribing chunk \(index + 1) of \(chunks.count) locally with \(speechRecognitionEngine.model.displayName)..."
            let promptContext = Self.speechRecognitionPromptContext(
                accumulatedTranscript: accumulatedTranscript,
                correctionEngine: transcriptCorrectionEngine,
                mode: mode
            )

            let segment = try await speechRecognitionEngine.transcribeChunk(
                audioFileURL: chunk.fileURL,
                previousTranscript: promptContext,
                task: task
            )

            let text = (task == .meetingTranscription
                ? TranscriptFormatting.cleanMeetingTranscriptText(segment.text)
                : segment.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let chunkOffset = max(0, chunk.startedAt.timeIntervalSince(captureResult.startedAt))

            if accumulatedTranscript.isEmpty {
                accumulatedTranscript = text
            } else {
                accumulatedTranscript += "\n" + text
            }

            if segment.timedSegments.isEmpty {
                if task == .meetingTranscription {
                    timedSegments.append(
                        TimedTranscriptSegment(
                            text: text,
                            startOffsetSeconds: chunkOffset,
                            endOffsetSeconds: max(
                                chunkOffset,
                                chunk.endedAt.timeIntervalSince(captureResult.startedAt)
                            )
                        )
                    )
                }
            } else {
                timedSegments.append(
                    contentsOf: segment.timedSegments.map { $0.offsetBy(chunkOffset) }
                )
            }

            showTranscribingHUD(
                mode: mode,
                completedChunks: index + 1,
                totalChunks: chunks.count,
                previewText: Self.hudPreviewText(from: accumulatedTranscript),
                detail: index + 1 == chunks.count
                    ? "Local transcription is ready for formatting."
                    : "Local transcription is building as chunks finish."
            )
        }

        if accumulatedTranscript.isEmpty {
            throw NSError(
                domain: "MyOwnVoice.Transcription",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Whisper returned an empty transcript."]
            )
        }

        return TranscribedCapture(
            text: accumulatedTranscript,
            timedSegments: timedSegments
        )
    }

    nonisolated static func boundedPreviousTranscriptContext(_ transcript: String) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.suffix(previousTranscriptContextCharacterLimit))
    }

    nonisolated static func speechRecognitionPromptContext(
        accumulatedTranscript: String,
        correctionEngine: TranscriptCorrectionEngine,
        mode: SessionMode
    ) -> String? {
        let previousTranscript = boundedPreviousTranscriptContext(accumulatedTranscript)
        guard mode == .quickDictation else {
            return previousTranscript
        }

        return correctionEngine.speechRecognitionPromptContext(
            previousTranscript: previousTranscript
        )
    }

    private func transcriptionTask(for mode: SessionMode) -> ModelTask {
        switch mode {
        case .quickDictation:
            return .streamingDictation
        case .longSession:
            return .longSessionTranscription
        case .meetingTranscript:
            return .meetingTranscription
        }
    }

    private func correctedTimedSegments(
        from segments: [TimedTranscriptSegment]
    ) -> [TimedTranscriptSegment] {
        segments.compactMap { segment in
            let correctedText = TranscriptFormatting.cleanMeetingTranscriptText(
                applyCorrections(to: segment.text)
            )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !correctedText.isEmpty else { return nil }

            return TimedTranscriptSegment(
                id: segment.id,
                text: correctedText,
                startOffsetSeconds: segment.startOffsetSeconds,
                endOffsetSeconds: segment.endOffsetSeconds,
                speakerID: segment.speakerID,
                speakerLabel: segment.speakerLabel,
                words: segment.words
            )
        }
    }

    private func maybeFormatTranscript(
        _ transcript: String,
        mode: SessionMode,
        updatesStatus: Bool = true
    ) async throws -> String {
        guard let formattingModelName = resolvedOllamaModelName(for: .formatting) else {
            return transcript
        }

        guard (mode == .quickDictation || mode == .longSession),
              recordingPreferences.enableCleanup else {
            return transcript
        }

        if Self.shouldSkipLocalCleanupForTranscript(transcript, mode: mode) {
            if updatesStatus {
                statusMessage = "Transcript is long, so it was saved without local cleanup to keep the app responsive."
                showDictationHUD(
                    DictationHUDSnapshot(
                        phase: .saved,
                        mode: mode,
                        title: "Saved Raw",
                        detail: "The transcript is long, so cleanup was skipped to keep the app responsive.",
                        previewText: Self.hudPreviewText(from: transcript),
                        recoveryText: "The raw transcript is saved in History."
                    )
                )
            }

            return transcript
        }

        if updatesStatus {
            statusMessage = "Polishing the transcript locally with \(recommendedModelName(for: .formatting))..."
            showPolishingHUD(
                mode: mode,
                previewText: Self.hudPreviewText(from: transcript)
            )
        }

        let cleanupPrompt = transcriptCorrectionEngine.cleanupPrompt(
            basePrompt: recordingPreferences.cleanupPrompt
        )

        return try await ollamaService.generate(
            model: formattingModelName,
            system: cleanupPrompt,
            prompt: Self.cleanupRequestPrompt(for: transcript)
        )
    }

    nonisolated static func cleanupRequestPrompt(for transcript: String) -> String {
        TranscriptCorrectionEngine.cleanupRequestPrompt(for: transcript)
    }

    nonisolated static func shouldSkipLocalCleanupForTranscript(
        _ transcript: String,
        mode: SessionMode
    ) -> Bool {
        guard mode == .quickDictation || mode == .longSession else {
            return false
        }

        return transcript.count > localCleanupCharacterLimit
    }

    private func finishDeferredCleanup(
        _ rawTranscript: String,
        mode: SessionMode,
        recentTranscriptID: UUID,
        sessionID: UUID
    ) async {
        defer {
            deferredCleanupTasks[recentTranscriptID] = nil
        }

        let cleanupStartedAt = ProcessInfo.processInfo.systemUptime

        do {
            let formattedTranscript = try await maybeFormatTranscript(
                rawTranscript,
                mode: mode,
                updatesStatus: false
            )
            let polishedTranscript = Self.cleanupTranscriptOrFallback(
                candidate: applyLocalFormatting(to: formattedTranscript, mode: mode),
                fallback: rawTranscript
            )
            let cleanupElapsedMs = elapsedMilliseconds(since: cleanupStartedAt)
            guard !Task.isCancelled else { return }

            if let index = recentTranscripts.firstIndex(where: { $0.id == recentTranscriptID }) {
                let existing = recentTranscripts[index]
                guard Self.canApplyDeferredCleanupResult(
                    isTaskCancelled: Task.isCancelled,
                    transcript: existing
                ) else {
                    return
                }

                recentTranscripts[index] = RecentTranscript(
                    id: existing.id,
                    createdAt: existing.createdAt,
                    mode: existing.mode,
                    text: polishedTranscript,
                    insertionOutcome: existing.insertionOutcome,
                    insertionMessage: existing.insertionMessage,
                    insertionTarget: existing.insertionTarget,
                    chunkCount: existing.chunkCount,
                    sessionDirectoryPath: existing.sessionDirectoryPath,
                    captureManifestPath: existing.captureManifestPath,
                    exportedArtifactPath: existing.exportedArtifactPath,
                    speakerLabels: existing.speakerLabels,
                    isStatusOnly: existing.isStatusOnly
                )
                refreshClipboardRecoveryAfterDeferredCleanup(
                    rawTranscript: rawTranscript,
                    polishedTranscript: polishedTranscript,
                    insertionOutcome: existing.insertionOutcome
                )
            }

            if recentTranscripts.first?.id == recentTranscriptID {
                lastTranscript = polishedTranscript
                lastTranscriptID = recentTranscriptID
                lastTranscriptMode = mode

                if !isRecording && !isProcessingCapture {
                    statusMessage = deferredCleanupFinishedMessage(for: recentTranscripts.first)
                    showSavedHUD(
                        mode: mode,
                        title: "Polished",
                        detail: "The cleaned transcript is ready in History.",
                        previewText: Self.hudPreviewText(from: polishedTranscript),
                        recoveryText: statusMessage
                    )
                }
            }

            pipelineLogger.info(
                "Deferred cleanup finished in \(cleanupElapsedMs, privacy: .public) ms for session \(sessionID.uuidString, privacy: .public)"
            )
        } catch {
            guard !Task.isCancelled else { return }
            pipelineLogger.error(
                "Deferred cleanup failed for session \(sessionID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func scheduleDeferredCleanup(
        _ rawTranscript: String,
        mode: SessionMode,
        recentTranscriptID: UUID,
        sessionID: UUID
    ) {
        deferredCleanupTasks[recentTranscriptID]?.cancel()
        deferredCleanupTasks[recentTranscriptID] = Task { @MainActor [weak self] in
            await self?.finishDeferredCleanup(
                rawTranscript,
                mode: mode,
                recentTranscriptID: recentTranscriptID,
                sessionID: sessionID
            )
        }
    }

    private func shouldDeferCleanup(
        mode: SessionMode,
        transcript: String,
        captureDuration: TimeInterval
    ) -> Bool {
        Self.shouldDeferCleanup(
            mode: mode,
            recordingPreferences: recordingPreferences,
            hasFormattingModel: resolvedOllamaModelName(for: .formatting) != nil,
            transcript: transcript,
            captureDuration: captureDuration
        )
    }

    nonisolated static func shouldDeferCleanup(
        mode: SessionMode,
        recordingPreferences: RecordingPreferences,
        hasFormattingModel: Bool,
        transcript: String = "",
        captureDuration: TimeInterval = 0
    ) -> Bool {
        guard mode == .quickDictation else {
            return false
        }

        guard recordingPreferences.enableCleanup,
              recordingPreferences.preferFastTranscriptFeedback,
              hasFormattingModel else {
            return false
        }

        return !shouldWaitForCleanupBeforeInsertion(
            mode: mode,
            transcript: transcript,
            captureDuration: captureDuration
        )
    }

    nonisolated static func shouldWaitForCleanupBeforeInsertion(
        mode: SessionMode,
        transcript _: String,
        captureDuration _: TimeInterval
    ) -> Bool {
        switch mode {
        case .longSession:
            return true
        case .meetingTranscript:
            return false
        case .quickDictation:
            return false
        }
    }

    nonisolated static func cleanupFailureRecoveryText(errorDescription: String) -> String {
        "Local cleanup could not finish (\(errorDescription)), so the raw transcript was saved."
    }

    nonisolated static func completionStatusMessage(
        insertionMessage: String,
        cleanupFailureRecoveryText: String?
    ) -> String {
        guard let cleanupFailureRecoveryText else {
            return insertionMessage
        }

        return "\(insertionMessage) \(cleanupFailureRecoveryText)"
    }

    private func insertTranscript(_ transcript: String, triggerInsertion: Bool) -> TextInsertionResult {
        if triggerInsertion {
            let result = insertionService.insert(text: transcript)
            schedulePostPasteLearningIfNeeded(from: result)
            return result
        }

        return TextInsertionResult(
            outcome: .notAttempted,
            message: "Transcript saved in the app. Copy, insert, or revisit it from History when you are ready."
        )
    }

    private func removeTranscriptFromHistoryIfNeeded(_ transcriptID: UUID?) {
        guard let transcriptID else { return }
        cancelDeferredHistoryTasks(for: transcriptID)
        recentTranscripts.removeAll { $0.id == transcriptID }
        reconcileLatestTranscriptAfterRemoving(transcriptID: transcriptID)
    }

    private func trimRecentTranscriptsToHistoryLimit() {
        let removedTranscriptIDs = Self.transcriptIDsRemovedByHistoryLimit(
            Self.recentTranscriptHistoryLimit,
            in: recentTranscripts
        )
        guard !removedTranscriptIDs.isEmpty else { return }

        for transcriptID in removedTranscriptIDs {
            cancelRowOwnedHistoryTasks(for: transcriptID)
            reconcileLatestTranscriptAfterRemoving(transcriptID: transcriptID)
        }

        recentTranscripts = Array(recentTranscripts.prefix(Self.recentTranscriptHistoryLimit))
    }

    private func cancelDeferredHistoryTasks(for transcriptID: UUID) {
        cancelRowOwnedHistoryTasks(for: transcriptID)
        cancelPostPasteLearning()
    }

    private func cancelRowOwnedHistoryTasks(for transcriptID: UUID) {
        deferredCleanupTasks[transcriptID]?.cancel()
        deferredCleanupTasks[transcriptID] = nil
        postInsertionVerificationTasks[transcriptID]?.cancel()
        postInsertionVerificationTasks[transcriptID] = nil
    }

    private func setLatestTranscript(from transcript: RecentTranscript) {
        guard Self.hasCopyableTranscriptText(transcript) else {
            return
        }

        lastTranscript = transcript.text
        lastTranscriptID = transcript.id
        lastTranscriptMode = transcript.mode
    }

    private func clearLatestTranscript() {
        lastTranscript = nil
        lastTranscriptID = nil
        lastTranscriptMode = nil
    }

    private func finishPendingFocusedInsertionProbe(statusMessage: String? = nil) {
        isFocusedInsertionProbePending = false
        focusedInsertionProbeTask = nil

        if let statusMessage {
            self.statusMessage = statusMessage
        }
    }

    private func cancelFocusedInsertionProbeIfNeeded(statusMessage: String? = nil) {
        guard Self.shouldCancelFocusedInsertionProbe(
            isPending: isFocusedInsertionProbePending,
            isRecording: isRecording,
            isProcessingCapture: isProcessingCapture
        ) else {
            return
        }

        focusedInsertionProbeTask?.cancel()
        finishPendingFocusedInsertionProbe(statusMessage: statusMessage)
    }

    private func cancelFocusedInsertionProbe(statusMessage: String? = nil) {
        guard isFocusedInsertionProbePending else {
            return
        }

        focusedInsertionProbeTask?.cancel()
        finishPendingFocusedInsertionProbe(statusMessage: statusMessage)
    }

    private func reconcileLatestTranscriptAfterRemoving(transcriptID: UUID) {
        guard lastTranscriptID == transcriptID else {
            return
        }

        guard let replacement = Self.latestTranscriptReplacement(in: recentTranscripts) else {
            clearLatestTranscript()
            return
        }

        setLatestTranscript(from: replacement)
    }

    nonisolated static func latestTranscriptReplacement(
        in transcripts: [RecentTranscript]
    ) -> RecentTranscript? {
        transcripts.first(where: hasCopyableTranscriptText(_:))
    }

    private func updateLatestTranscriptInsertion(
        text: String,
        mode: SessionMode?,
        insertionResult: TextInsertionResult
    ) -> UUID? {
        if let lastTranscriptID,
           let transcript = recentTranscripts.first(where: { $0.id == lastTranscriptID }),
           Self.hasInsertableTranscriptText(transcript) {
            updateTranscript(id: lastTranscriptID, insertionResult: insertionResult)
            return lastTranscriptID
        }

        guard let index = Self.matchingTranscriptIndexForLatestInsertion(
            text: text,
            mode: mode,
            in: recentTranscripts
        ) else {
            return nil
        }

        updateTranscript(at: index, insertionResult: insertionResult)
        return recentTranscripts[index].id
    }

    private func updateTranscript(
        id transcriptID: UUID,
        insertionResult: TextInsertionResult
    ) {
        guard let index = recentTranscripts.firstIndex(where: { $0.id == transcriptID }) else {
            return
        }

        updateTranscript(at: index, insertionResult: insertionResult)
    }

    private func updateTranscript(
        at index: Int,
        insertionResult: TextInsertionResult
    ) {
        let existing = recentTranscripts[index]
        recentTranscripts[index] = RecentTranscript(
            id: existing.id,
            createdAt: existing.createdAt,
            mode: existing.mode,
            text: existing.text,
            insertionOutcome: insertionResult.outcome,
            insertionMessage: insertionResult.message,
            insertionTarget: insertionResult.target ?? existing.insertionTarget,
            chunkCount: existing.chunkCount,
            sessionDirectoryPath: existing.sessionDirectoryPath,
            captureManifestPath: existing.captureManifestPath,
            exportedArtifactPath: existing.exportedArtifactPath,
            speakerLabels: existing.speakerLabels,
            isStatusOnly: existing.isStatusOnly
        )
    }

    private func saveFailedCaptureHistoryEntry(
        _ captureResult: AudioCaptureResult,
        mode: SessionMode,
        error: Error,
        replacingTranscriptID: UUID?
    ) {
        let sessionPath = captureResult.directoryURL.path
        let retryableChunkCount = Self.recoverableAudioChunks(in: captureResult, fileManager: fileManager).count
        let retryManifestPath = Self.failedCaptureRetryManifestPath(captureResult, fileManager: fileManager)
        let insertionMessage = Self.failedCaptureInsertionMessage(
            chunkCount: retryableChunkCount,
            hasRetryableManifest: retryManifestPath != nil
        )
        let recent = RecentTranscript(
            id: replacingTranscriptID ?? captureResult.sessionID,
            createdAt: captureResult.startedAt,
            mode: mode,
            text: "Local transcription failed: \(error.localizedDescription)",
            insertionOutcome: .notAttempted,
            insertionMessage: insertionMessage,
            insertionTarget: nil,
            chunkCount: retryableChunkCount,
            sessionDirectoryPath: sessionPath,
            captureManifestPath: retryManifestPath,
            isStatusOnly: true
        )

        let removedTranscriptIDs = Self.transcriptIDsRemovedByFailedCaptureEntry(
            replacingTranscriptID: recent.id,
            sessionDirectoryPath: sessionPath,
            in: recentTranscripts
        )
        for transcriptID in removedTranscriptIDs {
            cancelDeferredHistoryTasks(for: transcriptID)
        }
        recentTranscripts.removeAll { transcript in
            removedTranscriptIDs.contains(transcript.id)
        }
        for transcriptID in removedTranscriptIDs {
            reconcileLatestTranscriptAfterRemoving(transcriptID: transcriptID)
        }
        recentTranscripts.insert(recent, at: 0)
        trimRecentTranscriptsToHistoryLimit()
    }

    nonisolated static func recoverableAudioChunks(
        in captureResult: AudioCaptureResult,
        fileManager: FileManager = .default
    ) -> [AudioChunk] {
        captureResult.chunks.filter { chunk in
            AudioCaptureService.hasRecoverableAudioChunk(at: chunk.fileURL, fileManager: fileManager)
        }
    }

    nonisolated static func failedCaptureRetryManifestPath(
        _ captureResult: AudioCaptureResult,
        fileManager: FileManager = .default
    ) -> String? {
        guard !recoverableAudioChunks(in: captureResult, fileManager: fileManager).isEmpty else {
            return nil
        }

        return captureResult.manifestFileURL?.path
    }

    nonisolated static func failedCaptureInsertionMessage(
        chunkCount: Int,
        hasRetryableManifest: Bool
    ) -> String {
        if hasRetryableManifest {
            return "Saved \(chunkCount) audio chunk(s). Open the session folder or retry transcription from History."
        }

        if chunkCount > 0 {
            return "Saved \(chunkCount) audio chunk(s), but no retry manifest was available. Open the session folder to inspect local files, or record again."
        }

        return "No retryable audio chunks were captured. Open the session folder to inspect local files, or record again."
    }

    private func recoveredCaptureResult(from transcript: RecentTranscript) -> AudioCaptureResult? {
        guard let snapshot = Self.retryableCaptureSnapshot(
            transcript,
            fileManager: fileManager
        ) else {
            return nil
        }

        let endedAt = snapshot.manifest.endedAt
            ?? snapshot.chunks.map(\.endedAt).max()
            ?? Date()

        return AudioCaptureResult(
            sessionID: snapshot.manifest.sessionID,
            directoryURL: URL(fileURLWithPath: transcript.sessionDirectoryPath, isDirectory: true),
            manifestFileURL: snapshot.manifestFileURL,
            startedAt: snapshot.manifest.startedAt,
            endedAt: endedAt,
            chunks: snapshot.chunks
        )
    }

    private func initialStatusMessage(
        from insertionResult: TextInsertionResult,
        cleanupDeferred: Bool,
        triggerInsertion: Bool
    ) -> String {
        guard cleanupDeferred else {
            return insertionResult.message
        }

        if triggerInsertion {
            return "\(insertionResult.message) Cleanup is still running in the background."
        }

        return "Transcript is ready immediately. Cleanup is still running in the background."
    }

    private func deferredCleanupFinishedMessage(for transcript: RecentTranscript?) -> String {
        let transcriptLabel = transcript?.mode == .longSession
            ? "Long-session transcript"
            : "Quick transcript"

        switch transcript?.insertionOutcome {
        case .insertedDirectly:
            return "\(transcriptLabel) inserted. The polished version is now ready in the app."
        case .pastedViaClipboardFallback:
            return "\(transcriptLabel) paste was attempted. The polished version is now ready in the app and clipboard recovery is available."
        case .failed:
            return "\(transcriptLabel) was saved. The polished version is now ready in the app and clipboard recovery is available."
        case .notAttempted, nil:
            return "\(transcriptLabel) is saved. The polished version is now ready in the app."
        }
    }

    nonisolated private static func captureDuration(_ captureResult: AudioCaptureResult) -> TimeInterval {
        max(0, captureResult.endedAt.timeIntervalSince(captureResult.startedAt))
    }

    nonisolated static func emptyCaptureStatusMessage(captureDuration: TimeInterval) -> String {
        if captureDuration < 1 {
            return "Recording was too short to capture audio. Start again and hold for a moment."
        }

        return "No audio was captured. Start again and check microphone input if this repeats."
    }

    private func refreshClipboardRecoveryAfterDeferredCleanup(
        rawTranscript: String,
        polishedTranscript: String,
        insertionOutcome: InsertionOutcome
    ) {
        let clipboardText = NSPasteboard.general.string(forType: .string)
        guard Self.shouldRefreshClipboardRecoveryAfterCleanup(
            rawTranscript: rawTranscript,
            polishedTranscript: polishedTranscript,
            insertionOutcome: insertionOutcome,
            currentClipboardText: clipboardText
        ) else {
            return
        }

        copyToPasteboard(polishedTranscript)
    }

    nonisolated static func shouldRefreshClipboardRecoveryAfterCleanup(
        rawTranscript: String,
        polishedTranscript: String,
        insertionOutcome: InsertionOutcome,
        currentClipboardText: String?
    ) -> Bool {
        switch insertionOutcome {
        case .failed, .pastedViaClipboardFallback:
            break
        case .insertedDirectly, .notAttempted:
            return false
        }

        guard polishedTranscript != rawTranscript,
              hasUsableTranscriptText(polishedTranscript),
              currentClipboardText == rawTranscript else {
            return false
        }

        return true
    }

    nonisolated static func canApplyDeferredCleanupResult(
        isTaskCancelled: Bool,
        transcript: RecentTranscript?
    ) -> Bool {
        guard !isTaskCancelled, let transcript else {
            return false
        }

        return hasCopyableTranscriptText(transcript)
    }

    private func elapsedMilliseconds(since startedAt: TimeInterval) -> Int {
        Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
    }

    private func schedulePostPasteLearningIfNeeded(from result: TextInsertionResult) {
        cancelPostPasteLearning()

        guard recordingPreferences.enablePostPasteCorrectionLearning,
              let context = result.observationContext else {
            return
        }

        postPasteLearningTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.75))
            guard !Task.isCancelled else { return }

            for _ in 0..<30 {
                guard let self, !Task.isCancelled else { return }

                let learnedCorrections = insertionService.detectLearnedCorrections(from: context)
                if !learnedCorrections.isEmpty {
                    applyLearnedCorrections(learnedCorrections)
                    postPasteLearningTask = nil
                    return
                }

                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
            }

            self?.postPasteLearningTask = nil
        }
    }

    private func cancelPostPasteLearning() {
        postPasteLearningTask?.cancel()
        postPasteLearningTask = nil
    }

    private func schedulePostInsertionVerificationIfNeeded(
        from result: TextInsertionResult,
        transcriptID: UUID
    ) {
        guard let context = result.observationContext,
              Self.canRunDelayedInsertionVerification(for: result.outcome) else {
            return
        }

        let originalOutcome = result.outcome
        postInsertionVerificationTasks[transcriptID]?.cancel()
        postInsertionVerificationTasks[transcriptID] = Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                postInsertionVerificationTasks[transcriptID] = nil
            }

            var lastVisibleMismatch = false
            for attempt in 0..<FocusedTextInsertionService.delayedInsertionVerificationAttemptCount {
                let delay = attempt == 0
                    ? FocusedTextInsertionService.delayedInsertionVerificationInitialDelay
                    : FocusedTextInsertionService.delayedInsertionVerificationRetryDelay
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }

                guard let matched = insertionService.currentFocusedTextMatchesInsertion(from: context) else {
                    continue
                }

                if matched {
                    if let verificationResult = Self.delayedInsertionVerificationResult(
                        originalOutcome: originalOutcome,
                        matched: true
                    ) {
                        updateTranscript(id: transcriptID, insertionResult: verificationResult)
                    }
                    return
                }

                lastVisibleMismatch = true
            }

            guard lastVisibleMismatch,
                  let verificationResult = Self.delayedInsertionVerificationResult(
                    originalOutcome: originalOutcome,
                    matched: false
                  ) else { return }

            updateTranscript(id: transcriptID, insertionResult: verificationResult)
        }
    }

    nonisolated static func canRunDelayedInsertionVerification(for outcome: InsertionOutcome) -> Bool {
        outcome == .pastedViaClipboardFallback || outcome == .failed
    }

    nonisolated static func delayedInsertionVerificationResult(
        originalOutcome: InsertionOutcome,
        matched: Bool
    ) -> TextInsertionResult? {
        switch (originalOutcome, matched) {
        case (.pastedViaClipboardFallback, true):
            return TextInsertionResult(
                outcome: .pastedViaClipboardFallback,
                message: "Clipboard fallback text is visible in the focused field and remains on the clipboard for recovery."
            )
        case (.pastedViaClipboardFallback, false):
            return TextInsertionResult(
                outcome: .failed,
                message: "Clipboard fallback did not appear in the focused field. The transcript remains on the clipboard and in History."
            )
        case (.failed, true):
            return TextInsertionResult(
                outcome: .insertedDirectly,
                message: "Direct Accessibility insertion became visible in the focused field after delayed verification."
            )
        case (.failed, false):
            return TextInsertionResult(
                outcome: .failed,
                message: "Direct Accessibility insertion still could not be verified. The transcript remains on the clipboard and in History."
            )
        case (.notAttempted, _), (.insertedDirectly, _):
            return nil
        }
    }

    private func applyLearnedCorrections(_ learnedCorrections: [LearnedCorrection]) {
        var appliedCount = 0

        for learnedCorrection in learnedCorrections {
            if applyLearnedCorrection(learnedCorrection) {
                appliedCount += 1
            }
        }

        guard appliedCount > 1 else { return }
        statusMessage = "Learned \(appliedCount) corrections. Future dictation will preserve them."
    }

    @discardableResult
    private func applyLearnedCorrection(_ learnedCorrection: LearnedCorrection) -> Bool {
        let normalizedRule = "\(learnedCorrection.wrong) => \(learnedCorrection.right)"

        let existingRules = recordingPreferences.misheardReplacementsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        let existingPreferredTerms = recordingPreferences.preferredTermsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        var didUpdatePreferences = false

        if !existingRules.contains(normalizedRule.lowercased()) {
            recordingPreferences.misheardReplacementsText = appendLine(
                normalizedRule,
                to: recordingPreferences.misheardReplacementsText
            )
            didUpdatePreferences = true
        }

        if !existingPreferredTerms.contains(learnedCorrection.right.lowercased()) {
            recordingPreferences.preferredTermsText = appendLine(
                learnedCorrection.right,
                to: recordingPreferences.preferredTermsText
            )
            didUpdatePreferences = true
        }

        guard didUpdatePreferences else { return false }

        pipelineLogger.info(
            "Learned post-paste correction \(learnedCorrection.wrong, privacy: .public) => \(learnedCorrection.right, privacy: .public)"
        )
        statusMessage = "Learned a correction for \(learnedCorrection.right). Future dictation will preserve it."
        return true
    }

    private func appendLine(_ line: String, to existing: String) -> String {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else { return existing }
        guard !existing.isEmpty else { return trimmedLine }
        return existing + "\n" + trimmedLine
    }

    private func applyCorrections(to text: String) -> String {
        transcriptCorrectionEngine.apply(to: text)
    }

    private func applyLocalFormatting(to text: String, mode: SessionMode) -> String {
        let commandFormattedText: String

        switch mode {
        case .quickDictation, .longSession:
            commandFormattedText = TranscriptFormatting.applyDictationCommands(text)
        case .meetingTranscript:
            commandFormattedText = text
        }

        return applyCorrections(to: commandFormattedText)
    }

    private var transcriptCorrectionEngine: TranscriptCorrectionEngine {
        TranscriptCorrectionEngine(
            preferredTermsText: recordingPreferences.preferredTermsText,
            misheardReplacementsText: recordingPreferences.misheardReplacementsText
        )
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func textForClipboard(
        transcript: String,
        mode: SessionMode?
    ) -> String {
        guard mode == .meetingTranscript else {
            return transcript
        }

        return TranscriptFormatting.cleanMeetingTranscriptText(transcript)
    }

    private func saveValue<Value: Encodable>(_ value: Value, key: String) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value) else { return }
        userDefaults.set(data, forKey: key)
    }

    private func saveHistory(_ transcripts: [RecentTranscript]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(transcripts) else { return }

        try? fileManager.createDirectory(
            at: historyFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: historyFileURL, options: [.atomic])
    }

    private static func loadValue<Value: Decodable>(
        from userDefaults: UserDefaults,
        key: String,
        fallback: Value
    ) -> Value {
        guard let data = userDefaults.data(forKey: key) else {
            return fallback
        }

        return (try? JSONDecoder().decode(Value.self, from: data)) ?? fallback
    }

    private static func makeHistoryFileURL(fileManager: FileManager) -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MyOwnVoice", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)

        return baseURL.appendingPathComponent("recent-transcripts.json")
    }

    private static func loadHistory(from url: URL) -> [RecentTranscript] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RecentTranscript].self, from: data)) ?? []
    }

    private static func normalizeHistory(_ transcripts: [RecentTranscript]) -> [RecentTranscript] {
        transcripts.map { transcript in
            guard transcript.mode == .meetingTranscript else {
                return transcript
            }

            return RecentTranscript(
                id: transcript.id,
                createdAt: transcript.createdAt,
                mode: transcript.mode,
                text: TranscriptFormatting.cleanMeetingTranscriptText(transcript.text),
                insertionOutcome: transcript.insertionOutcome,
                insertionMessage: transcript.insertionMessage,
                insertionTarget: transcript.insertionTarget,
                chunkCount: transcript.chunkCount,
                sessionDirectoryPath: transcript.sessionDirectoryPath,
                captureManifestPath: transcript.captureManifestPath,
                exportedArtifactPath: transcript.exportedArtifactPath,
                speakerLabels: transcript.speakerLabels,
                isStatusOnly: transcript.isStatusOnly
            )
        }
    }

    private static func recoveredHistory(
        from recoveredSessions: [RecoveredAudioCaptureSession],
        excluding loadedHistory: [RecentTranscript]
    ) -> [RecentTranscript] {
        let knownSessionPaths = Set(loadedHistory.map(\.sessionDirectoryPath))

        return recoveredSessions.compactMap { recoveredSession in
            let sessionPath = recoveredSession.directoryURL.path
            guard !knownSessionPaths.contains(sessionPath) else {
                return nil
            }

            return RecentTranscript(
                id: recoveredSession.manifest.sessionID,
                createdAt: recoveredSession.manifest.startedAt,
                mode: .longSession,
                text: "Recovered interrupted audio capture. The source audio chunks are saved locally, but this session did not finish transcription before the app stopped.",
                insertionOutcome: .notAttempted,
                insertionMessage: "Recovered \(recoveredSession.manifest.chunks.count) saved audio chunk(s). Open the session folder to inspect the local files.",
                insertionTarget: nil,
                chunkCount: recoveredSession.manifest.chunks.count,
                sessionDirectoryPath: sessionPath,
                captureManifestPath: recoveredSession.manifestFileURL.path,
                isStatusOnly: true
            )
        }
    }

    nonisolated private static func loadCaptureManifest(from url: URL) -> AudioCaptureManifest? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AudioCaptureManifest.self, from: data)
    }

    nonisolated static func hasRetryableCaptureManifest(_ transcript: RecentTranscript) -> Bool {
        transcript.isStatusOnly &&
            transcript.captureManifestPath != nil &&
            transcript.chunkCount > 0
    }

    nonisolated static func hasAvailableRetryableCaptureFiles(
        _ transcript: RecentTranscript,
        fileManager: FileManager = .default
    ) -> Bool {
        retryableCaptureSnapshot(transcript, fileManager: fileManager) != nil
    }

    nonisolated private static func retryableCaptureSnapshot(
        _ transcript: RecentTranscript,
        fileManager: FileManager
    ) -> (
        manifestFileURL: URL,
        manifest: AudioCaptureManifest,
        chunks: [AudioChunk]
    )? {
        guard hasRetryableCaptureManifest(transcript),
              let captureManifestPath = transcript.captureManifestPath else {
            return nil
        }

        let manifestFileURL = URL(fileURLWithPath: captureManifestPath)
        guard let manifest = loadCaptureManifest(from: manifestFileURL) else {
            return nil
        }

        let chunks = manifest.chunks.filter { chunk in
            AudioCaptureService.hasRecoverableAudioChunk(at: chunk.fileURL, fileManager: fileManager)
        }
        guard !chunks.isEmpty else {
            return nil
        }

        return (manifestFileURL, manifest, chunks)
    }

    nonisolated static func hasInsertableTranscriptText(_ transcript: RecentTranscript) -> Bool {
        guard hasUsableTranscriptText(transcript.text) else { return false }
        return !transcript.isStatusOnly
    }

    nonisolated static func hasCopyableTranscriptText(_ transcript: RecentTranscript) -> Bool {
        hasInsertableTranscriptText(transcript)
    }

    nonisolated static func transcriptIDsRemovedByFailedCaptureEntry(
        replacingTranscriptID: UUID,
        sessionDirectoryPath: String,
        in transcripts: [RecentTranscript]
    ) -> [UUID] {
        transcripts.compactMap { transcript in
            guard transcript.id == replacingTranscriptID ||
                    transcript.sessionDirectoryPath == sessionDirectoryPath else {
                return nil
            }

            return transcript.id
        }
    }

    nonisolated static func transcriptIDsRemovedByHistoryLimit(
        _ limit: Int,
        in transcripts: [RecentTranscript]
    ) -> [UUID] {
        let boundedLimit = max(0, limit)
        guard transcripts.count > boundedLimit else { return [] }
        return transcripts.dropFirst(boundedLimit).map(\.id)
    }

    nonisolated static func matchingTranscriptIndexForLatestInsertion(
        text: String,
        mode: SessionMode?,
        in transcripts: [RecentTranscript]
    ) -> Int? {
        transcripts.firstIndex { transcript in
            transcript.text == text &&
                transcript.mode == mode &&
                hasInsertableTranscriptText(transcript)
        }
    }

    nonisolated static func hasUsableTranscriptText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    nonisolated static func cleanupTranscriptOrFallback(
        candidate: String,
        fallback: String
    ) -> String {
        if hasMeaningfulText(fallback), !hasMeaningfulText(candidate) {
            return fallback
        }

        if hasUsableTranscriptText(candidate) {
            if cleanupCandidateLikelyAnsweredPrompt(source: fallback, candidate: candidate) {
                return fallback
            }

            return candidate
        }

        return fallback
    }

    private nonisolated static func hasMeaningfulText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static func cleanupCandidateLikelyAnsweredPrompt(
        source: String,
        candidate: String
    ) -> Bool {
        let sourceText = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateText = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPromptLikeTranscript(sourceText),
              hasMeaningfulText(sourceText),
              hasMeaningfulText(candidateText) else {
            return false
        }

        if candidateHasAssistantResponsePrefix(candidateText) {
            return true
        }

        let sourceTokens = Set(cleanupComparisonTokens(from: sourceText))
        let candidateTokens = Set(cleanupComparisonTokens(from: candidateText))
        guard sourceTokens.count >= 2, !candidateTokens.isEmpty else {
            return false
        }

        let overlapCount = sourceTokens.intersection(candidateTokens).count
        let extraTokenCount = candidateTokens.subtracting(sourceTokens).count
        let overlapRatio = Double(overlapCount) / Double(sourceTokens.count)
        let extraTokenRatio = Double(extraTokenCount) / Double(sourceTokens.count)
        let extraTokenLimit = sourceTokens.count <= 3 ? 1 : 2

        return overlapRatio < 0.5 || (extraTokenCount >= extraTokenLimit && extraTokenRatio > 0.35)
    }

    private nonisolated static func isPromptLikeTranscript(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized.hasSuffix("?") { return true }

        let prefixes = [
            "answer",
            "can you",
            "compose",
            "could you",
            "create",
            "draft",
            "explain",
            "generate",
            "give me",
            "how",
            "list",
            "make",
            "please",
            "summarize",
            "tell me",
            "translate",
            "what",
            "what's",
            "whats",
            "when",
            "where",
            "which",
            "who",
            "why",
            "would you",
            "write",
        ]

        return prefixes.contains { prefix in
            normalized == prefix || normalized.hasPrefix(prefix + " ")
        }
    }

    private nonisolated static func candidateHasAssistantResponsePrefix(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefixes = [
            "absolutely",
            "answer:",
            "as an ai",
            "certainly",
            "here is",
            "here's",
            "i can",
            "i cannot",
            "i can't",
            "i have",
            "i will",
            "i've",
            "no,",
            "of course",
            "sure",
            "the answer",
            "yes,",
        ]

        return prefixes.contains { prefix in
            normalized == prefix || normalized.hasPrefix(prefix + " ")
        }
    }

    private nonisolated static func cleanupComparisonTokens(from text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { token in
                token.count >= 3 && !cleanupComparisonStopWords.contains(token)
            }
    }

    private nonisolated static let cleanupComparisonStopWords: Set<String> = [
        "about",
        "and",
        "answer",
        "are",
        "can",
        "compose",
        "could",
        "create",
        "draft",
        "explain",
        "for",
        "from",
        "generate",
        "give",
        "had",
        "has",
        "have",
        "how",
        "into",
        "list",
        "make",
        "please",
        "should",
        "summarize",
        "tell",
        "that",
        "the",
        "this",
        "translate",
        "was",
        "were",
        "what",
        "when",
        "where",
        "which",
        "who",
        "why",
        "will",
        "with",
        "would",
        "write",
        "you",
        "your",
    ]

    private struct ShortcutConflict {
        let action: HotkeyAction
        let otherAction: HotkeyAction
        let shortcut: KeyboardShortcut
    }

    private struct UnsupportedShortcut {
        let action: HotkeyAction
        let shortcut: KeyboardShortcut
    }

    private static func shortcutMap(from preferences: RecordingPreferences) -> [HotkeyAction: KeyboardShortcut] {
        [
            .holdToRecord: preferences.holdToRecordShortcut.normalized(),
            .toggleRecording: preferences.toggleRecordingShortcut.normalized()
        ]
    }

    private static func unsupportedShortcut(in preferences: RecordingPreferences) -> UnsupportedShortcut? {
        shortcutMap(from: preferences).compactMap { action, shortcut in
            shortcut.isSupportedGlobalShortcut
                ? nil
                : UnsupportedShortcut(action: action, shortcut: shortcut)
        }
        .first
    }

    private static func unsupportedShortcutMessage(_ unsupportedShortcut: UnsupportedShortcut) -> String {
        "\(unsupportedShortcut.action.displayName) shortcut \(unsupportedShortcut.shortcut.displayName) needs at least one modifier key."
    }

    private static func shortcutConflict(in preferences: RecordingPreferences) -> ShortcutConflict? {
        let shortcuts = shortcutMap(from: preferences)
        let actions = HotkeyAction.allCases

        for lhsIndex in actions.indices {
            for rhsIndex in actions.index(after: lhsIndex)..<actions.endIndex {
                let lhsAction = actions[lhsIndex]
                let rhsAction = actions[rhsIndex]

                guard let lhsShortcut = shortcuts[lhsAction],
                      let rhsShortcut = shortcuts[rhsAction],
                      lhsShortcut.hasSameKeyEquivalent(as: rhsShortcut) else {
                    continue
                }

                return ShortcutConflict(
                    action: lhsAction,
                    otherAction: rhsAction,
                    shortcut: lhsShortcut
                )
            }
        }

        return nil
    }

    private static func shortcutConflictMessage(_ conflict: ShortcutConflict) -> String {
        "\(conflict.shortcut.displayName) is assigned to both \(conflict.action.displayName) and \(conflict.otherAction.displayName)."
    }

    private static func makeShortcutSummary(from preferences: RecordingPreferences) -> String {
        "Hold: \(preferences.holdToRecordShortcut.displayName) · Toggle: \(preferences.toggleRecordingShortcut.displayName)"
    }

    private func isQuickHoldTap(releasedAt: Date) -> Bool {
        guard let holdShortcutPressedAt else { return false }
        return Self.isQuickHoldTap(
            pressedAt: holdShortcutPressedAt,
            releasedAt: releasedAt,
            threshold: Self.holdShortcutTapThreshold
        )
    }

    nonisolated static func isQuickHoldTap(
        pressedAt: Date,
        releasedAt: Date,
        threshold: TimeInterval
    ) -> Bool {
        let elapsed = releasedAt.timeIntervalSince(pressedAt)
        return elapsed >= 0 && elapsed <= threshold
    }

    nonisolated static func resolvedCaptureMode(
        activeCaptureMode: SessionMode?,
        currentMode: SessionMode
    ) -> SessionMode {
        activeCaptureMode ?? currentMode
    }

    private func schedulePendingHoldStop() {
        cancelPendingHoldStopTask()

        pendingHoldStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.holdShortcutDoubleTapWindowNanoseconds)
            await MainActor.run {
                self?.finishPendingHoldStopIfNeeded()
            }
        }
    }

    private func finishPendingHoldStopIfNeeded() {
        guard pendingHoldStopTask != nil else { return }
        pendingHoldStopTask = nil

        guard isRecording else { return }
        stopRecording(triggerInsertion: recordingPreferences.autoInsertIntoFocusedField)
    }

    private func cancelPendingHoldStopTask() {
        pendingHoldStopTask?.cancel()
        pendingHoldStopTask = nil
    }

    private func resetHoldShortcutState() {
        isHoldToRecordActive = false
        isHoldToRecordLatched = false
        holdShortcutPressedAt = nil
        cancelPendingHoldStopTask()
    }
}
