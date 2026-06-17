import ApplicationServices
import AVFoundation
import Combine
import CoreGraphics
import AppKit
import Foundation

@MainActor
public final class PermissionCenter: ObservableObject {
    @Published public private(set) var microphone: PermissionState = .unknown
    @Published public private(set) var accessibility: PermissionState = .unknown
    @Published public private(set) var screenCapture: PermissionState = .unknown

    private var cancellables: Set<AnyCancellable> = []

    public init() {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            .store(in: &cancellables)

        refresh()
    }

    public func state(for kind: PermissionKind) -> PermissionState {
        switch kind {
        case .microphone:
            microphone
        case .accessibility:
            accessibility
        case .screenCapture:
            screenCapture
        }
    }

    public func refresh() {
        microphone = mapMicrophoneStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        accessibility = AXIsProcessTrusted() ? .granted : .denied
        screenCapture = CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    public func request(_ kind: PermissionKind) {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                    Task { @MainActor in
                        self?.refresh()
                    }
                }
            case .authorized:
                refresh()
            case .denied, .restricted:
                openPrivacySettings(anchor: "Privacy_Microphone")
                refresh()
                scheduleFollowupRefresh(until: \.microphone)
            @unknown default:
                openPrivacySettings(anchor: "Privacy_Microphone")
                refresh()
                scheduleFollowupRefresh(until: \.microphone)
            }
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            openPrivacySettings(anchor: "Privacy_Accessibility")
            refresh()
            scheduleFollowupRefresh(until: \.accessibility)
        case .screenCapture:
            _ = CGRequestScreenCaptureAccess()
            openPrivacySettings(anchor: "Privacy_ScreenCapture")
            refresh()
            scheduleFollowupRefresh(until: \.screenCapture)
        }
    }

    private func mapMicrophoneStatus(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized:
            .granted
        case .notDetermined:
            .unknown
        case .denied, .restricted:
            .denied
        @unknown default:
            .unknown
        }
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func scheduleFollowupRefresh(until keyPath: KeyPath<PermissionCenter, PermissionState>) {
        Task { @MainActor in
            for _ in 0..<15 {
                try? await Task.sleep(for: .seconds(1))
                refresh()

                if self[keyPath: keyPath].isGranted {
                    break
                }
            }
        }
    }
}
