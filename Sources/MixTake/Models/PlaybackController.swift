import AVFoundation
import Combine
import Foundation

@MainActor
final class PlaybackController: ObservableObject {
    let player = AVPlayer()
    var onTimeChanged: ((Double) -> Void)?

    @Published private(set) var duration = 0.0
    @Published var currentTime = 0.0
    @Published private(set) var isPlaying = false

    private var timeObserver: Any?

    init() {
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.currentTime = max(0, time.seconds)
            self.duration = max(0, self.player.currentItem?.duration.seconds ?? 0)
            self.isPlaying = self.player.rate != 0
            self.onTimeChanged?(self.currentTime)
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func load(take: RecordingTake) throws {
        let asset = AVURLAsset(url: take.videoURL)
        guard asset.tracks(withMediaType: .video).first != nil else {
            throw ExportError.missingVideoTrack
        }
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        duration = max(0, asset.duration.seconds)
        seek(to: 0)
    }

    func unload() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        duration = 0
        currentTime = 0
        isPlaying = false
        onTimeChanged?(0)
    }

    func play(atHostTime hostTime: CMTime) {
        if duration > 0, currentTime >= duration - 0.05 { seek(to: 0) }
        let itemTime = CMTime(seconds: currentTime, preferredTimescale: 1_000_000)
        player.setRate(1, time: itemTime, atHostTime: hostTime)
        isPlaying = true
        onTimeChanged?(currentTime)
    }

    func stop() {
        player.pause()
        isPlaying = false
        onTimeChanged?(currentTime)
    }

    func seek(to seconds: Double) {
        let bounded = min(max(0, seconds), max(0, duration))
        player.seek(
            to: CMTime(seconds: bounded, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = bounded
        onTimeChanged?(bounded)
    }

}
