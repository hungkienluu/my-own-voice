import Foundation
import ModelRouting

public enum LocalWhisperCPPError: LocalizedError {
    case missingWhisperCLI
    case missingModelFile(String)
    case commandFailed(command: String, exitCode: Int32, errorOutput: String)
    case missingTranscriptFile(String)

    public var errorDescription: String? {
        switch self {
        case .missingWhisperCLI:
            return "whisper-cli is not installed. Install whisper-cpp with Homebrew first."
        case .missingModelFile(let path):
            return "Whisper model file is missing at \(path)."
        case .commandFailed(let command, let exitCode, let errorOutput):
            let details = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if details.isEmpty {
                return "\(command) failed with exit code \(exitCode)."
            }
            return "\(command) failed with exit code \(exitCode): \(details)"
        case .missingTranscriptFile(let path):
            return "Whisper did not produce a transcript file at \(path)."
        }
    }
}

public final class LocalWhisperCPPTranscriptionEngine: @unchecked Sendable, SpeechRecognitionEngine {
    public let model: LocalModel

    private let fileManager: FileManager
    private let whisperCLIURL: URL
    private let audioConverterURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    private let modelFileURL: URL
    private let language: String

    public init(
        model: LocalModel,
        fileManager: FileManager = .default,
        whisperCLIURL: URL? = nil,
        modelFileURL: URL? = nil,
        language: String = "en"
    ) {
        self.model = model
        self.fileManager = fileManager
        self.whisperCLIURL = whisperCLIURL ?? Self.defaultWhisperCLIURL()
        self.modelFileURL = modelFileURL ?? Self.defaultModelFileURL()
        self.language = language
    }

    public func transcribeChunk(
        audioFileURL: URL,
        previousTranscript: String?,
        task: ModelTask
    ) async throws -> TranscriptionSegment {
        let fileManager = self.fileManager
        let whisperCLIURL = self.whisperCLIURL
        let audioConverterURL = self.audioConverterURL
        let modelFileURL = self.modelFileURL
        let language = self.language

        return try await Task.detached(priority: .userInitiated) {
            guard fileManager.isExecutableFile(atPath: whisperCLIURL.path) else {
                throw LocalWhisperCPPError.missingWhisperCLI
            }

            guard fileManager.fileExists(atPath: modelFileURL.path) else {
                throw LocalWhisperCPPError.missingModelFile(modelFileURL.path)
            }

            let baseName = audioFileURL.deletingPathExtension().lastPathComponent
            let workingDirectory = audioFileURL.deletingLastPathComponent()
            let wavURL = workingDirectory.appendingPathComponent("\(baseName).whisper.wav")
            let outputBaseURL = workingDirectory.appendingPathComponent("\(baseName).whisper")
            let transcriptURL = outputBaseURL.appendingPathExtension("txt")

            try? fileManager.removeItem(at: wavURL)
            try? fileManager.removeItem(at: transcriptURL)

            try Self.runProcess(
                executableURL: audioConverterURL,
                arguments: [
                    "-f", "WAVE",
                    "-d", "LEI16@16000",
                    "-c", "1",
                    audioFileURL.path,
                    wavURL.path,
                ]
            )

            defer {
                try? fileManager.removeItem(at: wavURL)
                try? fileManager.removeItem(at: transcriptURL)
            }

            var arguments = [
                "-m", modelFileURL.path,
                "-f", wavURL.path,
                "-l", language,
                "-otxt",
                "-of", outputBaseURL.path,
                "-np",
                "-nt",
            ]

            if let previousTranscript,
               !previousTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let prompt = String(previousTranscript.suffix(400))
                arguments.append(contentsOf: ["--prompt", prompt])
            }

            try Self.runProcess(
                executableURL: whisperCLIURL,
                arguments: arguments
            )

            guard fileManager.fileExists(atPath: transcriptURL.path) else {
                throw LocalWhisperCPPError.missingTranscriptFile(transcriptURL.path)
            }

            let text = try String(contentsOf: transcriptURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return TranscriptionSegment(
                text: text,
                isFinal: true,
                startedAt: .now,
                endedAt: .now
            )
        }.value
    }

    private static func defaultWhisperCLIURL() -> URL {
        let candidatePaths = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
        ]

        if let path = candidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        return URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli")
    }

    private static func defaultModelFileURL() -> URL {
        let path = NSString(string: "~/Library/Application Support/MyOwnVoice/Models/whisper/ggml-small.en.bin").expandingTildeInPath
        return URL(fileURLWithPath: path)
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String]
    ) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            throw LocalWhisperCPPError.commandFailed(
                command: executableURL.lastPathComponent,
                exitCode: process.terminationStatus,
                errorOutput: errorOutput
            )
        }
    }
}
