import Foundation
import Testing
@testable import MixTake

@Suite("Session persistence")
struct SessionPersistenceTests {
    @Test("Session manifests reject package-escaping media names")
    func rejectsPackageEscapingMediaNames() throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("Traversal-\(UUID()).mixtake", isDirectory: true)
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: package) }

        let cases = [
            (
                manifest(videoFileName: "../outside.mov"),
                "../outside.mov"
            ),
            (
                manifest(channelFileName: "../outside.wav"),
                "../outside.wav"
            ),
            (
                manifest(backingTrackFileName: "../backing.wav"),
                "../backing.wav"
            )
        ]

        for (manifest, invalidName) in cases {
            try SessionStore.write(manifest, to: package)
            do {
                _ = try SessionStore.read(from: package)
                Issue.record("Expected \(invalidName) to be rejected")
            } catch SessionStoreError.invalidMediaPath(let name) {
                #expect(name == invalidName)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    private func manifest(
        videoFileName: String = "video.mov",
        channelFileName: String = "channel.wav",
        backingTrackFileName: String = "backing.wav"
    ) -> SessionManifest {
        SessionManifest(
            version: SessionManifest.currentVersion,
            startedAt: Date(),
            videoFileName: videoFileName,
            audioInterfaceID: nil,
            audioInterfaceDeviceID: nil,
            channels: [
                SessionManifest.Channel(
                    index: 0,
                    fileName: channelFileName,
                    volume: 1,
                    inputGainDecibels: nil,
                    isMonitored: false
                )
            ],
            backingTrack: SessionManifest.BackingTrack(
                fileName: backingTrackFileName,
                startTime: 0,
                timelineOffset: 0,
                syncAdjustment: 0,
                volume: 1
            ),
            effectChains: [],
            playbackPosition: 0
        )
    }
}
