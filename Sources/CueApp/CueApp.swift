import SwiftUI

@main
struct CueApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Label("Cue", systemImage: menuBarIcon)
        }

        Window("Cue", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 860, minHeight: 620)
        }
        .defaultSize(width: 1_000, height: 720)

        Settings {
            SettingsView(model: model)
                .frame(width: 640, height: 620)
        }
    }

    private var menuBarIcon: String {
        model.activeMeeting == nil ? "waveform.badge.mic" : "waveform.circle.fill"
    }
}
