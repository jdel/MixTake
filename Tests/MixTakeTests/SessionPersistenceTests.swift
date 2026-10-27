import Foundation
import Testing
@testable import MixTake

@Suite("Session persistence")
struct SessionPersistenceTests {
    private enum TestError: Error {
        case injectedFailure
    }

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

    @Test("A failed session replacement preserves the existing package")
    func failedReplacementPreservesExistingPackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSave-\(UUID())", isDirectory: true)
        let destination = root
            .appendingPathComponent("Existing.mixtake", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let marker = destination.appendingPathComponent("old-data")
        try Data("original".utf8).write(to: marker)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let _: Void = try SessionStore.replacePackage(at: destination) { staging in
                try FileManager.default.createDirectory(
                    at: staging,
                    withIntermediateDirectories: true
                )
                try Data("replacement".utf8).write(
                    to: staging.appendingPathComponent("new-data")
                )
                throw TestError.injectedFailure
            }
            Issue.record("Expected the staged save to fail")
        } catch TestError.injectedFailure {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(try String(contentsOf: marker, encoding: .utf8) == "original")
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("new-data").path
            )
        )
    }

    @Test("A completed session replacement installs the staged package")
    func completedReplacementInstallsStagedPackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSave-\(UUID())", isDirectory: true)
        let destination = root
            .appendingPathComponent("Existing.mixtake", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        try Data("original".utf8).write(
            to: destination.appendingPathComponent("old-data")
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try SessionStore.replacePackage(at: destination) { staging in
            try FileManager.default.createDirectory(
                at: staging,
                withIntermediateDirectories: true
            )
            try Data("replacement".utf8).write(
                to: staging.appendingPathComponent("new-data")
            )
            return 42
        }

        #expect(result == 42)
        #expect(
            try String(
                contentsOf: destination.appendingPathComponent("new-data"),
                encoding: .utf8
            ) == "replacement"
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("old-data").path
            )
        )
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
