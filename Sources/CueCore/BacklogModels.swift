import CryptoKit
import Foundation

public struct BacklogConfiguration: Codable, Hashable, Sendable {
    public let baseURL: URL
    public let projectID: Int
    public let issueTypeID: Int
    public let priorityID: Int
    public let credentialAccount: String

    public init(
        baseURL: URL,
        projectID: Int,
        issueTypeID: Int,
        priorityID: Int,
        credentialAccount: String
    ) {
        self.baseURL = baseURL
        self.projectID = projectID
        self.issueTypeID = issueTypeID
        self.priorityID = priorityID
        self.credentialAccount = credentialAccount
    }
}

public struct BacklogAssignee: Codable, Hashable, Sendable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

public enum BacklogIssueDraftStatus: String, Codable, Hashable, Sendable {
    case draft
    case awaitingApproval
    case approved
    case submitting
    case submitted
    case rejected
    case failed
}

public struct BacklogIssueDraft: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let title: String
    public let description: String
    public let background: String
    public let completionCriteria: [String]
    public let assignee: BacklogAssignee?
    public let deadline: Date?
    public let evidence: [EvidenceReference]
    public var status: BacklogIssueDraftStatus
    public let hash: String

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        title: String,
        description: String,
        background: String,
        completionCriteria: [String],
        assignee: BacklogAssignee? = nil,
        deadline: Date? = nil,
        evidence: [EvidenceReference],
        status: BacklogIssueDraftStatus = .draft,
        hash: String? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.title = title
        self.description = description
        self.background = background
        self.completionCriteria = completionCriteria
        self.assignee = assignee
        self.deadline = deadline
        self.evidence = evidence
        self.status = status
        self.hash = hash ?? Self.makeHash(
            meetingID: meetingID,
            title: title,
            description: description,
            background: background,
            completionCriteria: completionCriteria,
            assignee: assignee,
            deadline: deadline,
            evidence: evidence
        )
    }

    public var duplicateIdentifier: String {
        "cue:\(hash)"
    }

    /// Review の TODO 一件を Backlog 候補一件へ変換します。候補生成時点では外部通信しません。
    public static func candidates(from review: MeetingReviewSnapshot) -> [BacklogIssueDraft] {
        review.actionItems.enumerated().map { index, actionItem in
            let transcriptEvidence = EvidenceReference(
                kind: .transcript,
                label: "\(review.title) の会議レビュー（TODO \(index + 1)）",
                location: "meeting://\(review.meetingID.uuidString)",
                checkedAt: review.endedAt
            )
            let relatedRequirements = review.requirements.prefix(5).map { "- \($0)" }.joined(separator: "\n")
            let background = relatedRequirements.isEmpty
                ? "会議「\(review.title)」で合意されたTODOです。"
                : "会議「\(review.title)」で合意されたTODOです。\n\n関連要望:\n\(relatedRequirements)"
            return BacklogIssueDraft(
                meetingID: review.meetingID,
                title: normalizedTitle(actionItem),
                description: actionItem,
                background: background,
                completionCriteria: ["会議で合意した内容が完了していること", "関係者が結果を確認できること"],
                evidence: [transcriptEvidence],
                status: .awaitingApproval
            )
        }
    }

    private static func normalizedTitle(_ value: String) -> String {
        let title = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if title.count <= 100 { return title }
        return String(title.prefix(99)) + "…"
    }

    private static func makeHash(
        meetingID: UUID,
        title: String,
        description: String,
        background: String,
        completionCriteria: [String],
        assignee: BacklogAssignee?,
        deadline: Date?,
        evidence: [EvidenceReference]
    ) -> String {
        let evidenceSignature = evidence.map {
            [
                $0.kind.rawValue,
                $0.label,
                $0.location ?? "",
                $0.line.map(String.init) ?? ""
            ].joined(separator: ":")
        }.sorted().joined(separator: ",")
        let canonical = [
            meetingID.uuidString.lowercased(),
            title.trimmingCharacters(in: .whitespacesAndNewlines),
            description.trimmingCharacters(in: .whitespacesAndNewlines),
            background.trimmingCharacters(in: .whitespacesAndNewlines),
            completionCriteria.joined(separator: "\u{1F}"),
            assignee.map { "\($0.id):\($0.name)" } ?? "",
            deadline.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            evidenceSignature
        ].joined(separator: "\u{1E}")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
