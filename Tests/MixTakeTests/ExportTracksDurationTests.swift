import AudioToolbox
import AVFoundation
import Foundation
import Testing
@testable import MixTake

@Suite("Track export duration")
struct ExportTracksDurationTests {
    @Test("Recording asset duration limits an unprocessed backing track")
    func recordingAssetDurationLimitsUnprocessedBackingTrack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixTakeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let recordingURL = directory.appendingPathComponent("recording.wav")
        let backingTrackURL = directory.appendingPathComponent("backing-track-source.wav")
        let outputDirectory = directory.appendingPathComponent("export", isDirectory: true)
        try Self.writeTone(to: recordingURL, frameCount: 4_800)
        try Self.writeTone(to: backingTrackURL, frameCount: 14_400)

        let take = RecordingTake(
            directory: directory,
            videoURL: recordingURL,
            channelURLs: [:],
            startedAt: Date(),
            backingTrack: BackingTrackReference(
                sourceURL: backingTrackURL,
                startTime: 0
            )
        )
        try await ExportService.exportTracks(
            take,
            effects: [:],
            to: outputDirectory,
            progress: { _ in }
        )

        let backingTrackDuration = try Self.duration(
            of: outputDirectory.appendingPathComponent("backing-track.wav")
        )
        #expect(abs(backingTrackDuration - 0.100) < 0.030)
    }

    @Test("Recording asset duration limits effect-rendered tracks")
    func recordingAssetDurationLimitsEffectRenderedTracks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixTakeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let recordingURL = directory.appendingPathComponent("recording.wav")
        let channelURL = directory.appendingPathComponent("channel.wav")
        let backingTrackURL = directory.appendingPathComponent("backing-track-source.wav")
        let outputDirectory = directory.appendingPathComponent("export", isDirectory: true)
        try Self.writeTone(to: recordingURL, frameCount: 4_800)
        try Self.writeTone(to: channelURL, frameCount: 14_400)
        try Self.writeTone(to: backingTrackURL, frameCount: 14_400)

        let take = RecordingTake(
            directory: directory,
            videoURL: recordingURL,
            channelURLs: [0: channelURL],
            startedAt: Date(),
            backingTrack: BackingTrackReference(
                sourceURL: backingTrackURL,
                startTime: 0
            )
        )
        let effect = AudioEffectConfiguration(
            name: "Peak Limiter",
            componentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: kAudioUnitSubType_PeakLimiter,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            ),
            fullState: nil
        )
        try await ExportService.exportTracks(
            take,
            effects: [
                .channel(0): [effect],
                .backingTrack: [effect]
            ],
            to: outputDirectory,
            progress: { _ in }
        )

        let channelDuration = try Self.duration(
            of: outputDirectory.appendingPathComponent("channel-01.wav")
        )
        let backingTrackDuration = try Self.duration(
            of: outputDirectory.appendingPathComponent("backing-track.wav")
        )
        #expect(abs(channelDuration - 0.100) < 0.030)
        #expect(abs(backingTrackDuration - 0.100) < 0.030)
    }

    private static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
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
