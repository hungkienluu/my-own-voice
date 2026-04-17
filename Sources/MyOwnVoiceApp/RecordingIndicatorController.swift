import AppCore
import AppKit
import SwiftUI

@MainActor
final class RecordingIndicatorController: RecordingIndicatorPresenting {
    private let hostingController = NSHostingController(rootView: RecordingIndicatorView(phase: .recording))
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentViewController = hostingController
        return panel
    }()

    func showRecordingIndicator() {
        show(phase: .recording)
    }

    func showTranscribingIndicator() {
        show(phase: .transcribing)
    }

    func hideRecordingIndicator() {
        panel.orderOut(nil)
    }

    private func show(phase: RecordingIndicatorView.Phase) {
        hostingController.rootView = RecordingIndicatorView(phase: phase)
        let size = hostingController.view.fittingSize
        let frame = indicatorFrame(for: size)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    private func indicatorFrame(for size: NSSize) -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let origin = NSPoint(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.minY + 28
        )

        return NSRect(origin: origin, size: size)
    }
}

private struct RecordingIndicatorView: View {
    enum Phase {
        case recording
        case transcribing

        var title: String {
            switch self {
            case .recording:
                "Recording"
            case .transcribing:
                "Transcribing"
            }
        }

        var systemImage: String {
            switch self {
            case .recording:
                "mic.fill"
            case .transcribing:
                "waveform.and.magnifyingglass"
            }
        }

        var tint: Color {
            switch self {
            case .recording:
                .red
            case .transcribing:
                .orange
            }
        }
    }

    let phase: Phase
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(phase.tint.opacity(0.18))
                    .frame(width: 34, height: 34)
                    .scaleEffect(isAnimating ? 1.18 : 0.86)
                    .opacity(isAnimating ? 0.35 : 0.85)

                if phase == .recording {
                    Circle()
                        .fill(phase.tint)
                        .frame(width: 12, height: 12)
                        .scaleEffect(isAnimating ? 1.05 : 0.78)
                } else {
                    Image(systemName: phase.systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(phase.tint)
                        .rotationEffect(.degrees(isAnimating ? 360 : 0))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(phase.title)
                    .font(.headline)

                Text(phase == .recording ? "Listening for your dictation" : "Running local Whisper and Gemma")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(phase.tint.opacity(0.18), lineWidth: 1)
        )
        .onAppear {
            isAnimating = false

            withAnimation(animation) {
                isAnimating = true
            }
        }
        .onChange(of: phase) { _, _ in
            isAnimating = false

            withAnimation(animation) {
                isAnimating = true
            }
        }
    }

    private var animation: Animation {
        switch phase {
        case .recording:
            .easeInOut(duration: 0.95).repeatForever(autoreverses: true)
        case .transcribing:
            .linear(duration: 1.05).repeatForever(autoreverses: false)
        }
    }
}
