import CueCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var additionalReferencePaths = ""
    @State private var excludedPaths = ""
    @State private var priorityFiles = ""
    @State private var provider: AIProviderKind = .codex
    @State private var profile: MeetingProfile = .systemEngineer
    @State private var webSearchEnabled = false
    @State private var customProfilePrompt = ""
    @State private var projectPrompt = ""
    @State private var meetingPrompt = ""
    @State private var participantNames = ""
    @State private var backlogBaseURL = ""
    @State private var backlogProjectID = ""
    @State private var backlogIssueTypeID = ""
    @State private var backlogPriorityID = ""
    @State private var backlogAPIKey = ""

    var body: some View {
        Form {
            Section("権限") {
                LabeledContent("画面収録") {
                    Text(model.permissionSnapshot.screenCapture.rawValue)
                }
                LabeledContent("マイク") {
                    Text(model.permissionSnapshot.microphone.rawValue)
                }
                Button("権限を確認・要求") {
                    Task { await model.requestPermissions() }
                }
            }

            Section("保存") {
                Toggle("画面画像を保存", isOn: .constant(false))
                    .disabled(true)
                Toggle("生音声を保存", isOn: .constant(false))
                    .disabled(true)
                Text("MVPでは文字起こし・Meeting State・助言のみをローカル保存します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("音声入力") {
                AudioCaptureSelectionView(model: model)
                Text("音声ソースとマイクは次の会議開始時に適用されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Project検索") {
                if let project = model.selectedProject {
                    LabeledContent("Project Root", value: project.rootPath)
                    pathEditor(
                        "追加参照先",
                        text: $additionalReferencePaths,
                        prompt: "/path/to/reference（1行1件）"
                    )
                    pathEditor(
                        "除外パス",
                        text: $excludedPaths,
                        prompt: "build\nSecrets（1行1件）"
                    )
                    pathEditor(
                        "優先ファイル",
                        text: $priorityFiles,
                        prompt: "README.md\ndocs/spec.md（1行1件）"
                    )
                    HStack {
                        Spacer()
                        Button("検索設定を保存") {
                            Task {
                                await model.updateSelectedProjectSearchPolicy(
                                    additionalReferencePaths: lines(additionalReferencePaths),
                                    excludedPaths: lines(excludedPaths),
                                    priorityFiles: lines(priorityFiles)
                                )
                            }
                        }
                    }
                } else {
                    Text("メイン画面でProject Rootを登録してください。")
                        .foregroundStyle(.secondary)
                }
            }

            Section("AI") {
                Picker("Provider", selection: $provider) {
                    ForEach(AIProviderKind.allCases, id: \.rawValue) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                Picker("Profile", selection: $profile) {
                    ForEach(MeetingProfile.allCases, id: \.rawValue) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                if profile == .custom {
                    promptEditor(
                        "Custom Profile Prompt",
                        text: $customProfilePrompt,
                        prompt: "この会議支援役が重視する判断・質問・出力"
                    )
                }
                promptEditor(
                    "Project Prompt",
                    text: $projectPrompt,
                    prompt: "このProject固有の前提・用語・確認方針"
                )
                promptEditor(
                    "Meeting Prompt",
                    text: $meetingPrompt,
                    prompt: "次回会議だけで重視すること"
                )
                promptEditor(
                    "参加者ラベル",
                    text: $participantNames,
                    prompt: "田中さん\n佐藤さん（1行1名）"
                )
                LabeledContent("権限", value: "Read-Only")
                Toggle("Web自動検索を許可", isOn: $webSearchEnabled)
                    .disabled(provider == .claudeCode)
                Text(
                    provider == .claudeCode
                        ? "Claude Codeは安全なローカル読取り専用モードのため、Web検索を無効化します。Web検索を使う場合はCodexを選択してください。"
                        : webSearchEnabled
                        ? "会議内容から必要最小限の検索語を作り、外部Webへ送信します。URLと確認時刻を根拠に保存します。"
                        : "OFF時はProviderのWeb機能を無効化し、外部Webへ送信しません。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("AI設定を保存") {
                        Task {
                            await model.updateSelectedProjectAISettings(
                                provider: provider,
                                profile: profile,
                                webSearchEnabled: webSearchEnabled,
                                customProfilePrompt: customProfilePrompt,
                                projectPrompt: projectPrompt,
                                meetingPrompt: meetingPrompt,
                                participantNames: lines(participantNames)
                            )
                        }
                    }
                    .disabled(model.activeMeeting != nil)
                }
                LabeledContent("接続状態", value: model.codexStatus)
                if let executable = model.codexExecutableDescription {
                    LabeledContent("実行ファイル") {
                        Text(executable)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
                if let error = model.codexErrorDetail {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    if model.activeMeeting != nil {
                        Button("\(model.selectedProviderDisplayName)を再接続") {
                            Task { await model.reconnectCodex() }
                        }
                        .disabled(model.isCodexConnecting)
                    }
                }
                if model.activeMeeting == nil {
                    Button("\(model.selectedProviderDisplayName)接続をテスト") {
                        Task { await model.testCodexConnection() }
                    }
                    .disabled(model.selectedProject == nil || model.isCodexConnecting)
                }
            }

            Section("Backlog") {
                TextField("https://example.backlog.jp", text: $backlogBaseURL)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("projectId", text: $backlogProjectID)
                    TextField("issueTypeId", text: $backlogIssueTypeID)
                    TextField("priorityId", text: $backlogPriorityID)
                }
                .textFieldStyle(.roundedBorder)
                SecureField(
                    "APIキー（空欄なら既存Keychain値を維持）",
                    text: $backlogAPIKey
                )
                .textFieldStyle(.roundedBorder)
                Text("課題候補を表示し、内容確認と明示承認の後だけ登録します。APIキーはこのMacのKeychainに保存します。URLを空にして保存すると無効化します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Backlog設定を保存") {
                        Task {
                            await model.updateSelectedProjectBacklogSettings(
                                baseURL: backlogBaseURL,
                                projectID: Int(backlogProjectID),
                                issueTypeID: Int(backlogIssueTypeID),
                                priorityID: Int(backlogPriorityID),
                                apiKey: backlogAPIKey
                            )
                            backlogAPIKey = ""
                        }
                    }
                    .disabled(model.selectedProject == nil || model.activeMeeting != nil)
                }
            }

            Section("グローバルショートカット") {
                ForEach(GlobalHotKeyManager.Action.allCases, id: \.rawValue) { action in
                    Picker(
                        action.settingsTitle,
                        selection: Binding(
                            get: { model.shortcutChoice(for: action) },
                            set: { model.updateShortcut(action, choice: $0) }
                        )
                    ) {
                        ForEach(ShortcutModifierChoice.allCases) { choice in
                            Text(
                                choice == .disabled
                                    ? choice.title
                                    : "\(choice.title)（\(choice.displayPrefix)\(action.keyLabel)）"
                            )
                            .tag(choice)
                        }
                    }
                }
                LabeledContent("状態", value: model.shortcutStatus)
                Text("ショートカットはAccessibility権限を使わないCarbon Hot Keyで登録します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task(id: model.selectedProjectID) {
            loadProjectSearchSettings()
        }
        .onChange(of: provider) { _, value in
            if value == .claudeCode {
                webSearchEnabled = false
            }
        }
    }

    private func pathEditor(
        _ title: String,
        text: Binding<String>,
        prompt: String
    ) -> some View {
        LabeledContent(title) {
            TextField(prompt, text: text, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .frame(width: 310)
        }
    }

    private func promptEditor(
        _ title: String,
        text: Binding<String>,
        prompt: String
    ) -> some View {
        LabeledContent(title) {
            TextField(prompt, text: text, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .frame(width: 310)
        }
    }

    private func loadProjectSearchSettings() {
        guard let project = model.selectedProject else {
            additionalReferencePaths = ""
            excludedPaths = ""
            priorityFiles = ""
            provider = .codex
            profile = .systemEngineer
            webSearchEnabled = false
            customProfilePrompt = ""
            projectPrompt = ""
            meetingPrompt = ""
            participantNames = ""
            backlogBaseURL = ""
            backlogProjectID = ""
            backlogIssueTypeID = ""
            backlogPriorityID = ""
            backlogAPIKey = ""
            return
        }
        additionalReferencePaths = project.additionalReferencePaths.joined(separator: "\n")
        excludedPaths = project.excludedPaths.joined(separator: "\n")
        priorityFiles = project.priorityFiles.joined(separator: "\n")
        provider = project.provider
        profile = project.profile
        webSearchEnabled = project.webSearchEnabled
        customProfilePrompt = project.customProfilePrompt
        projectPrompt = project.projectPrompt
        meetingPrompt = project.meetingPrompt
        participantNames = project.participantNames.joined(separator: "\n")
        if let backlog = project.backlogConfiguration {
            backlogBaseURL = backlog.baseURL.absoluteString
            backlogProjectID = String(backlog.projectID)
            backlogIssueTypeID = String(backlog.issueTypeID)
            backlogPriorityID = String(backlog.priorityID)
        } else {
            backlogBaseURL = ""
            backlogProjectID = ""
            backlogIssueTypeID = ""
            backlogPriorityID = ""
        }
        backlogAPIKey = ""
    }

    private func lines(_ value: String) -> [String] {
        value.components(separatedBy: .newlines)
    }
}
