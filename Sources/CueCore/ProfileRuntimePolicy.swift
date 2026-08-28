import Foundation

public struct ProfileRuntimePolicy: Codable, Hashable, Sendable {
    public let profile: MeetingProfile
    public let roleDescription: String
    public let analysisFocus: [String]
    public let detectorKeywords: [String]
    public let customPrompt: String

    public init(project: ProjectConfiguration) {
        profile = project.profile
        customPrompt = project.profile == .custom
            ? project.customProfilePrompt.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            : ""

        switch project.profile {
        case .systemEngineer:
            roleDescription = "System Engineerとして、今この瞬間に聞く・言う・判断すべきことを支援する"
            analysisFocus = [
                "要件漏れ", "仕様変更", "技術リスク", "工数・納期",
                "矛盾", "ソースコードと既存資料"
            ]
            detectorKeywords = ["仕様", "要件", "権限", "データ", "工数", "納期"]
        case .sales:
            roleDescription = "Salesとして、顧客ニーズを理解し次の提案と確認を支援する"
            analysisFocus = [
                "顧客ニーズ", "提案ポイント", "質問", "クロージング", "宿題"
            ]
            detectorKeywords = ["課題", "予算", "導入", "提案", "決裁", "次回"]
        case .projectManager:
            roleDescription = "Project Managerとして、合意と実行可能性を支援する"
            analysisFocus = [
                "決定事項", "スケジュール", "リスク", "担当者", "未解決事項"
            ]
            detectorKeywords = ["決定", "期限", "担当", "リスク", "依存", "未決"]
        case .custom:
            roleDescription = customPrompt.isEmpty
                ? "ユーザー定義の会議支援役として、会議中の次の一手を支援する"
                : "ユーザー定義の会議支援役として行動する"
            analysisFocus = customPrompt.isEmpty
                ? ["重要な判断", "次に確認すべきこと"]
                : [customPrompt]
            detectorKeywords = []
        }
    }

    public var prompt: String {
        var sections = [
            "役割: \(roleDescription)",
            "重点: \(analysisFocus.joined(separator: "、"))"
        ]
        if !customPrompt.isEmpty {
            sections.append("Custom Profile Prompt:\n\(customPrompt)")
        }
        return sections.joined(separator: "\n")
    }
}

public struct PromptComposer: Sendable {
    public init() {}

    public func compose(
        base: String,
        project: ProjectConfiguration
    ) -> String {
        let profile = ProfileRuntimePolicy(project: project)
        let sections = [
            base,
            "Profile Prompt:\n\(profile.prompt)",
            nonEmptySection("Project Prompt", project.projectPrompt),
            nonEmptySection("Meeting Prompt", project.meetingPrompt)
        ].compactMap { $0 }
        return sections.joined(separator: "\n\n")
    }

    private func nonEmptySection(
        _ title: String,
        _ value: String
    ) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "\(title):\n\(trimmed)"
    }
}
