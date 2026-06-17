import AVFoundation
import Foundation

final class VoiceRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var activeRecordingURL: URL?

    func start() throws -> URL {
        guard recorder == nil else {
            if let activeRecordingURL {
                return activeRecordingURL
            }
            throw VoiceRecorderError.alreadyRecording
        }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.allowBluetooth, .defaultToSpeaker]
        )
        try audioSession.setActive(true)

        let fileURL = Self.makeRecordingURL()
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        recorder.record()

        self.recorder = recorder
        activeRecordingURL = fileURL
        return fileURL
    }

    func stop() throws -> URL? {
        guard let recorder else {
            return nil
        }

        let recordedURL = activeRecordingURL ?? recorder.url
        recorder.stop()
        self.recorder = nil
        activeRecordingURL = nil
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return recordedURL
    }

    private static func makeRecordingURL() -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyOwnVoiceRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        return directoryURL
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
    }
}

enum VoiceRecorderError: LocalizedError {
    case alreadyRecording

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "A recording is already active."
        }
    }
}
