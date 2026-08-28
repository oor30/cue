import Foundation
import Testing
@testable import CueCore

struct SQLiteMeetingRepositoryTests {
    @Test func persistsReplacesAndDeletesEncryptedVoiceprints() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CueVoiceprintTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try SQLiteMeetingRepository(
            databaseURL: directory.appending(path: "test.sqlite")
        )
        let participant = ParticipantProfile(
            displayName: "暗号化テスト",
            role: .internalMember
        )
        try await repository.saveParticipant(participant)
        let registeredAt = Date(timeIntervalSince1970: 1_000)
        let first = EncryptedVoiceprintRecord(
            participantID: participant.id,
            encryptedEmbedding: Data([1, 2, 3]),
            modelIdentifier: "test-model",
            sampleCount: 2,
            registeredAt: registeredAt,
            updatedAt: registeredAt
        )
        try await repository.saveVoiceprint(first)
        let stored = try await repository.voiceprints()
        #expect(stored.count == 1)
        #expect(stored.first?.participantID == participant.id)
        #expect(stored.first?.encryptedEmbedding == Data([1, 2, 3]))

        var replacement = first
        replacement.encryptedEmbedding = Data([4, 5, 6])
        replacement.updatedAt = Date(timeIntervalSince1970: 2_000)
        try await repository.saveVoiceprint(replacement)
        let replaced = try await repository.voiceprints()
        #expect(replaced.count == 1)
        #expect(replaced.first?.encryptedEmbedding == Data([4, 5, 6]))

        try await repository.deleteVoiceprint(participantID: participant.id)
        #expect(try await repository.voiceprints().isEmpty)
    }

    @Test func persistsReplacesAndCascadeDeletesSpeakerClusters() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CueSpeakerClusterTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try SQLiteMeetingRepository(
            databaseURL: directory.appending(path: "test.sqlite")
        )
        let project = ProjectConfiguration(name: "Diarization", rootPath: directory.path)
        try await repository.saveProject(project)
        let meeting = MeetingRecord(
            projectID: project.id,
            title: "Speaker Meeting",
            status: .reviewing
        )
        try await repository.createMeeting(meeting)
        let first = SpeakerClusterRecord(
            meetingID: meeting.id,
            clusterKey: "S1",
            displayLabel: "話者1",
            sourceSegmentIDs: [UUID()],
            speechDuration: 12,
            qualityScore: 0.8
        )
        let second = SpeakerClusterRecord(
            meetingID: meeting.id,
            clusterKey: "S2",
            displayLabel: "話者2",
            sourceSegmentIDs: [UUID(), UUID()],
            speechDuration: 8,
            qualityScore: 0.7
        )

        try await repository.replaceSpeakerClusters(
            meetingID: meeting.id,
            clusters: [first, second]
        )
        let stored = try await repository.speakerClusters(meetingID: meeting.id)
        #expect(stored.count == 2)
        #expect(stored.map(\.id) == [first.id, second.id])
        #expect(stored.map(\.sourceSegmentIDs) == [first.sourceSegmentIDs, second.sourceSegmentIDs])

        var renamed = first
        renamed.displayLabel = "田中さん"
        try await repository.replaceSpeakerClusters(
            meetingID: meeting.id,
            clusters: [renamed]
        )
        let replaced = try await repository.speakerClusters(meetingID: meeting.id)
        #expect(replaced.count == 1)
        #expect(replaced.first?.id == renamed.id)
        #expect(replaced.first?.displayLabel == "田中さん")

        try await repository.deleteMeeting(id: meeting.id)
        #expect(try await repository.speakerClusters(meetingID: meeting.id).isEmpty)
    }

    @Test func archivesAndRestoresProjectsAndMeetings() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CueArchiveTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try SQLiteMeetingRepository(
            databaseURL: directory.appending(path: "test.sqlite")
        )
        var project = ProjectConfiguration(name: "Archive", rootPath: directory.path)
        project.archivedAt = Date(timeIntervalSince1970: 900)
        try await repository.saveProject(project)
        #expect(try await repository.listProjects() == [project])

        project.archivedAt = nil
        try await repository.saveProject(project)
        let meeting = MeetingRecord(
            projectID: project.id,
            title: "Archive Meeting",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_100),
            status: .reviewing
        )
        try await repository.createMeeting(meeting)
        try await repository.upsertTranscript(
            TranscriptSegment(
                meetingID: meeting.id,
                source: .system,
                speaker: .other,
                startTime: 0,
                endTime: 1,
                text: "アーカイブ検索テスト",
                isFinal: true
            )
        )

        let archivedAt = Date(timeIntervalSince1970: 1_200)
        try await repository.setMeetingArchived(id: meeting.id, archivedAt: archivedAt)
        #expect(try await repository.meeting(id: meeting.id)?.archivedAt == archivedAt)
        #expect(
            try await repository.searchTranscripts(
                projectID: project.id,
                query: "アーカイブ検索テスト"
            ).isEmpty
        )

        try await repository.setMeetingArchived(id: meeting.id, archivedAt: nil)
        #expect(try await repository.meeting(id: meeting.id)?.archivedAt == nil)
        #expect(
            try await repository.searchTranscripts(
                projectID: project.id,
                query: "アーカイブ検索テスト"
            ).count == 1
        )
    }

    @Test func persistsProjectMeetingAndTranscript() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CueTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try SQLiteMeetingRepository(
            databaseURL: directory.appending(path: "test.sqlite")
        )
        let project = ProjectConfiguration(name: "Test", rootPath: directory.path)
        try await repository.saveProject(project)
        let participant = ParticipantProfile(
            displayName: "田中さん",
            role: .client,
            projectIDs: [project.id],
            createdAt: Date(timeIntervalSince1970: 990),
            updatedAt: Date(timeIntervalSince1970: 990)
        )
        try await repository.saveParticipant(participant)

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
            isFinal: true,
            speakerParticipantID: participant.id,
            speakerLabel: participant.displayName
        )
        try await repository.upsertTranscript(segment)
        let roster = [
            MeetingParticipantRecord(
                meetingID: meeting.id,
                participantID: participant.id,
                displayName: participant.displayName,
                role: participant.role,
                assignedAt: Date(timeIntervalSince1970: 1_005)
            )
        ]
        try await repository.replaceMeetingParticipants(
            meetingID: meeting.id,
            participants: roster
        )

        let summary = MeetingAISummary(
            meetingID: meeting.id,
            markdown: "## 概要\n仕様を確定した。",
            evidence: [
                EvidenceReference(
                    kind: .transcript,
                    label: "決定の発言",
                    location: segment.id.uuidString,
                    checkedAt: Date(timeIntervalSince1970: 1_025)
                )
            ],
            provider: .codex,
            generatedAt: Date(timeIntervalSince1970: 1_030)
        )
        try await repository.saveMeetingSummary(summary)

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
        let participants = try await repository.participants()
        let meetingParticipants = try await repository.meetingParticipants(
            meetingID: meeting.id
        )
        let segments = try await repository.recentSegments(meetingID: meeting.id)
        let storedDiagnostics = try await repository.diagnostics(meetingID: meeting.id)
        let analyses = try await repository.analysisRecords(meetingID: meeting.id)
        let pauseIntervals = try await repository.pauseIntervals(meetingID: meeting.id)
        let storedSummary = try await repository.meetingSummary(meetingID: meeting.id)

        #expect(projects == [project])
        #expect(participants == [participant])
        #expect(meetingParticipants == roster)
        #expect(segments.count == 1)
        #expect(segments.first?.id == segment.id)
        #expect(segments.first?.text == segment.text)
        #expect(segments.first?.isFinal == true)
        #expect(segments.first?.speakerParticipantID == participant.id)
        #expect(storedDiagnostics == diagnostics)
        #expect(analyses == [analysis])
        #expect(pauseIntervals == [pauseInterval])
        #expect(storedSummary == summary)
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
            try await repository.saveMeetingSummary(
                MeetingAISummary(
                    meetingID: meeting.id,
                    markdown: "## 概要\n長時間会議の要約",
                    evidence: [],
                    provider: .codex
                )
            )
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
        #expect(try await reopened.finalSegments(meetingID: meeting.id).count == 500)
        #expect(try await reopened.meetingSummary(meetingID: meeting.id) != nil)

        try await reopened.deleteMeeting(id: meeting.id)
        #expect(try await reopened.meeting(id: meeting.id) == nil)
        #expect(try await reopened.latestState(meetingID: meeting.id) == nil)
        #expect(try await reopened.events(meetingID: meeting.id).isEmpty)
        #expect(try await reopened.cards(meetingID: meeting.id).isEmpty)
        #expect(try await reopened.recentSegments(meetingID: meeting.id).isEmpty)
        #expect(try await reopened.finalSegments(meetingID: meeting.id).isEmpty)
        #expect(try await reopened.analysisRecords(meetingID: meeting.id).isEmpty)
        #expect(try await reopened.diagnostics(meetingID: meeting.id) == nil)
        #expect(try await reopened.pauseIntervals(meetingID: meeting.id).isEmpty)
        #expect(try await reopened.meetingSummary(meetingID: meeting.id) == nil)
    }
}
