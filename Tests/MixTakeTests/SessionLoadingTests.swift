import AVFoundation
import Foundation
import Testing
@testable import MixTake

@Suite("Session loading", .serialized)
@MainActor
struct SessionLoadingTests {
    @Test("A failed session load preserves the external package")
    func failedSessionLoadPreservesExternalPackage() async throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("Broken-\(UUID()).mixtake", isDirectory: true)
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: package) }

        let audioOnlyURL = package.appendingPathComponent("video.wav")
        try Self.writeTone(to: audioOnlyURL)
        try SessionStore.write(
            SessionManifest(
                version: SessionManifest.currentVersion,
                startedAt: Date(),
                videoFileName: audioOnlyURL.lastPathComponent,
                audioInterfaceID: nil,
                audioInterfaceDeviceID: nil,
                channels: [],
                backingTrack: nil,
                effectChains: [],
                playbackPosition: 0
            ),
            to: package
        )

        let model = AppModel.shared
        model.discardCurrentTake()
        model.errorMessage = nil
        model.openSession(at: package)

        let expectedError = ExportError.missingVideoTrack.errorDescription
        for _ in 0..<250 where model.errorMessage != expectedError {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(model.errorMessage == expectedError)

        model.discardCurrentTake()
        #expect(FileManager.default.fileExists(atPath: package.path))
        model.errorMessage = nil
    }

    @Test("An invalid backing track leaves the app ready for another action")
    func invalidBackingTrackLeavesStableState() async throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("Broken-\(UUID()).mixtake", isDirectory: true)
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: package) }

        let videoURL = package.appendingPathComponent("video.wav")
        let backingURL = package.appendingPathComponent("backing.wav")
        try Self.writeTone(to: videoURL)
        try Data("not audio".utf8).write(to: backingURL)
        try SessionStore.write(
            SessionManifest(
                version: SessionManifest.currentVersion,
                startedAt: Date(),
                videoFileName: videoURL.lastPathComponent,
                audioInterfaceID: nil,
                audioInterfaceDeviceID: nil,
                channels: [],
                backingTrack: SessionManifest.BackingTrack(
                    fileName: backingURL.lastPathComponent,
                    startTime: 0,
                    timelineOffset: 0,
                    syncAdjustment: 0,
                    volume: 1
                ),
                effectChains: [],
                playbackPosition: 0
            ),
            to: package
        )

        let model = AppModel.shared
        model.discardCurrentTake()
        model.errorMessage = nil
        model.openSession(at: package)

        let expectedError = BackingTrackError.unsupportedFile.errorDescription
        for _ in 0..<250 where model.errorMessage != expectedError {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(model.errorMessage == expectedError)
        #expect(model.state == .empty)
        #expect(model.currentTake == nil)
        #expect(FileManager.default.fileExists(atPath: package.path))
        model.errorMessage = nil
    }

    @Test("Mix changes invalidate a completed export")
    func mixChangesInvalidateCompletedExport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Take-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let model = AppModel.shared
        model.discardCurrentTake()
        model.currentTake = RecordingTake(
            directory: directory,
            videoURL: directory.appendingPathComponent("video.mov"),
            channelURLs: [:],
            startedAt: Date(),
            backingTrack: nil
        )
        model.mixerChannels = [
            MixerChannel(index: 0, volume: 1, inputGain: nil)
        ]
        defer { model.discardCurrentTake() }

        model.markCurrentTakeExported()
        #expect(model.terminationWarning == nil)

        model.setVolume(0.5, for: 0)
        #expect(model.hasExportedCurrentTake == false)
        #expect(model.terminationWarning != nil)

        model.markCurrentTakeExported()
        model.setBackingTrackVolume(0.5)
        #expect(model.hasExportedCurrentTake == false)
        #expect(model.terminationWarning != nil)
    }

    private static func writeTone(to url: URL) throws {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        )
        let frameCount: AVAudioFrameCount = 4_800
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
