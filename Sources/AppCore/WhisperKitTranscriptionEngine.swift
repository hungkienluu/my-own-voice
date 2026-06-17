import Foundation
import ModelRouting
@preconcurrency import WhisperKit

private struct WhisperChunkResult {
    let text: String
    let timedSegments: [ModelRouting.TimedTranscriptSegment]
}

struct WhisperKitRuntimePlan: Equatable {
    let modelName: String
    let modelsDirectory: URL
    let localModelFolderURL: URL?
    let shouldDownloadModel: Bool
}

public enum WhisperKitTranscriptionEngineError: LocalizedError {
    case emptyTranscript
    case timedOut(operation: String, modelName: String, timeoutSeconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            "WhisperKit returned an empty transcript."
        case .timedOut(let operation, let modelName, let timeoutSeconds):
            "WhisperKit \(operation) timed out for \(modelName) after \(Int(timeoutSeconds)) seconds."
        }
    }
}

public final class WhisperKitTranscriptionEngine: @unchecked Sendable, SpeechRecognitionEngine {
    public let model: LocalModel
    public var onStatusChange: (@MainActor @Sendable (String) -> Void)?

    private let runtime: WhisperKitRuntime
    private let fallbackEngine: any SpeechRecognitionEngine
    private let fallbackState = WhisperKitFallbackState()

    public init(
        model: LocalModel,
        fallbackEngine: any SpeechRecognitionEngine,
        modelName: String = DefaultModelCatalog.defaultWhisperKitModelName,
        fileManager: FileManager = .default
    ) {
        let modelsDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MyOwnVoice", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("WhisperKit", isDirectory: true)

        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let runtimePlan = Self.runtimePlan(
            modelName: modelName,
            modelsDirectory: modelsDirectory,
            fileManager: fileManager
        )

        self.model = model
        self.fallbackEngine = fallbackEngine
        self.runtime = WhisperKitRuntime(
            plan: runtimePlan
        )
    }

    static func runtimePlan(
        modelName: String,
        modelsDirectory: URL,
        fileManager: FileManager
    ) -> WhisperKitRuntimePlan {
        let localModelFolderURL = Self.localModelFolderURL(
            modelName: modelName,
            modelsDirectory: modelsDirectory,
            fileManager: fileManager
        )

        return WhisperKitRuntimePlan(
            modelName: modelName,
            modelsDirectory: modelsDirectory,
            localModelFolderURL: localModelFolderURL,
            shouldDownloadModel: localModelFolderURL == nil
        )
    }

    static func localModelFolderURL(
        modelName: String,
        modelsDirectory: URL,
        fileManager: FileManager
    ) -> URL? {
        let candidate = modelsDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent("openai_whisper-\(modelName)", isDirectory: true)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        return candidate
    }

    static func promptText(from previousTranscript: String?) -> String? {
        guard let previousTranscript else { return nil }
        let trimmed = previousTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.suffix(400))
    }

    public func prepare() async throws {
        if await fallbackState.shouldBypassWhisperKit {
            return
        }

        do {
            try await publishStatus("Preparing WhisperKit speech model...")
            try await withTimeout(
                seconds: Self.prepareTimeoutSeconds,
                operation: "prepare"
            ) {
                try await self.runtime.prepare()
            }
            try await publishStatus("WhisperKit is ready with the \(runtime.modelName) model.")
        } catch {
            await fallbackState.markBypass()
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
        if await fallbackState.shouldBypassWhisperKit {
            return try await fallbackEngine.transcribeChunk(
                audioFileURL: audioFileURL,
                previousTranscript: previousTranscript,
                task: task
            )
        }

        do {
            let timeoutSeconds = Self.transcriptionTimeoutSeconds(for: task)
            let result = try await withTimeout(
                seconds: timeoutSeconds,
                operation: "transcription"
            ) {
                try await self.runtime.transcribe(
                    audioFileURL: audioFileURL,
                    previousTranscript: previousTranscript,
                    task: task
                )
            }

            return ModelRouting.TranscriptionSegment(
                text: result.text,
                isFinal: true,
                startedAt: .now,
                endedAt: .now,
                timedSegments: result.timedSegments
            )
        } catch {
            await fallbackState.markBypass()
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

    private static let prepareTimeoutSeconds: TimeInterval = 45

    private static func transcriptionTimeoutSeconds(for task: ModelTask) -> TimeInterval {
        switch task {
        case .streamingDictation:
            return 12
        case .longSessionTranscription:
            return 30
        case .meetingTranscription:
            return 60
        case .formatting, .commands, .meetingSummary:
            return 30
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: String,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let box = TimeoutContinuationBox<T>(continuation)
            let operationTask = Task {
                do {
                    let value = try await body()
                    await box.resume(.success(value))
                } catch {
                    await box.resume(.failure(error))
                }
            }

            Task {
                let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                operationTask.cancel()
                await box.resume(
                    .failure(
                        WhisperKitTranscriptionEngineError.timedOut(
                            operation: operation,
                            modelName: runtime.modelName,
                            timeoutSeconds: seconds
                        )
                    )
                )
            }
        }
    }
}

private actor WhisperKitFallbackState {
    private(set) var shouldBypassWhisperKit = false

    func markBypass() {
        shouldBypassWhisperKit = true
    }
}

private actor TimeoutContinuationBox<T: Sendable> {
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        guard let continuation else { return }
        self.continuation = nil

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private actor WhisperKitRuntime {
    let modelName: String

    private let plan: WhisperKitRuntimePlan
    private var whisperKit: WhisperKit?

    init(plan: WhisperKitRuntimePlan) {
        self.modelName = plan.modelName
        self.plan = plan
    }

    func prepare() async throws {
        guard whisperKit == nil else { return }
        let config = WhisperKitConfig(
            model: plan.modelName,
            downloadBase: plan.modelsDirectory,
            modelFolder: plan.localModelFolderURL?.path,
            verbose: false,
            logLevel: .none,
            prewarm: false,
            load: true,
            download: plan.shouldDownloadModel,
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

        if let prompt = WhisperKitTranscriptionEngine.promptText(from: previousTranscript),
           let tokenizer = whisperKit.tokenizer {
            decodeOptions.promptTokens = tokenizer.encode(
                text: " " + prompt
            ).filter { token in
                token < tokenizer.specialTokens.specialTokenBegin
            }
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
