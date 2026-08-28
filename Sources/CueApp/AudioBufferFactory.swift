import AVFoundation
import CoreMedia
import Foundation

enum AudioBufferFactoryError: LocalizedError {
    case missingFormat
    case unsupportedFormat
    case allocationFailed
    case sampleBuffer(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingFormat:
            "音声フォーマットを取得できません。"
        case .unsupportedFormat:
            "対応していない音声フォーマットです。"
        case .allocationFailed:
            "音声バッファを確保できません。"
        case .sampleBuffer(let status):
            "音声サンプルを読み取れませんでした（\(status)）。"
        }
    }
}

enum AudioBufferFactory {
    static func copyPCMBuffer(
        from sampleBuffer: CMSampleBuffer
    ) throws -> AVAudioPCMBuffer {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else {
            throw AudioBufferFactoryError.missingFormat
        }

        guard let format = AVAudioFormat(streamDescription: streamDescription) else {
            throw AudioBufferFactoryError.unsupportedFormat
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let destination = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
              )
        else {
            throw AudioBufferFactoryError.allocationFailed
        }
        destination.frameLength = frameCount

        let channelCount = max(1, Int(streamDescription.pointee.mChannelsPerFrame))
        let bufferListSize = MemoryLayout<AudioBufferList>.size +
            MemoryLayout<AudioBuffer>.stride * max(0, channelCount - 1)
        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }

        let sourceList = rawBufferList.bindMemory(
            to: AudioBufferList.self,
            capacity: 1
        )
        var retainedBlockBuffer: CMBlockBuffer?
        var requiredSize = 0
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: sourceList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else {
            throw AudioBufferFactoryError.sampleBuffer(status)
        }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(sourceList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList
        )

        for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData
            else { continue }

            let byteCount = min(
                Int(sourceBuffers[index].mDataByteSize),
                Int(destinationBuffers[index].mDataByteSize)
            )
            destinationData.copyMemory(from: sourceData, byteCount: byteCount)
            destinationBuffers[index].mDataByteSize = UInt32(byteCount)
        }

        return destination
    }
}
