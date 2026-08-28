import AVFoundation
import CoreMedia
import Foundation
import CueCore
import ScreenCaptureKit

enum CaptureServiceState: Equatable, Sendable {
    case idle
    case selecting
    case starting
    case capturing
    case stopped
    case failed(String)

    var label: String {
        switch self {
        case .idle: "待機中"
        case .selecting: "共有対象を選択中"
        case .starting: "キャプチャ開始中"
        case .capturing: "キャプチャ中"
        case .stopped: "停止"
        case .failed(let message): "エラー: \(message)"
        }
    }
}

struct CapturedAudioBuffer: @unchecked Sendable {
    let source: AudioSource
    let buffer: AVAudioPCMBuffer
    let presentationTime: CMTime
    let capturedAt: Date

    init(
        source: AudioSource,
        buffer: AVAudioPCMBuffer,
        presentationTime: CMTime,
        capturedAt: Date = Date()
    ) {
        self.source = source
        self.buffer = buffer
        self.presentationTime = presentationTime
        self.capturedAt = capturedAt
    }
}

private struct CapturedContentFilter: @unchecked Sendable {
    let value: SCContentFilter
}

struct CapturedScreenFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
    let capturedAt: Date
    let contentRect: CGRect?
    let dirtyRects: [CGRect]

    init(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        capturedAt: Date = Date(),
        contentRect: CGRect? = nil,
        dirtyRects: [CGRect] = []
    ) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        self.capturedAt = capturedAt
        self.contentRect = contentRect
        self.dirtyRects = dirtyRects
    }
}

final class ScreenCaptureService: NSObject, @unchecked Sendable {
    typealias AudioHandler = @Sendable (CapturedAudioBuffer) -> Void
    typealias ScreenHandler = @Sendable (CapturedScreenFrame) -> Void
    typealias StateHandler = @Sendable (CaptureServiceState) -> Void

    private let systemAudioQueue = DispatchQueue(
        label: "jp.cue.capture.system-audio",
        qos: .userInteractive
    )
    private let microphoneQueue = DispatchQueue(
        label: "jp.cue.capture.microphone",
        qos: .userInteractive
    )
    private let screenQueue = DispatchQueue(
        label: "jp.cue.capture.screen",
        qos: .utility
    )

    private let audioHandler: AudioHandler
    private let screenHandler: ScreenHandler
    private let stateHandler: StateHandler
    private let lock = NSLock()
    private var stream: SCStream?
    private var isPickerRegistered = false

    init(
        audioHandler: @escaping AudioHandler,
        screenHandler: @escaping ScreenHandler,
        stateHandler: @escaping StateHandler
    ) {
        self.audioHandler = audioHandler
        self.screenHandler = screenHandler
        self.stateHandler = stateHandler
        super.init()
    }

    @MainActor
    func presentPicker() {
        stateHandler(.selecting)

        let picker = SCContentSharingPicker.shared
        if !isPickerRegistered {
            picker.add(self)
            isPickerRegistered = true
        }

        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [
            .singleWindow,
            .singleApplication,
            .singleDisplay
        ]
        configuration.allowsChangingSelectedContent = true
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            configuration.excludedBundleIDs = [bundleIdentifier]
        }
        picker.defaultConfiguration = configuration
        picker.isActive = true
        picker.present()
    }

    func stop() async {
        await MainActor.run {
            let picker = SCContentSharingPicker.shared
            if isPickerRegistered {
                picker.remove(self)
                isPickerRegistered = false
            }
            picker.isActive = false
        }

        let activeStream = lock.withLock {
            let activeStream = stream
            stream = nil
            return activeStream
        }

        if let activeStream {
            do {
                try await activeStream.stopCapture()
            } catch {
                stateHandler(.failed(error.localizedDescription))
                return
            }
        }
        stateHandler(.stopped)
    }

    private func startCapture(filter capturedFilter: CapturedContentFilter) async {
        stateHandler(.starting)
        await stopCurrentStreamIfNeeded()

        let configuration = SCStreamConfiguration()
        configuration.width = 1280
        configuration.height = 720
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.captureMicrophone = true

        let newStream = SCStream(
            filter: capturedFilter.value,
            configuration: configuration,
            delegate: self
        )

        do {
            try newStream.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: screenQueue
            )
            try newStream.addStreamOutput(
                self,
                type: .audio,
                sampleHandlerQueue: systemAudioQueue
            )
            try newStream.addStreamOutput(
                self,
                type: .microphone,
                sampleHandlerQueue: microphoneQueue
            )
            try await newStream.startCapture()
            lock.withLock { stream = newStream }
            stateHandler(.capturing)
        } catch {
            stateHandler(.failed(error.localizedDescription))
        }
    }

    private func stopCurrentStreamIfNeeded() async {
        let current = lock.withLock {
            let current = stream
            stream = nil
            return current
        }
        try? await current?.stopCapture()
    }
}

extension ScreenCaptureService: SCContentSharingPickerObserver {
    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        let capturedFilter = CapturedContentFilter(value: filter)
        Task { await startCapture(filter: capturedFilter) }
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        stateHandler(.idle)
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        stateHandler(.failed(error.localizedDescription))
    }
}

extension ScreenCaptureService: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }

        let source: AudioSource
        switch outputType {
        case .screen:
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let frameMetadata = Self.frameMetadata(from: sampleBuffer)
                screenHandler(
                    CapturedScreenFrame(
                        pixelBuffer: pixelBuffer,
                        presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                        contentRect: frameMetadata.contentRect,
                        dirtyRects: frameMetadata.dirtyRects
                    )
                )
            }
            return
        case .audio:
            source = .system
        case .microphone:
            source = .microphone
        default:
            return
        }

        do {
            let buffer = try AudioBufferFactory.copyPCMBuffer(from: sampleBuffer)
            audioHandler(
                CapturedAudioBuffer(
                    source: source,
                    buffer: buffer,
                    presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                )
            )
        } catch {
            stateHandler(.failed(error.localizedDescription))
        }
    }

    private static func frameMetadata(
        from sampleBuffer: CMSampleBuffer
    ) -> (contentRect: CGRect?, dirtyRects: [CGRect]) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let frameInfo = attachments.first
        else { return (nil, []) }

        return (
            frameInfo[.contentRect] as? CGRect,
            frameInfo[.dirtyRects] as? [CGRect] ?? []
        )
    }
}

extension ScreenCaptureService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        stateHandler(.failed(error.localizedDescription))
    }
}
