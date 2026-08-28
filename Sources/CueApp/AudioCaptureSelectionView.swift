import SwiftUI

struct AudioCaptureSelectionView: View {
    @Bindable var model: AppModel

    private let defaultMicrophoneToken = "__cue_default_microphone__"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(
                "音声ソース",
                selection: Binding(
                    get: { model.audioCapturePreferences.mode },
                    set: { model.updateAudioCaptureMode($0) }
                )
            ) {
                ForEach(AudioCaptureMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)

            if model.audioCapturePreferences.mode.capturesMicrophone {
                Picker(
                    "マイク",
                    selection: Binding(
                        get: {
                            model.audioCapturePreferences.microphoneDeviceID
                                ?? defaultMicrophoneToken
                        },
                        set: { value in
                            model.updateMicrophoneDevice(
                                id: value == defaultMicrophoneToken ? nil : value
                            )
                        }
                    )
                ) {
                    Text("PCのデフォルト").tag(defaultMicrophoneToken)
                    ForEach(model.microphoneDevices) { device in
                        Text(
                            device.isDefault
                                ? "\(device.name)（現在のデフォルト）"
                                : device.name
                        )
                        .tag(device.id)
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: 8) {
                    Text("外部ヘッドフォンは、ヘッドフォンに付属するマイクを選択します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("再検出") {
                        model.refreshAudioInputDevices()
                    }
                    .font(.caption)
                }
            } else {
                Text("Zoomなど、Macで再生されているPC音声だけを対象にします。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(model.activeMeeting != nil)
        .task {
            model.refreshAudioInputDevices()
        }
    }
}
