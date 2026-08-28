import CueCore
import Foundation
import Testing

@testable import CueApp

@Suite("CueDataMigrationTests")
struct CueDataMigrationTests {
    @Test func migratesLegacyDatabaseIncludingWALContent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CueDataMigrationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyDirectory = root.appending(path: "MeetingCopilot")
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let legacyRepository = try SQLiteMeetingRepository(
            databaseURL: legacyDirectory.appending(path: "meeting-copilot.sqlite")
        )
        let project = ProjectConfiguration(
            name: "移行テスト",
            rootPath: "/tmp/cue-migration"
        )
        try await legacyRepository.saveProject(project)
        let meeting = MeetingRecord(
            projectID: project.id,
            title: "旧Cue会議",
            status: .active
        )
        try await legacyRepository.createMeeting(meeting)

        let support = try CueDataMigration.prepareSupportDirectory(
            applicationSupportURL: root,
            migrateUserDefaults: false
        )
        let migratedRepository = try SQLiteMeetingRepository(
            databaseURL: support.appending(path: CueDataMigration.databaseName)
        )

        #expect(try await migratedRepository.listProjects() == [project])
        let migratedMeeting = try await migratedRepository.meeting(id: meeting.id)
        #expect(migratedMeeting?.id == meeting.id)
        #expect(migratedMeeting?.projectID == project.id)
        #expect(migratedMeeting?.title == meeting.title)
        #expect(migratedMeeting?.status == .active)
    }
}
