import CueCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            ProjectSidebar(model: model)
        } detail: {
            if model.activeMeeting != nil {
                MeetingWorkspace(model: model)
            } else if let review = model.lastReview {
                MeetingReviewView(
                    model: model,
                    review: review,
                    diagnostics: model.lastDiagnostics,
                    focusSegmentID: model.reviewFocusSegmentID,
                    onExport: model.exportLastReview,
                    onClose: model.closeReview
                )
            } else {
                StartMeetingView(model: model)
            }
        }
        .alert(
            "Cue",
            isPresented: Binding(
                get: { model.startupError != nil },
                set: { if !$0 { model.startupError = nil } }
            )
        ) {
            Button("閉じる", role: .cancel) {
                model.startupError = nil
            }
        } message: {
            Text(model.startupError ?? "")
        }
        .sheet(item: $model.screenEvidencePreview) { event in
            ScreenEvidenceDetailView(event: event)
        }
        .sheet(item: $model.documentChangeProposal) { proposal in
            DocumentChangeApprovalView(
                proposal: proposal,
                onApprove: {
                    Task { await model.applyDocumentUpdateProposal() }
                }
            )
        }
        .sheet(item: $model.backlogDraftForApproval) { draft in
            BacklogDraftApprovalView(
                draft: draft,
                isSubmitting: model.isBacklogSubmitting,
                onApprove: {
                    Task { await model.submitApprovedBacklogDraft() }
                }
            )
        }
    }
}

private struct ScreenEvidenceDetailView: View {
    let event: ScreenContextEvent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("画面差分の根拠")
                        .font(.title2.bold())
                    Text(event.capturedAt.formatted())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("閉じる") { dismiss() }
            }
            Text("キャプチャ画像は保存していません。OCR文字列・信頼度・正規化座標だけを表示します。")
                .font(.caption)
                .foregroundStyle(.secondary)
            List(event.changes) { change in
                let observation = change.current ?? change.previous
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(change.kind.displayName)
                            .font(.caption.bold())
                        Spacer()
                        if let observation {
                            Text("信頼度 \(Int(observation.confidence * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(observation?.text ?? "")
                        .textSelection(.enabled)
                    if let bounds = observation?.bounds {
                        Text(
                            String(
                                format: "x %.3f / y %.3f / w %.3f / h %.3f",
                                bounds.x, bounds.y, bounds.width, bounds.height
                            )
                        )
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 460)
    }
}

private extension ScreenTextChangeKind {
    var displayName: String {
        switch self {
        case .added: "追加"
        case .modified: "変更"
        case .removed: "削除"
        }
    }
}

private struct DocumentChangeApprovalView: View {
    let proposal: DocumentChangeProposal
    let onApprove: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("資料差分の確認")
                        .font(.title2.bold())
                    Text(proposal.targetPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("閉じる") { dismiss() }
            }
            Text("下の差分を確認し、承認した場合だけファイルへ反映します。反映直前に元ファイルのSHA256を再確認し、変更済みなら中止します。")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(proposal.diffPreview)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("承認前はファイルを書き換えません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("承認して反映", role: .destructive, action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .disabled(proposal.status != .awaitingApproval)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 560)
    }
}

private struct BacklogDraftApprovalView: View {
    let draft: BacklogIssueDraft
    let isSubmitting: Bool
    let onApprove: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Backlog登録内容の確認")
                    .font(.title2.bold())
                Spacer()
                Button("閉じる") { dismiss() }
            }
            LabeledContent("タイトル", value: draft.title)
            LabeledContent("内容") {
                Text(draft.description)
                    .textSelection(.enabled)
            }
            LabeledContent("背景") {
                Text(draft.background)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("完了条件").font(.headline)
                ForEach(draft.completionCriteria, id: \.self) {
                    Text("• \($0)")
                }
            }
            Text("この画面で承認するまでBacklog APIへ送信しません。APIキーはAIへ渡しません。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(
                    isSubmitting ? "登録中" : "承認してBacklogへ登録",
                    role: .destructive,
                    action: onApprove
                )
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.status == .submitted || isSubmitting)
            }
        }
        .padding(20)
        .frame(minWidth: 660, minHeight: 440)
    }
}

private extension BacklogIssueDraftStatus {
    var displayName: String {
        switch self {
        case .draft: "下書き"
        case .awaitingApproval: "確認待ち"
        case .approved: "承認済み"
        case .submitting: "登録中"
        case .submitted: "登録済み"
        case .rejected: "却下"
        case .failed: "登録失敗"
        }
    }
}

private struct MeetingReviewView: View {
    @Bindable var model: AppModel
    let review: MeetingReviewSnapshot
    let diagnostics: MeetingDiagnosticsReport?
    let focusSegmentID: UUID?
    let onExport: () -> Void
    let onClose: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Meeting Review")
                            .font(.largeTitle.bold())
                        Text(review.title)
                            .font(.title3)
                        Text("\(review.startedAt.formatted()) 〜 \(review.endedAt.formatted())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Markdownを書き出す", action: onExport)
                        .buttonStyle(.bordered)
                    Button("資料差分案") {
                        Task { await model.makeDocumentUpdateProposal() }
                    }
                    .buttonStyle(.bordered)
                    Button("新しい会議") { onClose() }
                        .buttonStyle(.borderedProminent)
                }

                HStack(spacing: 12) {
                    reviewMetric("決定", review.decisions.count, color: .blue)
                    reviewMetric("要望", review.requirements.count, color: .purple)
                    reviewMetric("TODO", review.actionItems.count, color: .green)
                    reviewMetric("リスク", review.risks.count, color: .orange)
                }

                reviewSection("決定事項", values: review.decisions, symbol: "checkmark.seal")
                reviewSection("TODO・宿題", values: review.actionItems, symbol: "checklist")
                reviewSection("クライアント要望", values: review.requirements, symbol: "wrench.and.screwdriver")
                reviewSection("未回答・確認事項", values: review.questions, symbol: "questionmark.bubble")
                reviewSection("リスク", values: review.risks, symbol: "exclamationmark.triangle")

                if !model.backlogDrafts.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Backlog候補", systemImage: "shippingbox")
                                .font(.title3.bold())
                            Spacer()
                            if let status = model.backlogOperationStatus {
                                Text(status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(model.backlogDrafts) { draft in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(draft.title)
                                        .font(.callout.weight(.medium))
                                    Text(draft.status.displayName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("確認") {
                                    model.presentBacklogApproval(draft)
                                }
                                .disabled(draft.status == .submitted)
                            }
                            .padding(10)
                            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                if let diagnostics {
                    DiagnosticsReviewSection(report: diagnostics)
                }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("文字起こし", systemImage: "text.quote")
                            .font(.headline)
                        ForEach(review.finalTranscript) { segment in
                            HStack(alignment: .top) {
                                SpeakerLabelMenu(
                                    segment: segment,
                                    labels: model.availableSpeakerLabels,
                                    onAssign: { label in
                                        Task {
                                            await model.assignSpeakerLabel(
                                                segmentID: segment.id,
                                                label: label
                                            )
                                        }
                                    }
                                )
                                Text(segment.text)
                            }
                            .padding(7)
                            .background(
                                focusSegmentID == segment.id
                                    ? Color.accentColor.opacity(0.14)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .id(segment.id)
                        }
                    }
                }
                .padding(28)
            }
            .task(id: focusSegmentID) {
                guard let focusSegmentID else { return }
                try? await Task.sleep(for: .milliseconds(80))
                withAnimation {
                    proxy.scrollTo(focusSegmentID, anchor: .center)
                }
            }
        }
    }

    private func reviewMetric(
        _ title: String,
        _ value: Int,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)")
                .font(.title.bold().monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func reviewSection(
        _ title: String,
        values: [String],
        symbol: String
    ) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Text("• \(value)")
                }
            }
        }
    }
}

private struct DiagnosticsReviewSection: View {
    let report: MeetingDiagnosticsReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("品質診断", systemImage: "gauge.with.dots.needle.67percent")
                .font(.headline)
            HStack(spacing: 12) {
                metric("CPUピーク", String(format: "%.1f%%", report.cpuPercent.max))
                metric("メモリピーク", String(format: "%.0f MB", report.memoryMegabytes.peak))
                metric("STT p95", String(format: "%.2f秒", report.sttFinalLatencySeconds.p95))
                metric("破棄音声", "\(report.counters.droppedAudioBuffers)")
            }
            DisclosureGroup("診断レポートの詳細") {
                Text(MeetingDiagnosticsMarkdownFormatter.render(report))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ProjectSidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selectedProjectID) {
            Section("プロジェクト") {
                ForEach(model.projects) { project in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(project.name)
                            .font(.headline)
                        Text(project.rootPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .tag(project.id)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await model.addProject() }
            } label: {
                Label("プロジェクトを追加", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
        .navigationSplitViewColumnWidth(min: 230, ideal: 280)
    }
}

private struct StartMeetingView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 58))
                    .foregroundStyle(.tint)
                VStack(spacing: 8) {
                    Text("Cue")
                        .font(.largeTitle.bold())
                    Text("会議中に必要な質問・回答・リスクをリアルタイムに提示します。")
                        .foregroundStyle(.secondary)
                }

                if let project = model.selectedProject {
                    VStack(spacing: 5) {
                        Text(project.name)
                            .font(.title3.bold())
                        Text(project.rootPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("最初にProject Rootを登録してください。")
                        .foregroundStyle(.secondary)
                }

                GroupBox("音声入力") {
                    AudioCaptureSelectionView(model: model)
                        .padding(.top, 4)
                }
                .frame(maxWidth: 520)

                Button {
                    Task { await model.startMeeting() }
                } label: {
                    Label("会議を開始", systemImage: "record.circle")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedProject == nil || model.isBusy)

                if let detection = model.pendingMeetingDetection {
                    VStack(spacing: 8) {
                        Label("Zoom会議を検知しました", systemImage: "video.fill")
                            .font(.headline)
                        Text(detection.displayTitle)
                            .font(.caption)
                            .lineLimit(2)
                        HStack {
                            Button("今回は使用しない") {
                                model.dismissMeetingDetection()
                            }
                            Button("開始") {
                                Task { await model.confirmMeetingDetection() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(14)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }

                PermissionStatusView(snapshot: model.permissionSnapshot)

                HStack(spacing: 10) {
                    Label("\(model.selectedProviderDisplayName): \(model.codexStatus)", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("接続をテスト") {
                        Task { await model.testCodexConnection() }
                    }
                    .disabled(model.selectedProject == nil || model.isCodexConnecting)
                    if let error = model.codexErrorDetail {
                        Button {
                            model.startupError = error
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }

                if model.selectedProject != nil {
                    ProjectHistoryPanel(model: model)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: model.selectedProjectID) {
            await model.refreshProjectBrief()
        }
    }
}

private struct ProjectHistoryPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Project Brief", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                Text(model.projectBriefStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.projectBriefItems.isEmpty {
                VStack(spacing: 6) {
                    ForEach(model.projectBriefItems) { item in
                        Button {
                            Task {
                                await model.openPastMeeting(
                                    meetingID: item.meetingID,
                                    focusSegmentID: item.sourceSegmentID
                                )
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: item.kind.symbolName)
                                    .foregroundStyle(item.kind.tint)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.text)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text("\(item.meetingTitle) · \(item.meetingStartedAt.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField(
                    "過去の発言を検索",
                    text: $model.pastMeetingSearchQuery
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    Task { await model.searchPastMeetings() }
                }
                Button("検索") {
                    Task { await model.searchPastMeetings() }
                }
                .disabled(
                    model.pastMeetingSearchQuery
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty || model.isSearchingPastMeetings
                )
            }

            if let status = model.pastMeetingSearchStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.pastMeetingSearchResults.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.pastMeetingSearchResults) { hit in
                            Button {
                                Task {
                                    await model.openPastMeeting(
                                        meetingID: hit.meetingID,
                                        focusSegmentID: hit.segment.id
                                    )
                                }
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Text(hit.segment.speaker == .selfSpeaker ? "自分" : "相手")
                                        .font(.caption2.bold())
                                        .foregroundStyle(
                                            hit.segment.speaker == .selfSpeaker
                                                ? Color.blue
                                                : Color.purple
                                        )
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(hit.segment.text)
                                            .foregroundStyle(.primary)
                                            .lineLimit(3)
                                        Text("\(hit.meetingTitle) · \(formatMeetingTime(hit.segment.startTime))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(8)
                            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .frame(maxHeight: 230)
            }
        }
        .padding(16)
        .frame(maxWidth: 760, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private func formatMeetingTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private extension ProjectBriefItemKind {
    var symbolName: String {
        switch self {
        case .decision: "checkmark.seal"
        case .actionItem: "checklist"
        case .unresolvedIssue: "questionmark.bubble"
        case .requirement: "wrench.and.screwdriver"
        case .risk: "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .decision: .blue
        case .actionItem: .green
        case .unresolvedIssue: .orange
        case .requirement: .purple
        case .risk: .red
        }
    }
}

private extension AnalysisStatus {
    var displayName: String {
        switch self {
        case .queued: "待機中"
        case .running: "更新中"
        case .completed: "更新済み"
        case .stale: "期限切れ"
        case .cancelled: "取消済み"
        case .timedOut: "AI更新見送り"
        case .failed: "更新失敗"
        }
    }

    var symbolName: String {
        switch self {
        case .queued: "clock"
        case .running: "hourglass"
        case .completed: "checkmark.circle"
        case .stale: "clock.badge.exclamationmark"
        case .cancelled: "xmark.circle"
        case .timedOut: "clock.badge.exclamationmark"
        case .failed: "exclamationmark.triangle"
        }
    }
}

private struct MeetingWorkspace: View {
    @Bindable var model: AppModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TranscriptTimeline(
                    segments: model.transcript,
                    focusRequest: model.transcriptFocusRequest,
                    speakerLabels: model.availableSpeakerLabels,
                    onAssignSpeaker: { segmentID, label in
                        Task {
                            await model.assignSpeakerLabel(
                                segmentID: segmentID,
                                label: label
                            )
                        }
                    }
                )
                if !model.currentScreenContext.isEmpty {
                    Divider()
                    DisclosureGroup("現在の画面コンテキスト") {
                        ScrollView {
                            Text(model.currentScreenContext)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 130)
                    }
                    .padding(12)
                }
            }
            .frame(minWidth: 360)
            SuggestionTimeline(
                cards: model.cards,
                deepAnalysisInProgressEventIDs: model.deepAnalysisInProgressEventIDs,
                analysisStatusByEventID: model.analysisStatusByEventID,
                onTogglePin: { card in
                    Task { await model.togglePin(card) }
                },
                canPromoteToDeep: model.canPromoteToDeep,
                onPromoteToDeep: { card in
                    Task { await model.promoteToDeep(card) }
                },
                onOpenEvidence: model.openEvidence,
                onCopyEvidence: model.copyEvidence
            )
            .frame(minWidth: 330, idealWidth: 390)
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Circle()
                    .fill(model.captureState == .capturing ? .red : .orange)
                    .frame(width: 9, height: 9)
                Text(model.captureState.label)
                    .font(.callout.weight(.medium))
                Divider()
                    .frame(height: 14)
                Image(systemName: "waveform")
                    .foregroundStyle(
                        model.transcriptionState.isHealthy ? Color.secondary : Color.orange
                    )
                Text(model.transcriptionState.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(model.transcriptionState.detail ?? "音声認識の状態")
                Divider()
                    .frame(height: 14)
                Image(systemName: "lock.shield")
                    .foregroundStyle(.secondary)
                Text("\(model.selectedProviderDisplayName): \(model.codexStatus)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(model.codexErrorDetail ?? model.codexExecutableDescription ?? "")
                if model.selectedProject?.webSearchEnabled == true {
                    Label("Web検索許可", systemImage: "globe")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("必要な場合、検索語が外部Webへ送信されます。結果URLと確認時刻を根拠に保存します。")
                }
                if let error = model.codexErrorDetail {
                    Button {
                        model.startupError = error
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .help("接続エラーの詳細")
                    Button("再接続") {
                        Task { await model.reconnectCodex() }
                    }
                    .disabled(model.isCodexConnecting)
                }
                Spacer()
                Button {
                    Task { await model.toggleMeetingPause() }
                } label: {
                    Label(model.pauseControlTitle, systemImage: model.pauseControlSymbol)
                }
                .disabled(model.isBusy)
                .help("\(model.pauseControlTitle)（\(model.shortcutLabel(for: .togglePause))）")
                Menu("手動分析") {
                    ForEach(ManualAnalysisAction.allCases) { action in
                        Button {
                            Task { await model.performManualAnalysis(action) }
                        } label: {
                            Label(
                                "\(action.title)（\(model.shortcutLabel(for: action))）",
                                systemImage: action.symbol
                            )
                        }
                    }
                }
                .disabled(!model.canRunManualAnalysis)
                Button("サイドパネル") {
                    model.showSidePanel()
                }
                if model.captureState != .capturing && model.captureState != .paused {
                    Button("共有対象を選択") {
                        model.selectCaptureTarget()
                    }
                }
                Button("会議を終了", role: .destructive) {
                    Task { await model.stopMeeting() }
                }
                .disabled(model.isBusy)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

private struct TranscriptTimeline: View {
    let segments: [TranscriptSegment]
    let focusRequest: TranscriptFocusRequest?
    let speakerLabels: [String]
    let onAssignSpeaker: (UUID, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("文字起こし")
                .font(.headline)
                .padding()
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(segments) { segment in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    SpeakerLabelMenu(
                                        segment: segment,
                                        labels: speakerLabels,
                                        onAssign: {
                                            onAssignSpeaker(segment.id, $0)
                                        }
                                    )
                                    Text(formatTime(segment.startTime))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                    if !segment.isFinal {
                                        Text("暫定")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(segment.text)
                                    .foregroundStyle(segment.isFinal ? .primary : .secondary)
                            }
                            .padding(8)
                            .background(
                                focusRequest?.segmentID == segment.id
                                    ? Color.accentColor.opacity(0.13)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(segment.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: segments.last?.id) { _, newID in
                    if let newID {
                        withAnimation { proxy.scrollTo(newID, anchor: .bottom) }
                    }
                }
                .onChange(of: focusRequest) { _, request in
                    if let request {
                        withAnimation {
                            proxy.scrollTo(request.segmentID, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct SpeakerLabelMenu: View {
    let segment: TranscriptSegment
    let labels: [String]
    let onAssign: (String?) -> Void

    var body: some View {
        if segment.speaker == .selfSpeaker {
            Text(segment.displaySpeakerName)
                .font(.caption.bold())
                .foregroundStyle(.blue)
                .frame(minWidth: 36, alignment: .leading)
        } else {
            Menu {
                Button("参加者（未割当）") { onAssign(nil) }
                ForEach(labels.filter { $0 != "参加者" }, id: \.self) { label in
                    Button(label) { onAssign(label) }
                }
            } label: {
                Text(segment.displaySpeakerName)
                    .font(.caption.bold())
                    .foregroundStyle(.purple)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("参加者ラベルを割り当て")
        }
    }
}

private struct SuggestionTimeline: View {
    let cards: [SuggestionCard]
    let deepAnalysisInProgressEventIDs: Set<UUID>
    let analysisStatusByEventID: [UUID: AnalysisStatus]
    let onTogglePin: (SuggestionCard) -> Void
    let canPromoteToDeep: (SuggestionCard) -> Bool
    let onPromoteToDeep: (SuggestionCard) -> Void
    let onOpenEvidence: (EvidenceReference) -> Void
    let onCopyEvidence: (EvidenceReference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("助言")
                .font(.headline)
                .padding()
            Divider()
            if cards.isEmpty {
                ContentUnavailableView(
                    "重要イベントを待っています",
                    systemImage: "sparkles",
                    description: Text("質問・要望・決定・リスクを検出したときだけ表示します。")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(cards) { card in
                            SuggestionCardView(
                                card: card,
                                isDeepAnalysisInProgress: deepAnalysisInProgressEventIDs
                                    .contains(card.sourceEventID),
                                analysisStatus: analysisStatusByEventID[
                                    card.sourceEventID
                                ],
                                onTogglePin: { onTogglePin(card) },
                                canPromoteToDeep: canPromoteToDeep(card),
                                onPromoteToDeep: { onPromoteToDeep(card) },
                                onOpenEvidence: onOpenEvidence,
                                onCopyEvidence: onCopyEvidence
                            )
                        }
                    }
                    .padding()
                }
            }
        }
    }
}

private struct SuggestionCardView: View {
    let card: SuggestionCard
    let isDeepAnalysisInProgress: Bool
    let analysisStatus: AnalysisStatus?
    let onTogglePin: () -> Void
    let canPromoteToDeep: Bool
    let onPromoteToDeep: () -> Void
    let onOpenEvidence: (EvidenceReference) -> Void
    let onCopyEvidence: (EvidenceReference) -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.category.symbol)
                Text(card.title)
                    .font(.headline)
                Text(card.mode == .deep ? "DEEP" : "FAST")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(card.mode == .deep ? .purple : .secondary)
                if let analysisStatus,
                   analysisStatus != .completed {
                    Label(
                        analysisStatus.displayName,
                        systemImage: analysisStatus.symbolName
                    )
                    .font(.caption2)
                    .foregroundStyle(
                        analysisStatus == .failed ? Color.red : Color.secondary
                    )
                }
                Spacer()
                Text("\(Int(card.confidence * 100))%")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(confidenceColor)
                Button(action: onTogglePin) {
                    Image(systemName: card.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.plain)
            }
            Text(card.body)
                .lineLimit(isExpanded ? nil : 4)
            if card.mode == .fast {
                Button(action: onPromoteToDeep) {
                    if isDeepAnalysisInProgress {
                        Label("詳細調査中", systemImage: "hourglass")
                    } else {
                        Label("詳しく調査", systemImage: "sparkle.magnifyingglass")
                    }
                }
                .buttonStyle(.link)
                .disabled(!canPromoteToDeep)
            }
            if !card.evidence.isEmpty {
                Button(isExpanded ? "詳細を閉じる" : "根拠を表示") {
                    withAnimation { isExpanded.toggle() }
                }
                .buttonStyle(.link)

                if isExpanded {
                    EvidenceListView(
                        evidence: card.evidence,
                        onOpen: onOpenEvidence,
                        onCopy: onCopyEvidence
                    )
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor.opacity(0.35), lineWidth: 1)
        }
    }

    private var confidenceColor: Color {
        if card.confidence >= 0.85 { return .green }
        if card.confidence >= 0.6 { return .orange }
        return .red
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

private struct PermissionStatusView: View {
    let snapshot: PermissionSnapshot

    var body: some View {
        HStack(spacing: 18) {
            status("画面収録", snapshot.screenCapture)
            status("マイク", snapshot.microphone)
        }
        .font(.caption)
    }

    private func status(_ title: String, _ state: PermissionState) -> some View {
        Label(title, systemImage: state == .granted ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(state == .granted ? .green : .secondary)
    }
}
