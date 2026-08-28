import AVFoundation
import CoreGraphics
import Foundation

enum PermissionState: String, Sendable {
    case unknown
    case granted
    case denied
}

struct PermissionSnapshot: Sendable {
    let screenCapture: PermissionState
    let microphone: PermissionState

    var isReady: Bool {
        screenCapture == .granted && microphone == .granted
    }
}

enum PermissionCenter {
    static func current() -> PermissionSnapshot {
        let screen: PermissionState = CGPreflightScreenCaptureAccess()
            ? .granted
            : .unknown

        let microphone: PermissionState
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphone = .granted
        case .denied, .restricted:
            microphone = .denied
        case .notDetermined:
            microphone = .unknown
        @unknown default:
            microphone = .unknown
        }

        return PermissionSnapshot(
            screenCapture: screen,
            microphone: microphone
        )
    }

    static func request() async -> PermissionSnapshot {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        return current()
    }
}
