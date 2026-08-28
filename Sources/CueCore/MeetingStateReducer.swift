import Foundation

public struct MeetingStateReducer: Sendable {
    public init() {}

    public func reducing(
        _ state: MeetingState,
        with events: [DetectedEvent]
    ) -> MeetingState {
        guard !events.isEmpty else { return state }

        var updated = state
        for event in events {
            switch event.type {
            case .question:
                appendUnique(event.excerpt, to: &updated.questions)
                appendUnique(event.excerpt, to: &updated.unresolvedIssues)
            case .requirement, .specificationChange:
                appendUnique(event.excerpt, to: &updated.requirements)
            case .contradiction:
                appendUnique(event.excerpt, to: &updated.unresolvedIssues)
            case .decision:
                appendUnique(event.excerpt, to: &updated.decisions)
                updated.unresolvedIssues.removeAll { $0 == event.excerpt }
            case .actionItem:
                appendUnique(event.excerpt, to: &updated.actionItems)
            case .risk:
                appendUnique(event.excerpt, to: &updated.risks)
            case .importantFact:
                appendUnique(event.excerpt, to: &updated.importantFacts)
            case .stalledDiscussion:
                appendUnique(event.excerpt, to: &updated.unresolvedIssues)
            }
        }
        updated.revision += 1
        return updated
    }

    private func appendUnique(_ value: String, to values: inout [String]) {
        guard !values.contains(value) else { return }
        values.append(value)
    }
}
