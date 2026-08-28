import Foundation
import SQLite3

public enum RepositoryError: LocalizedError {
    case openDatabase(String)
    case execute(String)
    case prepare(String)
    case bind(String)
    case decode(String)

    public var errorDescription: String? {
        switch self {
        case .openDatabase(let message): "データベースを開けません: \(message)"
        case .execute(let message): "SQLの実行に失敗しました: \(message)"
        case .prepare(let message): "SQLの準備に失敗しました: \(message)"
        case .bind(let message): "SQLパラメータの設定に失敗しました: \(message)"
        case .decode(let message): "保存データを読み取れません: \(message)"
        }
    }
}

public actor SQLiteMeetingRepository {
    private let connection: SQLiteConnection
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var database: OpaquePointer { connection.pointer }

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw RepositoryError.openDatabase(message)
        }

        self.connection = SQLiteConnection(pointer: handle)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .secondsSince1970
        self.decoder.dateDecodingStrategy = .secondsSince1970

        try Self.execute("PRAGMA journal_mode = WAL;", on: handle)
        try Self.execute("PRAGMA foreign_keys = ON;", on: handle)
        try Self.migrate(handle)
    }

    public func saveProject(_ project: ProjectConfiguration) throws {
        let data = try encoder.encode(project)
        try execute(
            """
            INSERT INTO projects (id, name, root_path, payload, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                root_path = excluded.root_path,
                payload = excluded.payload,
                updated_at = excluded.updated_at;
            """,
            bindings: [
                project.id.uuidString,
                project.name,
                project.rootPath,
                String(decoding: data, as: UTF8.self),
                Self.timestamp(Date())
            ]
        )
    }

    public func listProjects() throws -> [ProjectConfiguration] {
        try query("SELECT payload FROM projects ORDER BY updated_at DESC;") { statement in
            guard let text = sqlite3_column_text(statement, 0) else {
                throw RepositoryError.decode("project payload is null")
            }
            return try decoder.decode(
                ProjectConfiguration.self,
                from: Data(String(cString: text).utf8)
            )
        }
    }

    public func createMeeting(_ meeting: MeetingRecord) throws {
        try execute(
            """
            INSERT INTO meetings
                (id, project_id, title, started_at, ended_at, status, codex_fast_thread_id)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                meeting.id.uuidString,
                meeting.projectID.uuidString,
                meeting.title,
                Self.timestamp(meeting.startedAt),
                meeting.endedAt.map(Self.timestamp),
                meeting.status.rawValue,
                meeting.codexFastThreadID
            ]
        )
    }

    public func updateMeeting(_ meeting: MeetingRecord) throws {
        try execute(
            """
            UPDATE meetings
            SET title = ?, ended_at = ?, status = ?, codex_fast_thread_id = ?
            WHERE id = ?;
            """,
            bindings: [
                meeting.title,
                meeting.endedAt.map(Self.timestamp),
                meeting.status.rawValue,
                meeting.codexFastThreadID,
                meeting.id.uuidString
            ]
        )
    }

    public func meeting(id: UUID) throws -> MeetingRecord? {
        try query(
            """
            SELECT project_id, title, started_at, ended_at, status, codex_fast_thread_id
            FROM meetings WHERE id = ? LIMIT 1;
            """,
            bindings: [id.uuidString]
        ) { statement in
            guard let projectText = sqlite3_column_text(statement, 0),
                  let projectID = UUID(uuidString: String(cString: projectText)),
                  let titleText = sqlite3_column_text(statement, 1),
                  let startedText = sqlite3_column_text(statement, 2),
                  let startedAt = Self.date(String(cString: startedText)),
                  let statusText = sqlite3_column_text(statement, 4),
                  let status = MeetingStatus(rawValue: String(cString: statusText))
            else { throw RepositoryError.decode("meeting row is invalid") }

            let endedAt = sqlite3_column_text(statement, 3).flatMap {
                Self.date(String(cString: $0))
            }
            let codexThreadID = sqlite3_column_text(statement, 5).map {
                String(cString: $0)
            }
            return MeetingRecord(
                id: id,
                projectID: projectID,
                title: String(cString: titleText),
                startedAt: startedAt,
                endedAt: endedAt,
                status: status,
                codexFastThreadID: codexThreadID
            )
        }.first
    }

    public func meetings(projectID: UUID? = nil) throws -> [MeetingRecord] {
        let sql: String
        let bindings: [SQLValue?]
        if let projectID {
            sql = "SELECT id FROM meetings WHERE project_id = ? ORDER BY started_at DESC;"
            bindings = [.text(projectID.uuidString)]
        } else {
            sql = "SELECT id FROM meetings ORDER BY started_at DESC;"
            bindings = []
        }
        let ids: [UUID] = try query(sql, bindings: bindings) { statement in
            guard let text = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: text))
            else { throw RepositoryError.decode("meeting id is invalid") }
            return id
        }
        var records: [MeetingRecord] = []
        for id in ids {
            if let record = try meeting(id: id) {
                records.append(record)
            }
        }
        return records
    }

    public func deleteMeeting(id: UUID) throws {
        try execute("DELETE FROM meetings WHERE id = ?;", bindings: [id.uuidString])
    }

    public func upsertTranscript(_ segment: TranscriptSegment) throws {
        let payload = try String(decoding: encoder.encode(segment), as: UTF8.self)
        try execute(
            """
            INSERT INTO transcript_segments
                (id, meeting_id, source, start_time, end_time, text, is_final, revision, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                end_time = excluded.end_time,
                text = excluded.text,
                is_final = excluded.is_final,
                revision = excluded.revision,
                payload = excluded.payload;
            """,
            bindings: [
                segment.id.uuidString,
                segment.meetingID.uuidString,
                segment.source.rawValue,
                segment.startTime,
                segment.endTime,
                segment.text,
                segment.isFinal ? 1 : 0,
                segment.revision,
                payload
            ]
        )
        try execute(
            "DELETE FROM transcript_fts WHERE segment_id = ?;",
            bindings: [segment.id.uuidString]
        )
        if segment.isFinal {
            try execute(
                "INSERT INTO transcript_fts (segment_id, meeting_id, text) VALUES (?, ?, ?);",
                bindings: [
                    segment.id.uuidString,
                    segment.meetingID.uuidString,
                    segment.text
                ]
            )
        }
    }

    public func saveState(_ state: MeetingState) throws {
        let payload = try String(decoding: encoder.encode(state), as: UTF8.self)
        try execute(
            """
            INSERT INTO meeting_state_snapshots
                (meeting_id, revision, topic_revision, payload, created_at)
            VALUES (?, ?, ?, ?, ?);
            """,
            bindings: [
                state.meetingID.uuidString,
                state.revision,
                state.topic.revision,
                payload,
                Self.timestamp(Date())
            ]
        )
    }

    public func saveScreenContextEvent(
        _ event: ScreenContextEvent,
        meetingID: UUID
    ) throws {
        let payload = try String(decoding: encoder.encode(event), as: UTF8.self)
        try execute(
            """
            INSERT OR REPLACE INTO screen_context_events
                (id, meeting_id, captured_at, presentation_time, payload)
            VALUES (?, ?, ?, ?, ?);
            """,
            bindings: [
                event.id.uuidString,
                meetingID.uuidString,
                Self.timestamp(event.capturedAt),
                event.presentationTime,
                payload
            ]
        )
    }

    public func screenContextEvent(id: UUID) throws -> ScreenContextEvent? {
        try query(
            "SELECT payload FROM screen_context_events WHERE id = ? LIMIT 1;",
            bindings: [id.uuidString]
        ) { statement in
            guard let text = sqlite3_column_text(statement, 0) else {
                throw RepositoryError.decode("screen context payload is null")
            }
            return try decoder.decode(
                ScreenContextEvent.self,
                from: Data(String(cString: text).utf8)
            )
        }.first
    }

    public func saveDocumentChangeProposal(
        _ proposal: DocumentChangeProposal
    ) throws {
        let payload = try String(decoding: encoder.encode(proposal), as: UTF8.self)
        try execute(
            """
            INSERT OR REPLACE INTO document_change_proposals
                (id, meeting_id, status, target_path, payload, updated_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                proposal.id.uuidString,
                proposal.meetingID.uuidString,
                proposal.status.rawValue,
                proposal.targetPath,
                payload,
                Self.timestamp(Date())
            ]
        )
    }

    public func documentChangeProposals(
        meetingID: UUID
    ) throws -> [DocumentChangeProposal] {
        try query(
            """
            SELECT payload FROM document_change_proposals
            WHERE meeting_id = ? ORDER BY updated_at DESC;
            """,
            bindings: [meetingID.uuidString]
        ) { statement in
            guard let text = sqlite3_column_text(statement, 0) else {
                throw RepositoryError.decode("document proposal payload is null")
            }
            return try decoder.decode(
                DocumentChangeProposal.self,
                from: Data(String(cString: text).utf8)
            )
        }
    }

    public func saveBacklogDraft(_ draft: BacklogIssueDraft) throws {
        let payload = try String(decoding: encoder.encode(draft), as: UTF8.self)
        try execute(
            """
            INSERT OR REPLACE INTO backlog_issue_drafts
                (id, meeting_id, status, content_hash, payload, updated_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                draft.id.uuidString,
                draft.meetingID.uuidString,
                draft.status.rawValue,
                draft.hash,
                payload,
                Self.timestamp(Date())
            ]
        )
    }

    public func backlogDrafts(meetingID: UUID) throws -> [BacklogIssueDraft] {
        try query(
            """
            SELECT payload FROM backlog_issue_drafts
            WHERE meeting_id = ? ORDER BY updated_at ASC;
            """,
            bindings: [meetingID.uuidString]
        ) { statement in
            guard let text = sqlite3_column_text(statement, 0) else {
                throw RepositoryError.decode("backlog draft payload is null")
            }
            return try decoder.decode(
                BacklogIssueDraft.self,
                from: Data(String(cString: text).utf8)
            )
        }
    }

    public func latestState(meetingID: UUID) throws -> MeetingState? {
        try query(
            """
            SELECT payload FROM meeting_state_snapshots
            WHERE meeting_id = ? ORDER BY id DESC LIMIT 1;
            """,
            bindings: [meetingID.uuidString]
        ) { statement in
            guard let text = sqlite3_column_text(statement, 0) else {
                throw RepositoryError.decode("meeting state payload is null")
            }
            return try decoder.decode(
                MeetingState.self,
                from: Data(String(cString: text).utf8)
            )
        }.first
    }

    public func saveEvent(_ event: DetectedEvent) throws {
        let payload = try String(decoding: encoder.encode(event), as: UTF8.self)
        try execute(
            """
            INSERT OR REPLACE INTO event_candidates
                (id, meeting_id, type, topic_revision, payload, detected_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                event.id.uuidString,
                event.meetingID.uuidString,
                event.type.rawValue,
                event.topicRevision,
                payload,
                Self.timestamp(event.detectedAt)
            ]
        )
    }

    public func events(meetingID: UUID) throws -> [DetectedEvent] {
        try query(
            """
            SELECT payload FROM event_candidates
            WHERE meeting_id = ? ORDER BY detected_at ASC;
            """,
            bindings: [meetingID.uuidString]
        ) { statement in
            guard let text = sqlite3_column_text(statement, 0) else {
                throw RepositoryError.decode("event payload is null")
            }
            return try decoder.decode(
                DetectedEvent.self,
                from: Data(String(cString: text).utf8)
            )
        }
    }

    public func saveCard(_ card: SuggestionCard) throws {
        let payload = try String(decoding: encoder.encode(card), as: UTF8.self)
        // FastからDeepへ昇格したカードは同じイベントの最新版として扱う。
        // UUIDが変わっても古いカードを残さないことで、再起動後の重複を防ぐ。
        try execute(
            "DELETE FROM suggestion_cards WHERE meeting_id = ? AND source_event_id = ? AND id <> ?;",
            bindings: [
                card.meetingID.uuidString,
                card.sourceEventID.uuidString,
                card.id.uuidString
            ]
        )
        try execute(
            """
            INSERT OR REPLACE INTO suggestion_cards
                (id, meeting_id, source_event_id, category, topic_revision, importance, confidence, payload, generated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                card.id.uuidString,
                card.meetingID.uuidString,
                card.sourceEventID.uuidString,
                card.category.rawValue,
                card.topicRevision,
                card.importance.rawValue,
                card.confidence,
                payload,
                Self.timestamp(card.generatedAt)
            ]
        )
    }

    public func cards(meetingID: UUID) throws -> [SuggestionCard] {
        try query(
            """
            SELECT payload FROM suggestion_cards
            WHERE meeting_id = ? ORDER BY generated_at ASC;
            """,
            bindings: [meetingID.uuidString]
        ) { statement in
            guard let text = sqlite3_column_text(statement, 0) else {
                throw RepositoryError.decode("card payload is null")
            }
            return try decoder.decode(
                SuggestionCard.self,
                from: Data(String(cString: text).utf8)
            )
        }
    }

    public func saveDiagnostics(_ report: MeetingDiagnosticsReport) throws {
        let payload = try String(decoding: encoder.encode(report), as: UTF8.self)
        try execute(
            """
            INSERT INTO meeting_diagnostics
                (meeting_id, payload, created_at)
            VALUES (?, ?, ?)
            ON CONFLICT(meeting_id) DO UPDATE SET
                payload = excluded.payload,
                created_at = excluded.created_at;
            """,
            bindings: [
                report.meetingID.uuidString,
                payload,
                Self.timestamp(Date())
            ]
        )
    }

    public func saveAnalysisRecord(_ record: AnalysisRecord) throws {
        let payload = try String(decoding: encoder.encode(record), as: UTF8.self)
        try execute(
            """
            INSERT INTO analysis_records
                (id, meeting_id, event_id, topic_id, context_revision, status, payload, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                status = excluded.status,
                payload = excluded.payload,
                updated_at = excluded.updated_at;
            """,
            bindings: [
                record.id.uuidString,
                record.meetingID.uuidString,
                record.eventID.uuidString,
                record.topicID.uuidString,
                record.contextRevision,
                record.status.rawValue,
                payload,
                Self.timestamp(Date())
            ]
        )
    }

    public func analysisRecords(meetingID: UUID) throws -> [AnalysisRecord] {
        try query(
            """
            SELECT payload FROM analysis_records
            WHERE meeting_id = ? ORDER BY updated_at ASC;
            """,
            bindings: [meetingID.uuidString]
        ) { statement in
            guard let text = sqlite3_column_text(statement, 0) else {
                throw RepositoryError.decode("analysis payload is null")
            }
            return try decoder.decode(
                AnalysisRecord.self,
                from: Data(String(cString: text).utf8)
            )
        }
    }

    public func diagnostics(
        meetingID: UUID
    ) throws -> MeetingDiagnosticsReport? {
        try query(
            "SELECT payload FROM meeting_diagnostics WHERE meeting_id = ? LIMIT 1;",
            bindings: [meetingID.uuidString]
        ) { statement in
            guard let text = sqlite3_column_text(statement, 0) else {
                throw RepositoryError.decode("diagnostics payload is null")
            }
            return try decoder.decode(
                MeetingDiagnosticsReport.self,
                from: Data(String(cString: text).utf8)
            )
        }.first
    }

    public func recentSegments(
        meetingID: UUID,
        limit: Int = 100
    ) throws -> [TranscriptSegment] {
        try query(
            """
            SELECT payload FROM transcript_segments
            WHERE meeting_id = ? AND is_final = 1
            ORDER BY start_time DESC LIMIT ?;
            """,
            bindings: [meetingID.uuidString, limit]
        ) { statement in
            guard let text = sqlite3_column_text(statement, 0) else {
                throw RepositoryError.decode("transcript payload is null")
            }
            return try decoder.decode(
                TranscriptSegment.self,
                from: Data(String(cString: text).utf8)
            )
        }.reversed()
    }

    public func transcriptSegment(id: UUID) throws -> TranscriptSegment? {
        try query(
            "SELECT payload FROM transcript_segments WHERE id = ? LIMIT 1;",
            bindings: [id.uuidString]
        ) { statement in
            guard let text = sqlite3_column_text(statement, 0) else {
                throw RepositoryError.decode("transcript payload is null")
            }
            return try decoder.decode(
                TranscriptSegment.self,
                from: Data(String(cString: text).utf8)
            )
        }.first
    }

    public func projectBrief(
        projectID: UUID,
        limit: Int = 5,
        meetingScanLimit: Int = 12
    ) throws -> [ProjectBriefItem] {
        guard limit > 0 else { return [] }
        let recentMeetings = try meetings(projectID: projectID)
            .filter { $0.endedAt != nil }
            .prefix(max(1, meetingScanLimit))

        var result: [ProjectBriefItem] = []
        var seen: Set<String> = []

        for meeting in recentMeetings {
            guard let state = try latestState(meetingID: meeting.id) else {
                continue
            }
            let meetingEvents = try events(meetingID: meeting.id)

            let groups: [(ProjectBriefItemKind, [String])] = [
                (.unresolvedIssue, state.unresolvedIssues.reversed()),
                (.actionItem, state.actionItems.reversed()),
                (.decision, state.decisions.reversed()),
                (.requirement, state.requirements.reversed()),
                (.risk, state.risks.reversed())
            ].map { kind, values in (kind, Array(values)) }

            for (kind, values) in groups {
                for text in values {
                    let normalized = text
                        .lowercased()
                        .replacingOccurrences(
                            of: #"[\s\p{P}\p{S}]+"#,
                            with: "",
                            options: .regularExpression
                        )
                    guard !normalized.isEmpty,
                          seen.insert("\(kind.rawValue):\(normalized)").inserted
                    else { continue }

                    let sourceSegmentID = meetingEvents.last(where: {
                        $0.excerpt == text
                    })?.sourceSegmentIDs.last
                    result.append(
                        ProjectBriefItem(
                            projectID: projectID,
                            meetingID: meeting.id,
                            meetingTitle: meeting.title,
                            meetingStartedAt: meeting.startedAt,
                            kind: kind,
                            text: text,
                            sourceSegmentID: sourceSegmentID
                        )
                    )
                    if result.count >= limit {
                        return result
                    }
                }
            }
        }
        return result
    }

    public func searchTranscripts(
        projectID: UUID,
        query rawQuery: String,
        limit: Int = 20
    ) throws -> [ProjectTranscriptSearchHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }
        let phrase = "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""

        let transform: (OpaquePointer) throws -> ProjectTranscriptSearchHit = {
            statement in
            guard let payloadText = sqlite3_column_text(statement, 0),
                  let meetingIDText = sqlite3_column_text(statement, 1),
                  let meetingID = UUID(uuidString: String(cString: meetingIDText)),
                  let titleText = sqlite3_column_text(statement, 2),
                  let startedText = sqlite3_column_text(statement, 3),
                  let meetingStartedAt = Self.date(String(cString: startedText))
            else { throw RepositoryError.decode("transcript search row is invalid") }

            let segment = try self.decoder.decode(
                TranscriptSegment.self,
                from: Data(String(cString: payloadText).utf8)
            )
            return ProjectTranscriptSearchHit(
                projectID: projectID,
                meetingID: meetingID,
                meetingTitle: String(cString: titleText),
                meetingStartedAt: meetingStartedAt,
                segment: segment
            )
        }

        var results = try self.query(
            """
            SELECT ts.payload, m.id, m.title, m.started_at
            FROM transcript_fts
            JOIN transcript_segments AS ts
                ON ts.id = transcript_fts.segment_id
            JOIN meetings AS m
                ON m.id = transcript_fts.meeting_id
            WHERE transcript_fts MATCH ? AND m.project_id = ?
            ORDER BY bm25(transcript_fts), m.started_at DESC
            LIMIT ?;
            """,
            bindings: [phrase, projectID.uuidString, limit],
            transform: transform
        )

        if results.count < limit {
            let escaped = query
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let fallback = try self.query(
                """
                SELECT ts.payload, m.id, m.title, m.started_at
                FROM transcript_segments AS ts
                JOIN meetings AS m ON m.id = ts.meeting_id
                WHERE m.project_id = ?
                    AND ts.is_final = 1
                    AND ts.text LIKE ? ESCAPE '\\'
                ORDER BY m.started_at DESC, ts.start_time DESC
                LIMIT ?;
                """,
                bindings: [projectID.uuidString, "%\(escaped)%", limit],
                transform: transform
            )
            var seenSegmentIDs = Set(results.map(\.segment.id))
            for hit in fallback where seenSegmentIDs.insert(hit.segment.id).inserted {
                results.append(hit)
                if results.count >= limit { break }
            }
        }
        return results
    }

    private static func migrate(_ database: OpaquePointer) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS projects (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                root_path TEXT NOT NULL,
                payload TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS meetings (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL REFERENCES projects(id),
                title TEXT NOT NULL,
                started_at TEXT NOT NULL,
                ended_at TEXT,
                status TEXT NOT NULL,
                codex_fast_thread_id TEXT
            );

            CREATE TABLE IF NOT EXISTS transcript_segments (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                source TEXT NOT NULL,
                start_time REAL NOT NULL,
                end_time REAL NOT NULL,
                text TEXT NOT NULL,
                is_final INTEGER NOT NULL,
                revision INTEGER NOT NULL,
                payload TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_transcript_meeting_time
                ON transcript_segments(meeting_id, start_time);

            CREATE TABLE IF NOT EXISTS meeting_state_snapshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                revision INTEGER NOT NULL,
                topic_revision INTEGER NOT NULL,
                payload TEXT NOT NULL,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS screen_context_events (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                captured_at TEXT NOT NULL,
                presentation_time REAL,
                payload TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_screen_context_meeting_time
                ON screen_context_events(meeting_id, captured_at);

            CREATE TABLE IF NOT EXISTS document_change_proposals (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                status TEXT NOT NULL,
                target_path TEXT NOT NULL,
                payload TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS backlog_issue_drafts (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                status TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                payload TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE UNIQUE INDEX IF NOT EXISTS idx_backlog_draft_hash
                ON backlog_issue_drafts(meeting_id, content_hash);

            CREATE TABLE IF NOT EXISTS event_candidates (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                type TEXT NOT NULL,
                topic_revision INTEGER NOT NULL,
                payload TEXT NOT NULL,
                detected_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS suggestion_cards (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                source_event_id TEXT NOT NULL,
                category TEXT NOT NULL,
                topic_revision INTEGER NOT NULL,
                importance INTEGER NOT NULL,
                confidence REAL NOT NULL,
                payload TEXT NOT NULL,
                generated_at TEXT NOT NULL
            );

            DELETE FROM suggestion_cards
            WHERE rowid NOT IN (
                SELECT MAX(rowid)
                FROM suggestion_cards
                GROUP BY meeting_id, source_event_id
            );

            CREATE UNIQUE INDEX IF NOT EXISTS idx_suggestion_event_unique
                ON suggestion_cards(meeting_id, source_event_id);

            CREATE TABLE IF NOT EXISTS meeting_diagnostics (
                meeting_id TEXT PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
                payload TEXT NOT NULL,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS analysis_records (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                event_id TEXT NOT NULL,
                topic_id TEXT NOT NULL,
                context_revision INTEGER NOT NULL,
                status TEXT NOT NULL,
                payload TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_analysis_meeting_status
                ON analysis_records(meeting_id, status);

            CREATE VIRTUAL TABLE IF NOT EXISTS transcript_fts USING fts5(
                segment_id UNINDEXED,
                meeting_id UNINDEXED,
                text,
                tokenize = 'unicode61'
            );

            CREATE TRIGGER IF NOT EXISTS transcript_segments_after_delete
            AFTER DELETE ON transcript_segments
            BEGIN
                DELETE FROM transcript_fts WHERE segment_id = OLD.id;
            END;
            """,
            on: database
        )
    }

    private func execute(_ sql: String, bindings: [SQLValue?] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw RepositoryError.prepare(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RepositoryError.execute(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func query<T>(
        _ sql: String,
        bindings: [SQLValue?] = [],
        transform: (OpaquePointer) throws -> T
    ) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw RepositoryError.prepare(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)
        var results: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            try results.append(transform(statement))
        }
        return results
    }

    private func bind(_ values: [SQLValue?], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .none:
                result = sqlite3_bind_null(statement, index)
            case .some(let value):
                result = value.bind(to: statement, at: index)
            }
            guard result == SQLITE_OK else {
                throw RepositoryError.bind(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw RepositoryError.execute(message)
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}

private enum SQLValue {
    case text(String)
    case integer(Int64)
    case real(Double)

    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        switch self {
        case .text(let value):
            sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        case .integer(let value):
            sqlite3_bind_int64(statement, index, value)
        case .real(let value):
            sqlite3_bind_double(statement, index, value)
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private extension Optional where Wrapped == SQLValue {
    static func from(_ value: String?) -> SQLValue? {
        value.map(SQLValue.text)
    }
}

private extension Array where Element == SQLValue? {
    init(_ values: [Any?]) {
        self = values.map { value in
            switch value {
            case let value as String: .text(value)
            case let value as Int: .integer(Int64(value))
            case let value as Int64: .integer(value)
            case let value as Double: .real(value)
            case nil: nil
            default: nil
            }
        }
    }
}

private extension SQLiteMeetingRepository {
    func execute(_ sql: String, bindings values: [Any?]) throws {
        try execute(sql, bindings: [SQLValue?](values))
    }

    func query<T>(
        _ sql: String,
        bindings values: [Any?],
        transform: (OpaquePointer) throws -> T
    ) throws -> [T] {
        try query(sql, bindings: [SQLValue?](values), transform: transform)
    }
}
