import Foundation

public struct RuleBasedEventDetector: Sendable {
    private let profileKeywords: [String]

    public init(profile: ProfileRuntimePolicy? = nil) {
        self.profileKeywords = profile?.detectorKeywords ?? []
    }

    public func detect(
        in segment: TranscriptSegment,
        state: MeetingState
    ) -> [DetectedEvent] {
        guard segment.isFinal else { return [] }

        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        var matches: [(MeetingEventType, String, Double)] = []

        if matchesQuestion(text) {
            matches.append((.question, "疑問・確認表現を検出", 0.88))
        }
        let isSpecificationChange = matchesSpecificationChange(
            text,
            state: state
        )
        if isSpecificationChange {
            matches.append((
                .specificationChange,
                "既存の決定・要望に対する明示的な変更表現を検出",
                0.9
            ))
        } else if matchesRequirement(text) {
            matches.append((.requirement, "新規要望を示す表現を検出", 0.84))
        }
        if matchesContradiction(text, state: state) {
            matches.append((
                .contradiction,
                "既存の決定・要望との不整合を示す表現を検出",
                0.88
            ))
        }
        if matchesDecision(text) {
            matches.append((.decision, "合意・決定を示す表現を検出", 0.9))
        }
        if matchesActionItem(text) {
            matches.append((.actionItem, "確認・送付・持ち帰りを示す表現を検出", 0.82))
        }
        if matchesRisk(text) {
            matches.append((.risk, "技術・納期・運用リスク表現を検出", 0.78))
        }
        if matchesImportantFact(text) || matchesProfileFocus(text) {
            matches.append((
                .importantFact,
                matchesProfileFocus(text)
                    ? "選択中Profileの重点キーワードを検出"
                    : "日付・金額・期限等の重要情報を検出",
                0.8
            ))
        }
        if matchesStalledDiscussion(text, state: state) {
            matches.append((
                .stalledDiscussion,
                "未解決事項の保留・持ち越し表現を検出",
                0.83
            ))
        }

        return matches.map { type, reason, score in
            DetectedEvent(
                meetingID: segment.meetingID,
                topicID: state.topic.id,
                topicRevision: state.topic.revision,
                type: type,
                sourceSegmentIDs: [segment.id],
                triggerReason: reason,
                excerpt: text,
                localScore: score
            )
        }
    }

    public func fingerprint(for event: DetectedEvent) -> String {
        let normalized = event.excerpt
            .lowercased()
            .replacingOccurrences(
                of: #"[\s\p{P}\p{S}]+"#,
                with: "",
                options: .regularExpression
            )
        return "\(event.type.rawValue):\(String(normalized.prefix(80)))"
    }

    private func matchesQuestion(_ text: String) -> Bool {
        text.contains("？") || text.contains("?") ||
            contains(text, pattern: #"(できますか|でしょうか|どうすれば|いつまで|いくら|どのように|何を|なぜ|ですか[。]?$|ますか[。]?$)"#)
    }

    private func matchesRequirement(_ text: String) -> Bool {
        contains(text, pattern: #"(できるようにしたい|ようにできますか|追加してほしい|対応してほしい|変更したい|ほしいです|要望|必要です)"#)
    }

    private func matchesSpecificationChange(
        _ text: String,
        state: MeetingState
    ) -> Bool {
        let hasExistingSpecification = !state.requirements.isEmpty ||
            !state.decisions.isEmpty
        guard hasExistingSpecification else { return false }
        if contains(
            text,
            pattern: #"(先ほど|さっき|前回|従来|当初|いままで|これまで).*(ではなく|から変更|を変更|取りやめ|撤回|修正)|やはり.*(変更|戻し|やめ)|仕様を変更|方針を変更|に変えたい|へ変えたい|変更することに"#
        ) {
            return true
        }
        return hasStructuredValueChange(text, state: state) && contains(
            text,
            pattern: #"(ではなく|にする|へ変更|に変更|にしたい|で進め|まで|以降|以上|以下|のみ|も含)"#
        )
    }

    private func matchesContradiction(
        _ text: String,
        state: MeetingState
    ) -> Bool {
        let hasComparableState = !state.requirements.isEmpty ||
            !state.decisions.isEmpty ||
            !state.importantFacts.isEmpty
        guard hasComparableState else { return false }
        if contains(
            text,
            pattern: #"(矛盾して|整合しな|食い違|話が違|前回と違|先ほどと違|どちらが正し|両立しな|つじつまが合わ)"#
        ) {
            return true
        }
        return hasStructuredValueChange(text, state: state) && contains(
            text,
            pattern: #"(違う|ではない|不可|できない|対象外|不要|禁止|のみ)"#
        )
    }

    private func matchesDecision(_ text: String) -> Bool {
        contains(text, pattern: #"(これで進め|この仕様で|決まり|決定|採用|合意|確定|そうしましょう)"#)
    }

    private func matchesActionItem(_ text: String) -> Bool {
        contains(text, pattern: #"(確認しておき|確認します|後で送|持ち帰|調べておき|対応します|宿題|TODO|やっておき)"#)
    }

    private func matchesRisk(_ text: String) -> Bool {
        contains(text, pattern: #"(難しい|遅延|間に合わ|セキュリティ|脆弱|データ移行|互換性|工数が増|コストが増|運用負荷|リスク)"#)
    }

    private func matchesImportantFact(_ text: String) -> Bool {
        contains(text, pattern: #"([0-9０-９]{1,4}[年/月日時分円万]|今週|来週|今月|来月|期限|締切|担当|までに|見積)"#)
    }

    private func matchesProfileFocus(_ text: String) -> Bool {
        profileKeywords.contains {
            text.localizedCaseInsensitiveContains($0)
        }
    }

    private func matchesStalledDiscussion(
        _ text: String,
        state: MeetingState
    ) -> Bool {
        guard !state.unresolvedIssues.isEmpty else { return false }
        return contains(
            text,
            pattern: #"(結論が出な|決めきれ|判断できな|いったん保留|一旦保留|次回に持ち越|次回まで保留|あとで決め|今回は決めない|持ち帰って再度)"#
        )
    }

    private func contains(_ text: String, pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private func hasStructuredValueChange(
        _ text: String,
        state: MeetingState
    ) -> Bool {
        let previous = state.decisions + state.requirements + state.importantFacts
        let currentValues = structuredValues(in: text)
        guard !currentValues.isEmpty else { return false }
        let currentTopics = topicTerms(in: text)

        return previous.contains { oldText in
            let oldValues = structuredValues(in: oldText)
            guard !oldValues.isEmpty,
                  oldValues != currentValues
            else { return false }
            let oldTopics = topicTerms(in: oldText)
            return !currentTopics.isDisjoint(with: oldTopics)
        }
    }

    private func structuredValues(in text: String) -> Set<String> {
        let pattern = #"[0-9０-９]+(?:[.,．][0-9０-９]+)?\s*(?:年|月|日|時|分|秒|円|万円|件|人|台|%|％|GB|MB|営業日|週間|か月|ヶ月)?"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return Set(expression.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        })
    }

    private func topicTerms(in text: String) -> Set<String> {
        let candidates = [
            "権限", "対象", "ユーザー", "管理者", "担当者", "CSV", "API",
            "画面", "データ", "保存", "公開", "期限", "納期", "費用", "工数",
            "件数", "人数", "環境", "本番", "テスト", "仕様", "運用"
        ]
        return Set(candidates.filter { text.localizedCaseInsensitiveContains($0) })
    }
}

public actor EventDetectionEngine {
    private let detector: RuleBasedEventDetector
    private let deduplicationInterval: TimeInterval
    private var lastSeenByFingerprint: [String: Date] = [:]
    private var topicRepetition: [UUID: (terms: Set<String>, count: Int, first: Date)] = [:]

    public init(
        detector: RuleBasedEventDetector = RuleBasedEventDetector(),
        deduplicationInterval: TimeInterval = 90
    ) {
        self.detector = detector
        self.deduplicationInterval = deduplicationInterval
    }

    public func process(
        segment: TranscriptSegment,
        state: MeetingState,
        now: Date = Date()
    ) -> [DetectedEvent] {
        var candidates = detector.detect(in: segment, state: state)
        if !candidates.contains(where: { $0.type == .stalledDiscussion }),
           let stalled = repetitionStall(
               segment: segment,
               state: state,
               now: now
           ) {
            candidates.append(stalled)
        }
        var accepted: [DetectedEvent] = []

        for var event in candidates {
            let fingerprint = detector.fingerprint(for: event)
            if let lastSeen = lastSeenByFingerprint[fingerprint] {
                let elapsed = now.timeIntervalSince(lastSeen)
                if elapsed < deduplicationInterval {
                    continue
                }
                event = DetectedEvent(
                    id: event.id,
                    meetingID: event.meetingID,
                    topicID: event.topicID,
                    topicRevision: event.topicRevision,
                    type: event.type,
                    sourceSegmentIDs: event.sourceSegmentIDs,
                    triggerReason: event.triggerReason,
                    excerpt: event.excerpt,
                    localScore: event.localScore,
                    noveltyScore: min(1, elapsed / (deduplicationInterval * 3)),
                    detectedAt: event.detectedAt,
                    state: event.state
                )
            }

            lastSeenByFingerprint[fingerprint] = now
            accepted.append(event)
        }

        purgeEntries(olderThan: now.addingTimeInterval(-deduplicationInterval * 10))
        return accepted
    }

    private func purgeEntries(olderThan cutoff: Date) {
        lastSeenByFingerprint = lastSeenByFingerprint.filter { $0.value >= cutoff }
    }

    private func repetitionStall(
        segment: TranscriptSegment,
        state: MeetingState,
        now: Date
    ) -> DetectedEvent? {
        guard !state.unresolvedIssues.isEmpty else { return nil }
        let terms = semanticTerms(segment.text)
        guard terms.count >= 2 else { return nil }

        if let previous = topicRepetition[state.topic.id],
           overlap(terms, previous.terms) >= 0.55 {
            let next = (
                terms: previous.terms.union(terms),
                count: previous.count + 1,
                first: previous.first
            )
            topicRepetition[state.topic.id] = next
            guard next.count >= 3,
                  now.timeIntervalSince(next.first) >= 45
            else { return nil }
            topicRepetition[state.topic.id] = (terms, 0, now)
            return DetectedEvent(
                meetingID: segment.meetingID,
                topicID: state.topic.id,
                topicRevision: state.topic.revision,
                type: .stalledDiscussion,
                sourceSegmentIDs: [segment.id],
                triggerReason: "同じ未解決論点が時間を空けて3回以上反復",
                excerpt: segment.text,
                localScore: 0.76
            )
        }
        topicRepetition[state.topic.id] = (terms, 1, now)
        return nil
    }

    private func semanticTerms(_ text: String) -> Set<String> {
        let parts = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        if parts.count >= 2 { return Set(parts) }

        let compact = text.replacingOccurrences(
            of: #"[\s\p{P}\p{S}]+"#,
            with: "",
            options: .regularExpression
        )
        guard compact.count >= 4 else { return [] }
        var bigrams: Set<String> = []
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(after: index)
            guard next < compact.endIndex else { break }
            let end = compact.index(after: next)
            bigrams.insert(String(compact[index..<end]))
            index = next
        }
        return bigrams
    }

    private func overlap(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) /
            Double(min(lhs.count, rhs.count))
    }
}
