import AppCore
import SwiftUI

struct StatusMenuView: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var coordinator: DictationCoordinator
    @ObservedObject private var permissionCenter: PermissionCenter

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        _permissionCenter = ObservedObject(wrappedValue: coordinator.permissionCenter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            primaryCard

            if !permissionNotices.isEmpty {
                permissionCard
            }

            if let lastTranscript = coordinator.lastTranscript, !coordinator.isProcessingCapture {
                latestTranscriptCard(lastTranscript)
            }

            footer
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text("My Own Voice")
                    .font(.title3.weight(.semibold))

                statusBadge

                if coordinator.isProcessingCapture {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer(minLength: 10)

                Button(action: openSettingsWindow) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 30, height: 30)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Open Settings")
            }

            Label(coordinator.shortcutSummary, systemImage: "keyboard")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            Text(statusTitle)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.14), in: Capsule())
    }

    private var primaryCard: some View {
        SurfaceCard {
            HStack(alignment: .center, spacing: 14) {
                Button(action: coordinator.toggleRecordingFromUI) {
                    ZStack {
                        Circle()
                            .fill(primaryButtonFill)

                        Circle()
                            .strokeBorder(.white.opacity(0.18), lineWidth: 1)

                        if coordinator.isProcessingCapture {
                            ProgressView()
                                .tint(.white)
                                .controlSize(.regular)
                        } else {
                            Image(systemName: primaryButtonSymbol)
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 76, height: 76)
                    .shadow(color: statusColor.opacity(0.18), radius: 14, y: 8)
                }
                .buttonStyle(.plain)
                .disabled(coordinator.isProcessingCapture)
                .help(primaryActionTitle)

                VStack(alignment: .leading, spacing: 8) {
                    Text(primaryActionTitle)
                        .font(.headline.weight(.semibold))

                    Text(primaryActionSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    modeMenu
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var modeMenu: some View {
        Menu {
            ForEach(SessionMode.allCases) { mode in
                Button {
                    coordinator.sessionMode = mode
                } label: {
                    if mode == coordinator.sessionMode {
                        Label(mode.displayName, systemImage: "checkmark")
                    } else {
                        Text(mode.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol(for: coordinator.sessionMode))
                Text(coordinator.sessionMode.displayName)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .help("Choose recording mode")
    }

    private var permissionCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(permissionNotices) { notice in
                    HStack(alignment: .center, spacing: 12) {
                        Label(notice.title, systemImage: notice.symbol)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)

                        Spacer(minLength: 10)

                        Button(notice.actionTitle, action: notice.action)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func latestTranscriptCard(_ transcript: String) -> some View {
        SurfaceCard {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Latest Transcript")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(transcript)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Button("Copy") {
                        coordinator.copyLastTranscript()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Insert") {
                        coordinator.insertLastTranscript()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(footerMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var statusTitle: String {
        if coordinator.isRecording {
            return "Recording"
        }

        if coordinator.isProcessingCapture {
            return "Transcribing"
        }

        return "Ready"
    }

    private var statusColor: Color {
        if coordinator.isRecording {
            return .red
        }

        if coordinator.isProcessingCapture {
            return .orange
        }

        return .accentColor
    }

    private var primaryButtonFill: LinearGradient {
        LinearGradient(
            colors: [
                statusColor.opacity(0.95),
                statusColor.opacity(0.78),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var primaryButtonSymbol: String {
        if coordinator.isRecording {
            return "stop.fill"
        }

        return "mic.fill"
    }

    private var primaryActionTitle: String {
        if coordinator.isRecording {
            return "Stop Recording"
        }

        if coordinator.isProcessingCapture {
            return "Transcribing"
        }

        switch coordinator.sessionMode {
        case .meetingTranscript:
            return "Start Meeting Capture"
        case .quickDictation, .longSession:
            return "Start Recording"
        }
    }

    private var primaryActionSubtitle: String {
        if coordinator.isRecording {
            switch coordinator.sessionMode {
            case .meetingTranscript:
                return "Capture is running until you stop it."
            case .quickDictation, .longSession:
                return "Speak naturally. The transcript appears when you stop."
            }
        }

        if coordinator.isProcessingCapture {
            switch coordinator.sessionMode {
            case .meetingTranscript:
                return "Building your timestamped local transcript."
            case .quickDictation, .longSession:
                return "Cleaning up your latest capture."
            }
        }

        switch coordinator.sessionMode {
        case .quickDictation:
            return "Ready for short, fast dictation."
        case .longSession:
            return "Ready for longer thoughts and recovery."
        case .meetingTranscript:
            return "Ready to save a local meeting transcript."
        }
    }

    private var footerMessage: String {
        if coordinator.statusMessage == "Ready." {
            return "More controls live in Settings."
        }

        return coordinator.statusMessage
    }

    private var permissionNotices: [PermissionNotice] {
        var notices: [PermissionNotice] = []

        if !permissionCenter.microphone.isGranted {
            notices.append(
                PermissionNotice(
                    title: "Microphone Access",
                    detail: "Recording starts as soon as the microphone is available.",
                    symbol: "mic.fill",
                    actionTitle: permissionCenter.microphone == .unknown ? "Allow" : "Grant"
                ) {
                    coordinator.requestPermission(.microphone)
                }
            )
        }

        if coordinator.recordingPreferences.autoInsertIntoFocusedField && !permissionCenter.accessibility.isGranted {
            notices.append(
                PermissionNotice(
                    title: "Accessibility",
                    detail: "Grant this if you want transcripts inserted into the focused field.",
                    symbol: "accessibility",
                    actionTitle: "Grant"
                ) {
                    coordinator.requestPermission(.accessibility)
                }
            )
        }

        if coordinator.sessionMode == .meetingTranscript && !permissionCenter.screenCapture.isGranted {
            notices.append(
                PermissionNotice(
                    title: "Screen Capture",
                    detail: "Meeting capture works best after Screen Capture is enabled in System Settings.",
                    symbol: "display",
                    actionTitle: "Grant"
                ) {
                    coordinator.requestPermission(.screenCapture)
                }
            )
        }

        return notices
    }

    private func symbol(for mode: SessionMode) -> String {
        switch mode {
        case .quickDictation:
            return "bolt.fill"
        case .longSession:
            return "waveform"
        case .meetingTranscript:
            return "person.2.fill"
        }
    }

    private func openSettingsWindow() {
        openSettings()
        SettingsWindowController.revealSettingsWindow()
    }
}

private struct SurfaceCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct PermissionNotice: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let symbol: String
    let actionTitle: String
    let action: () -> Void
}
