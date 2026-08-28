import Foundation

struct SpeakerDiarizationPreferences: Codable, Equatable, Sendable {
    var isEnabled = false

    static let storageKey = "speakerDiarizationPreferences.v1"

    static func load(
        defaults: UserDefaults = .standard
    ) -> SpeakerDiarizationPreferences {
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
