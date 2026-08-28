import CoreMedia
import Testing
@testable import CueApp

@Suite("AudioInputTimelineTests")
struct AudioInputTimelineTests {
    @Test
    func assignsContiguousMonotonicTimesWithoutCaptureTimestamps() {
        var timeline = AudioInputTimeline()

        let first = timeline.takeStart(frameLength: 480, sampleRate: 48_000)
        let second = timeline.takeStart(frameLength: 960, sampleRate: 48_000)
        let third = timeline.takeStart(frameLength: 441, sampleRate: 44_100)

        #expect(CMTimeGetSeconds(first) == 0)
        #expect(abs(CMTimeGetSeconds(second) - 0.01) < 0.000_001)
        #expect(abs(CMTimeGetSeconds(third) - 0.03) < 0.000_001)
        #expect(abs(CMTimeGetSeconds(timeline.current) - 0.04) < 0.000_001)
    }
}
