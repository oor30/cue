import Foundation
import Security

enum KeychainCredentialStoreError: LocalizedError, Sendable {
    case invalidCredential
    case unexpectedData
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            "資格情報が空です。"
        case .unexpectedData:
            "Keychain の資格情報を読み取れませんでした。"
        case .osStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                "Keychain エラー: \(message)（\(status)）"
            } else {
                "Keychain エラー（\(status)）"
            }
        }
    }
}

protocol CredentialReading: Sendable {
    func credential(account: String) throws -> String
}

/// Backlog API キーを SQLite や設定JSONに混入させないためのKeychainストアです。
/// 端末外へ同期されず、端末のロック解除中だけ参照できます。
struct KeychainCredentialStore: CredentialReading, Sendable {
    static let backlogService = "jp.cue.BacklogAPIKey"
    private static let legacyBacklogServices = [
        "jp.cue.MeetingCopilot.BacklogAPIKey"
    ]

    let service: String
    let legacyServices: [String]

    init(
        service: String = Self.backlogService,
        legacyServices: [String]? = nil
    ) {
        self.service = service
        self.legacyServices = legacyServices
            ?? (service == Self.backlogService ? Self.legacyBacklogServices : [])
    }

    func save(_ credential: String, account: String) throws {
        let normalized = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !account.isEmpty else {
            throw KeychainCredentialStoreError.invalidCredential
        }
        let data = Data(normalized.utf8)
        var query = baseQuery(account: account)

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainCredentialStoreError.osStatus(updateStatus)
        }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainCredentialStoreError.osStatus(addStatus)
        }
    }

    func credential(account: String) throws -> String {
        do {
            return try credential(account: account, service: service)
        } catch KeychainCredentialStoreError.osStatus(let status)
            where status == errSecItemNotFound {
            for legacyService in legacyServices {
                do {
                    let value = try credential(
                        account: account,
                        service: legacyService
                    )
                    try save(value, account: account)
                    return value
                } catch KeychainCredentialStoreError.osStatus(let legacyStatus)
                    where legacyStatus == errSecItemNotFound {
                    continue
                }
            }
            throw KeychainCredentialStoreError.osStatus(status)
        }
    }

    private func credential(
        account: String,
        service: String
    ) throws -> String {
        var query = baseQuery(account: account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw KeychainCredentialStoreError.osStatus(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else {
            throw KeychainCredentialStoreError.unexpectedData
        }
        return value
    }

    func delete(account: String) throws {
        for service in [service] + legacyServices {
            let status = SecItemDelete(
                baseQuery(account: account, service: service) as CFDictionary
            )
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainCredentialStoreError.osStatus(status)
            }
        }
    }

    private func baseQuery(
        account: String,
        service: String? = nil
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service ?? self.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }
}
