import Foundation

public struct TranscriptSuppressionConfiguration: Hashable, Sendable {
    public var similarityThreshold: Double
    public var timeTolerance: TimeInterval
    public var retentionWindow: TimeInterval

    public init(
        similarityThreshold: Double = 0.88,
        timeTolerance: TimeInterval = 1.5,
        retentionWindow: TimeInterval = 12
    ) {
        self.similarityThreshold = similarityThreshold
        self.timeTolerance = timeTolerance
        self.retentionWindow = retentionWindow
    }
}

/// システム音声がマイクへ回り込んだ重複文字起こしを判定する純粋ロジックです。
/// マイク側だけを抑止し、システム音声や異なる発話は常に保持します。
public struct TranscriptEchoSuppressor: Sendable {
    private struct SystemUtterance: Sendable {
        let id: UUID
        let startTime: TimeInterval
        let endTime: TimeInterval
        let normalizedText: String
    }

    public let configuration: TranscriptSuppressionConfiguration
    private var systemUtterances: [SystemUtterance] = []

    public init(configuration: TranscriptSuppressionConfiguration = .init()) {
        self.configuration = configuration
    }

    /// `true` の場合だけ呼び出し側でセグメントを破棄します。
    public mutating func shouldSuppress(_ segment: TranscriptSegment) -> Bool {
        let normalized = Self.normalize(segment.text)
        guard normalized.count >= 4 else { return false }

        if segment.source == .system {
            systemUtterances.removeAll { $0.id == segment.id }
            systemUtterances.append(
                SystemUtterance(
                    id: segment.id,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    normalizedText: normalized
                )
            )
            trim(before: segment.endTime - configuration.retentionWindow)
            return false
        }

        trim(before: segment.startTime - configuration.retentionWindow)
        return systemUtterances.contains { system in
            Self.hasTemporalOverlap(
                lhsStart: segment.startTime,
                lhsEnd: segment.endTime,
                rhsStart: system.startTime,
                rhsEnd: system.endTime,
                tolerance: configuration.timeTolerance
            ) && Self.japaneseBigramSimilarity(
                normalized,
                system.normalizedText
            ) >= configuration.similarityThreshold
        }
    }

    public static func japaneseBigramSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = bigrams(normalize(lhs))
        let right = bigrams(normalize(rhs))
        guard !left.isEmpty, !right.isEmpty else {
            return lhs == rhs && !lhs.isEmpty ? 1 : 0
        }

        var remaining = right
        var intersection = 0
        for gram in left {
            if let index = remaining.firstIndex(of: gram) {
                intersection += 1
                remaining.remove(at: index)
            }
        }
        return (2 * Double(intersection)) / Double(left.count + right.count)
    }

    private mutating func trim(before cutoff: TimeInterval) {
        systemUtterances.removeAll { $0.endTime < cutoff }
    }

    private static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func bigrams(_ text: String) -> [String] {
        let characters = Array(text)
        guard characters.count >= 2 else { return [] }
        return (0..<(characters.count - 1)).map {
            String(characters[$0...($0 + 1)])
        }
    }

    private static func hasTemporalOverlap(
        lhsStart: TimeInterval,
        lhsEnd: TimeInterval,
        rhsStart: TimeInterval,
        rhsEnd: TimeInterval,
        tolerance: TimeInterval
    ) -> Bool {
        lhsStart <= rhsEnd + tolerance && rhsStart <= lhsEnd + tolerance
    }
}
