import CryptoKit
import CueCore
import Foundation
import Security

enum VoiceprintVaultError: LocalizedError {
    case invalidEncryptionKey
    case invalidEncryptedPayload
    case invalidEmbedding

    var errorDescription: String? {
        switch self {
        case .invalidEncryptionKey:
            "声紋暗号化鍵を読み取れませんでした。"
        case .invalidEncryptedPayload:
            "暗号化された声紋を復号できませんでした。"
        case .invalidEmbedding:
            "声紋として登録できる話者特徴がありません。"
        }
    }
}

enum VoiceprintCipher {
    static func encrypt(
        _ embedding: [Float],
        key: SymmetricKey
    ) throws -> Data {
        guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else {
            throw VoiceprintVaultError.invalidEmbedding
        }
        let plaintext = try JSONEncoder().encode(embedding)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw VoiceprintVaultError.invalidEncryptedPayload
        }
        return combined
    }

    static func decrypt(
        _ encryptedEmbedding: Data,
        key: SymmetricKey
    ) throws -> [Float] {
        let sealed = try AES.GCM.SealedBox(combined: encryptedEmbedding)
        let plaintext = try AES.GCM.open(sealed, using: key)
        guard let embedding = try? JSONDecoder().decode([Float].self, from: plaintext),
              !embedding.isEmpty,
              embedding.allSatisfy(\.isFinite)
        else {
            throw VoiceprintVaultError.invalidEncryptedPayload
        }
        return embedding
    }
}

struct VoiceprintMatch: Equatable, Sendable {
    let participantID: UUID
    let similarity: Double
}

enum VoiceprintMatcher {
    static func candidate(
        for embedding: [Float],
        registeredEmbeddings: [UUID: [Float]],
        minimumSimilarity: Double = 0.82,
        minimumMargin: Double = 0.06
    ) -> VoiceprintMatch? {
        let ranked = registeredEmbeddings.compactMap { participantID, registered in
            cosineSimilarity(embedding, registered).map {
                VoiceprintMatch(participantID: participantID, similarity: $0)
            }
        }
        .sorted { $0.similarity > $1.similarity }
        guard let best = ranked.first,
              best.similarity >= minimumSimilarity
        else { return nil }
        if ranked.count > 1,
           best.similarity - ranked[1].similarity < minimumMargin {
            return nil
        }
        return best
    }

    static func cosineSimilarity(
        _ lhs: [Float],
        _ rhs: [Float]
    ) -> Double? {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return nil }
        var dot = 0.0
        var lhsNorm = 0.0
        var rhsNorm = 0.0
        for (left, right) in zip(lhs, rhs) {
            let left = Double(left)
            let right = Double(right)
            dot += left * right
            lhsNorm += left * left
            rhsNorm += right * right
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return nil }
        return dot / (sqrt(lhsNorm) * sqrt(rhsNorm))
    }
}

struct VoiceprintVault: Sendable {
    static let modelIdentifier = "fluidaudio-0.15.6-offline-wespeaker"
    private static let keyAccount = "local-device-key.v1"
    private let credentialStore = KeychainCredentialStore(
        service: "jp.cue.VoiceprintEncryptionKey",
        legacyServices: []
    )

    func encrypt(_ embedding: [Float]) throws -> Data {
        try VoiceprintCipher.encrypt(embedding, key: encryptionKey())
    }

    func decrypt(_ record: EncryptedVoiceprintRecord) throws -> [Float] {
        try VoiceprintCipher.decrypt(
            record.encryptedEmbedding,
            key: encryptionKey()
        )
    }

    private func encryptionKey() throws -> SymmetricKey {
        do {
            let encoded = try credentialStore.credential(account: Self.keyAccount)
            guard let data = Data(base64Encoded: encoded), data.count == 32 else {
                throw VoiceprintVaultError.invalidEncryptionKey
            }
            return SymmetricKey(data: data)
        } catch KeychainCredentialStoreError.osStatus(let status)
            where status == errSecItemNotFound {
            let key = SymmetricKey(size: .bits256)
            let data = key.withUnsafeBytes { Data($0) }
            try credentialStore.save(
                data.base64EncodedString(),
                account: Self.keyAccount
            )
            return key
        }
    }
}
