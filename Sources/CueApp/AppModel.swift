import AppKit
import Foundation
import CueCore
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    var projects: [ProjectConfiguration] = []
    var selectedProjectID: UUID?
    var activeMeeting: MeetingRecord?
    var transcript: [TranscriptSegment] = []
    var cards: [SuggestionCard] = []
    var meetingState: MeetingState?
    var lastReview: MeetingReviewSnapshot?
    var lastDiagnostics: MeetingDiagnosticsReport?
    var reviewFocusSegmentID: UUID?
    var projectBriefItems: [ProjectBriefItem] = []
    var projectBriefStatus = "過去会議を読み込んでいます"
    var pastMeetingSearchQuery = ""
    var pastMeetingSearchResults: [ProjectTranscriptSearchHit] = []
    var pastMeetingSearchStatus: String?
    var isSearchingPastMeetings = false
    var captureState: CaptureServiceState = .idle
    var transcriptionState: TranscriptionServiceState = .idle
    var isMeetingPaused = false
    var audioCapturePreferences = AudioCapturePreferences.load()
    var microphoneDevices = AudioInputDeviceProvider.availableMicrophones()
    var codexStatus = "未接続"
    var codexErrorDetail: String?
    var codexExecutableDescription: String?
    var isCodexConnecting = false
    var shortcutStatus = "初期化中"
    var shortcutConfiguration = GlobalShortcutConfiguration.load()
    var currentScreenContext = ""
    var currentScreenEvent: ScreenContextEvent?
    var screenEvidencePreview: ScreenContextEvent?
    var documentChangeProposal: DocumentChangeProposal?
    var documentUpdateReceipt: DocumentUpdateReceipt?
    var backlogDrafts: [BacklogIssueDraft] = []
    var backlogDraftForApproval: BacklogIssueDraft?
    var backlogOperationStatus: String?
    var isBacklogSubmitting = false
    var transcriptFocusRequest: TranscriptFocusRequest?
    var fastAnalysisInProgressEventIDs: Set<UUID> = []
    var deepAnalysisInProgressEventIDs: Set<UUID> = []
    var analysisStatusByEventID: [UUID: AnalysisStatus] = [:]
    var pendingMeetingDetection: MeetingAppDetection?
    var permissionSnapshot = PermissionCenter.current()
    var startupError: String?
    var isBusy = false

    private let repository: SQLiteMeetingRepository?
    private let transcriptionService = SpeechTranscriptionService()
    private var eventDetector = EventDetectionEngine()
    private let stateReducer = MeetingStateReducer()
    private let topicTransitionDetector = TopicTransitionDetector()
    private let analysisFreshnessEvaluator = AnalysisFreshnessEvaluator()
    private let suggestionFactory = LocalSuggestionFactory()
    private let codexProvider = AIProviderCoordinator()
    private let documentUpdateCoordinator = DocumentUpdateCoordinator()
    private let backlogClient = BacklogClient()
    private let credentialStore = KeychainCredentialStore()
    private var captureService: ScreenCaptureService?
    private var screenContextService: ScreenContextService?
    private var codexSession: AISessionHandle?
    private var transcriptTask: Task<Void, Never>?
    private var transcriptionStateTask: Task<Void, Never>?
    private var desktopIntegration: DesktopIntegrationController?
    private var diagnosticsCollector: MeetingDiagnosticsCollector?
    private var analysisRecords: [UUID: AnalysisRecord] = [:]
    private var detectedEventsByID: [UUID: DetectedEvent] = [:]
    private var codexReconnectTask: Task<Void, Never>?
    private var automaticReconnectAttempts = 0
    private var projectBriefProjectID: UUID?
    private var fastAnalysisQueue: [PendingAIAnalysis] = []
    private var deepAnalysisQueue: [PendingAIAnalysis] = []
    private var fastAnalysisWorker: Task<Void, Never>?
    private var deepAnalysisWorker: Task<Void, Never>?
    private var activePauseInterval: MeetingPauseInterval?
    private let maximumQueuedFastAnalyses = 2
    private let maximumFastQueueWait: TimeInterval = 20

    var selectedProject: ProjectConfiguration? {
        guard let selectedProjectID else { return nil }
        return projects.first { $0.id == selectedProjectID }
    }

    var selectedProviderDisplayName: String {
        selectedProject?.provider.displayName ?? "AI"
    }

    var canRunManualAnalysis: Bool {
        activeMeeting != nil &&
            !isMeetingPaused &&
            codexSession != nil &&
            transcript.contains(where: \.isFinal)
    }

    var pauseControlTitle: String {
        isMeetingPaused ? "記録を再開" : "記録を一時停止"
    }

    var pauseControlSymbol: String {
        isMeetingPaused ? "play.fill" : "pause.fill"
    }

    init() {
        do {
            let support = try CueDataMigration.prepareSupportDirectory()
            repository = try SQLiteMeetingRepository(
                databaseURL: support.appending(path: CueDataMigration.databaseName)
            )
        } catch {
            repository = nil
            startupError = error.localizedDescription
        }

        transcriptTask = Task { [weak self, transcriptionService] in
            for await segment in transcriptionService.segments {
                guard !Task.isCancelled else { return }
                await self?.handleTranscript(segment)
            }
        }
        transcriptionStateTask = Task { [weak self, transcriptionService] in
            for await state in transcriptionService.states {
                guard !Task.isCancelled else { return }
                self?.transcriptionState = state
                if case .recovering = state,
                   let diagnostics = self?.diagnosticsCollector {
                    Task { await diagnostics.recordTranscriptionRecovery() }
                }
                if case .failed = state {
                    self?.startupError = """
                    \(state.detail ?? "文字起こしが停止しました。")

                    復旧手順:
                    1. システム設定 ＞ プライバシーとセキュリティ ＞ マイクでCueを許可
                    2. Bluetooth／入力デバイスの接続を確認
                    3. 会議を終了して再開始
                    """
                    if let diagnostics = self?.diagnosticsCollector {
                        Task {
                            await diagnostics.recordError(
                                state.detail ?? "文字起こしが停止しました。"
                            )
                        }
                    }
                }
            }
        }

        Task { [weak self] in
            await self?.loadProjects()
            await self?.refreshProjectBrief()
            self?.configureDesktopIntegration()
        }
    }

    func configureDesktopIntegration() {
        guard desktopIntegration == nil else { return }
        let integration = DesktopIntegrationController(model: self)
        desktopIntegration = integration
        integration.install()
    }

    func requestPermissions() async {
        permissionSnapshot = await PermissionCenter.request()
    }

    func refreshAudioInputDevices() {
        microphoneDevices = AudioInputDeviceProvider.availableMicrophones()
        if let selectedID = audioCapturePreferences.microphoneDeviceID,
           !microphoneDevices.contains(where: { $0.id == selectedID }) {
            audioCapturePreferences.microphoneDeviceID = nil
            audioCapturePreferences.save()
        }
    }

    func updateAudioCaptureMode(_ mode: AudioCaptureMode) {
        guard activeMeeting == nil else {
            startupError = "音声ソースは会議を開始する前に変更してください。"
            return
        }
        audioCapturePreferences.mode = mode
        audioCapturePreferences.save()
    }

    func updateMicrophoneDevice(id: String?) {
        guard activeMeeting == nil else {
            startupError = "マイクは会議を開始する前に変更してください。"
            return
        }
        audioCapturePreferences.microphoneDeviceID = id
        audioCapturePreferences.save()
    }

    func addProject() async {
        let panel = NSOpenPanel()
        panel.title = "Project Rootを選択"
        panel.prompt = "選択"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let project = ProjectConfiguration(
            name: url.lastPathComponent,
            rootPath: url.path
        )
        do {
            try await repository?.saveProject(project)
            projects.insert(project, at: 0)
            selectedProjectID = project.id
        } catch {
            startupError = error.localizedDescription
        }
    }

    func selectProject(_ project: ProjectConfiguration) {
        selectedProjectID = project.id
        Task { [weak self] in
            await self?.refreshProjectBrief()
        }
    }

    func refreshProjectBrief() async {
        guard activeMeeting == nil, let project = selectedProject else {
            if selectedProject == nil {
                projectBriefItems = []
                projectBriefStatus = "Project Rootを選択してください"
                projectBriefProjectID = nil
            }
            return
        }

        if projectBriefProjectID != project.id {
            pastMeetingSearchQuery = ""
            pastMeetingSearchResults = []
            pastMeetingSearchStatus = nil
        }
        projectBriefProjectID = project.id
        projectBriefStatus = "過去会議を読み込んでいます"
        do {
            projectBriefItems = try await repository?.projectBrief(
                projectID: project.id,
                limit: 5
            ) ?? []
            projectBriefStatus = projectBriefItems.isEmpty
                ? "このプロジェクトの過去会議はまだありません"
                : "直近会議から重要項目を5件まで表示"
        } catch {
            projectBriefItems = []
            projectBriefStatus = "過去会議を読み込めませんでした"
            startupError = error.localizedDescription
        }
    }

    func searchPastMeetings() async {
        guard let project = selectedProject else { return }
        let query = pastMeetingSearchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            pastMeetingSearchResults = []
            pastMeetingSearchStatus = nil
            return
        }

        isSearchingPastMeetings = true
        defer { isSearchingPastMeetings = false }
        do {
            let results = try await repository?.searchTranscripts(
                projectID: project.id,
                query: query,
                limit: 20
            ) ?? []
            guard selectedProjectID == project.id else { return }
            pastMeetingSearchResults = results
            pastMeetingSearchStatus = results.isEmpty
                ? "「\(query)」に一致する発言はありません"
                : "\(results.count)件の発言が見つかりました"
        } catch {
            pastMeetingSearchResults = []
            pastMeetingSearchStatus = "検索できませんでした"
            startupError = error.localizedDescription
        }
    }

    func openPastMeeting(
        meetingID: UUID,
        focusSegmentID: UUID? = nil
    ) async {
        guard activeMeeting == nil else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            guard let meeting = try await repository?.meeting(id: meetingID),
                  let endedAt = meeting.endedAt
            else {
                startupError = "過去会議を読み込めませんでした。"
                return
            }
            let state = try await repository?.latestState(meetingID: meetingID)
                ?? MeetingState(meetingID: meetingID)
            let finalTranscript = try await repository?.recentSegments(
                meetingID: meetingID,
                limit: 5_000
            ) ?? []
            transcript = finalTranscript
            cards = try await repository?.cards(meetingID: meetingID) ?? []
            let storedAnalysis = try await repository?.analysisRecords(
                meetingID: meetingID
            ) ?? []
            analysisRecords = Dictionary(
                uniqueKeysWithValues: storedAnalysis.map { ($0.id, $0) }
            )
            analysisStatusByEventID = Dictionary(
                storedAnalysis.map { ($0.eventID, $0.status) },
                uniquingKeysWith: { _, latest in latest }
            )
            lastDiagnostics = try await repository?.diagnostics(meetingID: meetingID)
            reviewFocusSegmentID = focusSegmentID
            lastReview = MeetingReviewSnapshot(
                meetingID: meeting.id,
                title: meeting.title,
                startedAt: meeting.startedAt,
                endedAt: endedAt,
                finalTranscript: finalTranscript,
                decisions: state.decisions,
                questions: state.unresolvedIssues.isEmpty
                    ? state.questions
                    : state.unresolvedIssues,
                requirements: state.requirements,
                actionItems: state.actionItems,
                risks: state.risks
            )
            let storedDrafts = try await repository?.backlogDrafts(
                meetingID: meetingID
            ) ?? []
            backlogDrafts = storedDrafts.isEmpty
                ? BacklogIssueDraft.candidates(from: lastReview!)
                : storedDrafts
            documentChangeProposal = try await repository?
                .documentChangeProposals(meetingID: meetingID)
                .first
        } catch {
            startupError = "過去会議を読み込めませんでした。\n\(error.localizedDescription)"
        }
    }

    func updateSelectedProjectSearchPolicy(
        additionalReferencePaths: [String],
        excludedPaths: [String],
        priorityFiles: [String]
    ) async {
        guard let selectedProjectID,
              let index = projects.firstIndex(where: { $0.id == selectedProjectID })
        else { return }

        projects[index].additionalReferencePaths = normalizedPathList(
            additionalReferencePaths
        )
        projects[index].excludedPaths = normalizedPathList(excludedPaths)
        projects[index].priorityFiles = normalizedPathList(priorityFiles)
        do {
            try await repository?.saveProject(projects[index])
            startupError = "Project検索設定を保存しました。"
        } catch {
            startupError = error.localizedDescription
        }
    }

    func updateSelectedProjectAISettings(
        provider: AIProviderKind,
        profile: MeetingProfile,
        webSearchEnabled: Bool,
        customProfilePrompt: String,
        projectPrompt: String,
        meetingPrompt: String,
        participantNames: [String]
    ) async {
        guard activeMeeting == nil,
              let selectedProjectID,
              let index = projects.firstIndex(where: { $0.id == selectedProjectID })
        else {
            startupError = "AI設定は会議を開始する前に変更してください。"
            return
        }

        projects[index].provider = provider
        projects[index].profile = profile
        projects[index].webSearchEnabled = provider == .codex && webSearchEnabled
        projects[index].customProfilePrompt = customProfilePrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        projects[index].projectPrompt = projectPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        projects[index].meetingPrompt = meetingPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        projects[index].participantNames = normalizedPathList(participantNames)
        do {
            try await repository?.saveProject(projects[index])
            startupError = "AI・Profile設定を保存しました。"
            codexStatus = "未接続"
            codexErrorDetail = nil
        } catch {
            startupError = error.localizedDescription
        }
    }

    private func normalizedPathList(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    func startMeeting(suggestedTitle: String? = nil) async {
        guard let project = selectedProject, activeMeeting == nil else { return }
        isBusy = true
        defer { isBusy = false }

        if projectBriefProjectID != project.id {
            await refreshProjectBrief()
        }

        refreshAudioInputDevices()
        let audioConfiguration = AudioCaptureConfiguration(
            preferences: audioCapturePreferences,
            devices: microphoneDevices
        )
        permissionSnapshot = await PermissionCenter.request(
            requiresMicrophone: audioConfiguration.capturesMicrophone
        )
        guard permissionSnapshot.isReady(
            requiresMicrophone: audioConfiguration.capturesMicrophone
        ) else {
            startupError = audioConfiguration.capturesMicrophone
                ? "画面収録とマイクの権限を許可してください。"
                : "画面収録の権限を許可してください。"
            return
        }

        var meeting = MeetingRecord(
            projectID: project.id,
            title: suggestedTitle.map { "\(project.name) / \($0)" }
                ?? "\(project.name) \(Date().formatted(date: .abbreviated, time: .shortened))",
            status: .active
        )
        do {
            try await repository?.createMeeting(meeting)
            try await transcriptionService.start(
                meetingID: meeting.id,
                sources: audioConfiguration.enabledSources
            )
        } catch {
            meeting.status = .failed
            startupError = error.localizedDescription
            return
        }

        activeMeeting = meeting
        isMeetingPaused = false
        activePauseInterval = nil
        eventDetector = EventDetectionEngine(
            detector: RuleBasedEventDetector(
                profile: ProfileRuntimePolicy(project: project)
            )
        )
        lastReview = nil
        lastDiagnostics = nil
        reviewFocusSegmentID = nil
        meetingState = MeetingState(meetingID: meeting.id)
        transcript = []
        cards = []
        analysisRecords = [:]
        detectedEventsByID = [:]
        fastAnalysisInProgressEventIDs = []
        deepAnalysisInProgressEventIDs = []
        analysisStatusByEventID = [:]
        fastAnalysisQueue = []
        deepAnalysisQueue = []
        fastAnalysisWorker?.cancel()
        deepAnalysisWorker?.cancel()
        fastAnalysisWorker = nil
        deepAnalysisWorker = nil
        currentScreenContext = ""
        currentScreenEvent = nil
        screenEvidencePreview = nil
        pendingMeetingDetection = nil
        desktopIntegration?.hideMeetingDetection()

        let diagnostics = MeetingDiagnosticsCollector(
            meetingID: meeting.id,
            startedAt: meeting.startedAt,
            codexProcessCountProvider: { [codexProvider] in
                await codexProvider.runningProcessCount()
            }
        )
        diagnosticsCollector = diagnostics
        await diagnostics.start()

        let screenContextMeetingID = meeting.id
        let screenContext = ScreenContextService(
            eventHandler: { [weak self] event in
                Task { @MainActor in
                    guard let self,
                          !self.isMeetingPaused,
                          var state = self.meetingState
                    else { return }
                    self.currentScreenEvent = event
                    self.currentScreenContext = event.fullText
                    state.currentScreenContext = event.fullText
                    state.revision += 1
                    self.meetingState = state
                    await self.persist { [repository = self.repository] in
                        try await repository?.saveScreenContextEvent(
                            event,
                            meetingID: screenContextMeetingID
                        )
                        try await repository?.saveState(state)
                    }
                }
            },
            metricsHandler: { [diagnostics] duration in
                Task { await diagnostics.recordScreenProcessing(duration) }
            }
        )
        screenContextService = screenContext

        let capture = ScreenCaptureService(
            configuration: audioConfiguration,
            audioHandler: { [transcriptionService] captured in
                transcriptionService.submit(captured)
            },
            screenHandler: { [screenContext] frame in
                screenContext.submit(frame)
            },
            stateHandler: { [weak self] state in
                Task { @MainActor in
                    self?.captureState = state
                    if case .failed(let message) = state,
                       let diagnostics = self?.diagnosticsCollector {
                        await diagnostics.recordError("画面キャプチャ: \(message)")
                    }
                    if case .failed(let message) = state {
                        self?.startupError = """
                        画面キャプチャを継続できません: \(message)

                        復旧手順:
                        1. システム設定 ＞ プライバシーとセキュリティ ＞ 画面収録でCueを許可
                        2. 対象アプリ／オーディオデバイスを確認
                        3. 「共有対象を選択」から対象を再選択
                        """
                    }
                }
            }
        )
        captureService = capture
        capture.presentPicker()
        desktopIntegration?.showSidePanel()

        Task { [weak self] in
            await self?.connectCodex(project: project, meetingID: meeting.id)
        }
    }

    func toggleMeetingPause() async {
        guard activeMeeting != nil, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        if isMeetingPaused {
            await resumeMeeting()
        } else {
            await pauseMeeting()
        }
    }

    private func pauseMeeting() async {
        guard var meeting = activeMeeting, !isMeetingPaused else { return }

        isMeetingPaused = true
        captureService?.setPaused(true)
        screenContextService?.setPaused(true)
        await transcriptionService.pause()
        await cancelActiveAnalyses()
        fastAnalysisWorker?.cancel()
        deepAnalysisWorker?.cancel()
        fastAnalysisWorker = nil
        deepAnalysisWorker = nil
        fastAnalysisQueue = []
        deepAnalysisQueue = []
        fastAnalysisInProgressEventIDs = []
        deepAnalysisInProgressEventIDs = []

        let interval = MeetingPauseInterval(meetingID: meeting.id)
        activePauseInterval = interval
        meeting.status = .paused
        activeMeeting = meeting
        do {
            try await repository?.savePauseInterval(interval)
            try await repository?.updateMeeting(meeting)
        } catch {
            startupError = "一時停止状態を保存できませんでした。\n\(error.localizedDescription)"
        }
    }

    private func resumeMeeting() async {
        guard var meeting = activeMeeting, isMeetingPaused else { return }

        let resumedAt = Date()
        if var interval = activePauseInterval {
            interval.endedAt = resumedAt
            do {
                try await repository?.savePauseInterval(interval)
            } catch {
                startupError = "再開時刻を保存できませんでした。\n\(error.localizedDescription)"
            }
        }
        activePauseInterval = nil
        meeting.status = .active
        activeMeeting = meeting
        do {
            try await repository?.updateMeeting(meeting)
        } catch {
            startupError = "再開状態を保存できませんでした。\n\(error.localizedDescription)"
        }

        await transcriptionService.resume()
        screenContextService?.setPaused(false)
        isMeetingPaused = false
        captureService?.setPaused(false)
    }

    func stopMeeting() async {
        guard var meeting = activeMeeting else { return }
        isBusy = true
        defer { isBusy = false }

        await captureService?.stop()
        await transcriptionService.stop()
        let audioIngress = transcriptionService.ingressDiagnostics()
        captureService = nil
        screenContextService = nil
        await cancelActiveAnalyses()
        fastAnalysisWorker?.cancel()
        deepAnalysisWorker?.cancel()
        fastAnalysisWorker = nil
        deepAnalysisWorker = nil
        fastAnalysisQueue = []
        deepAnalysisQueue = []
        if let codexSession {
            await codexProvider.endSession(codexSession)
            self.codexSession = nil
        }
        codexReconnectTask?.cancel()
        codexReconnectTask = nil
        automaticReconnectAttempts = 0
        codexStatus = "未接続"
        codexErrorDetail = nil
        codexExecutableDescription = nil
        desktopIntegration?.hideSidePanel()

        let endedAt = Date()
        if var interval = activePauseInterval {
            interval.endedAt = endedAt
            do {
                try await repository?.savePauseInterval(interval)
            } catch {
                startupError = "一時停止区間を確定できませんでした。\n\(error.localizedDescription)"
            }
        }
        activePauseInterval = nil
        isMeetingPaused = false
        meeting.endedAt = endedAt
        meeting.status = .reviewing
        do {
            try await repository?.updateMeeting(meeting)
            if let meetingState {
                try await repository?.saveState(meetingState)
            }
        } catch {
            startupError = error.localizedDescription
        }
        if let state = meetingState {
            lastReview = MeetingReviewSnapshot(
                meetingID: meeting.id,
                title: meeting.title,
                startedAt: meeting.startedAt,
                endedAt: endedAt,
                finalTranscript: transcript.filter(\.isFinal),
                decisions: state.decisions,
                questions: state.questions,
                requirements: state.requirements,
                actionItems: state.actionItems,
                risks: state.risks
            )
            backlogDrafts = BacklogIssueDraft.candidates(from: lastReview!)
            for draft in backlogDrafts {
                try? await repository?.saveBacklogDraft(draft)
            }
        }
        if let diagnosticsCollector {
            let report = await diagnosticsCollector.finish(
                endedAt: endedAt,
                audioIngress: audioIngress
            )
            do {
                try await repository?.saveDiagnostics(report)
            } catch {
                startupError = "診断レポートを保存できませんでした。\n\(error.localizedDescription)"
            }
            lastDiagnostics = report
            self.diagnosticsCollector = nil
        }
        activeMeeting = nil
    }

    func selectCaptureTarget() {
        captureService?.presentPicker()
    }

    func reconnectCodex() async {
        guard let meeting = activeMeeting,
              let project = projects.first(where: { $0.id == meeting.projectID }),
              !isCodexConnecting
        else { return }

        codexStatus = "再接続中"
        codexErrorDetail = nil
        codexSession = nil
        codexReconnectTask?.cancel()
        codexReconnectTask = nil
        automaticReconnectAttempts = 0
        await diagnosticsCollector?.recordCodexReconnect()
        await codexProvider.resetConnection()
        await connectCodex(project: project, meetingID: meeting.id)
    }

    func testCodexConnection() async {
        guard activeMeeting == nil,
              let project = selectedProject,
              !isCodexConnecting
        else { return }

        isCodexConnecting = true
        codexStatus = "接続テスト中"
        codexErrorDetail = nil
        defer { isCodexConnecting = false }

        await codexProvider.resetConnection()
        do {
            let session = try await codexProvider.startSession(project: project)
            codexExecutableDescription = await codexProvider.connectionDescription()
            codexStatus = "接続テスト成功"
            await codexProvider.endSession(session)
        } catch {
            codexStatus = "接続テスト失敗"
            codexErrorDetail = error.localizedDescription
            await codexProvider.resetConnection()
        }
    }

    func showSidePanel() {
        desktopIntegration?.showSidePanel()
    }

    func hideSidePanel() {
        desktopIntegration?.hideSidePanel()
    }

    func toggleSidePanel() {
        desktopIntegration?.toggleSidePanel()
    }

    func shortcutChoice(
        for action: GlobalHotKeyManager.Action
    ) -> ShortcutModifierChoice {
        shortcutConfiguration.choice(for: action)
    }

    func updateShortcut(
        _ action: GlobalHotKeyManager.Action,
        choice: ShortcutModifierChoice
    ) {
        shortcutConfiguration.setChoice(choice, for: action)
        shortcutConfiguration.save()
        desktopIntegration?.reloadHotKeys()
    }

    func shortcutLabel(for action: GlobalHotKeyManager.Action) -> String {
        shortcutConfiguration.label(for: action)
    }

    func shortcutLabel(for action: ManualAnalysisAction) -> String {
        let hotKeyAction: GlobalHotKeyManager.Action
        switch action {
        case .deepAnalyze: hotKeyAction = .deepAnalyze
        case .questionCandidates: hotKeyAction = .questionCandidates
        case .answerCandidate: hotKeyAction = .answerCandidate
        }
        return shortcutLabel(for: hotKeyAction)
    }

    func offerMeetingAppDetection(_ detection: MeetingAppDetection) {
        guard activeMeeting == nil,
              pendingMeetingDetection?.id != detection.id
        else { return }
        pendingMeetingDetection = detection
        desktopIntegration?.showMeetingDetection(detection)
    }

    func dismissMeetingDetection() {
        pendingMeetingDetection = nil
        desktopIntegration?.hideMeetingDetection()
    }

    func confirmMeetingDetection() async {
        guard let detection = pendingMeetingDetection else { return }
        dismissMeetingDetection()
        await startMeeting(suggestedTitle: detection.displayTitle)
    }

    func closeReview() {
        lastReview = nil
        lastDiagnostics = nil
        reviewFocusSegmentID = nil
        transcript = []
        cards = []
        meetingState = nil
        backlogDrafts = []
        backlogDraftForApproval = nil
        backlogOperationStatus = nil
        isBacklogSubmitting = false
        documentChangeProposal = nil
        documentUpdateReceipt = nil
        Task { [weak self] in
            await self?.refreshProjectBrief()
        }
    }

    func exportLastReview() {
        guard let review = lastReview else { return }
        let panel = NSSavePanel()
        panel.title = "Meeting Reviewを書き出す"
        panel.prompt = "書き出す"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText
        ]
        panel.canCreateDirectories = true
        let safeTitle = review.title.replacingOccurrences(
            of: #"[\\/:*?\"<>|\n\r]+"#,
            with: "_",
            options: .regularExpression
        )
        panel.nameFieldStringValue = "\(safeTitle)_Meeting-Review.md"

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let markdown = MeetingReviewMarkdownFormatter.render(
            review: review,
            cards: cards,
            diagnostics: lastDiagnostics,
            backlogDrafts: backlogDrafts,
            documentChangeProposals: documentChangeProposal.map { [$0] } ?? []
        )
        do {
            try markdown.write(to: destination, atomically: true, encoding: .utf8)
            startupError = "Meeting Reviewを書き出しました。\n\(destination.path)"
        } catch {
            startupError = "Meeting Reviewを書き出せませんでした。\n\(error.localizedDescription)"
        }
    }

    func makeDocumentUpdateProposal() async {
        guard let review = lastReview,
              let project = selectedProject
        else { return }
        let panel = NSOpenPanel()
        panel.title = "更新案を作るMarkdownまたはテキスト資料を選択"
        panel.prompt = "差分案を作成"
        panel.directoryURL = URL(filePath: project.rootPath)
        panel.allowedContentTypes = [.plainText]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let target = panel.url else { return }

        do {
            let policy = DocumentWritePolicy(rootPath: project.rootPath)
            let proposal = try await documentUpdateCoordinator.makeAppendProposal(
                review: review,
                targetPath: target.path,
                policy: policy
            )
            documentChangeProposal = proposal
            try await repository?.saveDocumentChangeProposal(proposal)
        } catch {
            startupError = "資料の差分案を作成できませんでした。\n\(error.localizedDescription)"
        }
    }

    func applyDocumentUpdateProposal() async {
        guard var proposal = documentChangeProposal,
              let project = selectedProject
        else { return }
        do {
            let receipt = try await documentUpdateCoordinator.applyApprovedProposal(
                proposal,
                approval: DocumentChangeApproval(proposalID: proposal.id),
                policy: DocumentWritePolicy(rootPath: project.rootPath)
            )
            proposal.status = .applied
            documentChangeProposal = proposal
            documentUpdateReceipt = receipt
            try await repository?.saveDocumentChangeProposal(proposal)
            startupError = receipt.backupPath.map {
                "資料を更新しました。\nバックアップ: \($0)"
            } ?? "資料を更新しました。"
        } catch {
            startupError = "資料を更新できませんでした。\n\(error.localizedDescription)"
        }
    }

    func presentBacklogApproval(_ draft: BacklogIssueDraft) {
        backlogDraftForApproval = draft
    }

    func submitApprovedBacklogDraft() async {
        guard !isBacklogSubmitting,
              var draft = backlogDraftForApproval,
              let configuration = selectedProject?.backlogConfiguration
        else {
            startupError = "Backlog設定がありません。設定画面でURL・各ID・APIキーを保存してください。"
            return
        }
        isBacklogSubmitting = true
        defer { isBacklogSubmitting = false }
        draft.status = .approved
        backlogDraftForApproval = draft
        updateBacklogDraft(draft)
        backlogOperationStatus = "Backlogへ登録中"
        do {
            try await repository?.saveBacklogDraft(draft)
            let receipt = try await backlogClient.createIssue(
                from: draft,
                configuration: configuration
            )
            draft.status = .submitted
            updateBacklogDraft(draft)
            try await repository?.saveBacklogDraft(draft)
            backlogDraftForApproval = nil
            backlogOperationStatus = receipt.wasAlreadyRegistered
                ? "既存課題 \(receipt.issueKey) を確認しました"
                : "\(receipt.issueKey) を登録しました"
        } catch {
            draft.status = .failed
            updateBacklogDraft(draft)
            try? await repository?.saveBacklogDraft(draft)
            backlogOperationStatus = "Backlog登録に失敗しました"
            startupError = "Backlogへ登録できませんでした。\n\(error.localizedDescription)"
        }
    }

    func updateSelectedProjectBacklogSettings(
        baseURL: String,
        projectID: Int?,
        issueTypeID: Int?,
        priorityID: Int?,
        apiKey: String
    ) async {
        guard activeMeeting == nil,
              let selectedProjectID,
              let index = projects.firstIndex(where: { $0.id == selectedProjectID })
        else { return }
        let credentialAccount = "project-\(selectedProjectID.uuidString)"
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedURL.isEmpty {
            projects[index].backlogConfiguration = nil
            do {
                try credentialStore.delete(account: credentialAccount)
                try await repository?.saveProject(projects[index])
                startupError = "Backlog連携を無効にしました。"
            } catch {
                startupError = error.localizedDescription
            }
            return
        }

        guard let url = URL(string: trimmedURL),
              let projectID, let issueTypeID, let priorityID,
              projectID > 0, issueTypeID > 0, priorityID > 0
        else {
            startupError = "Backlog URLとprojectId・issueTypeId・priorityIdを正しく入力してください。"
            return
        }
        do {
            if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try credentialStore.save(apiKey, account: credentialAccount)
            }
            projects[index].backlogConfiguration = BacklogConfiguration(
                baseURL: url,
                projectID: projectID,
                issueTypeID: issueTypeID,
                priorityID: priorityID,
                credentialAccount: credentialAccount
            )
            try await repository?.saveProject(projects[index])
            startupError = "Backlog設定を保存しました。APIキーはKeychainにのみ保存しています。"
        } catch {
            startupError = error.localizedDescription
        }
    }

    private func updateBacklogDraft(_ draft: BacklogIssueDraft) {
        if let index = backlogDrafts.firstIndex(where: { $0.id == draft.id }) {
            backlogDrafts[index] = draft
        }
    }

    func togglePin(_ card: SuggestionCard) async {
        guard let index = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cards[index].isPinned.toggle()
        let card = cards[index]
        await persist { [repository] in
            try await repository?.saveCard(card)
        }
    }

    var availableSpeakerLabels: [String] {
        ["参加者"] + (selectedProject?.participantNames ?? [])
    }

    func assignSpeakerLabel(
        segmentID: UUID,
        label: String?
    ) async {
        guard let index = transcript.firstIndex(where: { $0.id == segmentID })
        else { return }
        let normalized = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript[index].speakerLabel = (normalized?.isEmpty == false)
            ? normalized
            : nil
        let updatedSegment = transcript[index]
        await persist { [repository] in
            try await repository?.upsertTranscript(updatedSegment)
        }

        if let review = lastReview {
            var finalTranscript = review.finalTranscript
            if let reviewIndex = finalTranscript.firstIndex(where: {
                $0.id == segmentID
            }) {
                finalTranscript[reviewIndex] = updatedSegment
                lastReview = MeetingReviewSnapshot(
                    id: review.id,
                    meetingID: review.meetingID,
                    title: review.title,
                    startedAt: review.startedAt,
                    endedAt: review.endedAt,
                    finalTranscript: finalTranscript,
                    decisions: review.decisions,
                    questions: review.questions,
                    requirements: review.requirements,
                    actionItems: review.actionItems,
                    risks: review.risks
                )
            }
        }
    }

    func openEvidence(_ evidence: EvidenceReference) {
        switch evidence.kind {
        case .transcript:
            guard let location = evidence.location,
                  let segmentID = UUID(uuidString: location)
            else {
                startupError = "根拠となる発言IDが正しくありません。"
                return
            }
            if transcript.contains(where: { $0.id == segmentID }) {
                transcriptFocusRequest = TranscriptFocusRequest(segmentID: segmentID)
                return
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    guard let segment = try await self.repository?
                        .transcriptSegment(id: segmentID)
                    else {
                        self.startupError = "根拠となる発言が保存データに見つかりません。"
                        return
                    }
                    self.transcript.append(segment)
                    self.transcript.sort { $0.startTime < $1.startTime }
                    self.transcriptFocusRequest = TranscriptFocusRequest(
                        segmentID: segmentID
                    )
                } catch {
                    self.startupError = "根拠発言を読み込めませんでした。\n\(error.localizedDescription)"
                }
            }

        case .projectFile, .sourceCode:
            guard let location = evidence.location,
                  let project = evidenceProject,
                  let normalized = ProjectSearchPolicy(project: project)
                    .normalizedAllowedPath(location),
                  FileManager.default.fileExists(atPath: normalized)
            else {
                startupError = "根拠ファイルがProject Search Policyの範囲内に見つかりません。"
                return
            }
            if !NSWorkspace.shared.open(URL(filePath: normalized)) {
                startupError = "根拠ファイルを開けませんでした。\n\(normalized)"
            }

        case .web:
            guard let location = evidence.location,
                  let url = URL(string: location),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "")
            else {
                startupError = "根拠URLが正しくありません。"
                return
            }
            NSWorkspace.shared.open(url)

        case .screenContext:
            guard let location = evidence.location,
                  let eventID = UUID(uuidString: location)
            else {
                startupError = "画面根拠IDが正しくありません。"
                return
            }
            if currentScreenEvent?.id == eventID {
                screenEvidencePreview = currentScreenEvent
                return
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    self.screenEvidencePreview = try await self.repository?
                        .screenContextEvent(id: eventID)
                    if self.screenEvidencePreview == nil {
                        self.startupError = "画面根拠が保存データに見つかりません。"
                    }
                } catch {
                    self.startupError = "画面根拠を読み込めませんでした。\n\(error.localizedDescription)"
                }
            }

        case .gitHistory:
            copyEvidence(evidence)
        }
    }

    func copyEvidence(_ evidence: EvidenceReference) {
        let location = evidence.location ?? evidence.label
        let value = evidence.line.map { "\(location):\($0)" } ?? location
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private var evidenceProject: ProjectConfiguration? {
        if let activeMeeting {
            return projects.first { $0.id == activeMeeting.projectID }
        }
        return selectedProject
    }

    private func loadProjects() async {
        do {
            projects = try await repository?.listProjects() ?? []
            selectedProjectID = projects.first?.id
        } catch {
            startupError = error.localizedDescription
        }
    }

    private func handleTranscript(_ segment: TranscriptSegment) async {
        guard !isMeetingPaused,
              activeMeeting?.id == segment.meetingID,
              var state = meetingState
        else { return }

        if let index = transcript.firstIndex(where: { $0.id == segment.id }) {
            transcript[index] = segment
        } else {
            transcript.append(segment)
        }
        if transcript.count > 500 {
            transcript.removeFirst(transcript.count - 500)
        }
        let transcriptReceivedAt = Date()
        await persist { [repository] in
            try await repository?.upsertTranscript(segment)
        }

        guard segment.isFinal else { return }
        if let diagnostics = diagnosticsCollector {
            if let firstSubmittedAt = transcriptionService
                .ingressDiagnostics()
                .firstSubmittedAt {
                await diagnostics.recordAudioInput(at: firstSubmittedAt)
            }
            await diagnostics.recordFinalTranscript(
                endTime: segment.endTime,
                receivedAt: transcriptReceivedAt
            )
        }
        if let transitionedTopic = topicTransitionDetector.transitionedTopic(
            for: segment,
            current: state.topic
        ) {
            state.topic = transitionedTopic
            state.revision += 1
            meetingState = state
            await cancelAnalyses(outsideTopicID: transitionedTopic.id)
            await persist { [repository] in
                try await repository?.saveState(state)
            }
        }
        let events = await eventDetector.process(segment: segment, state: state)
        await diagnosticsCollector?.recordEventDetection(
            eventIDs: events.map(\.id),
            transcriptReceivedAt: transcriptReceivedAt
        )
        guard !events.isEmpty else { return }

        state = stateReducer.reducing(state, with: events)
        meetingState = state
        await persist { [repository] in
            try await repository?.saveState(state)
        }

        for event in events {
            detectedEventsByID[event.id] = event
            await persist { [repository] in
                try await repository?.saveEvent(event)
            }
            let card = suggestionFactory.card(for: event, segment: segment)
            cards.insert(card, at: 0)
            await persist { [repository] in
                try await repository?.saveCard(card)
            }
            desktopIntegration?.showSuggestionNotification(card)

            if codexSession != nil {
                await enqueueAnalysis(
                    event: event,
                    segment: segment,
                    state: state,
                    mode: .fast
                )
            }
        }
        if cards.count > 100 {
            cards.removeLast(cards.count - 100)
        }
    }

    func performManualAnalysis(_ action: ManualAnalysisAction) async {
        guard !isMeetingPaused else {
            startupError = "記録を再開してからAI分析を実行してください。"
            return
        }
        guard let meeting = activeMeeting,
              let state = meetingState,
              let segment = transcript.last(where: \.isFinal)
        else {
            startupError = "会議の確定済み文字起こしがまだありません。"
            return
        }
        guard codexSession != nil else {
            startupError = "\(selectedProviderDisplayName)が接続されるまでお待ちください。"
            return
        }

        let eventType: MeetingEventType
        let mode: AnalysisMode
        switch action {
        case .deepAnalyze:
            eventType = .importantFact
            mode = .deep
        case .questionCandidates:
            eventType = .requirement
            mode = .fast
        case .answerCandidate:
            eventType = .question
            mode = .fast
        }

        let event = DetectedEvent(
            meetingID: meeting.id,
            topicID: state.topic.id,
            topicRevision: state.topic.revision,
            type: eventType,
            sourceSegmentIDs: [segment.id],
            triggerReason: "手動操作: \(action.title)",
            excerpt: segment.text,
            localScore: 1
        )
        detectedEventsByID[event.id] = event
        await diagnosticsCollector?.recordEventDetection(
            eventIDs: [event.id],
            transcriptReceivedAt: Date()
        )
        await persist { [repository] in
            try await repository?.saveEvent(event)
        }

        let placeholder = manualPlaceholder(
            action: action,
            event: event,
            segment: segment,
            mode: mode
        )
        cards.insert(placeholder, at: 0)
        await persist { [repository] in
            try await repository?.saveCard(placeholder)
        }
        desktopIntegration?.showSuggestionNotification(placeholder)

        await enqueueAnalysis(
            event: event,
            segment: segment,
            state: state,
            mode: mode
        )
    }

    private func manualPlaceholder(
        action: ManualAnalysisAction,
        event: DetectedEvent,
        segment: TranscriptSegment,
        mode: AnalysisMode
    ) -> SuggestionCard {
        let category: SuggestionCategory
        switch action {
        case .deepAnalyze: category = .research
        case .questionCandidates: category = .question
        case .answerCandidate: category = .answer
        }
        return SuggestionCard(
            meetingID: event.meetingID,
            sourceEventID: event.id,
            topicRevision: event.topicRevision,
            category: category,
            title: action.title,
            body: mode == .deep ? "詳細調査中です。" : "AIで生成中です。",
            importance: .high,
            confidence: 0.5,
            evidence: [
                EvidenceReference(
                    kind: .transcript,
                    label: "直近の会議発言",
                    location: segment.id.uuidString
                )
            ],
            mode: mode
        )
    }

    func canPromoteToDeep(_ card: SuggestionCard) -> Bool {
        card.mode == .fast &&
            !isMeetingPaused &&
            codexSession != nil &&
            detectedEventsByID[card.sourceEventID] != nil &&
            !fastAnalysisInProgressEventIDs.contains(card.sourceEventID) &&
            !deepAnalysisInProgressEventIDs.contains(card.sourceEventID)
    }

    func promoteToDeep(_ card: SuggestionCard) async {
        guard canPromoteToDeep(card),
              let event = detectedEventsByID[card.sourceEventID],
              let segmentID = event.sourceSegmentIDs.last,
              let segment = transcript.first(where: { $0.id == segmentID }),
              let state = meetingState
        else {
            startupError = "このカードを詳細調査へ昇格できません。元の発言またはAI接続を確認してください。"
            return
        }

        await enqueueAnalysis(
            event: event,
            segment: segment,
            state: state,
            mode: .deep
        )
    }

    private func enqueueAnalysis(
        event: DetectedEvent,
        segment: TranscriptSegment,
        state: MeetingState,
        mode: AnalysisMode
    ) async {
        guard !isMeetingPaused,
              activeMeeting?.id == event.meetingID
        else { return }
        let inProgress = mode == .fast
            ? fastAnalysisInProgressEventIDs
            : deepAnalysisInProgressEventIDs
        guard !inProgress.contains(event.id) else { return }

        let pending = PendingAIAnalysis(
            analysisID: UUID(),
            event: event,
            segment: segment,
            state: state,
            mode: mode,
            enqueuedAt: Date()
        )
        var record = AnalysisRecord(
            id: pending.analysisID,
            meetingID: event.meetingID,
            topicID: state.topic.id,
            eventID: event.id,
            contextRevision: state.revision,
            mode: mode
        )
        record.status = .queued
        await saveAnalysisRecord(record)

        if mode == .fast {
            fastAnalysisInProgressEventIDs.insert(event.id)
            fastAnalysisQueue.append(pending)
            let overflowCount = max(
                0,
                fastAnalysisQueue.count - maximumQueuedFastAnalyses
            )
            if overflowCount > 0 {
                let superseded = Array(fastAnalysisQueue.prefix(overflowCount))
                fastAnalysisQueue.removeFirst(overflowCount)
                for item in superseded {
                    fastAnalysisInProgressEventIDs.remove(item.event.id)
                    await markAnalysisStale(
                        item.analysisID,
                        reason: "新しい会議イベントを優先したためAI更新を省略しました。"
                    )
                }
            }
            startAnalysisWorkerIfNeeded(mode: .fast)
        } else {
            deepAnalysisInProgressEventIDs.insert(event.id)
            // 同一topicでは最新のDeepだけを待機させる。
            let superseded = deepAnalysisQueue.filter {
                $0.state.topic.id == state.topic.id
            }
            deepAnalysisQueue.removeAll {
                $0.state.topic.id == state.topic.id
            }
            for item in superseded {
                deepAnalysisInProgressEventIDs.remove(item.event.id)
                await markAnalysisCancelled(item.analysisID)
            }
            deepAnalysisQueue.append(pending)
            startAnalysisWorkerIfNeeded(mode: .deep)
        }
    }

    private func startAnalysisWorkerIfNeeded(mode: AnalysisMode) {
        switch mode {
        case .fast:
            guard fastAnalysisWorker == nil else { return }
            fastAnalysisWorker = Task { [weak self] in
                await self?.drainAnalysisQueue(mode: .fast)
            }
        case .deep:
            guard deepAnalysisWorker == nil else { return }
            deepAnalysisWorker = Task { [weak self] in
                await self?.drainAnalysisQueue(mode: .deep)
            }
        }
    }

    private func drainAnalysisQueue(mode: AnalysisMode) async {
        defer {
            if mode == .fast {
                fastAnalysisWorker = nil
            } else {
                deepAnalysisWorker = nil
            }
        }

        while !Task.isCancelled {
            let pending: PendingAIAnalysis?
            if mode == .fast {
                pending = fastAnalysisQueue.isEmpty
                    ? nil
                    : fastAnalysisQueue.removeFirst()
            } else {
                pending = deepAnalysisQueue.isEmpty
                    ? nil
                    : deepAnalysisQueue.removeFirst()
            }
            guard let pending else { return }

            if mode == .fast,
               Date().timeIntervalSince(pending.enqueuedAt) > maximumFastQueueWait {
                fastAnalysisInProgressEventIDs.remove(pending.event.id)
                await markAnalysisStale(
                    pending.analysisID,
                    reason: "リアルタイム性を保つため古いAI更新を省略しました。"
                )
                continue
            }

            guard !isMeetingPaused,
                  activeMeeting?.id == pending.event.meetingID,
                  meetingState?.topic.id == pending.state.topic.id
            else {
                if mode == .fast {
                    fastAnalysisInProgressEventIDs.remove(pending.event.id)
                } else {
                    deepAnalysisInProgressEventIDs.remove(pending.event.id)
                }
                await markAnalysisCancelled(pending.analysisID)
                continue
            }

            await analyzeWithCodex(
                analysisID: pending.analysisID,
                event: pending.event,
                segment: pending.segment,
                state: pending.state,
                mode: mode
            )

            if mode == .fast,
               let card = cards.first(where: {
                   $0.sourceEventID == pending.event.id
               }),
               shouldAutomaticallyPromote(card: card, event: pending.event) {
                await enqueueAnalysis(
                    event: pending.event,
                    segment: pending.segment,
                    state: meetingState ?? pending.state,
                    mode: .deep
                )
            }
        }
    }

    private func shouldAutomaticallyPromote(
        card: SuggestionCard,
        event: DetectedEvent
    ) -> Bool {
        guard card.mode == .fast,
              analysisStatusByEventID[event.id] == .completed
        else { return false }
        if event.type == .contradiction || event.type == .specificationChange {
            return true
        }
        if card.importance == .critical ||
            (card.importance >= .high && card.confidence < 0.68) {
            return true
        }
        return event.excerpt.range(
            of: #"(費用|予算|納期|期限|セキュリティ|個人情報|障害|契約)"#,
            options: .regularExpression
        ) != nil
    }

    private func connectCodex(
        project: ProjectConfiguration,
        meetingID: UUID
    ) async {
        guard !isCodexConnecting else { return }
        isCodexConnecting = true
        defer { isCodexConnecting = false }
        codexStatus = "接続中"
        codexErrorDetail = nil
        do {
            let session = try await codexProvider.startSession(project: project)
            guard activeMeeting?.id == meetingID else {
                await codexProvider.endSession(session)
                return
            }
            codexSession = session
            codexStatus = "Read-Only接続済み"
            automaticReconnectAttempts = 0
            codexExecutableDescription = await codexProvider.connectionDescription()
            if var meeting = activeMeeting {
                meeting.codexFastThreadID = session.id
                activeMeeting = meeting
                await persist { [repository] in
                    try await repository?.updateMeeting(meeting)
                }
            }
        } catch {
            codexStatus = "接続失敗"
            codexErrorDetail = error.localizedDescription
            await diagnosticsCollector?.recordError(
                "AI Provider接続: \(error.localizedDescription)"
            )
            scheduleAutomaticCodexReconnect(meetingID: meetingID)
        }
    }

    private func analyzeWithCodex(
        analysisID: UUID,
        event: DetectedEvent,
        segment: TranscriptSegment,
        state: MeetingState,
        mode: AnalysisMode = .fast
    ) async {
        defer {
            if mode == .fast {
                fastAnalysisInProgressEventIDs.remove(event.id)
            } else {
                deepAnalysisInProgressEventIDs.remove(event.id)
            }
        }
        guard let codexSession,
              activeMeeting?.id == event.meetingID
        else {
            if var record = analysisRecords[analysisID] {
                record.status = .failed
                record.completedAt = Date()
                record.errorMessage = "AI Providerが未接続です。"
                await saveAnalysisRecord(record)
            }
            return
        }

        let recent = transcript
            .filter(\.isFinal)
            .suffix(80)
        let transcriptEvidence = EvidenceReference(
            kind: .transcript,
            label: "会議発言",
            location: segment.id.uuidString
        )
        var relatedEvidence = [transcriptEvidence]
        if let screenEvent = currentScreenEvent {
            let changedObservations = screenEvent.changes.compactMap {
                $0.current ?? $0.previous
            }
            let excerpt = changedObservations
                .map(\.text)
                .joined(separator: " / ")
            relatedEvidence.append(
                EvidenceReference(
                    kind: .screenContext,
                    label: "直近の画面差分",
                    location: screenEvent.id.uuidString,
                    meetingTime: screenEvent.presentationTime,
                    regions: changedObservations.map(\.bounds),
                    excerpt: String(excerpt.prefix(500)),
                    checkedAt: screenEvent.capturedAt
                )
            )
        }
        let context = MeetingContextEnvelope(
            meetingID: event.meetingID,
            topic: state.topic,
            state: state,
            recentTranscript: Array(recent),
            sourceEvent: event,
            relatedEvidence: relatedEvidence,
            projectSearchPolicy: activeMeeting.flatMap { meeting in
                projects.first(where: { $0.id == meeting.projectID })
            }.map(ProjectSearchPolicy.init),
            projectBrief: projectBriefItems
        )
        let request = AnalysisRequest(
            id: analysisID,
            mode: mode,
            context: context,
            deadline: mode == .fast ? .seconds(15) : .seconds(45)
        )
        var analysisRecord = AnalysisRecord(
            id: request.id,
            meetingID: event.meetingID,
            topicID: state.topic.id,
            eventID: event.id,
            contextRevision: state.revision,
            mode: mode
        )
        await saveAnalysisRecord(analysisRecord)
        analysisRecord.status = .running
        await saveAnalysisRecord(analysisRecord)
        await diagnosticsCollector?.recordAnalysisStarted(
            analysisID: request.id,
            eventID: event.id,
            mode: mode
        )

        codexStatus = mode == .fast ? "分析中" : "詳細調査中"
        let stream = await codexProvider.analyze(
            request: request,
            in: codexSession
        )
        var recordedCompletion = false
        do {
            for try await progress in stream {
                if analysisRecords[request.id]?.status == .cancelled {
                    await codexProvider.cancel(analysisID: request.id)
                    return
                }
                guard activeMeeting?.id == event.meetingID else {
                    await codexProvider.cancel(analysisID: request.id)
                    await diagnosticsCollector?.recordAnalysisCancelled(
                        analysisID: request.id
                    )
                    analysisRecord.status = .cancelled
                    analysisRecord.completedAt = Date()
                    await saveAnalysisRecord(analysisRecord)
                    return
                }
                if case .completed(let card) = progress {
                    await diagnosticsCollector?.recordAnalysisCompleted(
                        analysisID: request.id
                    )
                    recordedCompletion = true
                    let freshness = analysisFreshnessEvaluator.evaluate(
                        analysisRecord,
                        currentMeetingID: activeMeeting?.id,
                        currentState: meetingState
                    )
                    if freshness == .stale {
                        await diagnosticsCollector?.recordDroppedEvent()
                        analysisRecord.status = .stale
                        analysisRecord.completedAt = Date()
                        await saveAnalysisRecord(analysisRecord)
                        return
                    }
                    var card = card
                    if freshness == .relatedButOld {
                        card.title = "過去コンテキスト: \(card.title)"
                        if card.importance > .medium {
                            card.importance = .medium
                        }
                    }
                    if let index = cards.firstIndex(where: {
                        $0.sourceEventID == card.sourceEventID
                    }) {
                        cards[index] = card
                    } else {
                        cards.insert(card, at: 0)
                    }
                    await persist { [repository] in
                        try await repository?.saveCard(card)
                    }
                    analysisRecord.status = .completed
                    analysisRecord.completedAt = Date()
                    await saveAnalysisRecord(analysisRecord)
                }
            }
            if !recordedCompletion {
                guard analysisRecords[request.id]?.status != .cancelled else {
                    return
                }
                await diagnosticsCollector?.recordAnalysisFailed(
                    analysisID: request.id,
                    message: "AI分析が結果なしで終了しました。"
                )
                analysisRecord.status = .failed
                analysisRecord.completedAt = Date()
                analysisRecord.errorMessage = "結果なしで終了"
                await saveAnalysisRecord(analysisRecord)
            }
            codexStatus = "Read-Only接続済み"
        } catch {
            guard analysisRecords[request.id]?.status != .cancelled else {
                return
            }
            let timedOut = CodexAnalysisFailurePolicy.isDeadlineExceeded(error)
            codexStatus = timedOut ? "Read-Only接続済み" : "分析失敗"
            await diagnosticsCollector?.recordAnalysisFailed(
                analysisID: request.id,
                message: "AI分析: \(error.localizedDescription)"
            )
            analysisRecord.status = timedOut ? .timedOut : .failed
            analysisRecord.completedAt = Date()
            analysisRecord.errorMessage = error.localizedDescription
            await saveAnalysisRecord(analysisRecord)
            if CodexAnalysisFailurePolicy.shouldReconnect(error) {
                scheduleAutomaticCodexReconnect(meetingID: event.meetingID)
            } else if !timedOut {
                codexStatus = "Read-Only接続済み"
            }
        }
    }

    private func cancelActiveAnalyses() async {
        let cancellableIDs = analysisRecords.compactMap { id, record in
            switch record.status {
            case .queued, .running:
                id
            case .completed, .stale, .cancelled, .timedOut, .failed:
                nil
            }
        }
        guard !cancellableIDs.isEmpty else { return }

        let completedAt = Date()
        var cancelledRecords: [AnalysisRecord] = []
        for id in cancellableIDs {
            guard var record = analysisRecords[id] else { continue }
            record.status = .cancelled
            record.completedAt = completedAt
            analysisRecords[id] = record
            cancelledRecords.append(record)
        }

        for record in cancelledRecords {
            await codexProvider.cancel(analysisID: record.id)
            await diagnosticsCollector?.recordAnalysisCancelled(
                analysisID: record.id
            )
            await saveAnalysisRecord(record)
        }
    }

    private func cancelAnalyses(outsideTopicID topicID: UUID) async {
        let queuedFast = fastAnalysisQueue.filter {
            $0.state.topic.id != topicID
        }
        let queuedDeep = deepAnalysisQueue.filter {
            $0.state.topic.id != topicID
        }
        fastAnalysisQueue.removeAll { $0.state.topic.id != topicID }
        deepAnalysisQueue.removeAll { $0.state.topic.id != topicID }
        for pending in queuedFast + queuedDeep {
            fastAnalysisInProgressEventIDs.remove(pending.event.id)
            deepAnalysisInProgressEventIDs.remove(pending.event.id)
            await markAnalysisCancelled(pending.analysisID)
        }

        let active = analysisRecords.values.filter {
            $0.topicID != topicID && ($0.status == .queued || $0.status == .running)
        }
        for record in active {
            await codexProvider.cancel(analysisID: record.id)
            await markAnalysisCancelled(record.id)
        }
    }

    private func markAnalysisCancelled(_ id: UUID) async {
        guard var record = analysisRecords[id],
              record.status == .queued || record.status == .running
        else { return }
        record.status = .cancelled
        record.completedAt = Date()
        await diagnosticsCollector?.recordAnalysisCancelled(analysisID: id)
        await saveAnalysisRecord(record)
    }

    private func markAnalysisStale(_ id: UUID, reason: String) async {
        guard var record = analysisRecords[id],
              record.status == .queued || record.status == .running
        else { return }
        record.status = .stale
        record.completedAt = Date()
        record.errorMessage = reason
        await saveAnalysisRecord(record)
    }

    private func scheduleAutomaticCodexReconnect(meetingID: UUID) {
        guard activeMeeting?.id == meetingID,
              codexReconnectTask == nil,
              automaticReconnectAttempts < 3
        else { return }

        automaticReconnectAttempts += 1
        let attempt = automaticReconnectAttempts
        codexStatus = "自動再接続待機中（\(attempt)/3）"
        codexReconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1 << (attempt - 1)))
            } catch {
                return
            }
            guard let self,
                  let meeting = self.activeMeeting,
                  meeting.id == meetingID,
                  let project = self.projects.first(where: {
                      $0.id == meeting.projectID
                  })
            else { return }

            self.codexReconnectTask = nil
            self.codexSession = nil
            await self.diagnosticsCollector?.recordCodexReconnect()
            await self.codexProvider.resetConnection()
            await self.connectCodex(project: project, meetingID: meetingID)
        }
    }

    private func saveAnalysisRecord(_ record: AnalysisRecord) async {
        analysisRecords[record.id] = record
        analysisStatusByEventID[record.eventID] = record.status
        await persist { [repository] in
            try await repository?.saveAnalysisRecord(record)
        }
    }

    private func persist(
        _ operation: @MainActor () async throws -> Void
    ) async {
        let startedAt = Date()
        do {
            try await operation()
        } catch {
            await diagnosticsCollector?.recordError(
                "SQLite: \(error.localizedDescription)"
            )
        }
        await diagnosticsCollector?.recordSQLiteWrite(
            Date().timeIntervalSince(startedAt)
        )
    }
}

struct TranscriptFocusRequest: Equatable {
    let id = UUID()
    let segmentID: UUID
}

private struct PendingAIAnalysis: Sendable {
    let analysisID: UUID
    let event: DetectedEvent
    let segment: TranscriptSegment
    let state: MeetingState
    let mode: AnalysisMode
    let enqueuedAt: Date
}
