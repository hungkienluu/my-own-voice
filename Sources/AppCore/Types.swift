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
            "Background"
        case .beforePaste:
            "Before Paste"
        }
    }

    public var summary: String {
        switch self {
        case .off:
            "Quick dictation uses Whisper plus your correction rules only. No Gemma cleanup runs."
        case .background:
            "Quick dictation pastes immediately, then Gemma cleanup updates the app and History in the background."
        case .beforePaste:
            "Quick dictation waits for Gemma cleanup before it pastes or shows the final result."
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
            "Needed later for meeting and system audio capture. After granting it in System Settings, relaunch the app."
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
    func showRecordingIndicator()
    func showTranscribingIndicator()
    func hideRecordingIndicator()
}

public struct RecordingPreferences: Hashable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case holdToRecordShortcut
        case toggleRecordingShortcut
        case autoInsertIntoFocusedField
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

public struct AudioChunk: Identifiable, Hashable, Sendable {
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

public struct AudioCaptureResult: Sendable {
    public let sessionID: UUID
    public let directoryURL: URL
    public let startedAt: Date
    public let endedAt: Date
    public let chunks: [AudioChunk]

    public init(
        sessionID: UUID,
        directoryURL: URL,
        startedAt: Date,
        endedAt: Date,
        chunks: [AudioChunk]
    ) {
        self.sessionID = sessionID
        self.directoryURL = directoryURL
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.chunks = chunks
    }
}

public struct RecentTranscript: Identifiable, Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let mode: SessionMode
    public let text: String
    public let insertionOutcome: InsertionOutcome
    public let insertionMessage: String
    public let chunkCount: Int
    public let sessionDirectoryPath: String
    public let exportedArtifactPath: String?
    public let speakerLabels: [String]?

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        mode: SessionMode,
        text: String,
        insertionOutcome: InsertionOutcome,
        insertionMessage: String,
        chunkCount: Int,
        sessionDirectoryPath: String,
        exportedArtifactPath: String? = nil,
        speakerLabels: [String]? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.mode = mode
        self.text = text
        self.insertionOutcome = insertionOutcome
        self.insertionMessage = insertionMessage
        self.chunkCount = chunkCount
        self.sessionDirectoryPath = sessionDirectoryPath
        self.exportedArtifactPath = exportedArtifactPath
        self.speakerLabels = speakerLabels
    }
}
