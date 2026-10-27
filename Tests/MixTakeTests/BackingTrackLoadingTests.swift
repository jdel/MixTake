import AVFoundation
import Foundation
import Testing
@testable import MixTake

@Suite("Backing-track loading")
@MainActor
struct BackingTrackLoadingTests {
    @Test("Loading a playable track publishes its initial state")
    func loadingPlayableTrackPublishesInitialState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixTakeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let trackURL = directory.appendingPathComponent("backing.wav")
        try Self.writeTone(to: trackURL, frameCount: 4_800)
        let controller = BackingTrackController()

        try await controller.load(trackURL)

        #expect(controller.fileURL == trackURL)
        #expect(abs(controller.duration - 0.100) < 0.001)
        #expect(controller.startTime == 0)
        #expect(controller.syncAdjustment == 0)
        #expect(controller.candidateTime == 0)
        #expect(controller.volume == 1)
        #expect(controller.controlsVisible)
        #expect(!controller.isPreviewing)
    }

    @Test("Restoring a track clamps its saved state to the track duration")
    func restoringTrackClampsSavedState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixTakeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let trackURL = directory.appendingPathComponent("backing.wav")
        try Self.writeTone(to: trackURL, frameCount: 4_800)
        let controller = BackingTrackController()

        try await controller.restore(
            url: trackURL,
            startTime: 0.250,
            syncAdjustment: -0.250,
            volume: 2
        )

        #expect(controller.fileURL == trackURL)
        #expect(abs(controller.duration - 0.100) < 0.001)
        #expect(abs(controller.startTime - 0.100) < 0.001)
        #expect(abs(controller.candidateTime - 0.100) < 0.001)
        #expect(abs(controller.syncAdjustment + 0.100) < 0.001)
        #expect(controller.volume == 1)
        #expect(controller.controlsVisible)
    }

    @Test("Loading an unsupported file leaves the controller empty")
    func loadingUnsupportedFileLeavesControllerEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixTakeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let trackURL = directory.appendingPathComponent("invalid.wav")
        try Data("not an audio file".utf8).write(to: trackURL)
        let controller = BackingTrackController()

        do {
            try await controller.load(trackURL)
            Issue.record("Expected an unsupported-file error")
        } catch is BackingTrackError {
        }

        #expect(!controller.isLoaded)
        #expect(controller.duration == 0)
        #expect(!controller.controlsVisible)
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
