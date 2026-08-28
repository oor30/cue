import Foundation

public enum MeetingAppDetectionHeuristic {
    public static func isZoomMeetingWindow(
        ownerName: String,
        windowTitle: String,
        layer: Int,
        width: Double,
        height: Double
    ) -> Bool {
        let owner = ownerName.lowercased()
        guard owner == "zoom" || owner == "zoom.us" ||
                owner.contains("zoom workplace")
        else { return false }

        guard layer == 0, width >= 480, height >= 280 else { return false }

        let title = windowTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let excludedTitles = [
            "zoom", "zoom workplace", "zoom.us", "home", "settings", "preferences",
            "設定", "chat", "team chat", "contacts", "calendar", "whiteboard",
            "clips", "docs"
        ]
        return !title.isEmpty && !excludedTitles.contains(title)
    }
}
