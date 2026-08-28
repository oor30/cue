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

    func isReady(requiresMicrophone: Bool) -> Bool {
        screenCapture == .granted &&
            (!requiresMicrophone || microphone == .granted)
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

    static func request(requiresMicrophone: Bool = true) async -> PermissionSnapshot {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        if requiresMicrophone,
           AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        return current()
    }
}
