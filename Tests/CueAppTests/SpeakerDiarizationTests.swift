import CueCore
import CryptoKit
import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import CueApp

@Suite("SpeakerDiarizationTests")
struct SpeakerDiarizationTests {
    @Test func mapsSystemTranscriptToTheLargestOverlappingSpeakerInterval() {
        let meetingID = UUID()
        let first = TranscriptSegment(
            meetingID: meetingID,
            source: .system,
            speaker: .other,
            startTime: 0,
            endTime: 1.5,
            text: "最初の発言",
            isFinal: true
        )
        let second = TranscriptSegment(
            meetingID: meetingID,
            source: .system,
            speaker: .other,
            startTime: 2,
            endTime: 4,
            text: "次の発言",
            isFinal: true
        )
        let microphone = TranscriptSegment(
            meetingID: meetingID,
            source: .microphone,
            speaker: .selfSpeaker,
            startTime: 0,
            endTime: 4,
            text: "自分の発言",
            isFinal: true
        )
        let mapped = SpeakerDiarizationMapper.map(
            meetingID: meetingID,
            transcript: [first, second, microphone],
            intervals: [
                DiarizedSpeechInterval(
                    clusterKey: "S1",
                    startTime: 0,
                    endTime: 1.4,
                    qualityScore: 0.8
                ),
                DiarizedSpeechInterval(
                    clusterKey: "S2",
                    startTime: 1.4,
                    endTime: 4,
                    qualityScore: 0.6
                )
            ]
        )

        #expect(mapped.clusters.count == 2)
        #expect(mapped.clusters[0].displayLabel == "話者1")
        #expect(mapped.clusters[0].sourceSegmentIDs == [first.id])
        #expect(mapped.clusters[1].sourceSegmentIDs == [second.id])
        #expect(mapped.transcript[0].speakerClusterID == "S1")
        #expect(mapped.transcript[0].speakerLabel == "話者1")
        #expect(mapped.transcript[1].speakerClusterID == "S2")
        #expect(mapped.transcript[1].speakerLabel == "話者2")
        #expect(mapped.transcript[2].speakerClusterID == nil)
        #expect(mapped.transcript[2].speakerLabel == nil)
    }

    @Test func preservesAnExistingParticipantAssignmentWhileAddingTheCluster() {
        let meetingID = UUID()
        let participantID = UUID()
        let segment = TranscriptSegment(
            meetingID: meetingID,
            source: .system,
            speaker: .other,
            startTime: 0,
            endTime: 2,
            text: "割り当て済み",
            isFinal: true,
            speakerParticipantID: participantID,
            speakerLabel: "佐藤さん"
        )
        let mapped = SpeakerDiarizationMapper.map(
            meetingID: meetingID,
            transcript: [segment],
            intervals: [
                DiarizedSpeechInterval(
                    clusterKey: "S1",
                    startTime: 0,
                    endTime: 2,
                    qualityScore: 0.9
                )
            ]
        )

        #expect(mapped.transcript[0].speakerClusterID == "S1")
        #expect(mapped.transcript[0].speakerParticipantID == participantID)
        #expect(mapped.transcript[0].speakerLabel == "佐藤さん")
    }

    @Test func persistsTheOptInPreference() throws {
        let suiteName = "SpeakerDiarizationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(SpeakerDiarizationPreferences.load(defaults: defaults).isEnabled == false)
        let enabled = SpeakerDiarizationPreferences(isEnabled: true)
        enabled.save(defaults: defaults)
        #expect(SpeakerDiarizationPreferences.load(defaults: defaults) == enabled)
    }

    @Test func encryptsAndDecryptsVoiceprintsWithAESGCM() throws {
        let key = SymmetricKey(data: Data(repeating: 0x2A, count: 32))
        let embedding: [Float] = [0.1, -0.2, 0.3, 0.4]
        let encrypted = try VoiceprintCipher.encrypt(embedding, key: key)
        let plaintextJSON = try JSONEncoder().encode(embedding)
        let decrypted = try VoiceprintCipher.decrypt(encrypted, key: key)

        #expect(encrypted != plaintextJSON)
        #expect(decrypted == embedding)
    }

    @Test func suggestsOnlyAClearVoiceprintMatch() throws {
        let firstID = UUID()
        let secondID = UUID()
        let clear = VoiceprintMatcher.candidate(
            for: [1, 0, 0],
            registeredEmbeddings: [
                firstID: [0.99, 0.01, 0],
                secondID: [0, 1, 0]
            ]
        )
        #expect(clear?.participantID == firstID)
        #expect((clear?.similarity ?? 0) > 0.99)

        let ambiguous = VoiceprintMatcher.candidate(
            for: [1, 0, 0],
            registeredEmbeddings: [
                firstID: [0.99, 0.01, 0],
                secondID: [0.98, 0.02, 0]
            ]
        )
        #expect(ambiguous == nil)

        let weak = VoiceprintMatcher.candidate(
            for: [1, 0, 0],
            registeredEmbeddings: [firstID: [0, 1, 0]]
        )
        #expect(weak == nil)
    }

    @Test func recordsOnlySystemAudioIntoTheTemporaryFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CueTemporaryAudioTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try MeetingSystemAudioRecorder(
            meetingID: UUID(),
            supportDirectory: directory
        )
        let format = try #require(
            AVAudioFormat(
                standardFormatWithSampleRate: 48_000,
                channels: 1
            )
        )
        let microphoneBuffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240)
        )
        microphoneBuffer.frameLength = 240
        recorder.append(
            CapturedAudioBuffer(
                source: .microphone,
                buffer: microphoneBuffer,
                presentationTime: .zero
            )
        )
        let systemBuffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)
        )
        systemBuffer.frameLength = 480
        recorder.append(
            CapturedAudioBuffer(
                source: .system,
                buffer: systemBuffer,
                presentationTime: .zero
            )
        )

        let fileURL = try #require(try recorder.finish())
        let storedFile = try AVAudioFile(forReading: fileURL)
        #expect(storedFile.length == 480)
        let marker = fileURL.deletingLastPathComponent().appending(path: "keep.txt")
        try Data("keep".utf8).write(to: marker)
        MeetingSystemAudioRecorder.removeAbandonedRecordings(
            supportDirectory: directory
        )
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }
}
