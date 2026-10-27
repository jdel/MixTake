import AVFoundation
import Foundation
import Testing
@testable import MixTake

@Suite("Offline mix scheduling")
struct OfflineMixSchedulingTests {
    @Test("Source start and timeline offsets are applied before rendering")
    func appliesSourceStartAndTimelineOffsets() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixTakeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.wav")
        let outputURL = directory.appendingPathComponent("output.m4a")
        try Self.writeSource(to: sourceURL)

        let take = RecordingTake(
            directory: directory,
            videoURL: sourceURL,
            channelURLs: [:],
            startedAt: Date(),
            backingTrack: BackingTrackReference(
                sourceURL: sourceURL,
                startTime: 0.030,
                timelineOffset: 0.030
            )
        )
        var progressValues: [Double] = []
        try await ExportService.exportAudio(
            take,
            volumes: [:],
            backingTrackVolume: 1,
            effects: [:],
            to: outputURL,
            progress: { progressValues.append($0) }
        )

        let output = try AVAudioFile(forReading: outputURL)
        let duration = Double(output.length) / output.processingFormat.sampleRate
        #expect(abs(duration - 0.150) < 0.030)
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: output.processingFormat,
                frameCapacity: AVAudioFrameCount(output.length)
            )
        )
        try output.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        let sampleRate = output.processingFormat.sampleRate

        let leadingPeak = Self.peak(
            samples,
            seconds: 0.005..<0.015,
            sampleRate: sampleRate
        )
        let scheduledPeak = Self.peak(
            samples,
            seconds: 0.045..<0.055,
            sampleRate: sampleRate
        )
        #expect(leadingPeak < 0.01)
        #expect(scheduledPeak > 0.05)
        #expect(progressValues.first == 0)
        #expect(progressValues.last == 1)
    }

    private static func writeSource(to url: URL) throws {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        )
        let frameCount: AVAudioFrameCount = 7_200
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(frameCount) {
            let signalFrame = frame - 1_440
            samples[frame] = signalFrame < 0
                ? 0
                : 0.25 * sin(2 * Float.pi * 440 * Float(signalFrame) / 48_000)
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private static func peak(
        _ samples: UnsafePointer<Float>,
        seconds: Range<Double>,
        sampleRate: Double
    ) -> Float {
        let frames = Int(seconds.lowerBound * sampleRate)..<Int(
            seconds.upperBound * sampleRate
        )
        return frames.reduce(0) { max($0, abs(samples[$1])) }
    }
}
