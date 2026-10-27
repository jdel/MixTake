import Combine
import Foundation

@MainActor
final class OutputMeter: ObservableObject {
    @Published private(set) var peak: Float = 0
    @Published private(set) var clipped = false

    func update(_ value: Float) {
        peak = max(0, value)
        if value >= 0.999 {
            clipped = true
        }
    }

    func resetClipping() {
        clipped = false
    }

    func reset() {
        peak = 0
        clipped = false
    }
}
