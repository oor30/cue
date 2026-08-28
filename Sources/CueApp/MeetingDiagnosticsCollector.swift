import Darwin
import Foundation
import CueCore

actor MeetingDiagnosticsCollector {
    typealias CodexProcessCountProvider = @Sendable () async -> Int

    private let meetingID: UUID
    private let startedAt: Date
    private let codexProcessCountProvider: CodexProcessCountProvider
    private var samplerTask: Task<Void, Never>?
    private var processSampler = ProcessResourceSampler()

    private var cpuSamples: [Double] = []
    private var memorySamples: [Double] = []
    private var sttFinalLatencySamples: [Double] = []
    private var sttToEventLatencySamples: [Double] = []
    private var eventToFastCardLatencySamples: [Double] = []
    private var deepAnalysisSamples: [Double] = []
    private var screenProcessingSamples: [Double] = []
    private var sqliteWriteSamples: [Double] = []
    private var codexProcessSamples: [Double] = []
    private var eventDetectedAt: [UUID: Date] = [:]
    private var analysisStartedAt: [
        UUID: (date: Date, eventID: UUID, mode: AnalysisMode)
    ] = [:]
    private var firstAudioInputAt: Date?
    private var maximumAudioQueueDepth = 0
    private var maximumPendingEventCount = 0
    private var counters = MeetingDiagnosticCounters()
    private var recentErrors: [String] = []

    init(
        meetingID: UUID,
        startedAt: Date,
        codexProcessCountProvider: @escaping CodexProcessCountProvider
    ) {
        self.meetingID = meetingID
        self.startedAt = startedAt
        self.codexProcessCountProvider = codexProcessCountProvider
    }

    func start() async {
        guard samplerTask == nil else { return }
        await sampleResources()
        samplerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                await self?.sampleResources()
            }
        }
    }

    func finish(
        endedAt: Date,
        audioIngress: AudioIngressDiagnostics
    ) async -> MeetingDiagnosticsReport {
        samplerTask?.cancel()
        samplerTask = nil
        await sampleResources()
        firstAudioInputAt = firstAudioInputAt ?? audioIngress.firstSubmittedAt
        maximumAudioQueueDepth = max(
            maximumAudioQueueDepth,
            audioIngress.maximumQueueDepth
        )
        counters.droppedAudioBuffers += audioIngress.droppedBuffers

        return MeetingDiagnosticsReport(
            meetingID: meetingID,
            startedAt: startedAt,
            endedAt: endedAt,
            cpuPercent: MetricDistributionSummary(samples: cpuSamples),
            memoryMegabytes: ResourceUsageSummary(samples: memorySamples),
            sttFinalLatencySeconds: MetricDistributionSummary(
                samples: sttFinalLatencySamples
            ),
            sttToEventLatencySeconds: MetricDistributionSummary(
                samples: sttToEventLatencySamples
            ),
            eventToFastCardLatencySeconds: MetricDistributionSummary(
                samples: eventToFastCardLatencySamples
            ),
            deepAnalysisSeconds: MetricDistributionSummary(
                samples: deepAnalysisSamples
            ),
            screenProcessingSeconds: MetricDistributionSummary(
                samples: screenProcessingSamples
            ),
            sqliteWriteSeconds: MetricDistributionSummary(
                samples: sqliteWriteSamples
            ),
            codexProcessCount: ResourceUsageSummary(
                samples: codexProcessSamples
            ),
            maximumAudioQueueDepth: maximumAudioQueueDepth,
            maximumPendingEventCount: maximumPendingEventCount,
            counters: counters,
            recentErrors: recentErrors
        )
    }

    func recordAudioInput(at date: Date = Date()) {
        if firstAudioInputAt == nil {
            firstAudioInputAt = date
        }
    }

    func recordFinalTranscript(
        endTime: TimeInterval,
        receivedAt: Date = Date()
    ) {
        guard let firstAudioInputAt else { return }
        let expectedAt = firstAudioInputAt.addingTimeInterval(endTime)
        append(
            max(0, receivedAt.timeIntervalSince(expectedAt)),
            to: &sttFinalLatencySamples
        )
    }

    func recordEventDetection(
        eventIDs: [UUID],
        transcriptReceivedAt: Date,
        completedAt: Date = Date()
    ) {
        append(
            max(0, completedAt.timeIntervalSince(transcriptReceivedAt)),
            to: &sttToEventLatencySamples
        )
        eventIDs.forEach { eventDetectedAt[$0] = completedAt }
    }

    func recordAnalysisStarted(
        analysisID: UUID,
        eventID: UUID,
        mode: AnalysisMode,
        at date: Date = Date()
    ) {
        analysisStartedAt[analysisID] = (date, eventID, mode)
        maximumPendingEventCount = max(
            maximumPendingEventCount,
            analysisStartedAt.count
        )
    }

    func recordAnalysisCompleted(
        analysisID: UUID,
        at date: Date = Date()
    ) {
        guard let analysis = analysisStartedAt.removeValue(forKey: analysisID) else {
            return
        }
        let duration = max(0, date.timeIntervalSince(analysis.date))
        if analysis.mode == .deep {
            append(duration, to: &deepAnalysisSamples)
        } else if let detectedAt = eventDetectedAt[analysis.eventID] {
            append(
                max(0, date.timeIntervalSince(detectedAt)),
                to: &eventToFastCardLatencySamples
            )
        }
    }

    func recordAnalysisFailed(
        analysisID: UUID,
        message: String
    ) {
        analysisStartedAt.removeValue(forKey: analysisID)
        recordError(message)
    }

    func recordAnalysisCancelled(analysisID: UUID) {
        analysisStartedAt.removeValue(forKey: analysisID)
    }

    func recordScreenProcessing(_ duration: TimeInterval) {
        append(duration, to: &screenProcessingSamples)
    }

    func recordSQLiteWrite(_ duration: TimeInterval) {
        append(duration, to: &sqliteWriteSamples)
    }

    func recordCodexReconnect() {
        counters.codexReconnects += 1
    }

    func recordTranscriptionRecovery() {
        counters.transcriptionRecoveries += 1
    }

    func recordDroppedEvent() {
        counters.droppedEvents += 1
    }

    func recordError(_ message: String) {
        counters.errorCount += 1
        let timestamp = Date().formatted(
            .iso8601.year().month().day().time(includingFractionalSeconds: true)
        )
        recentErrors.append("\(timestamp) \(message)")
        if recentErrors.count > 20 {
            recentErrors.removeFirst(recentErrors.count - 20)
        }
    }

    private func sampleResources() async {
        if let sample = processSampler.sample() {
            append(sample.cpuPercent, to: &cpuSamples)
            append(sample.memoryMegabytes, to: &memorySamples)
        }
        let codexCount = await codexProcessCountProvider()
        append(Double(codexCount), to: &codexProcessSamples)
    }

    private func append(_ value: Double, to samples: inout [Double]) {
        guard value.isFinite else { return }
        samples.append(value)
        if samples.count > 50_000 {
            samples.removeFirst(samples.count - 50_000)
        }
    }
}

private struct ProcessResourceSampler {
    private var previousCPUSeconds: Double?
    private var previousDate: Date?

    mutating func sample(now: Date = Date()) -> (
        cpuPercent: Double,
        memoryMegabytes: Double
    )? {
        var usage = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(
                to: rusage_info_t?.self,
                capacity: 1
            ) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V2, rebound)
            }
        }
        guard status == 0 else { return nil }

        let cpuSeconds = Double(usage.ri_user_time + usage.ri_system_time) /
            1_000_000_000
        let cpuPercent: Double
        if let previousCPUSeconds, let previousDate {
            let wall = max(0.001, now.timeIntervalSince(previousDate))
            cpuPercent = max(0, (cpuSeconds - previousCPUSeconds) / wall * 100)
        } else {
            cpuPercent = 0
        }
        self.previousCPUSeconds = cpuSeconds
        self.previousDate = now

        return (
            cpuPercent,
            Double(usage.ri_phys_footprint) / 1_048_576
        )
    }
}
