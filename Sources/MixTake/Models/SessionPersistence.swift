import AudioToolbox
import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let mixTakeSession = UTType(
        exportedAs: "org.jdel.mixtake.session",
        conformingTo: .package
    )

    static let mixTakeChannelPreset = UTType(
        exportedAs: "org.jdel.mixtake.channel-preset",
        conformingTo: .data
    )
}

struct PersistedAudioEffect: Codable {
    let name: String
    let componentType: UInt32
    let componentSubType: UInt32
    let componentManufacturer: UInt32
    let componentFlags: UInt32
    let componentFlagsMask: UInt32
    let state: Data?
    let isDocumentState: Bool

    init(configuration: AudioEffectConfiguration) throws {
        name = configuration.name
        let description = configuration.componentDescription
        componentType = description.componentType
        componentSubType = description.componentSubType
        componentManufacturer = description.componentManufacturer
        componentFlags = description.componentFlags
        componentFlagsMask = description.componentFlagsMask
        isDocumentState = configuration.isDocumentState
        if let fullState = configuration.fullState {
            state = try PropertyListSerialization.data(
                fromPropertyList: fullState,
                format: .binary,
                options: 0
            )
        } else {
            state = nil
        }
    }

    func configuration() throws -> AudioEffectConfiguration {
        let fullState: [String: Any]?
        if let state {
            fullState = try PropertyListSerialization.propertyList(
                from: state,
                options: [],
                format: nil
            ) as? [String: Any]
        } else {
            fullState = nil
        }
        return AudioEffectConfiguration(
            name: name,
            componentDescription: AudioComponentDescription(
                componentType: componentType,
                componentSubType: componentSubType,
                componentManufacturer: componentManufacturer,
                componentFlags: componentFlags,
                componentFlagsMask: componentFlagsMask
            ),
            fullState: fullState,
            isDocumentState: isDocumentState
        )
    }
}

struct SessionManifest: Codable {
    static let currentVersion = 1

    struct Channel: Codable {
        let index: Int
        let fileName: String
        let volume: Float
        let inputGainDecibels: Float?
        let isMonitored: Bool
    }

    struct BackingTrack: Codable {
        let fileName: String
        let startTime: Double
        let timelineOffset: Double
        let syncAdjustment: Double
        let volume: Float
    }

    struct EffectChain: Codable {
        let channel: Int?
        let isBackingTrack: Bool
        let effects: [PersistedAudioEffect]
    }

    let version: Int
    let startedAt: Date
    let videoFileName: String
    let audioInterfaceID: String?
    let audioInterfaceDeviceID: String?
    let channels: [Channel]
    let backingTrack: BackingTrack?
    let effectChains: [EffectChain]
    let playbackPosition: Double
}

enum SessionStore {
    static let manifestName = "Session.plist"

    static func read(from packageURL: URL) throws -> SessionManifest {
        let data = try Data(contentsOf: packageURL.appendingPathComponent(manifestName))
        let manifest = try PropertyListDecoder().decode(SessionManifest.self, from: data)
        guard manifest.version == SessionManifest.currentVersion else {
            throw SessionStoreError.unsupportedVersion(manifest.version)
        }
        let mediaNames = [manifest.videoFileName]
            + manifest.channels.map(\.fileName)
            + [manifest.backingTrack?.fileName].compactMap { $0 }
        for name in mediaNames {
            try validateMediaName(name)
        }
        return manifest
    }

    private static func validateMediaName(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              URL(fileURLWithPath: name).lastPathComponent == name else {
            throw SessionStoreError.invalidMediaPath(name)
        }
    }

    static func write(_ manifest: SessionManifest, to packageURL: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(manifest)
        try data.write(
            to: packageURL.appendingPathComponent(manifestName),
            options: .atomic
        )
    }
}

enum SessionStoreError: LocalizedError {
    case unsupportedVersion(Int)
    case missingMedia(String)
    case invalidMediaPath(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "This MixTake session uses unsupported format version \(version)."
        case .missingMedia(let name):
            return "The session is missing \(name)."
        case .invalidMediaPath(let name):
            return "The session contains an invalid media path: \(name)."
        }
    }
}

struct ChannelStripPreset: Codable, Identifiable {
    let id: UUID
    var name: String
    let volume: Float
    let inputGainDecibels: Float?
    let isMonitored: Bool
    let effects: [PersistedAudioEffect]
}

enum ChannelPresetStore {
    static func load(from url: URL) throws -> ChannelStripPreset {
        let data = try Data(contentsOf: url)
        return try PropertyListDecoder().decode(ChannelStripPreset.self, from: data)
    }

    static func save(_ preset: ChannelStripPreset, to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(preset).write(to: url, options: .atomic)
    }
}
