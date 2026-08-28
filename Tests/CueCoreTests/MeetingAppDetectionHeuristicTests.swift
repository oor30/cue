import CueCore
import Testing

@Suite("MeetingAppDetectionHeuristicTests")
struct MeetingAppDetectionHeuristicTests {
    @Test
    func detectsLargeZoomMeetingWindow() {
        #expect(
            MeetingAppDetectionHeuristic.isZoomMeetingWindow(
                ownerName: "zoom.us",
                windowTitle: "JAMD 定例ミーティング",
                layer: 0,
                width: 1_200,
                height: 760
            )
        )
    }

    @Test
    func excludesZoomHomeWindow() {
        #expect(
            !MeetingAppDetectionHeuristic.isZoomMeetingWindow(
                ownerName: "Zoom Workplace",
                windowTitle: "Zoom Workplace",
                layer: 0,
                width: 1_000,
                height: 700
            )
        )
    }

    @Test
    func excludesSmallOrNonZoomWindow() {
        #expect(
            !MeetingAppDetectionHeuristic.isZoomMeetingWindow(
                ownerName: "zoom.us",
                windowTitle: "Meeting",
                layer: 0,
                width: 300,
                height: 200
            )
        )
        #expect(
            !MeetingAppDetectionHeuristic.isZoomMeetingWindow(
                ownerName: "Safari",
                windowTitle: "Zoom Meeting",
                layer: 0,
                width: 1_200,
                height: 760
            )
        )
    }
}
