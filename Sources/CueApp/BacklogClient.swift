import Foundation
import CueCore

struct BacklogIssueReceipt: Codable, Hashable, Sendable {
    let issueID: Int
    let issueKey: String
    let summary: String
    let duplicateIdentifier: String
    let wasAlreadyRegistered: Bool
}

enum BacklogClientError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case insecureEndpoint
    case localOrPrivateEndpoint
    case invalidCredential
    case invalidResponse
    case responseTooLarge
    case networkFailure
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason):
            "Backlog設定が不正です: \(reason)"
        case .insecureEndpoint:
            "Backlog APIにはHTTPSでのみ接続できます。"
        case .localOrPrivateEndpoint:
            "ローカルまたはプライベートネットワークのURLには接続できません。"
        case .invalidCredential:
            "Backlog APIキーが設定されていません。"
        case .invalidResponse:
            "Backlog APIから不正なレスポンスを受信しました。"
        case .responseTooLarge:
            "Backlog APIのレスポンスが上限を超えました。"
        case .networkFailure:
            "Backlog APIへの接続に失敗しました。"
        case .httpStatus(let status, let detail):
            "Backlog APIエラー（HTTP \(status)）: \(detail)"
        }
    }
}

/// 呼出し側が承認済みDraftだけを渡す想定の、狭いBacklog登録クライアントです。
/// APIキーは毎回Keychainから取り出し、この型やSQLiteには保持しません。
actor BacklogClient {
    private let credentials: any CredentialReading
    private let session: URLSession
    private let maximumResponseBytes: Int

    init(
        credentials: any CredentialReading = KeychainCredentialStore(),
        timeout: TimeInterval = 20,
        maximumResponseBytes: Int = 512 * 1_024
    ) {
        self.credentials = credentials
        self.maximumResponseBytes = max(1_024, maximumResponseBytes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = max(1, timeout)
        configuration.timeoutIntervalForResource = max(1, timeout)
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: configuration)
    }

    func createIssue(
        from draft: BacklogIssueDraft,
        configuration: BacklogConfiguration
    ) async throws -> BacklogIssueReceipt {
        guard draft.status == .approved else {
            throw BacklogClientError.invalidConfiguration("承認済みの課題候補ではありません")
        }
        try validate(configuration)
        let apiKey = try credentials.credential(account: configuration.credentialAccount)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw BacklogClientError.invalidCredential }

        if let existing = try await findDuplicate(
            identifier: draft.duplicateIdentifier,
            apiKey: apiKey,
            configuration: configuration
        ) {
            return BacklogIssueReceipt(
                issueID: existing.id,
                issueKey: existing.issueKey,
                summary: existing.summary,
                duplicateIdentifier: draft.duplicateIdentifier,
                wasAlreadyRegistered: true
            )
        }

        let url = try endpoint(
            path: "/api/v2/issues",
            queryItems: [URLQueryItem(name: "apiKey", value: apiKey)],
            configuration: configuration
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formBody(draft: draft, configuration: configuration)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // URL（query内のAPIキーを含む可能性がある）を上位層へ露出しません。
            throw BacklogClientError.networkFailure
        }
        let http = try validatedHTTPResponse(response, data: data, allowedStatus: 201)
        let issue = try decodeIssue(data, response: http)
        return BacklogIssueReceipt(
            issueID: issue.id,
            issueKey: issue.issueKey,
            summary: issue.summary,
            duplicateIdentifier: draft.duplicateIdentifier,
            wasAlreadyRegistered: false
        )
    }

    private func findDuplicate(
        identifier: String,
        apiKey: String,
        configuration: BacklogConfiguration
    ) async throws -> BacklogIssueResponse? {
        let url = try endpoint(
            path: "/api/v2/issues",
            queryItems: [
                URLQueryItem(name: "apiKey", value: apiKey),
                URLQueryItem(name: "projectId[]", value: String(configuration.projectID)),
                URLQueryItem(name: "keyword", value: identifier),
                URLQueryItem(name: "count", value: "10")
            ],
            configuration: configuration
        )
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BacklogClientError.networkFailure
        }
        _ = try validatedHTTPResponse(response, data: data, allowedStatus: 200)
        let issues: [BacklogIssueResponse]
        do {
            issues = try JSONDecoder().decode([BacklogIssueResponse].self, from: data)
        } catch {
            throw BacklogClientError.invalidResponse
        }
        return issues.first { $0.description?.contains(identifier) == true }
    }

    private func validate(_ configuration: BacklogConfiguration) throws {
        guard configuration.projectID > 0,
              configuration.issueTypeID > 0,
              configuration.priorityID > 0,
              !configuration.credentialAccount.isEmpty
        else {
            throw BacklogClientError.invalidConfiguration("projectId、issueTypeId、priorityId、資格情報名は必須です")
        }
        guard configuration.baseURL.scheme?.lowercased() == "https" else {
            throw BacklogClientError.insecureEndpoint
        }
        guard configuration.baseURL.user == nil,
              configuration.baseURL.password == nil,
              configuration.baseURL.query == nil,
              configuration.baseURL.fragment == nil,
              configuration.baseURL.path.isEmpty || configuration.baseURL.path == "/",
              let host = configuration.baseURL.host,
              !host.isEmpty
        else {
            throw BacklogClientError.invalidConfiguration("ベースURLにはホスト名だけを指定してください")
        }
        guard !isLocalOrPrivate(host: host) else {
            throw BacklogClientError.localOrPrivateEndpoint
        }
    }

    private func endpoint(
        path: String,
        queryItems: [URLQueryItem],
        configuration: BacklogConfiguration
    ) throws -> URL {
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw BacklogClientError.invalidConfiguration("API URLを構築できません")
        }
        return url
    }

    private func formBody(
        draft: BacklogIssueDraft,
        configuration: BacklogConfiguration
    ) -> Data {
        let completion = draft.completionCriteria.map { "- \($0)" }.joined(separator: "\n")
        let evidence = draft.evidence.map { reference in
            let location = reference.location.map { "（\($0)）" } ?? ""
            return "- \(reference.label)\(location)"
        }.joined(separator: "\n")
        let description = [
            draft.description,
            "## 背景\n\(draft.background)",
            "## 完了条件\n\(completion.isEmpty ? "- 未設定" : completion)",
            "## 根拠\n\(evidence.isEmpty ? "- 未設定" : evidence)",
            "<!-- \(draft.duplicateIdentifier) -->"
        ].joined(separator: "\n\n")

        var fields: [(String, String)] = [
            ("projectId", String(configuration.projectID)),
            ("summary", draft.title),
            ("description", description),
            ("issueTypeId", String(configuration.issueTypeID)),
            ("priorityId", String(configuration.priorityID))
        ]
        if let assignee = draft.assignee {
            fields.append(("assigneeId", String(assignee.id)))
        }
        if let deadline = draft.deadline {
            fields.append(("dueDate", Self.backlogDateFormatter.string(from: deadline)))
        }
        let body = fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
        return Data(body.utf8)
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    @discardableResult
    private func validatedHTTPResponse(
        _ response: URLResponse,
        data: Data,
        allowedStatus: Int
    ) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw BacklogClientError.invalidResponse
        }
        guard data.count <= maximumResponseBytes,
              http.expectedContentLength <= Int64(maximumResponseBytes) || http.expectedContentLength < 0
        else {
            throw BacklogClientError.responseTooLarge
        }
        guard http.statusCode == allowedStatus else {
            let detail = Self.safeErrorDetail(data)
            throw BacklogClientError.httpStatus(http.statusCode, detail)
        }
        return http
    }

    private func decodeIssue(_ data: Data, response: HTTPURLResponse) throws -> BacklogIssueResponse {
        do {
            return try JSONDecoder().decode(BacklogIssueResponse.self, from: data)
        } catch {
            throw BacklogClientError.invalidResponse
        }
    }

    private func isLocalOrPrivate(host: String) -> Bool {
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if value == "localhost" || value.hasSuffix(".localhost") || value.hasSuffix(".local") {
            return true
        }
        if !value.contains(".") && !value.contains(":") { return true }
        if value == "::" || value == "::1" || value.hasPrefix("fe8") || value.hasPrefix("fe9") ||
            value.hasPrefix("fea") || value.hasPrefix("feb") || value.hasPrefix("fc") ||
            value.hasPrefix("fd") || value.hasPrefix("::ffff:") {
            return true
        }
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0 ... 255).contains($0) }) else {
            return false
        }
        let first = parts[0]
        let second = parts[1]
        return first == 0 || first == 10 || first == 127 ||
            (first == 100 && (64 ... 127).contains(second)) ||
            (first == 169 && second == 254) ||
            (first == 172 && (16 ... 31).contains(second)) ||
            (first == 192 && second == 168) ||
            (first == 198 && (18 ... 19).contains(second)) ||
            first >= 224
    }

    private static let backlogDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func safeErrorDetail(_ data: Data) -> String {
        let text = String(data: data.prefix(2_048), encoding: .utf8) ?? "レスポンス本文を読み取れません"
        return text.replacingOccurrences(of: "\n", with: " ")
    }
}

private struct BacklogIssueResponse: Decodable {
    let id: Int
    let issueKey: String
    let summary: String
    let description: String?
}
