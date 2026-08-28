import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: AppModel

    var body: some View {
        Button("Cueを開く") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Divider()
        if model.activeMeeting == nil {
            Button("会議を開始") {
                Task { await model.startMeeting() }
            }
            .disabled(
                model.selectedProject == nil ||
                    model.selectedProject?.archivedAt != nil
            )
        } else {
            Text(model.captureState.label)
            Button(
                "\(model.pauseControlTitle)（\(model.shortcutLabel(for: .togglePause))）"
            ) {
                Task { await model.toggleMeetingPause() }
            }
            .disabled(model.isBusy)
            Button(
                "サイドパネルを表示（\(model.shortcutLabel(for: .togglePanel))）"
            ) {
                model.showSidePanel()
            }
            if model.codexErrorDetail != nil {
                Button("\(model.selectedProviderDisplayName)を再接続") {
                    Task { await model.reconnectCodex() }
                }
                .disabled(model.isCodexConnecting)
            }
            Button("会議を終了") {
                Task { await model.stopMeeting() }
            }
        }
        Divider()
        Button("終了") {
            NSApplication.shared.terminate(nil)
        }
    }
}
