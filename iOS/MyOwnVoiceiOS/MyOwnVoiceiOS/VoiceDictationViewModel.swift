import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class VoiceDictationViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var statusMessage = "Ready."
    @Published var latestTranscript: SharedTranscriptRecord?
    @Published var selectedModelName = "tiny.en"

    private let recorder = VoiceRecorder()
    private let transcriber = WhisperKitTranscriber()
    private let store = AppGroupTranscriptStore()
    private var keyboardRequestTimer: Timer?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init() {
        saveState(.idle, "Ready.")
        startKeyboardRequestPolling()
    }

    deinit {
        keyboardRequestTimer?.invalidate()
    }

    func toggleRecording() {
        if isRecording {
            stopRecordingAndTranscribe()
        } else {
            startRecording()
        }
    }

    func handleOpenURL(_ url: URL) {
        guard url.scheme == SharedAppConfig.recorderURLScheme else { return }

        if url.host == SharedAppConfig.recorderURLHost || url.path.contains(SharedAppConfig.recorderURLHost) {
            if !isRecording && !isTranscribing {
                startRecording()
            }
        }
    }

    func refreshLatestTranscript() {
        latestTranscript = store.latestTranscript()
        processKeyboardRequests()
    }

    private func startKeyboardRequestPolling() {
        keyboardRequestTimer?.invalidate()
        keyboardRequestTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.processKeyboardRequests()
            }
        }
    }

    private func processKeyboardRequests() {
        if store.consumeStopRecordingRequest(), isRecording {
            stopRecordingAndTranscribe()
            return
        }

        if store.consumeRecordingRequest(), !isRecording, !isTranscribing {
            startRecording()
        }
    }

    func copyLatestTranscript() {
        guard let text = latestTranscript?.text, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        statusMessage = "Copied transcript."
    }

    private func startRecording() {
        Task {
            guard await requestMicrophoneAccess() else {
                statusMessage = "Microphone permission is required for recording."
                saveState(.failed, statusMessage)
                return
            }

            do {
                _ = try recorder.start()
                isRecording = true
                statusMessage = "Recording. Return to the previous app and tap Stop when done."
                saveState(.recording, statusMessage)
                beginBackgroundTaskIfNeeded()
            } catch {
                statusMessage = "Could not start recording: \(error.localizedDescription)"
                saveState(.failed, statusMessage)
            }
        }
    }

    private func stopRecordingAndTranscribe() {
        do {
            guard let audioURL = try recorder.stop() else {
                isRecording = false
                statusMessage = "No recording was captured."
                saveState(.idle, statusMessage)
                endBackgroundTaskIfNeeded()
                return
            }

            isRecording = false
            isTranscribing = true
            statusMessage = "Transcribing locally with \(selectedModelName)..."
            saveState(.transcribing, statusMessage)

            Task {
                do {
                    let transcript = try await transcriber.transcribe(
                        audioURL: audioURL,
                        modelName: selectedModelName
                    )
                    let record = SharedTranscriptRecord(
                        text: Self.cleanedTranscript(transcript),
                        modelName: selectedModelName
                    )

                    try store.saveLatestTranscript(record)
                    latestTranscript = record
                    statusMessage = "Transcript ready. Return to the keyboard and tap Insert."
                    saveState(.ready, statusMessage)
                } catch {
                    statusMessage = "Transcription failed: \(error.localizedDescription)"
                    saveState(.failed, statusMessage)
                }

                isTranscribing = false
                endBackgroundTaskIfNeeded()
            }
        } catch {
            isRecording = false
            statusMessage = "Could not stop recording: \(error.localizedDescription)"
            saveState(.failed, statusMessage)
            endBackgroundTaskIfNeeded()
        }
    }

    private func saveState(_ phase: SharedRecordingPhase, _ message: String) {
        store.saveRecordingState(SharedRecordingState(phase: phase, message: message))
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskID == .invalid else { return }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "MyOwnVoiceRecording") { [weak self] in
            Task { @MainActor in
                self?.endBackgroundTaskIfNeeded()
            }
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }

        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func cleanedTranscript(_ transcript: String) -> String {
        transcript
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
