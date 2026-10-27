import AVFoundation
import Combine
import Foundation

enum BackingTrackError: LocalizedError {
    case unsupportedFile

    var errorDescription: String? {
        "The selected file is not a supported audio track."
    }
}

@MainActor
final class BackingTrackController: ObservableObject {
    @Published private(set) var fileURL: URL?
    @Published private(set) var duration = 0.0
    @Published private(set) var startTime = 0.0
    @Published private(set) var syncAdjustment = 0.0
    @Published var candidateTime = 0.0
    @Published private(set) var volume: Float = 1
    @Published private(set) var controlsVisible = false
    @Published private(set) var isPreviewing = false

    private var recordingTimelineOffset: Double?

    var isLoaded: Bool { fileURL != nil }
    var displayName: String { fileURL?.lastPathComponent ?? "Backing Track" }
    var reference: BackingTrackReference? {
        fileURL.map {
            BackingTrackReference(
                sourceURL: $0,
                startTime: startTime,
                syncAdjustment: syncAdjustment
            )
        }
    }
    var recordedReference: BackingTrackReference? {
        guard let fileURL, let recordingTimelineOffset else { return nil }
        return BackingTrackReference(
            sourceURL: fileURL,
            startTime: startTime,
            timelineOffset: recordingTimelineOffset,
            syncAdjustment: syncAdjustment
        )
    }

    func load(_ url: URL) throws {
        let asset = AVURLAsset(url: url)
        let seconds = asset.duration.seconds
        guard asset.isPlayable, seconds.isFinite, seconds > 0 else {
            throw BackingTrackError.unsupportedFile
        }

        fileURL = url
        duration = seconds
        startTime = 0
        syncAdjustment = 0
        candidateTime = 0
        controlsVisible = true
        isPreviewing = false
        recordingTimelineOffset = nil
    }

    func restore(
        url: URL,
        startTime: Double,
        syncAdjustment: Double,
        volume: Float
    ) throws {
        try load(url)
        self.startTime = boundedStartTime(startTime)
        candidateTime = max(0, self.startTime)
        self.syncAdjustment = min(max(-duration, syncAdjustment), duration)
        self.volume = min(1, max(0, volume))
        controlsVisible = true
    }

    func seekCandidate(to seconds: Double) {
        candidateTime = bounded(seconds)
    }

    func setStart(to seconds: Double? = nil) -> Double {
        isPreviewing = false
        recordingTimelineOffset = nil
        startTime = boundedStartTime(seconds ?? candidateTime)
        candidateTime = max(0, startTime)
        return startTime
    }

    func setSyncAdjustment(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return syncAdjustment }
        syncAdjustment = min(max(-duration, seconds), duration)
        return syncAdjustment
    }

    func toggleControls() {
        controlsVisible.toggle()
    }

    func remove() {
        isPreviewing = false
        recordingTimelineOffset = nil
        fileURL = nil
        duration = 0
        startTime = 0
        syncAdjustment = 0
        candidateTime = 0
        controlsVisible = false
    }

    func beginRecordingPlayback(timelineOffset: Double) {
        guard isLoaded else { return }
        isPreviewing = false
        recordingTimelineOffset = max(0, timelineOffset)
        candidateTime = max(0, startTime)
    }

    func stopAndReturnToStart() {
        guard isLoaded else { return }
        isPreviewing = false
        candidateTime = max(0, startTime)
    }

    func beginPreview() {
        guard isLoaded else { return }
        recordingTimelineOffset = nil
        isPreviewing = true
    }

    func stopPreview() {
        guard isLoaded else { return }
        isPreviewing = false
    }

    func updatePreviewPosition(_ seconds: Double) {
        guard isPreviewing else { return }
        candidateTime = bounded(seconds)
    }

    func setVolume(_ newValue: Float) {
        volume = min(1, max(0, newValue))
    }

    private func bounded(_ seconds: Double) -> Double {
        min(max(0, seconds), duration)
    }

    private func boundedStartTime(_ seconds: Double) -> Double {
        min(max(-duration, seconds), duration)
    }
}
