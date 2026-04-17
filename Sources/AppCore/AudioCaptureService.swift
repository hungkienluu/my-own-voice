import AVFoundation
import Foundation

public final class AudioCaptureService {
    private let engine = AVAudioEngine()
    private let fileManager: FileManager
    private let chunkDuration: TimeInterval

    private var sessionID: UUID?
    private var sessionDirectoryURL: URL?
    private var sessionStartedAt: Date?
    private var currentChunkStartedAt: Date?
    private var currentChunkFile: AVAudioFile?
    private var currentChunkURL: URL?
    private var chunks: [AudioChunk] = []

    public private(set) var isCapturing = false

    public init(
        fileManager: FileManager = .default,
        chunkDuration: TimeInterval = 30
    ) {
        self.fileManager = fileManager
        self.chunkDuration = chunkDuration
    }

    public func start() throws {
        guard !isCapturing else { return }

        let sessionID = UUID()
        let sessionDirectory = try makeSessionDirectory(for: sessionID)
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        self.sessionID = sessionID
        self.sessionDirectoryURL = sessionDirectory
        self.sessionStartedAt = .now
        self.currentChunkStartedAt = nil
        self.currentChunkFile = nil
        self.currentChunkURL = nil
        self.chunks = []

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            self?.write(buffer: buffer, format: inputFormat)
        }

        engine.prepare()
        try engine.start()
        isCapturing = true
    }

    public func stop() -> AudioCaptureResult? {
        guard isCapturing,
              let sessionID,
              let sessionDirectoryURL,
              let sessionStartedAt else {
            return nil
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        finalizeCurrentChunk(at: .now)
        isCapturing = false

        return AudioCaptureResult(
            sessionID: sessionID,
            directoryURL: sessionDirectoryURL,
            startedAt: sessionStartedAt,
            endedAt: .now,
            chunks: chunks
        )
    }

    private func write(buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        let now = Date()

        if currentChunkFile == nil {
            try? startNewChunk(format: format, at: now)
        } else if let currentChunkStartedAt,
                  now.timeIntervalSince(currentChunkStartedAt) >= chunkDuration {
            finalizeCurrentChunk(at: now)
            try? startNewChunk(format: format, at: now)
        }

        do {
            try currentChunkFile?.write(from: buffer)
        } catch {
            NSLog("MyOwnVoice failed to write audio chunk: \(error.localizedDescription)")
        }
    }

    private func startNewChunk(format: AVAudioFormat, at startedAt: Date) throws {
        guard let sessionDirectoryURL else { return }

        let fileName = ISO8601DateFormatter().string(from: startedAt).replacingOccurrences(of: ":", with: "-")
        let fileURL = sessionDirectoryURL.appendingPathComponent("\(fileName).caf")
        let audioFile = try AVAudioFile(forWriting: fileURL, settings: format.settings)

        currentChunkFile = audioFile
        currentChunkURL = fileURL
        currentChunkStartedAt = startedAt
    }

    private func finalizeCurrentChunk(at endedAt: Date) {
        guard let currentChunkURL,
              let currentChunkStartedAt else {
            return
        }

        chunks.append(
            AudioChunk(
                fileURL: currentChunkURL,
                startedAt: currentChunkStartedAt,
                endedAt: endedAt
            )
        )

        currentChunkFile = nil
        self.currentChunkURL = nil
        self.currentChunkStartedAt = nil
    }

    private func makeSessionDirectory(for sessionID: UUID) throws -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MyOwnVoice", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)

        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        return baseURL
    }
}
