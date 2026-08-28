import Foundation

public enum DocumentWritePolicyError: LocalizedError, Sendable {
    case emptyRootPath
    case pathOutsideRoot
    case unsupportedExtension(String)
    case symbolicLink(String)
    case missingParentDirectory
    case targetIsNotRegularFile
    case fileTooLarge(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyRootPath:
            "書込み対象のプロジェクトルートが設定されていません。"
        case .pathOutsideRoot:
            "プロジェクトルート外への書込みは許可されていません。"
        case .unsupportedExtension(let value):
            "拡張子 .\(value) は文書更新の対象外です。"
        case .symbolicLink(let path):
            "シンボリックリンクを含むパスには書き込めません: \(path)"
        case .missingParentDirectory:
            "書込み先の親ディレクトリが存在しません。"
        case .targetIsNotRegularFile:
            "書込み先は通常ファイルではありません。"
        case .fileTooLarge(let limit):
            "文書サイズが上限（\(limit) bytes）を超えています。"
        }
    }
}

/// 会議レビューから文書を更新する場合だけに用いる厳格な書込みポリシーです。
/// 読取り用の `ProjectSearchPolicy` と権限を共有しません。
public struct DocumentWritePolicy: Codable, Hashable, Sendable {
    public let rootPath: String
    public let allowedExtensions: Set<String>
    public let maximumFileSizeBytes: Int

    public init(
        rootPath: String,
        allowedExtensions: Set<String> = ["md", "txt"],
        maximumFileSizeBytes: Int = 2 * 1_024 * 1_024
    ) {
        self.rootPath = rootPath
        self.allowedExtensions = Set(
            allowedExtensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        )
        self.maximumFileSizeBytes = max(1, maximumFileSizeBytes)
    }

    /// root 内の通常ファイル、または既存ディレクトリ直下の新規ファイルだけを許可します。
    /// symlink は root・中間ディレクトリ・対象ファイルのいずれにあっても拒否します。
    public func validatedTargetURL(
        _ path: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard !rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentWritePolicyError.emptyRootPath
        }

        let root = URL(filePath: rootPath).standardizedFileURL
        let candidate: URL
        if path.hasPrefix("/") {
            candidate = URL(filePath: path).standardizedFileURL
        } else {
            candidate = root.appending(path: path).standardizedFileURL
        }

        guard candidate.path != root.path,
              candidate.path.hasPrefix(root.path + "/")
        else {
            throw DocumentWritePolicyError.pathOutsideRoot
        }

        let fileExtension = candidate.pathExtension.lowercased()
        guard allowedExtensions.contains(fileExtension) else {
            throw DocumentWritePolicyError.unsupportedExtension(fileExtension)
        }

        try rejectSymbolicLinks(from: root, through: candidate, fileManager: fileManager)

        let parent = candidate.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw DocumentWritePolicyError.missingParentDirectory
        }

        if fileManager.fileExists(atPath: candidate.path) {
            let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw DocumentWritePolicyError.targetIsNotRegularFile
            }
            if let size = values.fileSize, size > maximumFileSizeBytes {
                throw DocumentWritePolicyError.fileTooLarge(limit: maximumFileSizeBytes)
            }
        }
        return candidate
    }

    public func validateProposedSize(_ byteCount: Int) throws {
        guard byteCount <= maximumFileSizeBytes else {
            throw DocumentWritePolicyError.fileTooLarge(limit: maximumFileSizeBytes)
        }
    }

    private func rejectSymbolicLinks(
        from root: URL,
        through candidate: URL,
        fileManager: FileManager
    ) throws {
        var paths: [URL] = [root]
        let relativePath = String(candidate.path.dropFirst(root.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var current = root
        for component in relativePath.split(separator: "/") {
            current.append(path: String(component))
            paths.append(current)
        }

        for url in paths where fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw DocumentWritePolicyError.symbolicLink(url.path)
            }
        }
    }
}

public enum DocumentChangeStatus: String, Codable, Hashable, Sendable {
    case awaitingApproval
    case approved
    case applied
    case rejected
    case stale
    case failed
}

/// 承認画面に出す不変の文書変更案です。削除・移動・名前変更は表現できません。
public struct DocumentChangeProposal: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let targetPath: String
    public let baseSHA256: String
    public let proposedSHA256: String
    public let proposedContent: String
    public let diffPreview: String
    public let createdAt: Date
    public var status: DocumentChangeStatus

    public init(
        id: UUID = UUID(),
        meetingID: UUID,
        targetPath: String,
        baseSHA256: String,
        proposedSHA256: String,
        proposedContent: String,
        diffPreview: String,
        createdAt: Date = Date(),
        status: DocumentChangeStatus = .awaitingApproval
    ) {
        self.id = id
        self.meetingID = meetingID
        self.targetPath = targetPath
        self.baseSHA256 = baseSHA256
        self.proposedSHA256 = proposedSHA256
        self.proposedContent = proposedContent
        self.diffPreview = diffPreview
        self.createdAt = createdAt
        self.status = status
    }
}

/// UI で変更案を表示し、利用者が明示的に承認した時だけ生成する値です。
public struct DocumentChangeApproval: Codable, Hashable, Sendable {
    public let proposalID: UUID
    public let approvedAt: Date

    public init(proposalID: UUID, approvedAt: Date = Date()) {
        self.proposalID = proposalID
        self.approvedAt = approvedAt
    }
}

public struct DocumentUpdateReceipt: Codable, Hashable, Sendable {
    public let proposalID: UUID
    public let targetPath: String
    public let backupPath: String?
    public let previousSHA256: String
    public let appliedSHA256: String
    public let appliedAt: Date

    public init(
        proposalID: UUID,
        targetPath: String,
        backupPath: String?,
        previousSHA256: String,
        appliedSHA256: String,
        appliedAt: Date = Date()
    ) {
        self.proposalID = proposalID
        self.targetPath = targetPath
        self.backupPath = backupPath
        self.previousSHA256 = previousSHA256
        self.appliedSHA256 = appliedSHA256
        self.appliedAt = appliedAt
    }
}
