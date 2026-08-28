import Foundation

enum ManualAnalysisAction: String, CaseIterable, Identifiable, Sendable {
    case deepAnalyze
    case questionCandidates
    case answerCandidate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepAnalyze: "今の話を深掘り"
        case .questionCandidates: "質問候補"
        case .answerCandidate: "回答候補"
        }
    }

    var symbol: String {
        switch self {
        case .deepAnalyze: "sparkle.magnifyingglass"
        case .questionCandidates: "questionmark.bubble"
        case .answerCandidate: "text.bubble"
        }
    }

    var shortcutLabel: String {
        switch self {
        case .deepAnalyze: "⌥D"
        case .questionCandidates: "⌥Q"
        case .answerCandidate: "⌥A"
        }
    }
}
