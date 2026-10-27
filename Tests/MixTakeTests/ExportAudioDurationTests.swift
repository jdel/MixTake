import AVFoundation
import Foundation
import Testing
@testable import MixTake

@Suite("Audio export duration")
struct ExportAudioDurationTests {
    @Test("Recording asset duration limits exported audio")
    func recordingAssetDurationLimitsExportedAudio() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixTakeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let recordingURL = directory.appendingPathComponent("recording.wav")
        let sourceURL = directory.appendingPathComponent("source.wav")
        let outputURL = directory.appendingPathComponent("output.m4a")
        let progressRecorder = ProgressRecorder()
        try Self.writeTone(to: recordingURL, frameCount: 4_800)
        try Self.writeTone(to: sourceURL, frameCount: 14_400)

        let take = RecordingTake(
            directory: directory,
            videoURL: recordingURL,
            channelURLs: [0: sourceURL],
            startedAt: Date(),
            backingTrack: nil
        )
        try await ExportService.exportAudio(
            take,
            volumes: [0: 1],
            backingTrackVolume: 1,
            effects: [:],
            to: outputURL,
            progress: { progressRecorder.record($0) }
        )

        let output = try AVAudioFile(forReading: outputURL)
        let duration = Double(output.length) / output.processingFormat.sampleRate
        let progressValues = progressRecorder.values
        #expect(abs(duration - 0.100) < 0.030)
        #expect(progressValues.first == 0)
        #expect(progressValues.last == 1)
        #expect(progressValues.allSatisfy { (0...1).contains($0) })
        for (previous, next) in zip(progressValues, progressValues.dropFirst()) {
            #expect(previous <= next)
        }
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

private final class ProgressRecorder {
    private let lock = NSLock()
    private var recordedValues: [Double] = []

    var values: [Double] {
        lock.withLock { recordedValues }
    }

    func record(_ value: Double) {
        lock.withLock { recordedValues.append(value) }
    }
}
