import CryptoKit
import Foundation
import CueCore

enum DocumentUpdateError: LocalizedError, Sendable {
    case invalidUTF8
    case approvalMismatch
    case proposalNotAwaitingApproval
    case staleDocument
    case proposedHashMismatch
    case readbackMismatch

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            "対象文書はUTF-8ではないため更新できません。"
        case .approvalMismatch:
            "承認対象と変更案が一致しません。"
        case .proposalNotAwaitingApproval:
            "この変更案は承認待ちではありません。"
        case .staleDocument:
            "変更案の作成後に文書が更新されました。最新内容から変更案を作り直してください。"
        case .proposedHashMismatch:
            "変更案の内容が作成時から変化しています。"
        case .readbackMismatch:
            "更新後の読戻し検証に失敗しました。バックアップから復旧しました。"
        }
    }
}

/// 文書変更案の作成（読取り専用）と、明示承認後の適用を分離します。
actor DocumentUpdateCoordinator {
    func makeAppendProposal(
        review: MeetingReviewSnapshot,
        targetPath: String,
        policy: DocumentWritePolicy
    ) throws -> DocumentChangeProposal {
        let fileManager = FileManager.default
        let targetURL = try policy.validatedTargetURL(targetPath, fileManager: fileManager)
        let originalData: Data
        if fileManager.fileExists(atPath: targetURL.path) {
            originalData = try Data(contentsOf: targetURL, options: [.mappedIfSafe])
        } else {
            originalData = Data()
        }
        try policy.validateProposedSize(originalData.count)
        guard let original = String(data: originalData, encoding: .utf8) else {
            throw DocumentUpdateError.invalidUTF8
        }

        let reviewMarkdown = documentUpdateMarkdown(review)
        let separator = original.isEmpty || original.hasSuffix("\n\n")
            ? ""
            : (original.hasSuffix("\n") ? "\n" : "\n\n")
        let appendedBlock = "<!-- Cue: \(review.meetingID.uuidString) -->\n\(reviewMarkdown)\n"
        let proposedContent = original + separator + appendedBlock
        let proposedData = Data(proposedContent.utf8)
        try policy.validateProposedSize(proposedData.count)

        return DocumentChangeProposal(
            meetingID: review.meetingID,
            targetPath: targetURL.path,
            baseSHA256: sha256(originalData),
            proposedSHA256: sha256(proposedData),
            proposedContent: proposedContent,
            diffPreview: appendOnlyDiff(
                targetPath: targetURL.path,
                originalLineCount: original.split(separator: "\n", omittingEmptySubsequences: false).count,
                appendedBlock: separator + appendedBlock
            )
        )
    }

    /// このメソッドだけがファイルを書き換えます。呼出し側は承認UIから生成した approval を渡します。
    func applyApprovedProposal(
        _ proposal: DocumentChangeProposal,
        approval: DocumentChangeApproval,
        policy: DocumentWritePolicy
    ) throws -> DocumentUpdateReceipt {
        guard proposal.status == .awaitingApproval else {
            throw DocumentUpdateError.proposalNotAwaitingApproval
        }
        guard approval.proposalID == proposal.id else {
            throw DocumentUpdateError.approvalMismatch
        }

        let fileManager = FileManager.default
        let targetURL = try policy.validatedTargetURL(proposal.targetPath, fileManager: fileManager)
        let proposedData = Data(proposal.proposedContent.utf8)
        try policy.validateProposedSize(proposedData.count)
        guard sha256(proposedData) == proposal.proposedSHA256 else {
            throw DocumentUpdateError.proposedHashMismatch
        }

        let targetExisted = fileManager.fileExists(atPath: targetURL.path)
        let currentData = targetExisted
            ? try Data(contentsOf: targetURL, options: [.mappedIfSafe])
            : Data()
        guard sha256(currentData) == proposal.baseSHA256 else {
            throw DocumentUpdateError.staleDocument
        }

        let backupURL = try targetExisted
            ? makeBackup(of: targetURL, data: currentData, policy: policy, fileManager: fileManager)
            : nil

        do {
            try proposedData.write(to: targetURL, options: [.atomic])
            let readback = try Data(contentsOf: targetURL, options: [.mappedIfSafe])
            guard sha256(readback) == proposal.proposedSHA256 else {
                throw DocumentUpdateError.readbackMismatch
            }
        } catch {
            if let backupURL {
                let backupData = try? Data(contentsOf: backupURL)
                try? backupData?.write(to: targetURL, options: [.atomic])
            } else if fileManager.fileExists(atPath: targetURL.path) {
                try? fileManager.removeItem(at: targetURL)
            }
            throw error
        }

        return DocumentUpdateReceipt(
            proposalID: proposal.id,
            targetPath: targetURL.path,
            backupPath: backupURL?.path,
            previousSHA256: proposal.baseSHA256,
            appliedSHA256: proposal.proposedSHA256
        )
    }

    private func makeBackup(
        of targetURL: URL,
        data: Data,
        policy: DocumentWritePolicy,
        fileManager: FileManager
    ) throws -> URL {
        let root = URL(filePath: policy.rootPath).standardizedFileURL
        let backupDirectory = root.appending(path: ".cue-backups")
        if fileManager.fileExists(atPath: backupDirectory.path) {
            let values = try backupDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw DocumentWritePolicyError.symbolicLink(backupDirectory.path)
            }
        } else {
            try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: false)
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let shortHash = String(sha256(data).prefix(12))
        let backupName = "\(targetURL.lastPathComponent).\(timestamp).\(shortHash).bak"
        let backupURL = backupDirectory.appending(path: backupName)
        try data.write(to: backupURL, options: [.atomic, .withoutOverwriting])
        return backupURL
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func appendOnlyDiff(
        targetPath: String,
        originalLineCount: Int,
        appendedBlock: String
    ) -> String {
        let addedLines = appendedBlock.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "+\($0)" }
            .joined(separator: "\n")
        return [
            "--- \(targetPath)",
            "+++ \(targetPath) (提案)",
            "@@ -\(max(1, originalLineCount)),0 +\(originalLineCount + 1),\(appendedBlock.split(separator: "\n", omittingEmptySubsequences: false).count) @@",
            addedLines
        ].joined(separator: "\n")
    }

    private func documentUpdateMarkdown(
        _ review: MeetingReviewSnapshot
    ) -> String {
        var lines = [
            "## 会議決定の反映案（\(review.endedAt.formatted(date: .numeric, time: .omitted))）",
            "",
            "出典: \(review.title)",
            ""
        ]
        append("決定事項", values: review.decisions, to: &lines)
        append("仕様・要望", values: review.requirements, to: &lines)
        append("未回答・確認事項", values: review.questions, to: &lines)
        append("対応事項", values: review.actionItems, to: &lines)
        append("リスク", values: review.risks, to: &lines)
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func append(
        _ title: String,
        values: [String],
        to lines: inout [String]
    ) {
        guard !values.isEmpty else { return }
        lines.append("### \(title)")
        lines.append(contentsOf: values.map {
            "- " + $0.replacingOccurrences(of: "\n", with: " ")
        })
        lines.append("")
    }
}
