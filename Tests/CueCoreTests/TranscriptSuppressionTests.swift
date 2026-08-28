import Foundation
import Testing
@testable import CueCore

@Suite("TranscriptEchoSuppressorTests")
struct TranscriptEchoSuppressorTests {
    @Test func suppressesOnlySimilarOverlappingMicrophoneText() {
        let meetingID = UUID()
        var suppressor = TranscriptEchoSuppressor()
        let system = TranscriptSegment(
            meetingID: meetingID,
            source: .system,
            speaker: .other,
            startTime: 10,
            endTime: 14,
            text: "公開予定日は来週金曜日です。",
            isFinal: true
        )
        let echoedMicrophone = TranscriptSegment(
            meetingID: meetingID,
            source: .microphone,
            speaker: .selfSpeaker,
            startTime: 10.2,
            endTime: 14.1,
            text: "公開予定日は来週金曜日です",
            isFinal: true
        )
        let differentMicrophone = TranscriptSegment(
            meetingID: meetingID,
            source: .microphone,
            speaker: .selfSpeaker,
            startTime: 10.3,
            endTime: 14.2,
            text: "担当者と完了条件も確認します。",
            isFinal: true
        )

        let suppressSystem = suppressor.shouldSuppress(system)
        let suppressEcho = suppressor.shouldSuppress(echoedMicrophone)
        let suppressDifferent = suppressor.shouldSuppress(differentMicrophone)
        #expect(!suppressSystem)
        #expect(suppressEcho)
        #expect(!suppressDifferent)
    }

    @Test func retainsSimilarMicrophoneTextOutsideTheTimeWindow() {
        let meetingID = UUID()
        var suppressor = TranscriptEchoSuppressor()
        let system = TranscriptSegment(
            meetingID: meetingID,
            source: .system,
            speaker: .other,
            startTime: 1,
            endTime: 3,
            text: "この方針で進めます。",
            isFinal: true
        )
        let laterMicrophone = TranscriptSegment(
            meetingID: meetingID,
            source: .microphone,
            speaker: .selfSpeaker,
            startTime: 20,
            endTime: 22,
            text: "この方針で進めます。",
            isFinal: true
        )

        let suppressSystem = suppressor.shouldSuppress(system)
        let suppressLater = suppressor.shouldSuppress(laterMicrophone)
        #expect(!suppressSystem)
        #expect(!suppressLater)
    }
}
