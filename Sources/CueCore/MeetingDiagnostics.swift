import Foundation

public struct MetricDistributionSummary: Codable, Hashable, Sendable {
    public let count: Int
    public let p50: Double
    public let p95: Double
    public let max: Double

    public init(samples: [Double]) {
        let values = samples.filter(\.isFinite).sorted()
        self.count = values.count
        self.p50 = Self.percentile(0.50, values: values)
        self.p95 = Self.percentile(0.95, values: values)
        self.max = values.last ?? 0
    }

    private static func percentile(_ value: Double, values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let index = Int(
            (Double(values.count - 1) * value).rounded(.up)
        )
        return values[Swift.min(Swift.max(0, index), values.count - 1)]
    }
}

public struct ResourceUsageSummary: Codable, Hashable, Sendable {
    public let start: Double
    public let end: Double
    public let peak: Double

    public init(samples: [Double]) {
        let values = samples.filter(\.isFinite)
        self.start = values.first ?? 0
        self.end = values.last ?? 0
        self.peak = values.max() ?? 0
    }
}

public struct MeetingDiagnosticCounters: Codable, Hashable, Sendable {
    public var codexReconnects: Int
    public var droppedAudioBuffers: Int
    public var droppedEvents: Int
    public var transcriptionRecoveries: Int
    public var errorCount: Int

    public init(
        codexReconnects: Int = 0,
        droppedAudioBuffers: Int = 0,
        droppedEvents: Int = 0,
        transcriptionRecoveries: Int = 0,
        errorCount: Int = 0
    ) {
        self.codexReconnects = codexReconnects
        self.droppedAudioBuffers = droppedAudioBuffers
        self.droppedEvents = droppedEvents
        self.transcriptionRecoveries = transcriptionRecoveries
        self.errorCount = errorCount
    }
}

public struct MeetingDiagnosticsReport: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let cpuPercent: MetricDistributionSummary
    public let memoryMegabytes: ResourceUsageSummary
    public let sttFinalLatencySeconds: MetricDistributionSummary
    public let sttToEventLatencySeconds: MetricDistributionSummary
    public let eventToFastCardLatencySeconds: MetricDistributionSummary
    public let deepAnalysisSeconds: MetricDistributionSummary
    public let screenProcessingSeconds: MetricDistributionSummary
    public let sqliteWriteSeconds: MetricDistributionSummary
    public let codexProcessCount: ResourceUsageSummary
    public let maximumAudioQueueDepth: Int
    public let maximumPendingEventCount: Int
    public let counters: MeetingDiagnosticCounters
    public let recentErrors: [String]

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        startedAt: Date,
        endedAt: Date,
        cpuPercent: MetricDistributionSummary,
        memoryMegabytes: ResourceUsageSummary,
        sttFinalLatencySeconds: MetricDistributionSummary,
        sttToEventLatencySeconds: MetricDistributionSummary,
        eventToFastCardLatencySeconds: MetricDistributionSummary,
        deepAnalysisSeconds: MetricDistributionSummary,
        screenProcessingSeconds: MetricDistributionSummary,
        sqliteWriteSeconds: MetricDistributionSummary,
        codexProcessCount: ResourceUsageSummary,
        maximumAudioQueueDepth: Int,
        maximumPendingEventCount: Int,
        counters: MeetingDiagnosticCounters,
        recentErrors: [String]
    ) {
        self.id = id
        self.meetingID = meetingID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.cpuPercent = cpuPercent
        self.memoryMegabytes = memoryMegabytes
        self.sttFinalLatencySeconds = sttFinalLatencySeconds
        self.sttToEventLatencySeconds = sttToEventLatencySeconds
        self.eventToFastCardLatencySeconds = eventToFastCardLatencySeconds
        self.deepAnalysisSeconds = deepAnalysisSeconds
        self.screenProcessingSeconds = screenProcessingSeconds
        self.sqliteWriteSeconds = sqliteWriteSeconds
        self.codexProcessCount = codexProcessCount
        self.maximumAudioQueueDepth = maximumAudioQueueDepth
        self.maximumPendingEventCount = maximumPendingEventCount
        self.counters = counters
        self.recentErrors = Array(recentErrors.suffix(20))
    }

    public var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }
}

public enum MeetingDiagnosticsMarkdownFormatter {
    public static func render(_ report: MeetingDiagnosticsReport) -> String {
        var lines = [
            "## 診断レポート",
            "",
            "- Meeting duration: \(duration(report.duration))",
            "- CPU peak: \(decimal(report.cpuPercent.max))%",
            "- Memory: start \(decimal(report.memoryMegabytes.start)) MB / end \(decimal(report.memoryMegabytes.end)) MB / peak \(decimal(report.memoryMegabytes.peak)) MB",
            "- Memory growth: \(signed(report.memoryMegabytes.end - report.memoryMegabytes.start)) MB (\(signed(memoryGrowthPerHour(report))) MB/hour)",
            "- Codex process peak: \(Int(report.codexProcessCount.peak.rounded()))",
            "- Max audio queue depth: \(report.maximumAudioQueueDepth)",
            "- Max pending events: \(report.maximumPendingEventCount)",
            "- Dropped audio buffers: \(report.counters.droppedAudioBuffers)",
            "- Dropped events: \(report.counters.droppedEvents)",
            "- Codex reconnects: \(report.counters.codexReconnects)",
            "- Transcription recoveries: \(report.counters.transcriptionRecoveries)",
            "- Errors: \(report.counters.errorCount)",
            ""
        ]
        append("STT final latency", report.sttFinalLatencySeconds, to: &lines)
        append("STT final → Event Detector", report.sttToEventLatencySeconds, to: &lines)
        append("Event → Fast card", report.eventToFastCardLatencySeconds, to: &lines)
        append("Deep Analysis", report.deepAnalysisSeconds, to: &lines)
        append("Screen processing", report.screenProcessingSeconds, to: &lines)
        append("SQLite write", report.sqliteWriteSeconds, to: &lines)

        if !report.recentErrors.isEmpty {
            lines.append("### Recent errors")
            lines.append("")
            report.recentErrors.forEach { lines.append("- \($0)") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func append(
        _ title: String,
        _ summary: MetricDistributionSummary,
        to lines: inout [String]
    ) {
        lines.append("### \(title)")
        lines.append("")
        lines.append("- samples: \(summary.count)")
        lines.append("- p50: \(decimal(summary.p50)) sec")
        lines.append("- p95: \(decimal(summary.p95)) sec")
        lines.append("- max: \(decimal(summary.max)) sec")
        lines.append("")
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func signed(_ value: Double) -> String {
        String(format: "%+.3f", value)
    }

    private static func memoryGrowthPerHour(
        _ report: MeetingDiagnosticsReport
    ) -> Double {
        guard report.duration > 0 else { return 0 }
        return (report.memoryMegabytes.end - report.memoryMegabytes.start) /
            report.duration * 3_600
    }

    private static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        return String(
            format: "%02d:%02d:%02d",
            total / 3_600,
            (total % 3_600) / 60,
            total % 60
        )
    }
}
