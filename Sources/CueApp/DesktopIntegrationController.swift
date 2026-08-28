import AppKit
import CueCore
import SwiftUI

@MainActor
final class DesktopIntegrationController {
    private let model: AppModel
    private let hotKeyManager = GlobalHotKeyManager()
    private lazy var meetingAppMonitor = MeetingAppMonitor { [weak model] detection in
        model?.offerMeetingAppDetection(detection)
    }

    private var sidePanel: RightSidePanel?
    private var notificationPanel: RightSidePanel?
    private var detectionPanel: RightSidePanel?
    private var notificationDismissTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
    }

    func install() {
        reloadHotKeys()
        meetingAppMonitor.start()
    }

    func reloadHotKeys() {
        let failures = hotKeyManager.install(
            configuration: model.shortcutConfiguration,
            handlers: [
            .togglePanel: { [weak model] in
                model?.toggleSidePanel()
            },
            .deepAnalyze: { [weak model] in
                Task { await model?.performManualAnalysis(.deepAnalyze) }
            },
            .questionCandidates: { [weak model] in
                Task { await model?.performManualAnalysis(.questionCandidates) }
            },
            .answerCandidate: { [weak model] in
                Task { await model?.performManualAnalysis(.answerCandidate) }
            },
            .togglePause: { [weak model] in
                Task { await model?.toggleMeetingPause() }
            }
        ])
        model.shortcutStatus = failures.isEmpty
            ? "有効（\(model.shortcutConfiguration.enabledCount)件）"
            : "一部登録失敗（他のアプリとの競合の可能性）"
    }

    func showSidePanel() {
        let panel = sidePanel ?? makeSidePanel()
        positionSidePanel(panel)
        panel.orderFrontRegardless()
    }

    func hideSidePanel() {
        sidePanel?.orderOut(nil)
    }

    func toggleSidePanel() {
        if sidePanel?.isVisible == true {
            hideSidePanel()
        } else {
            showSidePanel()
        }
    }

    func showSuggestionNotification(_ card: SuggestionCard) {
        guard card.importance >= .high else { return }
        notificationDismissTask?.cancel()

        let panel = notificationPanel ?? makeAuxiliaryPanel(width: 360, height: 170)
        notificationPanel = panel
        panel.contentView = NSHostingView(
            rootView: FloatingSuggestionView(
                card: card,
                showPanel: { [weak self] in
                    self?.showSidePanel()
                    self?.notificationPanel?.orderOut(nil)
                },
                dismiss: { [weak self] in
                    self?.notificationPanel?.orderOut(nil)
                }
            )
        )
        positionAuxiliaryPanel(panel, besideSidePanel: true)
        panel.orderFrontRegardless()

        notificationDismissTask = Task { [weak self, weak panel] in
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil)
            self?.notificationDismissTask = nil
        }
    }

    func showMeetingDetection(_ detection: MeetingAppDetection) {
        let panel = detectionPanel ?? makeAuxiliaryPanel(width: 380, height: 190)
        detectionPanel = panel
        panel.contentView = NSHostingView(
            rootView: MeetingDetectionPromptView(
                model: model,
                detection: detection
            )
        )
        positionAuxiliaryPanel(panel, besideSidePanel: false)
        panel.orderFrontRegardless()
    }

    func hideMeetingDetection() {
        detectionPanel?.orderOut(nil)
    }

    private func makeSidePanel() -> RightSidePanel {
        let panel = RightSidePanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: MeetingSidePanelView(model: model))
        panel.minSize = NSSize(width: 350, height: 480)
        panel.maxSize = NSSize(
            width: 520,
            height: CGFloat.greatestFiniteMagnitude
        )
        configure(panel)
        sidePanel = panel
        return panel
    }

    private func makeAuxiliaryPanel(width: CGFloat, height: CGFloat) -> RightSidePanel {
        let panel = RightSidePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configure(panel)
        panel.hasShadow = true
        return panel
    }

    private func configure(_ panel: NSPanel) {
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]
        panel.animationBehavior = .utilityWindow
    }

    private func positionSidePanel(_ panel: NSPanel) {
        let frame = targetScreen().visibleFrame
        let width = min(max(panel.frame.width, 390), 520)
        let height = max(480, frame.height - 32)
        panel.setFrame(
            NSRect(
                x: frame.maxX - width - 12,
                y: frame.minY + 16,
                width: width,
                height: height
            ),
            display: true
        )
    }

    private func positionAuxiliaryPanel(
        _ panel: NSPanel,
        besideSidePanel: Bool
    ) {
        let frame = targetScreen().visibleFrame
        var x = frame.maxX - panel.frame.width - 18
        if besideSidePanel, sidePanel?.isVisible == true, let sidePanel {
            x = sidePanel.frame.minX - panel.frame.width - 12
        }
        panel.setFrameOrigin(
            NSPoint(x: x, y: frame.maxY - panel.frame.height - 18)
        )
    }

    private func targetScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

private final class RightSidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct MeetingSidePanelView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(model.captureState == .capturing ? .red : .orange)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cue")
                        .font(.headline)
                    Text(model.captureState.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.transcriptionState.label)
                        .font(.caption2)
                        .foregroundStyle(
                            model.transcriptionState.isHealthy ? Color.secondary : Color.orange
                        )
                        .help(model.transcriptionState.detail ?? "音声認識の状態")
                }
                Spacer()
                if model.activeMeeting != nil {
                    Button {
                        Task { await model.toggleMeetingPause() }
                    } label: {
                        Image(systemName: model.pauseControlSymbol)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isBusy)
                    .help(
                        "\(model.pauseControlTitle)（\(model.shortcutLabel(for: .togglePause))）"
                    )
                }
                Button {
                    model.hideSidePanel()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("パネルを閉じる（⌥Spaceで再表示）")
            }
            .padding(14)

            Divider()

            if model.activeMeeting == nil {
                ContentUnavailableView(
                    "会議は開始されていません",
                    systemImage: "waveform.badge.mic",
                    description: Text("メイン画面またはメニューバーから開始してください。")
                )
            } else {
                manualActions
                Divider()
                cardTimeline
                Divider()
                footer
            }
        }
        .frame(minWidth: 350, idealWidth: 390, minHeight: 480)
        .background(.ultraThinMaterial)
    }

    private var manualActions: some View {
        HStack(spacing: 8) {
            ForEach(ManualAnalysisAction.allCases) { action in
                Button {
                    Task { await model.performManualAnalysis(action) }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: action.symbol)
                        Text(action.title)
                            .lineLimit(1)
                        Text(model.shortcutLabel(for: action))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.bordered)
                .disabled(!model.canRunManualAnalysis)
            }
        }
        .padding(12)
    }

    private var cardTimeline: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if model.cards.isEmpty {
                    ContentUnavailableView(
                        "重要イベントを待っています",
                        systemImage: "sparkles"
                    )
                    .frame(minHeight: 260)
                } else {
                    ForEach(model.cards) { card in
                        CompactSuggestionCard(
                            card: card,
                            isDeepAnalysisInProgress: model.deepAnalysisInProgressEventIDs
                                .contains(card.sourceEventID),
                            onTogglePin: {
                                Task { await model.togglePin(card) }
                            },
                            canPromoteToDeep: model.canPromoteToDeep(card),
                            onPromoteToDeep: {
                                Task { await model.promoteToDeep(card) }
                            },
                            onOpenEvidence: model.openEvidence,
                            onCopyEvidence: model.copyEvidence
                        )
                    }
                }
            }
            .padding(12)
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Image(systemName: "lock.shield")
            Text("\(model.selectedProviderDisplayName): \(model.codexStatus)")
                .lineLimit(1)
                .help(model.codexErrorDetail ?? model.codexExecutableDescription ?? "")
            Spacer()
            if model.codexErrorDetail != nil {
                Button("再接続") {
                    Task { await model.reconnectCodex() }
                }
                .disabled(model.isCodexConnecting)
            }
            Button {
                Task { await model.toggleMeetingPause() }
            } label: {
                Label(model.pauseControlTitle, systemImage: model.pauseControlSymbol)
            }
            .disabled(model.isBusy)
            Button("終了", role: .destructive) {
                Task { await model.stopMeeting() }
            }
            .disabled(model.isBusy)
        }
        .font(.caption)
        .padding(12)
    }
}

private struct CompactSuggestionCard: View {
    let card: SuggestionCard
    let isDeepAnalysisInProgress: Bool
    let onTogglePin: () -> Void
    let canPromoteToDeep: Bool
    let onPromoteToDeep: () -> Void
    let onOpenEvidence: (EvidenceReference) -> Void
    let onCopyEvidence: (EvidenceReference) -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.category.symbol)
                Text(card.title)
                    .font(.headline)
                Text(card.mode == .deep ? "DEEP" : "FAST")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(card.mode == .deep ? .purple : .secondary)
                Spacer()
                Text("\(Int(card.confidence * 100))%")
                    .font(.caption.monospacedDigit())
                Button(action: onTogglePin) {
                    Image(systemName: card.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.plain)
            }
            Text(card.body)
                .font(.callout)
                .lineLimit(isExpanded ? nil : 4)
            if card.mode == .fast {
                Button(action: onPromoteToDeep) {
                    Label(
                        isDeepAnalysisInProgress ? "詳細調査中" : "詳しく調査",
                        systemImage: isDeepAnalysisInProgress
                            ? "hourglass"
                            : "sparkle.magnifyingglass"
                    )
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(!canPromoteToDeep)
            }
            if !card.evidence.isEmpty {
                Button(isExpanded ? "閉じる" : "根拠") {
                    withAnimation { isExpanded.toggle() }
                }
                .buttonStyle(.link)
                .font(.caption)
                if isExpanded {
                    EvidenceListView(
                        evidence: card.evidence,
                        onOpen: onOpenEvidence,
                        onCopy: onCopyEvidence
                    )
                }
            }
        }
        .padding(12)
        .background(.background.opacity(0.78), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor.opacity(0.45), lineWidth: 1)
        }
    }

    private var borderColor: Color {
        switch card.importance {
        case .low: .gray
        case .medium: .blue
        case .high: .orange
        case .critical: .red
        }
    }
}

private struct FloatingSuggestionView: View {
    let card: SuggestionCard
    let showPanel: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(card.category.symbol)
                Text(card.title)
                    .font(.headline)
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            Text(card.body)
                .font(.callout)
                .lineLimit(3)
            HStack {
                Text("確信度 \(Int(card.confidence * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("パネルで見る", action: showPanel)
                    .buttonStyle(.link)
            }
        }
        .padding(16)
        .frame(width: 360, height: 170)
        .background(.ultraThinMaterial)
    }
}

private struct MeetingDetectionPromptView: View {
    @Bindable var model: AppModel
    let detection: MeetingAppDetection

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Zoom会議を検知しました", systemImage: "video.fill")
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text(detection.displayTitle)
                    .lineLimit(2)
                Text("プロジェクト: \(model.selectedProject?.name ?? "未選択")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button("今回は使用しない") {
                    model.dismissMeetingDetection()
                }
                Spacer()
                Button("開始") {
                    Task { await model.confirmMeetingDetection() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.selectedProject == nil ||
                        model.selectedProject?.archivedAt != nil ||
                        model.activeMeeting != nil
                )
            }
        }
        .padding(18)
        .frame(width: 380, height: 190)
        .background(.ultraThinMaterial)
    }
}
