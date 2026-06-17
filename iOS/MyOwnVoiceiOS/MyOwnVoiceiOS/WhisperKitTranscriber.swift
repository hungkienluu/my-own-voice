import Foundation
@preconcurrency import WhisperKit

actor WhisperKitTranscriber {
    struct ModelOption {
        let name: String
        let label: String
    }

    static let availableModels = [
        ModelOption(name: "tiny.en", label: "Whisper Tiny EN"),
        ModelOption(name: "base.en", label: "Whisper Base EN"),
        ModelOption(name: "small.en", label: "Whisper Small EN")
    ]

    private var runtime: WhisperKit?
    private var loadedModelName: String?

    func transcribe(audioURL: URL, modelName: String) async throws -> String {
        let whisperKit = try await preparedRuntime(modelName: modelName)
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            withoutTimestamps: true,
            wordTimestamps: false
        )

        let results = try await whisperKit.transcribe(
            audioPath: audioURL.path,
            decodeOptions: options
        )
        let transcript = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !transcript.isEmpty else {
            throw WhisperKitTranscriberError.emptyTranscript
        }

        return transcript
    }

    private func preparedRuntime(modelName: String) async throws -> WhisperKit {
        if let runtime, loadedModelName == modelName {
            return runtime
        }

        let modelsDirectory = try Self.modelsDirectory()
        let config = WhisperKitConfig(
            model: modelName,
            downloadBase: modelsDirectory,
            verbose: false,
            logLevel: .none,
            prewarm: false,
            load: true,
            download: true,
            useBackgroundDownloadSession: false
        )
        let runtime = try await WhisperKit(config)
        self.runtime = runtime
        loadedModelName = modelName
        return runtime
    }

    private static func modelsDirectory() throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyOwnVoice", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("WhisperKit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

enum WhisperKitTranscriberError: LocalizedError {
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            "Whisper returned an empty transcript."
        }
    }
}
