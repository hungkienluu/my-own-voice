import Darwin
import Foundation
import ModelRouting

public enum LocalWhisperCPPError: LocalizedError {
    case missingWhisperCLI
    case missingModelFile(String)
    case commandTimedOut(command: String, timeoutSeconds: TimeInterval)
    case commandFailed(command: String, exitCode: Int32, errorOutput: String)
    case missingTranscriptFile(String)

    public var errorDescription: String? {
        switch self {
        case .missingWhisperCLI:
            return "whisper-cli is not installed. Install whisper-cpp with Homebrew first."
        case .missingModelFile(let path):
            return "Whisper model file is missing at \(path)."
        case .commandTimedOut(let command, let timeoutSeconds):
            return "\(command) timed out after \(Int(timeoutSeconds)) seconds."
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

struct LocalWhisperCPPInvocationPlan: Equatable {
    let workingDirectory: URL
    let wavURL: URL
    let outputBaseURL: URL
    let transcriptURL: URL
    let transcriptJSONURL: URL?
    let arguments: [String]
}

private struct WhisperCPPJSONTranscript: Decodable {
    let transcription: [Segment]

    struct Segment: Decodable {
        let timestamps: TimestampRange?
        let offsets: OffsetRange?
        let text: String
        let tokens: [Token]?
    }

    struct Token: Decodable {
        let text: String
        let timestamps: TimestampRange?
        let offsets: OffsetRange?
        let id: Int?
        let probability: Double?

        private enum CodingKeys: String, CodingKey {
            case text
            case timestamps
            case offsets
            case id
            case probability = "p"
        }
    }

    struct TimestampRange: Decodable {
        let from: String
        let to: String
    }

    struct OffsetRange: Decodable {
        let from: Int
        let to: Int
    }
}

public final class LocalWhisperCPPTranscriptionEngine: @unchecked Sendable, SpeechRecognitionEngine {
    public let model: LocalModel

    private let fileManager: FileManager
    private let whisperCLIURL: URL
    private let audioConverterURL: URL
    private let modelFileURL: URL
    private let language: String
    private let additionalWhisperArguments: [String]
    private let audioConversionTimeoutSeconds: TimeInterval
    private let transcriptionTimeoutSeconds: TimeInterval
    private let processTerminationGraceSeconds: TimeInterval

    public init(
        model: LocalModel,
        fileManager: FileManager = .default,
        whisperCLIURL: URL? = nil,
        audioConverterURL: URL = URL(fileURLWithPath: "/usr/bin/afconvert"),
        modelFileURL: URL? = nil,
        language: String = "en",
        additionalWhisperArguments: [String] = [],
        audioConversionTimeoutSeconds: TimeInterval = 30,
        transcriptionTimeoutSeconds: TimeInterval = 120,
        processTerminationGraceSeconds: TimeInterval = 5
    ) {
        self.model = model
        self.fileManager = fileManager
        self.whisperCLIURL = whisperCLIURL ?? Self.defaultWhisperCLIURL()
        self.audioConverterURL = audioConverterURL
        self.modelFileURL = modelFileURL ?? Self.defaultModelFileURL()
        self.language = language
        self.additionalWhisperArguments = additionalWhisperArguments
        self.audioConversionTimeoutSeconds = audioConversionTimeoutSeconds
        self.transcriptionTimeoutSeconds = transcriptionTimeoutSeconds
        self.processTerminationGraceSeconds = processTerminationGraceSeconds
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
        let additionalWhisperArguments = self.additionalWhisperArguments
        let audioConversionTimeoutSeconds = self.audioConversionTimeoutSeconds
        let transcriptionTimeoutSeconds = self.transcriptionTimeoutSeconds
        let processTerminationGraceSeconds = self.processTerminationGraceSeconds

        return try await Task.detached(priority: .userInitiated) {
            guard fileManager.isExecutableFile(atPath: whisperCLIURL.path) else {
                throw LocalWhisperCPPError.missingWhisperCLI
            }

            guard fileManager.fileExists(atPath: modelFileURL.path) else {
                throw LocalWhisperCPPError.missingModelFile(modelFileURL.path)
            }

            let invocationPlan = Self.invocationPlan(
                audioFileURL: audioFileURL,
                modelFileURL: modelFileURL,
                language: language,
                previousTranscript: previousTranscript,
                task: task,
                additionalWhisperArguments: additionalWhisperArguments
            )

            try? fileManager.removeItem(at: invocationPlan.wavURL)
            try? fileManager.removeItem(at: invocationPlan.transcriptURL)
            if let transcriptJSONURL = invocationPlan.transcriptJSONURL {
                try? fileManager.removeItem(at: transcriptJSONURL)
            }

            defer {
                try? fileManager.removeItem(at: invocationPlan.wavURL)
                try? fileManager.removeItem(at: invocationPlan.transcriptURL)
                if let transcriptJSONURL = invocationPlan.transcriptJSONURL {
                    try? fileManager.removeItem(at: transcriptJSONURL)
                }
            }

            try Self.runProcess(
                executableURL: audioConverterURL,
                arguments: [
                    "-f", "WAVE",
                    "-d", "LEI16@16000",
                    "-c", "1",
                    audioFileURL.path,
                    invocationPlan.wavURL.path,
                ],
                timeoutSeconds: audioConversionTimeoutSeconds,
                terminationGraceSeconds: processTerminationGraceSeconds
            )

            try Self.runProcess(
                executableURL: whisperCLIURL,
                arguments: invocationPlan.arguments,
                timeoutSeconds: transcriptionTimeoutSeconds,
                terminationGraceSeconds: processTerminationGraceSeconds
            )

            guard fileManager.fileExists(atPath: invocationPlan.transcriptURL.path) else {
                throw LocalWhisperCPPError.missingTranscriptFile(invocationPlan.transcriptURL.path)
            }

            let text = try String(contentsOf: invocationPlan.transcriptURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let timedSegments: [TimedTranscriptSegment]
            if task == .meetingTranscription,
               let transcriptJSONURL = invocationPlan.transcriptJSONURL {
                timedSegments = (try? Self.timedSegments(fromWhisperCPPJSONAt: transcriptJSONURL)) ?? []
            } else {
                timedSegments = []
            }

            return TranscriptionSegment(
                text: text,
                isFinal: true,
                startedAt: .now,
                endedAt: .now,
                timedSegments: timedSegments
            )
        }.value
    }

    static func invocationPlan(
        audioFileURL: URL,
        modelFileURL: URL,
        language: String,
        previousTranscript: String?,
        task: ModelTask = .streamingDictation,
        additionalWhisperArguments: [String] = []
    ) -> LocalWhisperCPPInvocationPlan {
        let baseName = audioFileURL.deletingPathExtension().lastPathComponent
        let workingDirectory = audioFileURL.deletingLastPathComponent()
        let wavURL = workingDirectory.appendingPathComponent("\(baseName).whisper.wav")
        let outputBaseURL = workingDirectory.appendingPathComponent("\(baseName).whisper")
        let transcriptURL = outputBaseURL.appendingPathExtension("txt")
        let transcriptJSONURL = task == .meetingTranscription
            ? outputBaseURL.appendingPathExtension("json")
            : nil

        var arguments = [
            "-m", modelFileURL.path,
            "-f", wavURL.path,
            "-l", language,
            "-otxt",
            "-of", outputBaseURL.path,
            "-np",
        ]

        if task == .meetingTranscription {
            arguments.append(contentsOf: ["-oj", "-ojf"])
        } else {
            arguments.append("-nt")
        }

        if let prompt = boundedPrompt(from: previousTranscript) {
            arguments.append(contentsOf: ["--prompt", prompt])
        }

        arguments.append(contentsOf: additionalWhisperArguments)

        return LocalWhisperCPPInvocationPlan(
            workingDirectory: workingDirectory,
            wavURL: wavURL,
            outputBaseURL: outputBaseURL,
            transcriptURL: transcriptURL,
            transcriptJSONURL: transcriptJSONURL,
            arguments: arguments
        )
    }

    static func timedSegments(fromWhisperCPPJSONAt transcriptJSONURL: URL) throws -> [TimedTranscriptSegment] {
        let data = try Data(contentsOf: transcriptJSONURL)
        return try timedSegments(fromWhisperCPPJSONData: data)
    }

    static func timedSegments(fromWhisperCPPJSONData data: Data) throws -> [TimedTranscriptSegment] {
        let decoded = try JSONDecoder().decode(WhisperCPPJSONTranscript.self, from: data)

        return decoded.transcription.compactMap { segment in
            let text = TranscriptFormatting.cleanMeetingTranscriptText(segment.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            let start = Self.seconds(from: segment.offsets?.from)
                ?? Self.seconds(fromWhisperTimestamp: segment.timestamps?.from)
                ?? 0
            let end = Self.seconds(from: segment.offsets?.to)
                ?? Self.seconds(fromWhisperTimestamp: segment.timestamps?.to)
                ?? start
            let words = (segment.tokens ?? []).compactMap { token -> TimedTranscriptWord? in
                guard !Self.isSpecialWhisperCPPToken(token) else { return nil }

                let word = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !word.isEmpty else { return nil }

                let wordStart = Self.seconds(from: token.offsets?.from)
                    ?? Self.seconds(fromWhisperTimestamp: token.timestamps?.from)
                    ?? start
                let wordEnd = Self.seconds(from: token.offsets?.to)
                    ?? Self.seconds(fromWhisperTimestamp: token.timestamps?.to)
                    ?? wordStart

                return TimedTranscriptWord(
                    word: word,
                    startOffsetSeconds: max(0, wordStart),
                    endOffsetSeconds: max(max(0, wordStart), wordEnd),
                    probability: token.probability
                )
            }

            return TimedTranscriptSegment(
                text: text,
                startOffsetSeconds: max(0, start),
                endOffsetSeconds: max(max(0, start), end),
                words: words
            )
        }
    }

    static func boundedPrompt(from previousTranscript: String?) -> String? {
        guard let previousTranscript else { return nil }
        let trimmed = previousTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.suffix(400))
    }

    private static func seconds(from milliseconds: Int?) -> TimeInterval? {
        guard let milliseconds else { return nil }
        return TimeInterval(milliseconds) / 1_000
    }

    private static func seconds(fromWhisperTimestamp timestamp: String?) -> TimeInterval? {
        guard let timestamp else { return nil }
        let parts = timestamp.split(separator: ":")
        guard parts.count == 3,
              let hours = TimeInterval(parts[0]),
              let minutes = TimeInterval(parts[1]) else {
            return nil
        }

        let secondsText = parts[2].replacingOccurrences(of: ",", with: ".")
        guard let seconds = TimeInterval(secondsText) else {
            return nil
        }

        return hours * 3_600 + minutes * 60 + seconds
    }

    private static func isSpecialWhisperCPPToken(_ token: WhisperCPPJSONTranscript.Token) -> Bool {
        if let id = token.id, id >= 50_000 {
            return true
        }

        let text = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("[_") && text.hasSuffix("]")
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
        arguments: [String],
        timeoutSeconds: TimeInterval,
        terminationGraceSeconds: TimeInterval
    ) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        let processFinished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            processFinished.signal()
        }

        try process.run()
        let waitResult = processFinished.wait(timeout: .now() + timeoutSeconds)
        if waitResult == .timedOut {
            process.terminate()
            let terminationResult = processFinished.wait(timeout: .now() + terminationGraceSeconds)
            if terminationResult == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = processFinished.wait(timeout: .now() + 1)
            }
            throw LocalWhisperCPPError.commandTimedOut(
                command: executableURL.lastPathComponent,
                timeoutSeconds: timeoutSeconds
            )
        }

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
