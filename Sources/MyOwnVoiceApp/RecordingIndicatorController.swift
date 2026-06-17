import AppCore
import AppKit
import SwiftUI

@MainActor
final class RecordingIndicatorController: RecordingIndicatorPresenting {
    private let hostingController = NSHostingController(
        rootView: RecordingIndicatorHostView(snapshot: nil, style: .detailed, maxWidth: 1)
    )
    private var autoDismissTask: Task<Void, Never>?

    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 128),
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

    func showDictationHUD(_ snapshot: DictationHUDSnapshot, style: DictationHUDStyle) {
        autoDismissTask?.cancel()
        autoDismissTask = nil

        let visibleFrame = indicatorVisibleFrame()
        let maxWidth = Self.maxHUDWidth(for: style, in: visibleFrame)
        hostingController.rootView = RecordingIndicatorHostView(
            snapshot: snapshot,
            style: style,
            maxWidth: maxWidth
        )
        hostingController.view.layoutSubtreeIfNeeded()

        let size = Self.panelSize(
            fittingSize: hostingController.view.fittingSize,
            style: style,
            maxWidth: maxWidth,
            visibleFrame: visibleFrame
        )

        panel.setFrame(indicatorFrame(for: size, in: visibleFrame), display: true)
        panel.orderFrontRegardless()

        if snapshot.isTerminal {
            scheduleAutoDismiss()
        }
    }

    func hideRecordingIndicator() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        hostingController.rootView = RecordingIndicatorHostView(snapshot: nil, style: .detailed, maxWidth: 1)
        panel.orderOut(nil)
    }

    private func scheduleAutoDismiss() {
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.hideRecordingIndicator()
        }
    }

    private static func maxHUDWidth(for style: DictationHUDStyle, in visibleFrame: NSRect) -> CGFloat {
        switch style {
        case .detailed:
            if let override = ProcessInfo.processInfo.environment["MY_OWN_VOICE_HUD_MAX_WIDTH"].flatMap(Double.init) {
                return max(260, min(440, CGFloat(override)))
            }

            return max(260, min(440, visibleFrame.width - 32))
        case .compact:
            return max(180, min(300, visibleFrame.width - 32))
        }
    }

    private static func panelSize(
        fittingSize: NSSize,
        style: DictationHUDStyle,
        maxWidth: CGFloat,
        visibleFrame: NSRect
    ) -> NSSize {
        var size = fittingSize

        switch style {
        case .detailed:
            size.width = max(min(maxWidth, 320), min(maxWidth, size.width))
            size.height = min(max(96, size.height), max(96, visibleFrame.height - 32))
        case .compact:
            size.width = min(maxWidth, max(184, size.width))
            size.height = min(max(58, size.height), max(58, visibleFrame.height - 32))
        }

        return size
    }

    private func indicatorVisibleFrame() -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 440, height: 180)
    }

    private func indicatorFrame(for size: NSSize, in visibleFrame: NSRect) -> NSRect {
        let origin = NSPoint(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.minY + 28
        )

        return NSRect(origin: origin, size: size)
    }
}

private struct RecordingIndicatorHostView: View {
    let snapshot: DictationHUDSnapshot?
    let style: DictationHUDStyle
    let maxWidth: CGFloat

    @ViewBuilder
    var body: some View {
        if let snapshot {
            switch style {
            case .detailed:
                RecordingIndicatorView(snapshot: snapshot)
                    .frame(width: maxWidth, alignment: .leading)
            case .compact:
                CompactRecordingIndicatorView(snapshot: snapshot)
                    .frame(maxWidth: maxWidth, alignment: .leading)
            }
        } else {
            Color.clear
                .frame(width: 1, height: 1)
        }
    }
}

private struct RecordingIndicatorView: View {
    let snapshot: DictationHUDSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                PhaseActivityGlyph(phase: snapshot.phase, tint: tint, size: 42)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(snapshot.title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        statusPill
                    }

                    Text(snapshot.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let progress = snapshot.progress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(tint)

                    if let progressLabel = snapshot.progressLabel {
                        Text(progressLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else if let progressLabel = snapshot.progressLabel {
                Text(progressLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let previewText = snapshot.previewText {
                Divider()

                VStack(alignment: .leading, spacing: 3) {
                    Label("Last heard", systemImage: "text.quote")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(previewText)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.disabled)
                }
            }

            if let recoveryText = snapshot.recoveryText {
                Divider()

                Label {
                    Text(recoveryText)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: recoverySymbol)
                        .foregroundStyle(tint)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.54),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Image(systemName: modeSymbol)
                .font(.caption2.weight(.semibold))

            Text(snapshot.mode.displayName)
                .lineLimit(1)

            if let startedAt = snapshot.startedAt {
                Text("-")
                    .foregroundStyle(.tertiary)

                ElapsedTimeText(startedAt: startedAt)
                    .monospacedDigit()
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.08), in: Capsule())
    }

    private var tint: Color {
        switch snapshot.phase {
        case .recording:
            return .red
        case .transcribing:
            return .orange
        case .polishing, .inserting:
            return .accentColor
        case .inserted, .saved:
            return .green
        case .recovery:
            return .orange
        case .failed:
            return .red
        }
    }

    private var modeSymbol: String {
        switch snapshot.mode {
        case .quickDictation:
            return "bolt.fill"
        case .longSession:
            return "waveform"
        case .meetingTranscript:
            return "person.2.fill"
        }
    }

    private var recoverySymbol: String {
        switch snapshot.phase {
        case .failed:
            return "exclamationmark.triangle.fill"
        case .recovery:
            return "doc.on.clipboard.fill"
        default:
            return "checkmark.circle.fill"
        }
    }

    private var accessibilitySummary: String {
        [
            snapshot.title,
            snapshot.mode.displayName,
            snapshot.detail,
            snapshot.progressLabel,
            snapshot.previewText,
            snapshot.recoveryText,
        ]
        .compactMap { $0 }
        .joined(separator: ". ")
    }
}

private struct CompactRecordingIndicatorView: View {
    let snapshot: DictationHUDSnapshot

    var body: some View {
        HStack(spacing: 12) {
            PhaseActivityGlyph(phase: snapshot.phase, tint: tint, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(compactDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(tint.opacity(0.18), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.title). \(compactDetail)")
    }

    private var compactDetail: String {
        switch snapshot.phase {
        case .recording:
            return "Listening for your dictation"
        case .transcribing:
            return "Transcribing locally"
        case .polishing:
            return "Polishing transcript"
        case .inserting:
            return "Inserting text"
        case .inserted, .saved, .recovery, .failed:
            return snapshot.recoveryText ?? snapshot.detail
        }
    }

    private var tint: Color {
        switch snapshot.phase {
        case .recording:
            return .red
        case .transcribing:
            return .orange
        case .polishing, .inserting:
            return .accentColor
        case .inserted, .saved:
            return .green
        case .recovery:
            return .orange
        case .failed:
            return .red
        }
    }
}

private struct ElapsedTimeText: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Text(Self.formattedElapsed(from: startedAt, to: timeline.date))
        }
    }

    private static func formattedElapsed(from startedAt: Date, to now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        let hours = elapsed / 3_600
        let minutes = (elapsed % 3_600) / 60
        let seconds = elapsed % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct PhaseActivityGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let phase: DictationHUDPhase
    let tint: Color
    let size: CGFloat

    var body: some View {
        if reduceMotion {
            staticGlyph
        } else {
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
                animatedGlyph(elapsed: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private var staticGlyph: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.12))

            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }

    private func animatedGlyph(elapsed: TimeInterval) -> some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.12))

            switch phase {
            case .recording:
                recordingGlyph(elapsed: elapsed)
            case .transcribing, .polishing, .inserting:
                activeProcessingGlyph(elapsed: elapsed)
            case .inserted, .saved, .recovery, .failed:
                Image(systemName: symbol)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
    }

    private func recordingGlyph(elapsed: TimeInterval) -> some View {
        let pulse = (sin(elapsed * 4.4) + 1) / 2

        return ZStack {
            Circle()
                .strokeBorder(tint.opacity(0.18 + pulse * 0.24), lineWidth: 2)
                .scaleEffect(0.76 + pulse * 0.18)

            Circle()
                .fill(tint)
                .frame(width: size * 0.24, height: size * 0.24)
                .shadow(color: tint.opacity(0.28), radius: 8, y: 3)
        }
    }

    private func activeProcessingGlyph(elapsed: TimeInterval) -> some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.16), lineWidth: 3)

            Circle()
                .trim(from: 0.08, to: 0.72)
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(elapsed * 110))
                .padding(3)

            HStack(spacing: 2.5) {
                ForEach(0..<4, id: \.self) { index in
                    let wave = (sin(elapsed * 5 + Double(index) * 0.72) + 1) / 2

                    Capsule()
                        .fill(tint)
                        .frame(width: 3, height: 8 + CGFloat(wave) * 12)
                }
            }
        }
    }

    private var symbol: String {
        switch phase {
        case .recording:
            return "mic.fill"
        case .transcribing:
            return "waveform"
        case .polishing:
            return "sparkles"
        case .inserting:
            return "text.cursor"
        case .inserted:
            return "checkmark.circle.fill"
        case .saved:
            return "tray.and.arrow.down.fill"
        case .recovery:
            return "doc.on.clipboard.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }
}
