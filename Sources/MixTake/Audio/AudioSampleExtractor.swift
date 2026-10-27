import AVFoundation
import CoreMedia
import Foundation

struct ExtractedAudio {
    let channels: [[Float]]
    let sampleRate: Double
    let presentationTime: CMTime

    var frameCount: Int { channels.first?.count ?? 0 }
}

enum AudioSampleExtractor {
    static func extract(_ sampleBuffer: CMSampleBuffer) -> ExtractedAudio? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            return nil
        }

        var requiredSize = 0
        var retainedBlockBuffer: CMBlockBuffer?
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard requiredSize > 0 else { return nil }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }

        let audioBufferList = storage.assumingMemoryBound(to: AudioBufferList.self)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: requiredSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let channelCount = Int(description.mChannelsPerFrame)
        guard frameCount > 0, channelCount > 0 else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let isNonInterleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = Int(description.mBitsPerChannel)
        var channels = Array(
            repeating: [Float](repeating: 0, count: frameCount),
            count: channelCount
        )

        if isNonInterleaved {
            var outputChannel = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                for localChannel in 0..<Int(buffer.mNumberChannels) where outputChannel < channelCount {
                    for frame in 0..<frameCount {
                        channels[outputChannel][frame] = sample(
                            data: data,
                            sampleIndex: frame * Int(buffer.mNumberChannels) + localChannel,
                            bits: bits,
                            isFloat: isFloat
                        )
                    }
                    outputChannel += 1
                }
            }
        } else if let buffer = buffers.first, let data = buffer.mData {
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    channels[channel][frame] = sample(
                        data: data,
                        sampleIndex: frame * channelCount + channel,
                        bits: bits,
                        isFloat: isFloat
                    )
                }
            }
        } else {
            return nil
        }

        return ExtractedAudio(
            channels: channels,
            sampleRate: description.mSampleRate,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
    }

    private static func sample(
        data: UnsafeMutableRawPointer,
        sampleIndex: Int,
        bits: Int,
        isFloat: Bool
    ) -> Float {
        if isFloat, bits == 32 {
            return data.assumingMemoryBound(to: Float.self)[sampleIndex]
        }
        if isFloat, bits == 64 {
            return Float(data.assumingMemoryBound(to: Double.self)[sampleIndex])
        }
        if bits == 16 {
            return Float(data.assumingMemoryBound(to: Int16.self)[sampleIndex]) / 32_768
        }
        if bits == 24 {
            let bytes = data.assumingMemoryBound(to: UInt8.self).advanced(by: sampleIndex * 3)
            var value = Int32(bytes[0]) | (Int32(bytes[1]) << 8) | (Int32(bytes[2]) << 16)
            if value & 0x0080_0000 != 0 { value |= ~0x00ff_ffff }
            return Float(value) / 8_388_608
        }
        if bits == 32 {
            return Float(data.assumingMemoryBound(to: Int32.self)[sampleIndex]) / 2_147_483_648
        }
        return 0
    }
}
