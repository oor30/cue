import Foundation

public enum MeetingReviewMarkdownFormatter {
    public static func render(
        review: MeetingReviewSnapshot,
        cards: [SuggestionCard] = [],
        aiSummary: MeetingAISummary? = nil,
        meetingParticipants: [MeetingParticipantRecord] = [],
        diagnostics: MeetingDiagnosticsReport? = nil,
        backlogDrafts: [BacklogIssueDraft] = [],
        documentChangeProposals: [DocumentChangeProposal] = []
    ) -> String {
        var lines: [String] = [
            "# \(singleLine(review.title))",
            "",
            "- 開始: \(iso8601(review.startedAt))",
            "- 終了: \(iso8601(review.endedAt))",
            "- 所要時間: \(duration(review.endedAt.timeIntervalSince(review.startedAt)))",
            ""
        ]

        lines.append("## 参加者名簿")
        lines.append("")
        if meetingParticipants.isEmpty {
            lines.append("- 未登録")
        } else {
            for participant in meetingParticipants {
                lines.append(
                    "- \(singleLine(participant.displayName))（\(participant.role.displayName)）"
                )
            }
        }
        lines.append("")

        lines.append("## AI会議要約")
        lines.append("")
        if let aiSummary {
            lines.append(aiSummary.markdown)
            lines.append("")
            for evidence in aiSummary.evidence {
                let location = evidence.location.map { " — \($0)" } ?? ""
                lines.append("- 根拠: \(singleLine(evidence.label))\(location)")
            }
        } else {
            lines.append("- 未生成")
        }
        lines.append("")

        appendSection("決定事項", values: review.decisions, to: &lines)
        appendSection("TODO・宿題", values: review.actionItems, to: &lines)
        appendSection("クライアント要望", values: review.requirements, to: &lines)
        appendSection("未回答・確認事項", values: review.questions, to: &lines)
        appendSection("リスク", values: review.risks, to: &lines)

        lines.append("## 重要な助言")
        lines.append("")
        let importantCards = cards
            .filter { $0.isPinned || $0.importance >= .high }
            .sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return $0.generatedAt < $1.generatedAt
            }
        if importantCards.isEmpty {
            lines.append("- なし")
        } else {
            for card in importantCards {
                let pin = card.isPinned ? "📌 " : ""
                lines.append("- \(pin)**\(singleLine(card.title))**（確信度 \(Int(card.confidence * 100))%）")
                lines.append("  \(indented(card.body))")
                for evidence in card.evidence {
                    let location = evidence.location.map { " — \($0)" } ?? ""
                    let line = evidence.line.map { ":\($0)" } ?? ""
                    lines.append("  - 根拠: \(singleLine(evidence.label))\(location)\(line)")
                }
            }
        }
        lines.append("")

        lines.append("## 参照した根拠")
        lines.append("")
        let references = cards.flatMap(\.evidence).filter {
            $0.kind != .transcript
        }
        if references.isEmpty {
            lines.append("- なし")
        } else {
            var seen: Set<String> = []
            for evidence in references {
                let key = "\(evidence.kind.rawValue):\(evidence.location ?? evidence.label)"
                guard seen.insert(key).inserted else { continue }
                let location = evidence.location.map { " — \($0)" } ?? ""
                lines.append("- [\(evidence.kind.rawValue)] \(singleLine(evidence.label))\(location)")
            }
        }
        lines.append("")

        lines.append("## Backlog候補")
        lines.append("")
        if backlogDrafts.isEmpty {
            lines.append("- なし")
        } else {
            for draft in backlogDrafts {
                lines.append("- [\(draft.status.rawValue)] **\(singleLine(draft.title))**")
                lines.append("  \(singleLine(draft.description))")
            }
        }
        lines.append("")

        lines.append("## 資料差分案")
        lines.append("")
        if documentChangeProposals.isEmpty {
            lines.append("- なし")
        } else {
            for proposal in documentChangeProposals {
                lines.append("- [\(proposal.status.rawValue)] \(proposal.targetPath)")
            }
        }
        lines.append("")
        if let diagnostics {
            lines.append(MeetingDiagnosticsMarkdownFormatter.render(diagnostics))
            lines.append("")
        }

        lines.append("## 文字起こし")
        lines.append("")
        if review.finalTranscript.isEmpty {
            lines.append("- なし")
        } else {
            for segment in review.finalTranscript.sorted(by: { $0.startTime < $1.startTime }) {
                let speaker = segment.displaySpeakerName
                lines.append(
                    "- [\(timestamp(segment.startTime))] **\(speaker)**: \(singleLine(segment.text))"
                )
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func appendSection(
        _ title: String,
        values: [String],
        to lines: inout [String]
    ) {
        lines.append("## \(title)")
        lines.append("")
        if values.isEmpty {
            lines.append("- なし")
        } else {
            values.forEach { lines.append("- \(singleLine($0))") }
        }
        lines.append("")
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 { return "\(hours)時間\(minutes)分\(remainder)秒" }
        return "\(minutes)分\(remainder)秒"
    }

    private static func timestamp(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func indented(_ value: String) -> String {
        singleLine(value)
    }
}
