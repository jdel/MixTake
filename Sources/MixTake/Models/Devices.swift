import Foundation

struct CameraDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

struct AudioInterface: Identifiable, Hashable {
    static let systemDefaultID = "system-default-input"

    let id: String
    let configurationID: String
    let name: String
    let captureDeviceID: String
    let coreAudioDeviceID: UInt32
    let channelCount: Int

    var channels: [Int] {
        Array(0..<channelCount)
    }
}

struct AudioOutputDevice: Identifiable, Hashable {
    static let systemDefaultID = "system-default-output"

    let id: String
    let name: String
    let deviceUID: String?
    let coreAudioDeviceID: UInt32
}

struct InputGain: Hashable {
    var decibels: Float
    let minimumDecibels: Float
    let maximumDecibels: Float
    let element: UInt32
}

struct MixerChannel: Identifiable, Hashable {
    let index: Int
    var volume: Float
    var inputGain: InputGain?

    var id: Int { index }
    var number: Int { index + 1 }
}

struct RecordingTake: Identifiable {
    let id = UUID()
    let directory: URL
    let videoURL: URL
    let channelURLs: [Int: URL]
    let startedAt: Date
    let backingTrack: BackingTrackReference?
}

struct BackingTrackReference {
    let sourceURL: URL
    let startTime: Double
    let timelineOffset: Double
    let syncAdjustment: Double

    init(
        sourceURL: URL,
        startTime: Double,
        timelineOffset: Double = 0,
        syncAdjustment: Double = 0
    ) {
        self.sourceURL = sourceURL
        self.startTime = startTime
        self.timelineOffset = timelineOffset
        self.syncAdjustment = syncAdjustment
    }

    var effectiveStartTime: Double {
        let sourceStartTime = max(0, startTime)
        return sourceStartTime + max(0, -signedTimelineOffset)
    }

    var effectiveTimelineOffset: Double {
        max(0, signedTimelineOffset)
    }

    private var signedTimelineOffset: Double {
        timelineOffset + max(0, -startTime) + syncAdjustment
    }
}
