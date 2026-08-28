import AVFoundation
import CueCore
import Foundation

enum MeetingSystemAudioRecorderError: LocalizedError {
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let message):
            "話者分離用の一時音声を書き込めませんでした: \(message)"
        }
    }
}

final class MeetingSystemAudioRecorder: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var didWriteFrames = false
    private var writeError: Error?

    static func removeAbandonedRecordings(supportDirectory: URL) {
        let directory = supportDirectory.appending(
            path: "TemporaryAudio",
            directoryHint: .isDirectory
        )
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension.lowercased() == "caf" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    init(meetingID: UUID, supportDirectory: URL) throws {
        let directory = supportDirectory.appending(
            path: "TemporaryAudio",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        fileURL = directory.appending(path: "\(meetingID.uuidString).caf")
        try? FileManager.default.removeItem(at: fileURL)
    }

    func append(_ captured: CapturedAudioBuffer) {
        guard captured.source == .system else { return }
        lock.withLock {
            guard writeError == nil else { return }
            do {
                if audioFile == nil {
                    audioFile = try AVAudioFile(
                        forWriting: fileURL,
                        settings: captured.buffer.format.settings,
                        commonFormat: captured.buffer.format.commonFormat,
                        interleaved: captured.buffer.format.isInterleaved
                    )
                }
                try audioFile?.write(from: captured.buffer)
                didWriteFrames = didWriteFrames || captured.buffer.frameLength > 0
            } catch {
                writeError = error
                audioFile = nil
            }
        }
    }

    func finish() throws -> URL? {
        let result = lock.withLock { () -> (Bool, Error?) in
            audioFile = nil
            return (didWriteFrames, writeError)
        }
        if let error = result.1 {
            try? FileManager.default.removeItem(at: fileURL)
            throw MeetingSystemAudioRecorderError.writeFailed(
                error.localizedDescription
            )
        }
        guard result.0 else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return fileURL
    }

    func discard() {
        lock.withLock {
            audioFile = nil
            didWriteFrames = false
        }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
