import CueCore
import FluidAudio
import Foundation

struct DiarizedSpeechInterval: Equatable, Sendable {
    let clusterKey: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let qualityScore: Double
}

struct SpeakerDiarizationOutput: Sendable {
    let clusters: [SpeakerClusterRecord]
    let transcript: [TranscriptSegment]
    let embeddings: [String: [Float]]
}

enum SpeakerDiarizationMapper {
    static func map(
        meetingID: UUID,
        transcript: [TranscriptSegment],
        intervals: [DiarizedSpeechInterval]
    ) -> (clusters: [SpeakerClusterRecord], transcript: [TranscriptSegment]) {
        let orderedClusterKeys = Array(Set(intervals.map(\.clusterKey))).sorted()
        let labels = Dictionary(
            uniqueKeysWithValues: orderedClusterKeys.enumerated().map {
                ($0.element, "話者\($0.offset + 1)")
            }
        )
        var updatedTranscript = transcript
        var segmentIDsByCluster: [String: [UUID]] = [:]

        for index in updatedTranscript.indices {
            let segment = updatedTranscript[index]
            guard segment.source == .system, segment.isFinal else { continue }
            let best = intervals
                .map { interval in
                    (
                        interval,
                        overlap(
                            start: segment.startTime,
                            end: segment.endTime,
                            withStart: interval.startTime,
                            withEnd: interval.endTime
                        )
                    )
                }
                .filter { $0.1 > 0 }
                .max { lhs, rhs in lhs.1 < rhs.1 }
            guard let best else { continue }
            updatedTranscript[index].speakerClusterID = best.0.clusterKey
            if updatedTranscript[index].speakerParticipantID == nil {
                updatedTranscript[index].speakerLabel = labels[best.0.clusterKey]
            }
            segmentIDsByCluster[best.0.clusterKey, default: []].append(segment.id)
        }

        let clusters = orderedClusterKeys.map { key in
            let matching = intervals.filter { $0.clusterKey == key }
            let duration = matching.reduce(0) {
                $0 + max(0, $1.endTime - $1.startTime)
            }
            let quality = matching.reduce(0) { partial, interval in
                let intervalDuration = max(0, interval.endTime - interval.startTime)
                return partial + interval.qualityScore * intervalDuration
            }
            return SpeakerClusterRecord(
                meetingID: meetingID,
                clusterKey: key,
                displayLabel: labels[key] ?? key,
                sourceSegmentIDs: segmentIDsByCluster[key] ?? [],
                speechDuration: duration,
                qualityScore: duration > 0 ? quality / duration : 0
            )
        }
        return (clusters, updatedTranscript)
    }

    private static func overlap(
        start: TimeInterval,
        end: TimeInterval,
        withStart otherStart: TimeInterval,
        withEnd otherEnd: TimeInterval
    ) -> TimeInterval {
        max(0, min(end, otherEnd) - max(start, otherStart))
    }
}

final class SpeakerDiarizationService: @unchecked Sendable {
    private let modelDirectory: URL

    init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    func prepareModels() async throws {
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await manager.prepareModels(directory: modelDirectory)
    }

    func analyze(
        audioURL: URL,
        meetingID: UUID,
        transcript: [TranscriptSegment],
        expectedSpeakerCount: Int?
    ) async throws -> SpeakerDiarizationOutput {
        var config = OfflineDiarizerConfig()
        if let expectedSpeakerCount, expectedSpeakerCount > 0 {
            config = config.withSpeakers(
                min: 1,
                max: max(4, expectedSpeakerCount + 2)
            )
        }
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels(directory: modelDirectory)
        let result = try await manager.process(audioURL)
        let intervals = result.segments.map {
            DiarizedSpeechInterval(
                clusterKey: $0.speakerId,
                startTime: TimeInterval($0.startTimeSeconds),
                endTime: TimeInterval($0.endTimeSeconds),
                qualityScore: min(1, max(0, Double($0.qualityScore)))
            )
        }
        let mapped = SpeakerDiarizationMapper.map(
            meetingID: meetingID,
            transcript: transcript,
            intervals: intervals
        )
        return SpeakerDiarizationOutput(
            clusters: mapped.clusters,
            transcript: mapped.transcript,
            embeddings: result.speakerDatabase ?? [:]
        )
    }
}
