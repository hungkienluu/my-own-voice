import Foundation

public struct TimedTranscriptWord: Hashable, Sendable, Codable {
    public let word: String
    public let startOffsetSeconds: TimeInterval
    public let endOffsetSeconds: TimeInterval
    public let probability: Double?

    public init(
        word: String,
        startOffsetSeconds: TimeInterval,
        endOffsetSeconds: TimeInterval,
        probability: Double? = nil
    ) {
        self.word = word
        self.startOffsetSeconds = startOffsetSeconds
        self.endOffsetSeconds = endOffsetSeconds
        self.probability = probability
    }
}

public struct TimedTranscriptSegment: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let text: String
    public let startOffsetSeconds: TimeInterval
    public let endOffsetSeconds: TimeInterval
    public let speakerID: String?
    public let speakerLabel: String?
    public let words: [TimedTranscriptWord]

    public init(
        id: UUID = UUID(),
        text: String,
        startOffsetSeconds: TimeInterval,
        endOffsetSeconds: TimeInterval,
        speakerID: String? = nil,
        speakerLabel: String? = nil,
        words: [TimedTranscriptWord] = []
    ) {
        self.id = id
        self.text = text
        self.startOffsetSeconds = startOffsetSeconds
        self.endOffsetSeconds = endOffsetSeconds
        self.speakerID = speakerID
        self.speakerLabel = speakerLabel
        self.words = words
    }

    public func offsetBy(_ seconds: TimeInterval) -> TimedTranscriptSegment {
        TimedTranscriptSegment(
            id: id,
            text: text,
            startOffsetSeconds: startOffsetSeconds + seconds,
            endOffsetSeconds: endOffsetSeconds + seconds,
            speakerID: speakerID,
            speakerLabel: speakerLabel,
            words: words.map {
                TimedTranscriptWord(
                    word: $0.word,
                    startOffsetSeconds: $0.startOffsetSeconds + seconds,
                    endOffsetSeconds: $0.endOffsetSeconds + seconds,
                    probability: $0.probability
                )
            }
        )
    }

    public func withSpeaker(id: String?, label: String?) -> TimedTranscriptSegment {
        TimedTranscriptSegment(
            id: self.id,
            text: text,
            startOffsetSeconds: startOffsetSeconds,
            endOffsetSeconds: endOffsetSeconds,
            speakerID: id,
            speakerLabel: label,
            words: words
        )
    }
}

public struct TranscriptionSegment: Hashable, Sendable {
    public let text: String
    public let isFinal: Bool
    public let startedAt: Date
    public let endedAt: Date
    public let timedSegments: [TimedTranscriptSegment]

    public init(
        text: String,
        isFinal: Bool,
        startedAt: Date,
        endedAt: Date,
        timedSegments: [TimedTranscriptSegment] = []
    ) {
        self.text = text
        self.isFinal = isFinal
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.timedSegments = timedSegments
    }
}

public enum VoiceCommand: Hashable, Sendable {
    case newLine
    case newParagraph
    case pressEnter
    case literal(String)
}

public protocol SpeechRecognitionEngine: Sendable {
    var model: LocalModel { get }

    func prepare() async throws
    func transcribeChunk(
        audioFileURL: URL,
        previousTranscript: String?,
        task: ModelTask
    ) async throws -> TranscriptionSegment
}

public extension SpeechRecognitionEngine {
    func prepare() async throws {}
}

public protocol TextFormatterEngine: Sendable {
    var model: LocalModel { get }

    func format(
        text: String,
        task: ModelTask
    ) async throws -> String
}

public protocol CommandInterpreter: Sendable {
    var model: LocalModel { get }

    func interpretCommands(in text: String) async throws -> [VoiceCommand]
}
