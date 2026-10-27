import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import MixTake

@Suite("Mix export muxing")
struct ExportMixMuxingTests {
    @Test("Exported mix preserves the source video timing and transform")
    func exportedMixPreservesSourceVideoTimingAndTransform() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixTakeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let videoURL = directory.appendingPathComponent("video.mp4")
        let channelURL = directory.appendingPathComponent("channel.wav")
        let outputURL = directory.appendingPathComponent("mix.mp4")
        try await Self.writeVideo(to: videoURL)
        try Self.writeTone(to: channelURL, frameCount: 24_000)

        let take = RecordingTake(
            directory: directory,
            videoURL: videoURL,
            channelURLs: [0: channelURL],
            startedAt: Date(),
            backingTrack: nil
        )
        try await ExportService.exportMix(
            take,
            volumes: [0: 1],
            backingTrackVolume: 1,
            effects: [:],
            to: outputURL,
            progress: { _ in }
        )

        let sourceAsset = AVURLAsset(url: videoURL)
        let outputAsset = AVURLAsset(url: outputURL)
        let sourceDuration = try await sourceAsset.load(.duration)
        let outputDuration = try await outputAsset.load(.duration)
        let sourceVideo = try #require(
            try await sourceAsset.loadTracks(withMediaType: .video).first
        )
        let outputVideo = try #require(
            try await outputAsset.loadTracks(withMediaType: .video).first
        )
        let outputAudio = try await outputAsset.loadTracks(withMediaType: .audio)
        let sourceTransform = try await sourceVideo.load(.preferredTransform)
        let outputTransform = try await outputVideo.load(.preferredTransform)

        #expect(abs(outputDuration.seconds - sourceDuration.seconds) < 0.050)
        #expect(outputTransform == sourceTransform)
        #expect(outputAudio.count == 1)
    }

    private static func writeVideo(to url: URL) async throws {
        let width = 64
        let height = 48
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 48, ty: 0)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        try #require(writer.canAdd(input))
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let pool = try #require(adaptor.pixelBufferPool)

        for frame in 0..<4 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var optionalBuffer: CVPixelBuffer?
            try #require(
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess
            )
            let buffer = try #require(optionalBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
                memset(baseAddress, 0, CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try #require(
                adaptor.append(
                    buffer,
                    withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)
                )
            )
        }

        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    private static func writeTone(
        to url: URL,
        frameCount: AVAudioFrameCount
    ) throws {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        )
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(frameCount) {
            samples[frame] = 0.25 * sin(2 * Float.pi * 440 * Float(frame) / 48_000)
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }
}
