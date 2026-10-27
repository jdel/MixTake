import Foundation
import Testing
@testable import MixTake

@Suite("Transport view")
struct TransportViewTests {
    @Test("Recording time shows padded elapsed minutes and seconds")
    func recordingTimeShowsElapsedDuration() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(
            TransportView.recordingTime(
                startedAt: start,
                at: start.addingTimeInterval(65.9)
            ) == "01:05"
        )
        #expect(TransportView.recordingTime(startedAt: nil, at: start) == "00:00")
        #expect(
            TransportView.recordingTime(
                startedAt: start,
                at: start.addingTimeInterval(-1)
            ) == "00:00"
        )
    }
}
