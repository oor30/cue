import Foundation
import SQLite3

enum CueDataMigration {
    static let supportDirectoryName = "Cue"
    static let databaseName = "cue.sqlite"

    private static let legacySupportDirectoryName = "MeetingCopilot"
    private static let legacyDatabaseName = "meeting-copilot.sqlite"
    private static let legacyBundleIdentifier = "jp.meetingcopilot.app"

    static func prepareSupportDirectory(
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil,
        migrateUserDefaults: Bool = true
    ) throws -> URL {
        let applicationSupport = try applicationSupportURL
            ?? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        let support = applicationSupport.appending(
            path: supportDirectoryName,
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: support,
            withIntermediateDirectories: true
        )

        let destination = support.appending(path: databaseName)
        let legacyDatabase = applicationSupport
            .appending(
                path: legacySupportDirectoryName,
                directoryHint: .isDirectory
            )
            .appending(path: legacyDatabaseName)
        if !fileManager.fileExists(atPath: destination.path),
           fileManager.fileExists(atPath: legacyDatabase.path) {
            try backupDatabase(
                from: legacyDatabase,
                to: destination,
                fileManager: fileManager
            )
        }

        if migrateUserDefaults {
            migrateUserDefaultsIfNeeded()
        }
        return support
    }

    private static func migrateUserDefaultsIfNeeded() {
        let storageKey = GlobalShortcutConfiguration.storageKey
        let current = UserDefaults.standard
        guard current.object(forKey: storageKey) == nil,
              let legacy = UserDefaults(suiteName: legacyBundleIdentifier),
              let data = legacy.data(forKey: storageKey)
        else { return }
        current.set(data, forKey: storageKey)
    }

    private static func backupDatabase(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appending(path: ".cue-migration-\(UUID().uuidString).sqlite")
        var sourceDatabase: OpaquePointer?
        var destinationDatabase: OpaquePointer?
        defer {
            if let sourceDatabase { sqlite3_close(sourceDatabase) }
            if let destinationDatabase { sqlite3_close(destinationDatabase) }
            try? fileManager.removeItem(at: temporaryURL)
        }

        guard sqlite3_open_v2(
            sourceURL.path,
            &sourceDatabase,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK,
              let sourceHandle = sourceDatabase
        else {
            throw migrationError(
                database: sourceDatabase,
                action: "旧データベースを開く"
            )
        }
        guard sqlite3_open_v2(
            temporaryURL.path,
            &destinationDatabase,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK,
              let destinationHandle = destinationDatabase
        else {
            throw migrationError(
                database: destinationDatabase,
                action: "移行先を作成する"
            )
        }
        guard let backup = sqlite3_backup_init(
            destinationHandle,
            "main",
            sourceHandle,
            "main"
        ) else {
            throw migrationError(
                database: destinationHandle,
                action: "データ移行を開始する"
            )
        }

        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw migrationError(
                database: destinationHandle,
                action: "データをコピーする"
            )
        }
        let closeResult = sqlite3_close(destinationHandle)
        destinationDatabase = nil
        guard closeResult == SQLITE_OK else {
            throw NSError(
                domain: "jp.cue.data-migration",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "移行先を確定する処理に失敗しました。"
                ]
            )
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }

    private static func migrationError(
        database: OpaquePointer?,
        action: String
    ) -> NSError {
        let detail = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "unknown"
        return NSError(
            domain: "jp.cue.data-migration",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "\(action)処理に失敗しました: \(detail)"
            ]
        )
    }
}
