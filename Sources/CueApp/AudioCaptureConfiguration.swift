import AVFoundation
import CueCore
import Foundation

enum AudioCaptureMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case systemAndMicrophone
    case systemOnly
    case microphoneOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemAndMicrophone: "PC音声 + マイク"
        case .systemOnly: "PC音声のみ"
        case .microphoneOnly: "マイクのみ"
        }
    }

    var capturesSystemAudio: Bool {
        self != .microphoneOnly
    }

    var capturesMicrophone: Bool {
        self != .systemOnly
    }

    var enabledSources: [AudioSource] {
        switch self {
        case .systemAndMicrophone: [.system, .microphone]
        case .systemOnly: [.system]
        case .microphoneOnly: [.microphone]
        }
    }
}

struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isDefault: Bool
}

struct AudioCapturePreferences: Codable, Equatable, Sendable {
    var mode: AudioCaptureMode = .systemAndMicrophone
    var microphoneDeviceID: String?

    static let storageKey = "audioCapturePreferences.v1"

    static func load(
        defaults: UserDefaults = .standard
    ) -> AudioCapturePreferences {
        guard let data = defaults.data(forKey: storageKey),
              let preferences = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return preferences
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

struct AudioCaptureConfiguration: Equatable, Sendable {
    let capturesSystemAudio: Bool
    let capturesMicrophone: Bool
    let microphoneDeviceID: String?

    init(preferences: AudioCapturePreferences, devices: [AudioInputDevice]) {
        capturesSystemAudio = preferences.mode.capturesSystemAudio
        capturesMicrophone = preferences.mode.capturesMicrophone
        microphoneDeviceID = preferences.microphoneDeviceID.flatMap { selectedID in
            devices.contains(where: { $0.id == selectedID }) ? selectedID : nil
        }
    }

    var enabledSources: [AudioSource] {
        var sources: [AudioSource] = []
        if capturesSystemAudio { sources.append(.system) }
        if capturesMicrophone { sources.append(.microphone) }
        return sources
    }
}

enum AudioInputDeviceProvider {
    static func availableMicrophones() -> [AudioInputDevice] {
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
        return devices
            .map {
                AudioInputDevice(
                    id: $0.uniqueID,
                    name: $0.localizedName,
                    isDefault: $0.uniqueID == defaultID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}
