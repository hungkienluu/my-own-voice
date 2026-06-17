import AVFoundation
import Foundation

public final class AudioCaptureService {
    private struct CaptureSessionSnapshot {
        let sessionID: UUID
        let directoryURL: URL
        let manifestFileURL: URL?
        let startedAt: Date
    }

    private let engine = AVAudioEngine()
    private let fileManager: FileManager
    private let chunkDuration: TimeInterval
    private let stateQueue = DispatchQueue(label: "com.hungkienluu.myownvoice.audio-capture-state")

    private var sessionID: UUID?
    private var sessionDirectoryURL: URL?
    private var manifestFileURL: URL?
    private var sessionStartedAt: Date?
    private var currentChunkStartedAt: Date?
    private var currentChunkFile: AVAudioFile?
    private var currentChunkURL: URL?
    private var chunks: [AudioChunk] = []
    private var currentChunkSequence = 0
    private var isCapturingState = false

    public var isCapturing: Bool {
        stateQueue.sync { isCapturingState }
    }

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

        stateQueue.sync {
            self.sessionID = sessionID
            self.sessionDirectoryURL = sessionDirectory
            self.manifestFileURL = Self.manifestFileURL(in: sessionDirectory)
            self.sessionStartedAt = .now
            self.currentChunkStartedAt = nil
            self.currentChunkFile = nil
            self.currentChunkURL = nil
            self.chunks = []
            self.currentChunkSequence = 0
            writeManifest()
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            self?.write(buffer: buffer, format: inputFormat)
        }

        do {
            engine.prepare()
            stateQueue.sync {
                isCapturingState = true
            }
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            try? fileManager.removeItem(at: sessionDirectory)
            stateQueue.sync {
                clearSessionState()
            }
            throw error
        }
    }

    public func stop() -> AudioCaptureResult? {
        let sessionSnapshot = stateQueue.sync {
            takeStopSessionSnapshot()
        }

        guard let sessionSnapshot else {
            return nil
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let endedAt = Date()

        return stateQueue.sync {
            finishStoppedCapture(snapshot: sessionSnapshot, endedAt: endedAt)
        }
    }

    public func recoverableCaptureSessions() -> [RecoveredAudioCaptureSession] {
        recoverableCaptureSessions(in: Self.sessionsDirectoryURL(fileManager: fileManager))
    }

    func recoverableCaptureSessions(in sessionsDirectoryURL: URL) -> [RecoveredAudioCaptureSession] {
        guard let sessionDirectoryURLs = try? fileManager.contentsOfDirectory(
            at: sessionsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return sessionDirectoryURLs.compactMap(recoverableCaptureSession(in:))
            .sorted { lhs, rhs in
                lhs.manifest.startedAt > rhs.manifest.startedAt
            }
    }

    @MainActor
    public func importExistingAudioFile(at sourceFileURL: URL) async throws -> AudioCaptureResult {
        let sessionID = UUID()
        let sessionDirectoryURL = try makeSessionDirectory(for: sessionID)
        let manifestFileURL = Self.manifestFileURL(in: sessionDirectoryURL)
        let destinationURL = sessionDirectoryURL.appendingPathComponent(sourceFileURL.lastPathComponent)
        let startedAt = Date()

        do {
            try fileManager.copyItem(at: sourceFileURL, to: destinationURL)
            let duration = try await importedAudioDuration(at: destinationURL)
            let endedAt = startedAt.addingTimeInterval(duration)
            let chunk = AudioChunk(
                fileURL: destinationURL,
                startedAt: startedAt,
                endedAt: endedAt
            )
            try writeManifest(
                AudioCaptureManifest(
                    sessionID: sessionID,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    chunkDuration: chunkDuration,
                    chunks: [chunk]
                ),
                to: manifestFileURL
            )

            return AudioCaptureResult(
                sessionID: sessionID,
                directoryURL: sessionDirectoryURL,
                manifestFileURL: manifestFileURL,
                startedAt: startedAt,
                endedAt: endedAt,
                chunks: [chunk]
            )
        } catch {
            try? fileManager.removeItem(at: sessionDirectoryURL)
            throw error
        }
    }

    private func write(buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        stateQueue.sync {
            guard isCapturingState else { return }

            let now = Date()

            do {
                if currentChunkFile == nil {
                    try startNewChunk(format: format, at: now)
                } else if let currentChunkStartedAt,
                          now.timeIntervalSince(currentChunkStartedAt) >= chunkDuration {
                    finalizeCurrentChunk(at: now)
                    try startNewChunk(format: format, at: now)
                }
            } catch {
                NSLog("MyOwnVoice failed to start audio chunk: \(error.localizedDescription)")
                return
            }

            do {
                try currentChunkFile?.write(from: buffer)
            } catch {
                NSLog("MyOwnVoice failed to write audio chunk: \(error.localizedDescription)")
            }
        }
    }

    private func startNewChunk(format: AVAudioFormat, at startedAt: Date) throws {
        guard let sessionDirectoryURL else { return }

        currentChunkSequence += 1
        let fileURL = sessionDirectoryURL.appendingPathComponent(
            Self.chunkFileName(startedAt: startedAt, sequence: currentChunkSequence)
        )
        let audioFile = try AVAudioFile(forWriting: fileURL, settings: format.settings)

        currentChunkFile = audioFile
        currentChunkURL = fileURL
        currentChunkStartedAt = startedAt
        writeManifest()
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
        writeManifest()
    }

    private func takeStopSessionSnapshot() -> CaptureSessionSnapshot? {
        guard isCapturingState,
              let sessionID,
              let sessionDirectoryURL,
              let sessionStartedAt else {
            return nil
        }

        isCapturingState = false
        return CaptureSessionSnapshot(
            sessionID: sessionID,
            directoryURL: sessionDirectoryURL,
            manifestFileURL: manifestFileURL,
            startedAt: sessionStartedAt
        )
    }

    private func finishStoppedCapture(
        snapshot: CaptureSessionSnapshot,
        endedAt: Date
    ) -> AudioCaptureResult {
        finalizeCurrentChunk(at: endedAt)
        writeManifest(endedAt: endedAt)

        let result = AudioCaptureResult(
            sessionID: snapshot.sessionID,
            directoryURL: snapshot.directoryURL,
            manifestFileURL: snapshot.manifestFileURL,
            startedAt: snapshot.startedAt,
            endedAt: endedAt,
            chunks: chunks
        )
        clearSessionState()
        return result
    }

    private func writeManifest(endedAt: Date? = nil) {
        guard let sessionID,
              let sessionStartedAt,
              let manifestFileURL else {
            return
        }

        let manifest = AudioCaptureManifest(
            sessionID: sessionID,
            startedAt: sessionStartedAt,
            endedAt: endedAt,
            chunkDuration: chunkDuration,
            chunks: manifestChunks(endedAt: endedAt)
        )

        do {
            try writeManifest(manifest, to: manifestFileURL)
        } catch {
            NSLog("MyOwnVoice failed to write audio capture manifest: \(error.localizedDescription)")
        }
    }

    private func writeManifest(
        _ manifest: AudioCaptureManifest,
        to fileURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(manifest)
        try data.write(to: fileURL, options: [.atomic])
    }

    private func manifestChunks(endedAt: Date?) -> [AudioChunk] {
        guard endedAt == nil,
              let currentChunkURL,
              let currentChunkStartedAt else {
            return chunks
        }

        if chunks.contains(where: { $0.fileURL == currentChunkURL }) {
            return chunks
        }

        return chunks + [
            AudioChunk(
                fileURL: currentChunkURL,
                startedAt: currentChunkStartedAt,
                endedAt: Date()
            )
        ]
    }

    @MainActor
    private func importedAudioDuration(at fileURL: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration).seconds

        guard duration.isFinite, duration > 0 else {
            return 0
        }

        return duration
    }

    private func makeSessionDirectory(for sessionID: UUID) throws -> URL {
        let baseURL = Self.sessionsDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)

        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        return baseURL
    }

    private func clearSessionState() {
        sessionID = nil
        sessionDirectoryURL = nil
        manifestFileURL = nil
        sessionStartedAt = nil
        currentChunkStartedAt = nil
        currentChunkFile = nil
        currentChunkURL = nil
        chunks = []
        currentChunkSequence = 0
        isCapturingState = false
    }

#if DEBUG
    func debugSeedCapturingSession(
        sessionID: UUID,
        directoryURL: URL,
        manifestFileURL: URL,
        startedAt: Date,
        chunks: [AudioChunk],
        currentChunkURL: URL? = nil,
        currentChunkStartedAt: Date? = nil
    ) {
        stateQueue.sync {
            self.sessionID = sessionID
            sessionDirectoryURL = directoryURL
            self.manifestFileURL = manifestFileURL
            sessionStartedAt = startedAt
            self.currentChunkStartedAt = currentChunkStartedAt
            currentChunkFile = nil
            self.currentChunkURL = currentChunkURL
            self.chunks = chunks
            currentChunkSequence = chunks.count
            isCapturingState = true
            writeManifest()
        }
    }

    func debugFinishSeededStoppedCapture(endedAt: Date) -> AudioCaptureResult? {
        let snapshot = stateQueue.sync {
            takeStopSessionSnapshot()
        }

        guard let snapshot else {
            return nil
        }

        return stateQueue.sync {
            finishStoppedCapture(snapshot: snapshot, endedAt: endedAt)
        }
    }

    func debugStateSnapshot() -> (
        hasSession: Bool,
        hasManifestURL: Bool,
        chunkCount: Int,
        currentChunkSequence: Int,
        isCapturing: Bool
    ) {
        stateQueue.sync {
            (
                sessionID != nil || sessionDirectoryURL != nil || sessionStartedAt != nil,
                manifestFileURL != nil,
                chunks.count,
                currentChunkSequence,
                isCapturingState
            )
        }
    }
#endif

    nonisolated static func chunkFileName(startedAt: Date, sequence: Int) -> String {
        let timestamp = ISO8601DateFormatter()
            .string(from: startedAt)
            .replacingOccurrences(of: ":", with: "-")
        return String(format: "%04d-%@.caf", max(0, sequence), timestamp)
    }

    private func recoverableCaptureSession(in sessionDirectoryURL: URL) -> RecoveredAudioCaptureSession? {
        let manifestFileURL = Self.manifestFileURL(in: sessionDirectoryURL)
        guard let data = try? Data(contentsOf: manifestFileURL) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let manifest = try? decoder.decode(AudioCaptureManifest.self, from: data),
              !manifest.isComplete else {
            return nil
        }

        let availableChunks = manifest.chunks.filter { chunk in
            Self.hasRecoverableAudioChunk(at: chunk.fileURL, fileManager: fileManager)
        }

        guard !availableChunks.isEmpty else {
            return nil
        }

        let availableManifest = AudioCaptureManifest(
            schemaVersion: manifest.schemaVersion,
            sessionID: manifest.sessionID,
            startedAt: manifest.startedAt,
            endedAt: manifest.endedAt,
            chunkDuration: manifest.chunkDuration,
            chunks: availableChunks
        )

        return RecoveredAudioCaptureSession(
            directoryURL: sessionDirectoryURL,
            manifestFileURL: manifestFileURL,
            manifest: availableManifest
        )
    }

    private static func sessionsDirectoryURL(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MyOwnVoice", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
    }

    nonisolated static func hasRecoverableAudioChunk(
        at fileURL: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return false
        }

        return fileSize.int64Value > 0
    }

    private static func manifestFileURL(in sessionDirectoryURL: URL) -> URL {
        sessionDirectoryURL.appendingPathComponent("capture-manifest.json")
    }
}
