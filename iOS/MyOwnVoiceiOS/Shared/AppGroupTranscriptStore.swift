import Foundation
#if canImport(UIKit)
import UIKit
#endif

final class AppGroupTranscriptStore {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(appGroupID: String = SharedAppConfig.appGroupID) {
        defaults = UserDefaults(suiteName: appGroupID) ?? .standard
    }

    func saveLatestTranscript(_ record: SharedTranscriptRecord) throws {
        let data = try encoder.encode(record)
        defaults.set(data, forKey: SharedAppConfig.latestTranscriptKey)
        defaults.synchronize()

        #if canImport(UIKit)
        setPasteboardValue(record.text as NSString, forType: "public.utf8-plain-text")
        #endif
    }

    func latestTranscript() -> SharedTranscriptRecord? {
        if let data = defaults.data(forKey: SharedAppConfig.latestTranscriptKey),
           let record = try? decoder.decode(SharedTranscriptRecord.self, from: data) {
            return record
        }

        #if canImport(UIKit)
        if let pasteboardText = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !pasteboardText.isEmpty {
            return SharedTranscriptRecord(
                text: pasteboardText,
                modelName: "Pasteboard"
            )
        }
        #endif

        return nil
    }

    func requestRecordingFromKeyboard() {
        defaults.set(true, forKey: SharedAppConfig.recordingRequestKey)
        defaults.synchronize()

        #if canImport(UIKit)
        setPasteboardValue(UUID().uuidString as NSString, forType: SharedAppConfig.recordingRequestPasteboardType)
        #endif
    }

    func requestStopRecordingFromKeyboard() {
        defaults.set(true, forKey: SharedAppConfig.stopRecordingRequestKey)
        defaults.synchronize()

        #if canImport(UIKit)
        setPasteboardValue(UUID().uuidString as NSString, forType: SharedAppConfig.stopRecordingRequestPasteboardType)
        #endif
    }

    func consumeRecordingRequest() -> Bool {
        var wasRequested = defaults.bool(forKey: SharedAppConfig.recordingRequestKey)

        #if canImport(UIKit)
        if let pasteboardRequestID = pasteboardRecordingRequestID(),
           pasteboardRequestID != UserDefaults.standard.string(forKey: SharedAppConfig.consumedRecordingRequestKey) {
            UserDefaults.standard.set(pasteboardRequestID, forKey: SharedAppConfig.consumedRecordingRequestKey)
            wasRequested = true
        }
        #endif

        guard wasRequested else { return false }

        defaults.set(false, forKey: SharedAppConfig.recordingRequestKey)
        defaults.synchronize()
        return true
    }

    func consumeStopRecordingRequest() -> Bool {
        var wasRequested = defaults.bool(forKey: SharedAppConfig.stopRecordingRequestKey)

        #if canImport(UIKit)
        if let pasteboardRequestID = pasteboardString(forType: SharedAppConfig.stopRecordingRequestPasteboardType),
           pasteboardRequestID != UserDefaults.standard.string(forKey: SharedAppConfig.consumedStopRecordingRequestKey) {
            UserDefaults.standard.set(pasteboardRequestID, forKey: SharedAppConfig.consumedStopRecordingRequestKey)
            wasRequested = true
        }
        #endif

        guard wasRequested else { return false }

        defaults.set(false, forKey: SharedAppConfig.stopRecordingRequestKey)
        defaults.synchronize()
        return true
    }

    func saveRecordingState(_ state: SharedRecordingState) {
        if let data = try? encoder.encode(state) {
            defaults.set(data, forKey: SharedAppConfig.recordingStatePasteboardType)
            defaults.synchronize()

            #if canImport(UIKit)
            setPasteboardValue(data as NSData, forType: SharedAppConfig.recordingStatePasteboardType)
            #endif
        }
    }

    func latestRecordingState() -> SharedRecordingState {
        if let data = defaults.data(forKey: SharedAppConfig.recordingStatePasteboardType),
           let state = try? decoder.decode(SharedRecordingState.self, from: data) {
            return state
        }

        #if canImport(UIKit)
        if let data = pasteboardData(forType: SharedAppConfig.recordingStatePasteboardType),
           let state = try? decoder.decode(SharedRecordingState.self, from: data) {
            return state
        }
        #endif

        return SharedRecordingState(phase: .idle, message: "Ready.")
    }

    #if canImport(UIKit)
    private func pasteboardRecordingRequestID() -> String? {
        pasteboardString(forType: SharedAppConfig.recordingRequestPasteboardType)
    }

    private func pasteboardString(forType type: String) -> String? {
        for item in UIPasteboard.general.items {
            if let string = item[type] as? String {
                return string
            }

            if let string = item[type] as? NSString {
                return string as String
            }

            if let data = item[type] as? Data,
               let string = String(data: data, encoding: .utf8) {
                return string
            }
        }

        return nil
    }

    private func pasteboardData(forType type: String) -> Data? {
        for item in UIPasteboard.general.items {
            if let data = item[type] as? Data {
                return data
            }

            if let data = item[type] as? NSData {
                return data as Data
            }
        }

        return nil
    }

    private func setPasteboardValue(_ value: Any, forType type: String) {
        var items = UIPasteboard.general.items
        var firstItem = items.first ?? [:]
        firstItem[type] = value

        if items.isEmpty {
            items = [firstItem]
        } else {
            items[0] = firstItem
        }

        UIPasteboard.general.items = items
    }
    #endif
}
