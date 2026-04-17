import AppKit
import Combine
import Foundation
import ModelRouting
import OSLog

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
    @Published public private(set) var localModelRuntimeStatus = "Checking local model runtime..."
    @Published public private(set) var speechRecognitionRuntimeStatus = "Preparing WhisperKit speech model..."
    @Published public private(set) var installedRuntimeModels: [String] = []
    @Published public private(set) var missingRuntimeModels: [String] = []
    @Published public private(set) var lastGemmaCheckResult: String?
    @Published public private(set) var isPreparingLocalRuntime = false

    public let permissionCenter: PermissionCenter
    public let modelRegistry: InMemoryModelRegistry
    public let modelRouter: DefaultModelRouter

    private let hotkeyManager: HotkeyManager
    private let audioCaptureService: AudioCaptureService
    private let insertionService: FocusedTextInsertionService
    private let ollamaService: OllamaService
    private let speechRecognitionEngine: any SpeechRecognitionEngine
    private let meetingTranscriptService: MeetingTranscriptService
    private let runtimeSetupService: OllamaRuntimeSetupService
    private let recordingIndicatorPresenter: (any RecordingIndicatorPresenting)?
    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let historyFileURL: URL

    private let gemmaRuntimeModel = "gemma4"
    private var cancellables: Set<AnyCancellable> = []
    private var isHoldToRecordActive = false
    private var isHoldToRecordLatched = false
    private var holdShortcutPressedAt: Date?
    private var pendingHoldStopTask: Task<Void, Never>?
    private var postPasteLearningTask: Task<Void, Never>?

    private static let modelPreferencesKey = "MyOwnVoice.modelPreferences"
    private static let recordingPreferencesKey = "MyOwnVoice.recordingPreferences"
    private static let holdShortcutTapThreshold: TimeInterval = 0.22
    private static let holdShortcutDoubleTapWindowNanoseconds: UInt64 = 320_000_000

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
        let loadedHistory = Self.loadHistory(from: historyFileURL)

        self.permissionCenter = permissionCenter
        self.modelRegistry = modelRegistry
        self.modelRouter = DefaultModelRouter(registry: modelRegistry)
        self.hotkeyManager = hotkeyManager
        self.audioCaptureService = audioCaptureService
        self.insertionService = insertionService
        self.ollamaService = ollamaService
        self.meetingTranscriptService = MeetingTranscriptService(
            ollamaService: ollamaService,
            speakerAttributionModelName: gemmaRuntimeModel
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
        self.recentTranscripts = loadedHistory
        self.shortcutSummary = Self.makeShortcutSummary(from: loadedRecordingPreferences)
        let defaultSpeechRecognitionEngine: any SpeechRecognitionEngine = {
            let asrModel = modelRegistry.model(id: "whisper-small-en")
                ?? DefaultModelCatalog.seededRegistry().model(id: "whisper-small-en")!
            let whisperCPPFallback = LocalWhisperCPPTranscriptionEngine(model: asrModel)
            return WhisperKitTranscriptionEngine(
                model: asrModel,
                fallbackEngine: whisperCPPFallback
            )
        }()

        self.speechRecognitionEngine = speechRecognitionEngine ?? defaultSpeechRecognitionEngine

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

        saveValue(loadedRecordingPreferences, key: Self.recordingPreferencesKey)

        if let whisperKitEngine = self.speechRecognitionEngine as? WhisperKitTranscriptionEngine {
            whisperKitEngine.onStatusChange = { [weak self] status in
                self?.speechRecognitionRuntimeStatus = status
            }
        }

        Task { @MainActor in
            await refreshLocalModelRuntime()
        }

        Task { @MainActor in
            await prepareSpeechRecognitionEngine()
        }
    }

    public var canUseGemmaRuntime: Bool {
        installedRuntimeModels.contains(where: { modelName in
            modelName == gemmaRuntimeModel || modelName.hasPrefix("\(gemmaRuntimeModel):")
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
            statusMessage = "Screen Capture settings opened. After enabling it, quit and reopen the app."
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

    public func applyShortcut(_ shortcut: KeyboardShortcut, for action: HotkeyAction) {
        let normalizedShortcut = shortcut.normalized()

        switch action {
        case .holdToRecord:
            recordingPreferences.holdToRecordShortcut = normalizedShortcut
        case .toggleRecording:
            recordingPreferences.toggleRecordingShortcut = normalizedShortcut
        }

        statusMessage = "\(action.displayName) updated to \(normalizedShortcut.displayName)."
    }

    public func restoreDefaultShortcuts() {
        recordingPreferences.holdToRecordShortcut = .defaultHoldToRecord
        recordingPreferences.toggleRecordingShortcut = .defaultToggleRecording
        statusMessage = "Restored the default recording shortcuts."
    }

    public func copyLastTranscript() {
        guard let lastTranscript else {
            statusMessage = "There is no transcript to copy yet."
            return
        }

        copyToPasteboard(lastTranscript)
        statusMessage = "Copied the latest transcript."
    }

    public func copyTranscript(_ transcript: RecentTranscript) {
        copyToPasteboard(transcript.text)
        statusMessage = "Copied the selected transcript."
    }

    public func insertLastTranscript() {
        guard let lastTranscript else {
            statusMessage = "There is no transcript to insert yet."
            return
        }

        let result = insertionService.insert(text: lastTranscript)
        schedulePostPasteLearningIfNeeded(from: result)
        statusMessage = result.message
    }

    public func insertTranscript(_ transcript: RecentTranscript) {
        let result = insertionService.insert(text: transcript.text)
        schedulePostPasteLearningIfNeeded(from: result)
        statusMessage = result.message
    }

    public func removeTranscript(_ transcript: RecentTranscript) {
        recentTranscripts.removeAll { $0.id == transcript.id }
        statusMessage = "Removed the selected transcript from history."
    }

    public func clearRecentTranscripts() {
        recentTranscripts.removeAll()
        statusMessage = "Cleared saved transcript history."
    }

    public func revealTranscriptFiles(_ transcript: RecentTranscript) {
        let url = URL(fileURLWithPath: transcript.sessionDirectoryPath, isDirectory: true)
        guard fileManager.fileExists(atPath: url.path) else {
            statusMessage = "The saved audio chunk folder is no longer available."
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([url])
        statusMessage = "Revealed the saved recording files in Finder."
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

    public func availableModels(for task: ModelTask) -> [LocalModel] {
        modelRouter.availableModels(for: task)
    }

    public func refreshLocalModelRuntime() async {
        let diagnostics = await runtimeSetupService.inspect(requiredModels: [gemmaRuntimeModel])

        installedRuntimeModels = diagnostics.installedModels
        missingRuntimeModels = diagnostics.missingRequiredModels

        if diagnostics.isReady {
            localModelRuntimeStatus = "Ollama is running and Gemma 4 is installed locally."
        } else if diagnostics.serverReachable && diagnostics.installedModels.isEmpty {
            localModelRuntimeStatus = "Ollama is running, but no local models are installed yet."
        } else if diagnostics.serverReachable {
            localModelRuntimeStatus = "Ollama is running, but Gemma 4 is not installed."
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
                requiredModels: [gemmaRuntimeModel]
            ) { [weak self] message in
                self?.localModelRuntimeStatus = message
            }
            await refreshLocalModelRuntime()

            if canUseGemmaRuntime {
                statusMessage = "Local runtime setup is complete. Gemma 4 is ready."
            } else {
                statusMessage = "Local runtime setup needs one more step. Finish the Ollama install, then run setup again."
            }
        } catch {
            statusMessage = "Local runtime setup failed: \(error.localizedDescription)"
            await refreshLocalModelRuntime()
        }
    }

    public func runGemmaFormattingCheck() async {
        statusMessage = "Running a local Gemma 4 formatting check..."

        if installedRuntimeModels.isEmpty {
            await refreshLocalModelRuntime()
        }

        guard canUseGemmaRuntime else {
            statusMessage = "Gemma 4 is not installed in Ollama yet."
            return
        }

        let sampleDictation = "tomorrow morning remind me to send the contract and thank jen for the quick turnaround"

        do {
            let response = try await ollamaService.generate(
                model: gemmaRuntimeModel,
                system: recordingPreferences.cleanupPrompt,
                prompt: sampleDictation
            )

            lastGemmaCheckResult = applyCorrections(to: response)
            statusMessage = "Gemma 4 formatted a local sample successfully."
        } catch {
            statusMessage = "Gemma 4 formatting check failed: \(error.localizedDescription)"
        }
    }

    public func prepareSpeechRecognitionEngine() async {
        do {
            try await speechRecognitionEngine.prepare()
        } catch {
            speechRecognitionRuntimeStatus = "WhisperKit could not be prepared. The app will keep using whisper.cpp when needed."
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

        do {
            try audioCaptureService.start()
            isRecording = true
            recordingIndicatorPresenter?.showRecordingIndicator()

            let transcriptionModel = recommendedModelName(for: transcriptionTask(for: sessionMode))

            if sessionMode == .meetingTranscript {
                statusMessage = "Meeting capture started from the \(trigger). Routing through \(transcriptionModel) and saving a timestamped transcript after you stop."
            } else {
                let formattingModel = recommendedModelName(for: .formatting)
                statusMessage = "Recording started from the \(trigger). Routing through \(transcriptionModel) with \(formattingModel) for cleanup."
            }
        } catch {
            recordingIndicatorPresenter?.hideRecordingIndicator()
            statusMessage = "Could not start audio capture: \(error.localizedDescription)"
        }
    }

    private func stopRecording(triggerInsertion: Bool) {
        resetHoldShortcutState()
        guard isRecording else { return }
        isRecording = false

        guard let captureResult = audioCaptureService.stop() else {
            recordingIndicatorPresenter?.hideRecordingIndicator()
            statusMessage = "Recording stopped, but no capture result was produced."
            return
        }

        isProcessingCapture = true
        recordingIndicatorPresenter?.showTranscribingIndicator()
        statusMessage = sessionMode == .meetingTranscript
            ? "Captured \(captureResult.chunks.count) chunk(s). Building a local meeting transcript..."
            : "Captured \(captureResult.chunks.count) chunk(s). Starting local Whisper transcription..."

        Task { @MainActor in
            await processCaptureResult(captureResult, triggerInsertion: triggerInsertion)
        }
    }

    private func refreshStatus() {
        if isRecording {
            statusMessage = "Recording..."
            return
        }

        if !permissionCenter.microphone.isGranted {
            statusMessage = "Microphone permission is still missing."
        } else if recordingPreferences.autoInsertIntoFocusedField && !permissionCenter.accessibility.isGranted {
            statusMessage = "Accessibility is still missing, so automatic focused-field paste will fall back later."
        } else {
            statusMessage = "Ready."
        }
    }

    private func registerConfiguredHotkeys() {
        do {
            try hotkeyManager.register(shortcuts: [
                .holdToRecord: recordingPreferences.holdToRecordShortcut,
                .toggleRecording: recordingPreferences.toggleRecordingShortcut
            ])
            shortcutSummary = Self.makeShortcutSummary(from: recordingPreferences)
        } catch {
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
                registerConfiguredHotkeys()
                refreshStatus()
            }
            .store(in: &cancellables)

        $recentTranscripts
            .dropFirst()
            .sink { [weak self] transcripts in
                self?.saveHistory(transcripts)
            }
            .store(in: &cancellables)
    }

    private func processCaptureResult(_ captureResult: AudioCaptureResult, triggerInsertion: Bool) async {
        defer {
            isProcessingCapture = false
            recordingIndicatorPresenter?.hideRecordingIndicator()
        }

        do {
            let pipelineStartedAt = ProcessInfo.processInfo.systemUptime
            let currentSessionMode = sessionMode
            let task = transcriptionTask(for: currentSessionMode)
            let transcribedCapture = try await transcribeCaptureResult(captureResult, task: task)
            let transcriptionElapsedMs = elapsedMilliseconds(since: pipelineStartedAt)
            let initialTranscript = applyCorrections(to: transcribedCapture.text)

            if currentSessionMode == .meetingTranscript {
                let correctedSegments = correctedTimedSegments(from: transcribedCapture.timedSegments)
                let meetingTranscript = await meetingTranscriptService.buildTranscript(
                    sessionID: captureResult.sessionID,
                    startedAt: captureResult.startedAt,
                    endedAt: captureResult.endedAt,
                    rawTranscript: initialTranscript,
                    sourceSegments: correctedSegments
                )
                let exportedFiles = try meetingTranscriptService.save(
                    meetingTranscript,
                    in: captureResult.directoryURL
                )

                lastTranscript = meetingTranscript.annotatedTranscript

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

                recentTranscripts.insert(recent, at: 0)
                recentTranscripts = Array(recentTranscripts.prefix(25))
                statusMessage = "Meeting transcript saved with \(meetingTranscript.speakers.count) speaker(s)."

                pipelineLogger.info(
                    "Meeting transcript finished in \(self.elapsedMilliseconds(since: pipelineStartedAt), privacy: .public) ms (ASR: \(transcriptionElapsedMs, privacy: .public) ms) for session \(captureResult.sessionID.uuidString, privacy: .public)"
                )
                return
            }

            if shouldDeferCleanup(mode: currentSessionMode) {
                let insertionResult = insertTranscript(
                    initialTranscript,
                    triggerInsertion: triggerInsertion
                )
                let recent = RecentTranscript(
                    mode: currentSessionMode,
                    text: initialTranscript,
                    insertionOutcome: insertionResult.outcome,
                    insertionMessage: insertionResult.message,
                    chunkCount: captureResult.chunks.count,
                    sessionDirectoryPath: captureResult.directoryURL.path
                )

                lastTranscript = initialTranscript
                recentTranscripts.insert(recent, at: 0)
                recentTranscripts = Array(recentTranscripts.prefix(25))
                statusMessage = initialStatusMessage(
                    from: insertionResult,
                    cleanupDeferred: true,
                    triggerInsertion: triggerInsertion
                )

                pipelineLogger.info(
                    "Initial transcript ready in \(self.elapsedMilliseconds(since: pipelineStartedAt), privacy: .public) ms (ASR: \(transcriptionElapsedMs, privacy: .public) ms, cleanup deferred) for session \(captureResult.sessionID.uuidString, privacy: .public)"
                )

                Task { [weak self] in
                    await self?.finishDeferredCleanup(
                        transcribedCapture.text,
                        mode: currentSessionMode,
                        recentTranscriptID: recent.id,
                        sessionID: captureResult.sessionID
                    )
                }
                return
            }

            let cleanupStartedAt = ProcessInfo.processInfo.systemUptime
            let formattedTranscript = try await maybeFormatTranscript(
                transcribedCapture.text,
                mode: currentSessionMode
            )
            let cleanupElapsedMs = elapsedMilliseconds(since: cleanupStartedAt)
            let transcript = applyCorrections(to: formattedTranscript)

            lastTranscript = transcript

            let insertionResult = insertTranscript(transcript, triggerInsertion: triggerInsertion)

            let recent = RecentTranscript(
                mode: currentSessionMode,
                text: transcript,
                insertionOutcome: insertionResult.outcome,
                insertionMessage: insertionResult.message,
                chunkCount: captureResult.chunks.count,
                sessionDirectoryPath: captureResult.directoryURL.path
            )

            recentTranscripts.insert(recent, at: 0)
            recentTranscripts = Array(recentTranscripts.prefix(25))
            statusMessage = insertionResult.message

            pipelineLogger.info(
                "Transcript pipeline finished in \(self.elapsedMilliseconds(since: pipelineStartedAt), privacy: .public) ms (ASR: \(transcriptionElapsedMs, privacy: .public) ms, cleanup: \(cleanupElapsedMs, privacy: .public) ms) for session \(captureResult.sessionID.uuidString, privacy: .public)"
            )
        } catch {
            pipelineLogger.error(
                "Transcript pipeline failed for session \(captureResult.sessionID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            statusMessage = "Local transcription failed: \(error.localizedDescription)"
        }
    }

    private func transcribeCaptureResult(
        _ captureResult: AudioCaptureResult,
        task: ModelTask
    ) async throws -> TranscribedCapture {
        var accumulatedTranscript = ""
        var timedSegments = [TimedTranscriptSegment]()

        for (index, chunk) in captureResult.chunks.enumerated() {
            statusMessage = "Transcribing chunk \(index + 1) of \(captureResult.chunks.count) locally with Whisper..."

            let segment = try await speechRecognitionEngine.transcribeChunk(
                audioFileURL: chunk.fileURL,
                previousTranscript: accumulatedTranscript,
                task: task
            )

            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
            let correctedText = applyCorrections(to: segment.text)
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
        guard mode == .quickDictation,
              recordingPreferences.enableCleanup,
              canUseGemmaRuntime else {
            return transcript
        }

        if updatesStatus {
            statusMessage = "Polishing the transcript locally with Gemma 4..."
        }

        let cleanupPrompt = transcriptCorrectionEngine.cleanupPrompt(
            basePrompt: recordingPreferences.cleanupPrompt
        )

        return try await ollamaService.generate(
            model: gemmaRuntimeModel,
            system: cleanupPrompt,
            prompt: transcript
        )
    }

    private func finishDeferredCleanup(
        _ rawTranscript: String,
        mode: SessionMode,
        recentTranscriptID: UUID,
        sessionID: UUID
    ) async {
        let cleanupStartedAt = ProcessInfo.processInfo.systemUptime

        do {
            let formattedTranscript = try await maybeFormatTranscript(
                rawTranscript,
                mode: mode,
                updatesStatus: false
            )
            let polishedTranscript = applyCorrections(to: formattedTranscript)
            let cleanupElapsedMs = elapsedMilliseconds(since: cleanupStartedAt)

            if let index = recentTranscripts.firstIndex(where: { $0.id == recentTranscriptID }) {
                let existing = recentTranscripts[index]
                recentTranscripts[index] = RecentTranscript(
                    id: existing.id,
                    createdAt: existing.createdAt,
                    mode: existing.mode,
                    text: polishedTranscript,
                    insertionOutcome: existing.insertionOutcome,
                    insertionMessage: existing.insertionMessage,
                    chunkCount: existing.chunkCount,
                    sessionDirectoryPath: existing.sessionDirectoryPath,
                    exportedArtifactPath: existing.exportedArtifactPath,
                    speakerLabels: existing.speakerLabels
                )
            }

            if recentTranscripts.first?.id == recentTranscriptID {
                lastTranscript = polishedTranscript

                if !isRecording && !isProcessingCapture {
                    statusMessage = "Quick transcript pasted. The polished version is now ready in the app."
                }
            }

            pipelineLogger.info(
                "Deferred cleanup finished in \(cleanupElapsedMs, privacy: .public) ms for session \(sessionID.uuidString, privacy: .public)"
            )
        } catch {
            pipelineLogger.error(
                "Deferred cleanup failed for session \(sessionID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func shouldDeferCleanup(mode: SessionMode) -> Bool {
        mode == .quickDictation &&
            recordingPreferences.enableCleanup &&
            recordingPreferences.preferFastTranscriptFeedback &&
            canUseGemmaRuntime
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

    private func elapsedMilliseconds(since startedAt: TimeInterval) -> Int {
        Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
    }

    private func schedulePostPasteLearningIfNeeded(from result: TextInsertionResult) {
        postPasteLearningTask?.cancel()
        postPasteLearningTask = nil

        guard recordingPreferences.enablePostPasteCorrectionLearning,
              let context = result.observationContext else {
            return
        }

        postPasteLearningTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))

            for _ in 0..<15 {
                guard let self else { return }

                if let learnedCorrection = insertionService.detectLearnedCorrection(from: context) {
                    applyLearnedCorrection(learnedCorrection)
                    postPasteLearningTask = nil
                    return
                }

                try? await Task.sleep(for: .seconds(1))
            }

            self?.postPasteLearningTask = nil
        }
    }

    private func applyLearnedCorrection(_ learnedCorrection: LearnedCorrection) {
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

        guard didUpdatePreferences else { return }

        pipelineLogger.info(
            "Learned post-paste correction \(learnedCorrection.wrong, privacy: .public) => \(learnedCorrection.right, privacy: .public)"
        )
        statusMessage = "Learned a correction for \(learnedCorrection.right). Future dictation will preserve it."
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

    private static func makeShortcutSummary(from preferences: RecordingPreferences) -> String {
        "Hold: \(preferences.holdToRecordShortcut.displayName) · Toggle: \(preferences.toggleRecordingShortcut.displayName)"
    }

    private func isQuickHoldTap(releasedAt: Date) -> Bool {
        guard let holdShortcutPressedAt else { return false }
        return releasedAt.timeIntervalSince(holdShortcutPressedAt) <= Self.holdShortcutTapThreshold
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
