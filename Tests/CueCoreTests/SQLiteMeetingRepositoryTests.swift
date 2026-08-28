import Foundation
import Testing
@testable import CueCore

struct SQLiteMeetingRepositoryTests {
    @Test func persistsProjectMeetingAndTranscript() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CueTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try SQLiteMeetingRepository(
            databaseURL: directory.appending(path: "test.sqlite")
        )
        let project = ProjectConfiguration(name: "Test", rootPath: directory.path)
        try await repository.saveProject(project)

        let meeting = MeetingRecord(
            projectID: project.id,
            title: "Test Meeting",
            startedAt: Date(timeIntervalSince1970: 1_000),
            status: .active
        )
        try await repository.createMeeting(meeting)

        var pauseInterval = MeetingPauseInterval(
            meetingID: meeting.id,
            startedAt: Date(timeIntervalSince1970: 1_010)
        )
        try await repository.savePauseInterval(pauseInterval)
        #expect(try await repository.pauseIntervals(meetingID: meeting.id) == [pauseInterval])
        pauseInterval.endedAt = Date(timeIntervalSince1970: 1_020)
        try await repository.savePauseInterval(pauseInterval)

        let segment = TranscriptSegment(
            meetingID: meeting.id,
            source: .microphone,
            speaker: .selfSpeaker,
            startTime: 1,
            endTime: 2,
            text: "この仕様で進めます",
            isFinal: true
        )
        try await repository.upsertTranscript(segment)

        let diagnostics = MeetingDiagnosticsReport(
            meetingID: meeting.id,
            startedAt: meeting.startedAt,
            endedAt: meeting.startedAt.addingTimeInterval(120),
            cpuPercent: MetricDistributionSummary(samples: [10, 20]),
            memoryMegabytes: ResourceUsageSummary(samples: [100, 120]),
            sttFinalLatencySeconds: MetricDistributionSummary(samples: [0.4]),
            sttToEventLatencySeconds: MetricDistributionSummary(samples: [0.1]),
            eventToFastCardLatencySeconds: MetricDistributionSummary(samples: [1.2]),
            deepAnalysisSeconds: MetricDistributionSummary(samples: [8]),
            screenProcessingSeconds: MetricDistributionSummary(samples: [0.2]),
            sqliteWriteSeconds: MetricDistributionSummary(samples: [0.01]),
            codexProcessCount: ResourceUsageSummary(samples: [0, 1]),
            maximumAudioQueueDepth: 3,
            maximumPendingEventCount: 2,
            counters: MeetingDiagnosticCounters(),
            recentErrors: []
        )
        try await repository.saveDiagnostics(diagnostics)
        var analysis = AnalysisRecord(
            id: UUID(),
            meetingID: meeting.id,
            topicID: UUID(),
            eventID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_001),
            contextRevision: 1,
            mode: .deep,
            status: .running
        )
        try await repository.saveAnalysisRecord(analysis)
        analysis.status = .stale
        analysis.completedAt = Date(timeIntervalSince1970: 1_002)
        try await repository.saveAnalysisRecord(analysis)

        let projects = try await repository.listProjects()
        let segments = try await repository.recentSegments(meetingID: meeting.id)
        let storedDiagnostics = try await repository.diagnostics(meetingID: meeting.id)
        let analyses = try await repository.analysisRecords(meetingID: meeting.id)
        let pauseIntervals = try await repository.pauseIntervals(meetingID: meeting.id)

        #expect(projects == [project])
        #expect(segments.count == 1)
        #expect(segments.first?.id == segment.id)
        #expect(segments.first?.text == segment.text)
        #expect(segments.first?.isFinal == true)
        #expect(storedDiagnostics == diagnostics)
        #expect(analyses == [analysis])
        #expect(pauseIntervals == [pauseInterval])
    }

    @Test func reopensReadsBackAndCascadeDeletesLargeMeeting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CuePersistenceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appending(path: "test.sqlite")
        let project = ProjectConfiguration(name: "Persistence", rootPath: directory.path)
        var meeting = MeetingRecord(
            projectID: project.id,
            title: "Long Meeting",
            startedAt: Date(timeIntervalSince1970: 2_000),
            status: .active
        )
        var state = MeetingState(meetingID: meeting.id)
        state.topic = MeetingTopic(
            title: "永続化",
            startedAt: Date(timeIntervalSince1970: 2_000)
        )
        state.requirements = ["大量データでも復元できること"]
        state.revision = 1
        let event = DetectedEvent(
            meetingID: meeting.id,
            topicID: state.topic.id,
            topicRevision: state.topic.revision,
            type: .requirement,
            sourceSegmentIDs: [],
            triggerReason: "テスト",
            excerpt: "大量データでも復元できること",
            localScore: 1,
            detectedAt: Date(timeIntervalSince1970: 2_001)
        )
        let card = SuggestionCard(
            meetingID: meeting.id,
            sourceEventID: event.id,
            topicRevision: state.topic.revision,
            category: .question,
            title: "確認",
            body: "復元結果を確認してください。",
            importance: .high,
            confidence: 0.9,
            evidence: [],
            mode: .fast,
            generatedAt: Date(timeIntervalSince1970: 2_002)
        )

        do {
            let repository = try SQLiteMeetingRepository(databaseURL: databaseURL)
            try await repository.saveProject(project)
            try await repository.createMeeting(meeting)
            try await repository.saveState(state)
            try await repository.saveEvent(event)
            try await repository.saveCard(card)
            for index in 0..<500 {
                try await repository.upsertTranscript(
                    TranscriptSegment(
                        meetingID: meeting.id,
                        source: index.isMultiple(of: 2) ? .system : .microphone,
                        speaker: index.isMultiple(of: 2) ? .other : .selfSpeaker,
                        startTime: Double(index),
                        endTime: Double(index) + 0.8,
                        text: "発言 \(index)",
                        isFinal: true,
                        createdAt: Date(timeIntervalSince1970: 2_000 + Double(index))
                    )
                )
            }
            meeting.endedAt = Date(timeIntervalSince1970: 2_600)
            meeting.status = .reviewing
            try await repository.updateMeeting(meeting)
        }

        let reopened = try SQLiteMeetingRepository(databaseURL: databaseURL)
        #expect(try await reopened.meeting(id: meeting.id) == meeting)
        #expect(try await reopened.meetings(projectID: project.id) == [meeting])
        #expect(try await reopened.latestState(meetingID: meeting.id) == state)
        #expect(try await reopened.events(meetingID: meeting.id) == [event])
        #expect(try await reopened.cards(meetingID: meeting.id) == [card])
        #expect(try await reopened.recentSegments(meetingID: meeting.id, limit: 1_000).count == 500)

        try await reopened.deleteMeeting(id: meeting.id)
        #expect(try await reopened.meeting(id: meeting.id) == nil)
        #expect(try await reopened.latestState(meetingID: meeting.id) == nil)
        #expect(try await reopened.events(meetingID: meeting.id).isEmpty)
        #expect(try await reopened.cards(meetingID: meeting.id).isEmpty)
        #expect(try await reopened.recentSegments(meetingID: meeting.id).isEmpty)
        #expect(try await reopened.analysisRecords(meetingID: meeting.id).isEmpty)
        #expect(try await reopened.diagnostics(meetingID: meeting.id) == nil)
        #expect(try await reopened.pauseIntervals(meetingID: meeting.id).isEmpty)
    }
}
