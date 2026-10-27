import Combine
import Foundation

@MainActor
final class MeterLevels: ObservableObject {
    @Published private(set) var peaks: [Int: Float] = [:]
    @Published private(set) var clippedChannels = Set<Int>()

    func update(_ newPeaks: [Int: Float]) {
        peaks = newPeaks
        for (channel, peak) in newPeaks where peak >= 0.999 {
            clippedChannels.insert(channel)
        }
    }

    func reset() {
        peaks = [:]
        clippedChannels = []
    }

    func resetClipping(for channel: Int) {
        clippedChannels.remove(channel)
    }
}
