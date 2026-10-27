import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import MixTake

@Suite("Playback loading")
@MainActor
struct PlaybackLoadingTests {
    @Test("Loading a video publishes its initial playback state")
    func loadingVideoPublishesInitialPlaybackState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixTakeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let videoURL = directory.appendingPathComponent("video.mp4")
        try await Self.writeVideo(to: videoURL)
        let expectedDuration = try await AVURLAsset(url: videoURL).load(.duration).seconds
        let take = RecordingTake(
            directory: directory,
            videoURL: videoURL,
            channelURLs: [:],
            startedAt: Date(),
            backingTrack: nil
        )
        let controller = PlaybackController()
        var reportedTimes: [Double] = []
        controller.onTimeChanged = { reportedTimes.append($0) }

        try await controller.load(take: take)

        #expect(controller.player.currentItem != nil)
        #expect(abs(controller.duration - expectedDuration) < 0.001)
        #expect(controller.currentTime == 0)
        #expect(!controller.isPlaying)
        #expect(reportedTimes.last == 0)
    }

    @Test("Loading an audio-only asset leaves playback unloaded")
    func loadingAudioOnlyAssetLeavesPlaybackUnloaded() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixTakeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let audioURL = directory.appendingPathComponent("audio.wav")
        try Self.writeTone(to: audioURL, frameCount: 4_800)
        let take = RecordingTake(
            directory: directory,
            videoURL: audioURL,
            channelURLs: [:],
            startedAt: Date(),
            backingTrack: nil
        )
        let controller = PlaybackController()

        do {
            try await controller.load(take: take)
            Issue.record("Expected a missing-video-track error")
        } catch ExportError.missingVideoTrack {
        }

        #expect(controller.player.currentItem == nil)
        #expect(controller.duration == 0)
        #expect(controller.currentTime == 0)
        #expect(!controller.isPlaying)
    }

    @Test("Periodic observer publishes playback progress")
    func periodicObserverPublishesPlaybackProgress() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixTakeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let videoURL = directory.appendingPathComponent("video.mp4")
        try await Self.writeVideo(to: videoURL, frameCount: 30)
        let take = RecordingTake(
            directory: directory,
            videoURL: videoURL,
            channelURLs: [:],
            startedAt: Date(),
            backingTrack: nil
        )
        let controller = PlaybackController()
        try await controller.load(take: take)
        var reportedTimes: [Double] = []
        controller.onTimeChanged = { reportedTimes.append($0) }

        for _ in 0..<100 {
            if controller.player.status != .unknown {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(controller.player.status == .readyToPlay)
        controller.play(atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
        defer { controller.stop() }
        for _ in 0..<50 {
            if controller.currentTime > 0,
               controller.isPlaying,
               reportedTimes.contains(where: { $0 > 0 }) {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(controller.currentTime > 0)
        #expect(controller.duration > 0)
        #expect(controller.isPlaying)
        #expect(reportedTimes.contains(where: { $0 > 0 }))
    }

    private static func writeVideo(
        to url: URL,
        frameCount: Int = 4
    ) async throws {
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

        for frame in 0..<frameCount {
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
