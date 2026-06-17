import Foundation

public enum SessionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case quickDictation
    case longSession
    case meetingTranscript

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .quickDictation:
            "Quick Dictation"
        case .longSession:
            "Long Session"
        case .meetingTranscript:
            "Meeting Transcript"
        }
    }

    public var description: String {
        switch self {
        case .quickDictation:
            "Low-latency, release-to-insert dictation."
        case .longSession:
            "Rolling chunk capture for long recordings and recovery."
        case .meetingTranscript:
            "Save a timestamped local transcript with best-effort speaker labels."
        }
    }
}

public enum QuickDictationCleanupMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case background
    case beforePaste

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off:
            "Off"
        case .background:
            "Adaptive"
        case .beforePaste:
            "Before Paste"
        }
    }

    public var summary: String {
        switch self {
        case .off:
            "Quick dictation uses Whisper plus your correction rules only. No local cleanup model runs."
        case .background:
            "Quick dictations paste immediately, then local cleanup updates History in the background."
        case .beforePaste:
            "Quick dictation waits for local cleanup before it inserts, copies, or shows the final result."
        }
    }
}

public enum DictationHUDStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case detailed
    case compact

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .detailed:
            "Detailed"
        case .compact:
            "Compact"
        }
    }

    public var summary: String {
        switch self {
        case .detailed:
            "Shows progress, mode, transcript preview, and recovery details in the floating HUD."
        case .compact:
            "Shows the smaller floating recording and transcribing indicator."
        }
    }
}

public enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case accessibility
    case screenCapture

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .microphone:
            "Microphone"
        case .accessibility:
            "Accessibility"
        case .screenCapture:
            "Screen Capture"
        }
    }

    public var helpText: String {
        switch self {
        case .microphone:
            "Needed to capture your voice."
        case .accessibility:
            "Needed to paste into the currently focused field."
        case .screenCapture:
            "Reserved for a future screen and system-audio capture flow. It is not required for the current microphone-only meeting transcript mode."
        }
    }
}

public enum PermissionState: String, Sendable {
    case unknown
    case granted
    case denied

    public var isGranted: Bool {
        self == .granted
    }

    public var displayName: String {
        switch self {
        case .unknown:
            "Unknown"
        case .granted:
            "Granted"
        case .denied:
            "Missing"
        }
    }
}

@MainActor
public protocol RecordingIndicatorPresenting: AnyObject {
    func showDictationHUD(_ snapshot: DictationHUDSnapshot, style: DictationHUDStyle)
    func hideRecordingIndicator()
}

public extension RecordingIndicatorPresenting {
    func showDictationHUD(_ snapshot: DictationHUDSnapshot) {
        showDictationHUD(snapshot, style: .detailed)
    }

    func showRecordingIndicator() {
        showDictationHUD(
            DictationHUDSnapshot(
                phase: .recording,
                mode: .quickDictation,
                title: "Recording",
                detail: "Listening"
            )
        )
    }

    func showTranscribingIndicator() {
        showDictationHUD(
            DictationHUDSnapshot(
                phase: .transcribing,
                mode: .quickDictation,
                title: "Transcribing",
                detail: "Preparing transcript"
            )
        )
    }
}

public enum DictationHUDPhase: String, Codable, Sendable {
    case recording
    case transcribing
    case polishing
    case inserting
    case inserted
    case saved
    case recovery
    case failed

    public var isTerminal: Bool {
        switch self {
        case .recording, .transcribing, .polishing, .inserting:
            return false
        case .inserted, .saved, .recovery, .failed:
            return true
        }
    }
}

public struct DictationHUDSnapshot: Equatable, Sendable {
    public let phase: DictationHUDPhase
    public let mode: SessionMode
    public let title: String
    public let detail: String
    public let startedAt: Date?
    public let progress: Double?
    public let progressLabel: String?
    public let previewText: String?
    public let recoveryText: String?

    public init(
        phase: DictationHUDPhase,
        mode: SessionMode,
        title: String,
        detail: String,
        startedAt: Date? = nil,
        progress: Double? = nil,
        progressLabel: String? = nil,
        previewText: String? = nil,
        recoveryText: String? = nil
    ) {
        self.phase = phase
        self.mode = mode
        self.title = title
        self.detail = detail
        self.startedAt = startedAt
        self.progress = progress.map { min(max($0, 0), 1) }
        self.progressLabel = progressLabel
        self.previewText = previewText
        self.recoveryText = recoveryText
    }

    public var isTerminal: Bool {
        phase.isTerminal
    }
}

public struct RecordingPreferences: Hashable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case holdToRecordShortcut
        case toggleRecordingShortcut
        case autoInsertIntoFocusedField
        case dictationHUDStyle
        case preferFastTranscriptFeedback
        case enablePostPasteCorrectionLearning
        case enableDoubleTapHoldToToggle
        case enableCleanup
        case cleanupPrompt
        case preferredTermsText
        case misheardReplacementsText
        case hasSeededSuggestedCorrections
        case correctionsText
    }

    public var holdToRecordShortcut: KeyboardShortcut
    public var toggleRecordingShortcut: KeyboardShortcut
    public var autoInsertIntoFocusedField: Bool
    public var dictationHUDStyle: DictationHUDStyle
    public var preferFastTranscriptFeedback: Bool
    public var enablePostPasteCorrectionLearning: Bool
    public var enableDoubleTapHoldToToggle: Bool
    public var enableCleanup: Bool
    public var cleanupPrompt: String
    public var preferredTermsText: String
    public var misheardReplacementsText: String
    public var hasSeededSuggestedCorrections: Bool

    public init(
        holdToRecordShortcut: KeyboardShortcut = .defaultHoldToRecord,
        toggleRecordingShortcut: KeyboardShortcut = .defaultToggleRecording,
        autoInsertIntoFocusedField: Bool = true,
        dictationHUDStyle: DictationHUDStyle = .detailed,
        preferFastTranscriptFeedback: Bool = true,
        enablePostPasteCorrectionLearning: Bool = true,
        enableDoubleTapHoldToToggle: Bool = true,
        enableCleanup: Bool = true,
        cleanupPrompt: String = RecordingPreferences.defaultCleanupPrompt,
        preferredTermsText: String = "",
        misheardReplacementsText: String = "",
        hasSeededSuggestedCorrections: Bool = false
    ) {
        self.holdToRecordShortcut = holdToRecordShortcut
        self.toggleRecordingShortcut = toggleRecordingShortcut
        self.autoInsertIntoFocusedField = autoInsertIntoFocusedField
        self.dictationHUDStyle = dictationHUDStyle
        self.preferFastTranscriptFeedback = preferFastTranscriptFeedback
        self.enablePostPasteCorrectionLearning = enablePostPasteCorrectionLearning
        self.enableDoubleTapHoldToToggle = enableDoubleTapHoldToToggle
        self.enableCleanup = enableCleanup
        self.cleanupPrompt = cleanupPrompt
        self.preferredTermsText = preferredTermsText
        self.misheardReplacementsText = misheardReplacementsText
        self.hasSeededSuggestedCorrections = hasSeededSuggestedCorrections
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyCorrectionsText = try container.decodeIfPresent(String.self, forKey: .correctionsText) ?? ""

        self.init(
            holdToRecordShortcut: try container.decodeIfPresent(KeyboardShortcut.self, forKey: .holdToRecordShortcut) ?? .defaultHoldToRecord,
            toggleRecordingShortcut: try container.decodeIfPresent(KeyboardShortcut.self, forKey: .toggleRecordingShortcut) ?? .defaultToggleRecording,
            autoInsertIntoFocusedField: try container.decodeIfPresent(Bool.self, forKey: .autoInsertIntoFocusedField) ?? true,
            dictationHUDStyle: try container.decodeIfPresent(DictationHUDStyle.self, forKey: .dictationHUDStyle) ?? .detailed,
            preferFastTranscriptFeedback: try container.decodeIfPresent(Bool.self, forKey: .preferFastTranscriptFeedback) ?? true,
            enablePostPasteCorrectionLearning: try container.decodeIfPresent(Bool.self, forKey: .enablePostPasteCorrectionLearning) ?? true,
            enableDoubleTapHoldToToggle: try container.decodeIfPresent(Bool.self, forKey: .enableDoubleTapHoldToToggle) ?? true,
            enableCleanup: try container.decodeIfPresent(Bool.self, forKey: .enableCleanup) ?? true,
            cleanupPrompt: try container.decodeIfPresent(String.self, forKey: .cleanupPrompt) ?? RecordingPreferences.defaultCleanupPrompt,
            preferredTermsText: try container.decodeIfPresent(String.self, forKey: .preferredTermsText) ?? "",
            misheardReplacementsText: try container.decodeIfPresent(String.self, forKey: .misheardReplacementsText) ?? legacyCorrectionsText,
            hasSeededSuggestedCorrections: try container.decodeIfPresent(Bool.self, forKey: .hasSeededSuggestedCorrections) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(holdToRecordShortcut, forKey: .holdToRecordShortcut)
        try container.encode(toggleRecordingShortcut, forKey: .toggleRecordingShortcut)
        try container.encode(autoInsertIntoFocusedField, forKey: .autoInsertIntoFocusedField)
        try container.encode(dictationHUDStyle, forKey: .dictationHUDStyle)
        try container.encode(preferFastTranscriptFeedback, forKey: .preferFastTranscriptFeedback)
        try container.encode(enablePostPasteCorrectionLearning, forKey: .enablePostPasteCorrectionLearning)
        try container.encode(enableDoubleTapHoldToToggle, forKey: .enableDoubleTapHoldToToggle)
        try container.encode(enableCleanup, forKey: .enableCleanup)
        try container.encode(cleanupPrompt, forKey: .cleanupPrompt)
        try container.encode(preferredTermsText, forKey: .preferredTermsText)
        try container.encode(misheardReplacementsText, forKey: .misheardReplacementsText)
        try container.encode(hasSeededSuggestedCorrections, forKey: .hasSeededSuggestedCorrections)
        try container.encode(misheardReplacementsText, forKey: .correctionsText)
    }

    public static let defaultCleanupPrompt = """
    You are a local dictation formatter inside a macOS voice app.
    Clean up a dictated transcript while preserving meaning.
    Fix capitalization, punctuation, paragraphing, and obvious casing for names.
    Do not add commentary.
    Return only the cleaned transcript.
    """

    public func normalized() -> RecordingPreferences {
        var copy = self
        copy.holdToRecordShortcut = holdToRecordShortcut.normalized()
        copy.toggleRecordingShortcut = toggleRecordingShortcut.normalized()
        copy.seedSuggestedCorrectionsIfNeeded()
        return copy
    }

    public var quickDictationCleanupMode: QuickDictationCleanupMode {
        get {
            guard enableCleanup else { return .off }
            return preferFastTranscriptFeedback ? .background : .beforePaste
        }
        set {
            switch newValue {
            case .off:
                enableCleanup = false
                preferFastTranscriptFeedback = true
            case .background:
                enableCleanup = true
                preferFastTranscriptFeedback = true
            case .beforePaste:
                enableCleanup = true
                preferFastTranscriptFeedback = false
            }
        }
    }

    private mutating func seedSuggestedCorrectionsIfNeeded() {
        guard !hasSeededSuggestedCorrections else { return }

        preferredTermsText = Self.mergedLines(
            existing: preferredTermsText,
            additions: Self.suggestedPreferredTerms
        )
        misheardReplacementsText = Self.mergedLines(
            existing: misheardReplacementsText,
            additions: Self.suggestedMisheardReplacements
        )
        hasSeededSuggestedCorrections = true
    }

    private static func mergedLines(
        existing: String,
        additions: [String]
    ) -> String {
        var lines = existing
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let existingKeys = Set(lines.map { $0.lowercased() })
        let newLines = additions.filter { !existingKeys.contains($0.lowercased()) }
        lines.append(contentsOf: newLines)
        return lines.joined(separator: "\n")
    }

    public static let suggestedPreferredTerms = [
        "Gemma",
        "Gemma 4",
        "WhisperKit",
        "whisper.cpp",
        "Ghost Pepper",
        "Wispr Flow",
        "Jen",
    ]

    public static let suggestedMisheardReplacements = [
        "gamma => Gemma",
        "gemma four => Gemma 4",
        "whisper kit => WhisperKit",
        "whisper cpp => whisper.cpp",
        "ghostpepper => Ghost Pepper",
        "wisper flow => Wispr Flow",
        "jen => Jen",
    ]
}

public enum InsertionOutcome: String, Codable, Sendable {
    case notAttempted
    case insertedDirectly
    case pastedViaClipboardFallback
    case failed
}

public struct InsertionTarget: Codable, Hashable, Sendable {
    public let applicationName: String
    public let bundleIdentifier: String?
    public let processIdentifier: Int32?

    public init(
        applicationName: String,
        bundleIdentifier: String? = nil,
        processIdentifier: Int32? = nil
    ) {
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }

    public var displayName: String {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return applicationName
        }

        return "\(applicationName) (\(bundleIdentifier))"
    }
}

public struct AudioChunk: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let fileURL: URL
    public let startedAt: Date
    public let endedAt: Date

    public init(id: UUID = UUID(), fileURL: URL, startedAt: Date, endedAt: Date) {
        self.id = id
        self.fileURL = fileURL
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public struct AudioCaptureManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let sessionID: UUID
    public let startedAt: Date
    public let endedAt: Date?
    public let chunkDuration: TimeInterval
    public let chunks: [AudioChunk]

    public init(
        schemaVersion: Int = 1,
        sessionID: UUID,
        startedAt: Date,
        endedAt: Date? = nil,
        chunkDuration: TimeInterval,
        chunks: [AudioChunk]
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.chunkDuration = chunkDuration
        self.chunks = chunks
    }

    public var isComplete: Bool {
        endedAt != nil
    }
}

public struct AudioCaptureResult: Sendable {
    public let sessionID: UUID
    public let directoryURL: URL
    public let manifestFileURL: URL?
    public let startedAt: Date
    public let endedAt: Date
    public let chunks: [AudioChunk]

    public init(
        sessionID: UUID,
        directoryURL: URL,
        manifestFileURL: URL? = nil,
        startedAt: Date,
        endedAt: Date,
        chunks: [AudioChunk]
    ) {
        self.sessionID = sessionID
        self.directoryURL = directoryURL
        self.manifestFileURL = manifestFileURL
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.chunks = chunks
    }
}

public struct RecoveredAudioCaptureSession: Identifiable, Sendable {
    public var id: UUID { manifest.sessionID }

    public let directoryURL: URL
    public let manifestFileURL: URL
    public let manifest: AudioCaptureManifest

    public init(
        directoryURL: URL,
        manifestFileURL: URL,
        manifest: AudioCaptureManifest
    ) {
        self.directoryURL = directoryURL
        self.manifestFileURL = manifestFileURL
        self.manifest = manifest
    }
}

public struct RecentTranscript: Identifiable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case mode
        case text
        case insertionOutcome
        case insertionMessage
        case insertionTarget
        case chunkCount
        case sessionDirectoryPath
        case captureManifestPath
        case exportedArtifactPath
        case speakerLabels
        case isStatusOnly
    }

    public let id: UUID
    public let createdAt: Date
    public let mode: SessionMode
    public let text: String
    public let insertionOutcome: InsertionOutcome
    public let insertionMessage: String
    public let insertionTarget: InsertionTarget?
    public let chunkCount: Int
    public let sessionDirectoryPath: String
    public let captureManifestPath: String?
    public let exportedArtifactPath: String?
    public let speakerLabels: [String]?
    public let isStatusOnly: Bool

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        mode: SessionMode,
        text: String,
        insertionOutcome: InsertionOutcome,
        insertionMessage: String,
        insertionTarget: InsertionTarget? = nil,
        chunkCount: Int,
        sessionDirectoryPath: String,
        captureManifestPath: String? = nil,
        exportedArtifactPath: String? = nil,
        speakerLabels: [String]? = nil,
        isStatusOnly: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.mode = mode
        self.text = text
        self.insertionOutcome = insertionOutcome
        self.insertionMessage = insertionMessage
        self.insertionTarget = insertionTarget
        self.chunkCount = chunkCount
        self.sessionDirectoryPath = sessionDirectoryPath
        self.captureManifestPath = captureManifestPath
        self.exportedArtifactPath = exportedArtifactPath
        self.speakerLabels = speakerLabels
        self.isStatusOnly = isStatusOnly
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .text)

        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            mode: try container.decode(SessionMode.self, forKey: .mode),
            text: text,
            insertionOutcome: try container.decode(InsertionOutcome.self, forKey: .insertionOutcome),
            insertionMessage: try container.decode(String.self, forKey: .insertionMessage),
            insertionTarget: try container.decodeIfPresent(InsertionTarget.self, forKey: .insertionTarget),
            chunkCount: try container.decode(Int.self, forKey: .chunkCount),
            sessionDirectoryPath: try container.decode(String.self, forKey: .sessionDirectoryPath),
            captureManifestPath: try container.decodeIfPresent(String.self, forKey: .captureManifestPath),
            exportedArtifactPath: try container.decodeIfPresent(String.self, forKey: .exportedArtifactPath),
            speakerLabels: try container.decodeIfPresent([String].self, forKey: .speakerLabels),
            isStatusOnly: try container.decodeIfPresent(Bool.self, forKey: .isStatusOnly)
                ?? Self.inferLegacyStatusOnly(from: text)
        )
    }

    private static func inferLegacyStatusOnly(from text: String) -> Bool {
        text.hasPrefix("Local transcription failed:") ||
            text.hasPrefix("Recovered interrupted audio capture.")
    }
}
