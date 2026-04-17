import Foundation
import ModelRouting
@preconcurrency import WhisperKit

private struct WhisperChunkResult {
    let text: String
    let timedSegments: [ModelRouting.TimedTranscriptSegment]
}

public enum WhisperKitTranscriptionEngineError: LocalizedError {
    case emptyTranscript

    public var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            "WhisperKit returned an empty transcript."
        }
    }
}

public final class WhisperKitTranscriptionEngine: @unchecked Sendable, SpeechRecognitionEngine {
    public let model: LocalModel
    public var onStatusChange: (@MainActor @Sendable (String) -> Void)?

    private let runtime: WhisperKitRuntime
    private let fallbackEngine: any SpeechRecognitionEngine

    public init(
        model: LocalModel,
        fallbackEngine: any SpeechRecognitionEngine,
        modelName: String = "small.en",
        fileManager: FileManager = .default
    ) {
        let modelsDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MyOwnVoice", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("WhisperKit", isDirectory: true)

        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        self.model = model
        self.fallbackEngine = fallbackEngine
        self.runtime = WhisperKitRuntime(
            modelName: modelName,
            downloadBaseURL: modelsDirectory
        )
    }

    public func prepare() async throws {
        do {
            try await publishStatus("Preparing WhisperKit speech model...")
            try await runtime.prepare()
            try await publishStatus("WhisperKit is ready with the \(runtime.modelName) model.")
        } catch {
            try await publishStatus(
                "WhisperKit could not be prepared: \(error.localizedDescription). Falling back to whisper.cpp."
            )
            throw error
        }
    }

    public func transcribeChunk(
        audioFileURL: URL,
        previousTranscript: String?,
        task: ModelTask
    ) async throws -> ModelRouting.TranscriptionSegment {
        do {
            let result = try await runtime.transcribe(
                audioFileURL: audioFileURL,
                previousTranscript: previousTranscript,
                task: task
            )

            return ModelRouting.TranscriptionSegment(
                text: result.text,
                isFinal: true,
                startedAt: .now,
                endedAt: .now,
                timedSegments: result.timedSegments
            )
        } catch {
            try? await publishStatus(
                "WhisperKit hit an error and the app is falling back to whisper.cpp: \(error.localizedDescription)"
            )
            return try await fallbackEngine.transcribeChunk(
                audioFileURL: audioFileURL,
                previousTranscript: previousTranscript,
                task: task
            )
        }
    }

    private func publishStatus(_ message: String) async throws {
        await MainActor.run {
            onStatusChange?(message)
        }
    }
}

private actor WhisperKitRuntime {
    let modelName: String

    private let downloadBaseURL: URL
    private var whisperKit: WhisperKit?

    init(
        modelName: String,
        downloadBaseURL: URL
    ) {
        self.modelName = modelName
        self.downloadBaseURL = downloadBaseURL
    }

    func prepare() async throws {
        guard whisperKit == nil else { return }
        let config = WhisperKitConfig(
            model: modelName,
            downloadBase: downloadBaseURL,
            verbose: false,
            logLevel: .none,
            prewarm: false,
            load: true,
            download: true,
            useBackgroundDownloadSession: false
        )
        whisperKit = try await WhisperKit(config)
    }

    func transcribe(
        audioFileURL: URL,
        previousTranscript: String?,
        task: ModelTask
    ) async throws -> WhisperChunkResult {
        try await prepare()

        guard let whisperKit else {
            throw WhisperKitTranscriptionEngineError.emptyTranscript
        }

        var decodeOptions = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            withoutTimestamps: task != .meetingTranscription,
            wordTimestamps: task == .meetingTranscription
        )

        if task == .longSessionTranscription || task == .meetingTranscription {
            decodeOptions.chunkingStrategy = .vad
        }

        let results = try await whisperKit.transcribe(
            audioPath: audioFileURL.path,
            decodeOptions: decodeOptions
        )

        let text = results
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw WhisperKitTranscriptionEngineError.emptyTranscript
        }

        let timedSegments = results
            .flatMap(\.segments)
            .compactMap { segment -> ModelRouting.TimedTranscriptSegment? in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }

                return ModelRouting.TimedTranscriptSegment(
                    text: text,
                    startOffsetSeconds: TimeInterval(segment.start),
                    endOffsetSeconds: TimeInterval(max(segment.end, segment.start)),
                    words: (segment.words ?? []).map { word in
                        ModelRouting.TimedTranscriptWord(
                            word: word.word.trimmingCharacters(in: .whitespacesAndNewlines),
                            startOffsetSeconds: TimeInterval(word.start),
                            endOffsetSeconds: TimeInterval(max(word.end, word.start)),
                            probability: Double(word.probability)
                        )
                    }
                )
            }

        return WhisperChunkResult(
            text: text,
            timedSegments: timedSegments
        )
    }
}
