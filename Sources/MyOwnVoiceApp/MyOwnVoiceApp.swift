import AppCore
import SwiftUI

@main
struct MyOwnVoiceApp: App {
    private let recordingIndicatorController: RecordingIndicatorController
    @StateObject private var coordinator: DictationCoordinator

    init() {
        let recordingIndicatorController = RecordingIndicatorController()
        self.recordingIndicatorController = recordingIndicatorController
        _coordinator = StateObject(
            wrappedValue: DictationCoordinator(recordingIndicatorPresenter: recordingIndicatorController)
        )
    }

    var body: some Scene {
        MenuBarExtra(
            "My Own Voice",
            systemImage: menuBarSystemImage
        ) {
            StatusMenuView(coordinator: coordinator)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(coordinator: coordinator)
                .frame(minWidth: 1040, idealWidth: 1120, minHeight: 680, idealHeight: 760)
        }
    }

    private var menuBarSystemImage: String {
        if coordinator.isRecording {
            return "waveform.badge.mic"
        }

        if coordinator.isProcessingCapture {
            return "waveform.and.magnifyingglass"
        }

        return "waveform.circle"
    }
}
