import Foundation

enum SharedAppConfig {
    static let appGroupID = "group.com.hungkienluu.myownvoice"
    static let recorderURLScheme = "myownvoice"
    static let recorderURLHost = "record"
    static let latestTranscriptKey = "latestTranscriptRecord"
    static let recordingRequestKey = "keyboardRequestedRecording"
    static let stopRecordingRequestKey = "keyboardRequestedStopRecording"
    static let consumedRecordingRequestKey = "consumedKeyboardRecordingRequest"
    static let consumedStopRecordingRequestKey = "consumedKeyboardStopRecordingRequest"
    static let recordingRequestPasteboardType = "com.hungkienluu.myownvoice.recording-request"
    static let stopRecordingRequestPasteboardType = "com.hungkienluu.myownvoice.stop-recording-request"
    static let recordingStatePasteboardType = "com.hungkienluu.myownvoice.recording-state"
}

struct SharedTranscriptRecord: Codable, Equatable {
    let id: UUID
    let text: String
    let createdAt: Date
    let modelName: String

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        modelName: String
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.modelName = modelName
    }
}

enum SharedRecordingPhase: String, Codable, Equatable {
    case idle
    case recording
    case transcribing
    case ready
    case failed
}

struct SharedRecordingState: Codable, Equatable {
    let phase: SharedRecordingPhase
    let message: String
    let updatedAt: Date

    init(
        phase: SharedRecordingPhase,
        message: String,
        updatedAt: Date = Date()
    ) {
        self.phase = phase
        self.message = message
        self.updatedAt = updatedAt
    }
}
