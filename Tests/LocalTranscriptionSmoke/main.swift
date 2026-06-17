import AppCore
import AVFoundation
import Foundation
import ModelRouting

@main
struct LocalTranscriptionSmoke {
    static func main() async {
        do {
            let configuration = try Configuration(arguments: Array(CommandLine.arguments.dropFirst()))
            let result = try await run(configuration: configuration)

            print("engine=\(configuration.engine.rawValue)")
            print("modelName=\(configuration.modelName)")
            print("prepareMode=\(configuration.skipPrepare ? "skipped" : "explicit")")
            print("whisperKitFallbackEnabled=\(configuration.enableWhisperKitFallback)")
            print("phrase=\(configuration.phrase)")
            print("audioFile=\(result.audioFile.path)")
            print("artifactsKept=\(configuration.keepArtifacts)")
            print("transcript=\(result.transcript)")
            print(String(format: "prepareSeconds=%.3f", result.prepareSeconds))
            print(String(format: "transcribeSeconds=%.3f", result.transcribeSeconds))
            print(String(format: "elapsedSeconds=%.3f", result.elapsedSeconds))
            print("requiredWords=\(configuration.requiredWords.joined(separator: ","))")
            print("result=PASS")
        } catch {
            let message = "Local transcription smoke failed: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
    }

    private static func run(configuration: Configuration) async throws -> SmokeResult {
        let fileManager = FileManager.default
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("myownvoice-local-transcription-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let audioFile = tempDirectory.appendingPathComponent("local-transcription-smoke.aiff")

        do {
            try runProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/say"),
                arguments: ["-o", audioFile.path, configuration.phrase]
            )
            try validateSynthesizedAudio(at: audioFile)

            let model = modelMetadata(for: configuration)
            let engine = speechRecognitionEngine(for: configuration, model: model)

            let prepareSeconds: TimeInterval
            if configuration.skipPrepare {
                prepareSeconds = 0
            } else {
                let prepareStartDate = Date()
                try await engine.prepare()
                prepareSeconds = Date().timeIntervalSince(prepareStartDate)
            }

            let startDate = Date()
            let segment = try await engine.transcribeChunk(
                audioFileURL: audioFile,
                previousTranscript: nil,
                task: .streamingDictation
            )
            let transcribeSeconds = Date().timeIntervalSince(startDate)

            let missingWords = configuration.requiredWords.filter { word in
                !normalizedWords(in: segment.text).contains(word.lowercased())
            }

            guard missingWords.isEmpty else {
                throw SmokeError.missingExpectedWords(
                    words: missingWords,
                    transcript: segment.text
                )
            }

            guard transcribeSeconds <= configuration.maxSeconds else {
                throw SmokeError.tooSlow(
                    elapsedSeconds: transcribeSeconds,
                    maxSeconds: configuration.maxSeconds
                )
            }

            if !configuration.keepArtifacts {
                try? fileManager.removeItem(at: tempDirectory)
            }

            return SmokeResult(
                audioFile: audioFile,
                transcript: segment.text,
                prepareSeconds: prepareSeconds,
                transcribeSeconds: transcribeSeconds
            )
        } catch {
            if !configuration.keepArtifacts {
                try? fileManager.removeItem(at: tempDirectory)
            }
            throw error
        }
    }

    private static func modelMetadata(for configuration: Configuration) -> LocalModel {
        if configuration.engine == .whisperKit {
            let registry = DefaultModelCatalog.seededRegistry()
            if let model = registry.installedModels.first(where: { model in
                DefaultModelCatalog.whisperKitModelName(for: model.id) == configuration.whisperKitModelName
            }) {
                return model
            }
        }

        return LocalModel(
            id: "whisperkit-\(configuration.whisperKitModelName.replacingOccurrences(of: "_", with: "-"))",
            displayName: "WhisperKit \(configuration.whisperKitModelName)",
            family: "ASR",
            supportedTasks: [.streamingDictation, .longSessionTranscription, .meetingTranscription],
            supportsStreaming: false,
            qualityTier: 5,
            latencyTier: .low,
            memoryFootprint: .medium,
            languageSupport: ["en"],
            preferredChunkSeconds: 30,
            quantization: "\(configuration.whisperKitModelName) Core ML",
            localPathHint: "~/Library/Application Support/MyOwnVoice/Models/WhisperKit"
        )
    }

    private static func speechRecognitionEngine(
        for configuration: Configuration,
        model: LocalModel
    ) -> any SpeechRecognitionEngine {
        switch configuration.engine {
        case .whisperCPP:
            return LocalWhisperCPPTranscriptionEngine(
                model: model,
                whisperCLIURL: configuration.whisperCLIURL,
                modelFileURL: configuration.modelFileURL,
                additionalWhisperArguments: configuration.additionalWhisperArguments
            )
        case .whisperKit:
            let fallbackEngine: any SpeechRecognitionEngine = configuration.enableWhisperKitFallback
                ? LocalWhisperCPPTranscriptionEngine(
                    model: model,
                    whisperCLIURL: configuration.whisperCLIURL,
                    modelFileURL: configuration.modelFileURL,
                    additionalWhisperArguments: configuration.additionalWhisperArguments
                )
                : FailingSpeechRecognitionEngine(model: model)

            return WhisperKitTranscriptionEngine(
                model: model,
                fallbackEngine: fallbackEngine,
                modelName: configuration.whisperKitModelName
            )
        }
    }

    private static func normalizedWords(in text: String) -> Set<String> {
        let words = text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        return Set(words)
    }

    private static func validateSynthesizedAudio(
        at audioFile: URL
    ) throws {
        let audio = try AVAudioFile(forReading: audioFile)
        guard audio.length > 0 else {
            throw SmokeError.emptySynthesizedAudio(audioFile.path)
        }
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
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            throw SmokeError.processFailed(
                executable: executableURL.lastPathComponent,
                status: process.terminationStatus,
                output: output
            )
        }
    }
}

private struct Configuration {
    var engine: TranscriptionEngineKind = .whisperCPP
    var phrase = "my own voice local dictation smoke test"
    var requiredWords = ["my", "own", "voice", "local", "dictation", "smoke", "test"]
    var maxSeconds: TimeInterval = 8
    var keepArtifacts = false
    var skipPrepare = false
    var enableWhisperKitFallback = false
    var additionalWhisperArguments: [String] = []
    var whisperCLIURL: URL?
    var modelFileURL: URL?
    var whisperKitModelName = DefaultModelCatalog.defaultWhisperKitModelName

    var modelName: String {
        switch engine {
        case .whisperCPP:
            return modelFileURL?.path ?? "default whisper.cpp model"
        case .whisperKit:
            return whisperKitModelName
        }
    }

    init(arguments: [String]) throws {
        var iterator = arguments.makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--engine":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw SmokeError.invalidArguments("--engine requires whisper-cpp or whisperkit")
                }
                guard let engine = TranscriptionEngineKind(rawValue: value) else {
                    throw SmokeError.invalidArguments("--engine must be whisper-cpp or whisperkit")
                }
                self.engine = engine
            case "--phrase":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw SmokeError.invalidArguments("--phrase requires a non-empty value")
                }
                phrase = value
            case "--expect":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw SmokeError.invalidArguments("--expect requires a non-empty value")
                }
                requiredWords.append(value.lowercased())
            case "--max-seconds":
                guard let value = iterator.next(),
                      let seconds = TimeInterval(value),
                      seconds > 0 else {
                    throw SmokeError.invalidArguments("--max-seconds requires a positive number")
                }
                maxSeconds = seconds
            case "--keep-artifacts":
                keepArtifacts = true
            case "--skip-prepare":
                skipPrepare = true
            case "--enable-whisperkit-fallback":
                enableWhisperKitFallback = true
            case "--whisper-cli":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw SmokeError.invalidArguments("--whisper-cli requires a non-empty value")
                }
                whisperCLIURL = URL(fileURLWithPath: value)
            case "--model-file":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw SmokeError.invalidArguments("--model-file requires a non-empty value")
                }
                modelFileURL = URL(fileURLWithPath: value)
            case "--whisper-arg":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw SmokeError.invalidArguments("--whisper-arg requires a non-empty value")
                }
                additionalWhisperArguments.append(value)
            case "--whisperkit-model":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw SmokeError.invalidArguments("--whisperkit-model requires a non-empty value")
                }
                whisperKitModelName = value
            default:
                throw SmokeError.invalidArguments("unknown argument: \(argument)")
            }
        }

        requiredWords = Array(Set(requiredWords.map { $0.lowercased() })).sorted()
    }
}

private enum TranscriptionEngineKind: String {
    case whisperCPP = "whisper-cpp"
    case whisperKit = "whisperkit"
}

private struct SmokeResult {
    let audioFile: URL
    let transcript: String
    let prepareSeconds: TimeInterval
    let transcribeSeconds: TimeInterval

    var elapsedSeconds: TimeInterval {
        prepareSeconds + transcribeSeconds
    }
}

private struct FailingSpeechRecognitionEngine: SpeechRecognitionEngine {
    let model: LocalModel

    func transcribeChunk(
        audioFileURL: URL,
        previousTranscript: String?,
        task: ModelTask
    ) async throws -> TranscriptionSegment {
        throw SmokeError.whisperKitFallbackDisabled(model.displayName)
    }
}

private enum SmokeError: LocalizedError {
    case invalidArguments(String)
    case emptySynthesizedAudio(String)
    case processFailed(executable: String, status: Int32, output: String)
    case missingExpectedWords(words: [String], transcript: String)
    case tooSlow(elapsedSeconds: TimeInterval, maxSeconds: TimeInterval)
    case whisperKitFallbackDisabled(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return message
        case .emptySynthesizedAudio(let path):
            return "/usr/bin/say produced no audio samples at \(path)"
        case .processFailed(let executable, let status, let output):
            let details = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if details.isEmpty {
                return "\(executable) exited with status \(status)"
            }
            return "\(executable) exited with status \(status): \(details)"
        case .missingExpectedWords(let words, let transcript):
            return "transcript is missing expected word(s) \(words.joined(separator: ", ")): \(transcript)"
        case .tooSlow(let elapsedSeconds, let maxSeconds):
            return String(
                format: "local transcription took %.3fs, above %.3fs threshold",
                elapsedSeconds,
                maxSeconds
            )
        case .whisperKitFallbackDisabled(let modelName):
            return "WhisperKit failed for \(modelName), and fallback is disabled for benchmark runs"
        }
    }
}
