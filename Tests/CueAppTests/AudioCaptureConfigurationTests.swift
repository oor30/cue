import CueCore
import Foundation
import Testing

@testable import CueApp

@Suite("AudioCaptureConfigurationTests")
struct AudioCaptureConfigurationTests {
    @Test func mapsEachModeToTheExpectedAudioSources() {
        let devices = [
            AudioInputDevice(id: "external", name: "Headset Microphone", isDefault: false)
        ]

        let both = AudioCaptureConfiguration(
            preferences: AudioCapturePreferences(
                mode: .systemAndMicrophone,
                microphoneDeviceID: "external"
            ),
            devices: devices
        )
        #expect(both.enabledSources == [.system, .microphone])
        #expect(both.microphoneDeviceID == "external")

        let system = AudioCaptureConfiguration(
            preferences: AudioCapturePreferences(mode: .systemOnly),
            devices: devices
        )
        #expect(system.enabledSources == [.system])
        #expect(!system.capturesMicrophone)

        let microphone = AudioCaptureConfiguration(
            preferences: AudioCapturePreferences(mode: .microphoneOnly),
            devices: devices
        )
        #expect(microphone.enabledSources == [.microphone])
        #expect(!microphone.capturesSystemAudio)
    }

    @Test func fallsBackToTheSystemDefaultWhenADeviceIsDisconnected() {
        let configuration = AudioCaptureConfiguration(
            preferences: AudioCapturePreferences(
                mode: .systemAndMicrophone,
                microphoneDeviceID: "disconnected"
            ),
            devices: []
        )

        #expect(configuration.microphoneDeviceID == nil)
    }

    @Test func addsThePauseShortcutWhenLoadingLegacySettings() throws {
        let legacyJSON = """
        {
          "togglePanel": "controlOption",
          "deepAnalyze": "option",
          "questionCandidates": "commandOption",
          "answerCandidate": "disabled"
        }
        """
        let configuration = try JSONDecoder().decode(
            GlobalShortcutConfiguration.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(configuration.togglePanel == .controlOption)
        #expect(configuration.answerCandidate == .disabled)
        #expect(configuration.togglePause == .option)
        #expect(configuration.label(for: .togglePause) == "⌥P")
    }
}
