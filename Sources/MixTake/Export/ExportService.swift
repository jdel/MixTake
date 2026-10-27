import AVFoundation
import Foundation

enum ExportError: LocalizedError {
    case missingVideoTrack
    case cannotCreateExporter
    case exportFailed(String)
    case noAudioTracks

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            return "The recording does not contain a video track."
        case .cannotCreateExporter:
            return "AVFoundation could not create the requested exporter."
        case .exportFailed(let message):
            return "Export failed: \(message)"
        case .noAudioTracks:
            return "The recording does not contain any enabled audio tracks."
        }
    }
}

enum ExportService {
    typealias ProgressHandler = (Double) -> Void

    private struct OfflineMixSource {
        let url: URL
        let startTime: Double
        let timelineOffset: Double
        let volume: Float
        let effects: [AudioEffectConfiguration]
    }

    static func exportTracks(
        _ take: RecordingTake,
        effects: AudioEffectChains,
        to destination: URL,
        progress: @escaping ProgressHandler
    ) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let itemCount = 1 + take.channelURLs.count + (take.backingTrack == nil ? 0 : 1)
        var completedItems = 0
        progress(0)
        try copyReplacing(take.videoURL, to: destination.appendingPathComponent("video.mp4"))
        completedItems += 1
        progress(Double(completedItems) / Double(itemCount))
        let videoAsset = AVURLAsset(url: take.videoURL)
        for (channel, source) in take.channelURLs.sorted(by: { $0.key < $1.key }) {
            let filename = String(format: "channel-%02d.wav", channel + 1)
            let outputURL = destination.appendingPathComponent(filename)
            if let channelEffects = effects[.channel(channel)], !channelEffects.isEmpty {
                try await renderStereoMix(
                    [
                        OfflineMixSource(
                            url: source,
                            startTime: 0,
                            timelineOffset: 0,
                            volume: 1,
                            effects: channelEffects
                        )
                    ],
                    duration: try await videoAsset.load(.duration).seconds,
                    destination: outputURL,
                    progress: scaledProgress(
                        progress,
                        from: Double(completedItems) / Double(itemCount),
                        to: Double(completedItems + 1) / Double(itemCount)
                    )
                )
            } else {
                try copyReplacing(source, to: outputURL)
            }
            completedItems += 1
            progress(Double(completedItems) / Double(itemCount))
        }
        if let backingTrack = take.backingTrack {
            let outputURL = destination.appendingPathComponent("backing-track.wav")
            let backingProgress = scaledProgress(
                progress,
                from: Double(completedItems) / Double(itemCount),
                to: 1
            )
            if let backingEffects = effects[.backingTrack], !backingEffects.isEmpty {
                try await renderStereoMix(
                    [
                        OfflineMixSource(
                            url: backingTrack.sourceURL,
                            startTime: backingTrack.effectiveStartTime,
                            timelineOffset: backingTrack.effectiveTimelineOffset,
                            volume: 1,
                            effects: backingEffects
                        )
                    ],
                    duration: try await videoAsset.load(.duration).seconds,
                    destination: outputURL,
                    progress: backingProgress
                )
            } else {
                try await exportBackingTrack(
                    backingTrack,
                    videoURL: take.videoURL,
                    destination: outputURL,
                    progress: backingProgress
                )
            }
        }
        progress(1)
    }

    static func exportMix(
        _ take: RecordingTake,
        volumes: [Int: Float],
        backingTrackVolume: Float,
        effects: AudioEffectChains,
        to destination: URL,
        progress: @escaping ProgressHandler
    ) async throws {
        guard !take.channelURLs.isEmpty || take.backingTrack != nil else {
            throw ExportError.noAudioTracks
        }
        let workDirectory = try createExportDirectory(near: destination)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        progress(0)
        let audioURL = workDirectory.appendingPathComponent("mix.m4a")
        try await encodeMixedAAC(
            take,
            volumes: volumes,
            backingTrackVolume: backingTrackVolume,
            effects: effects,
            destination: audioURL,
            progress: scaledProgress(progress, from: 0, to: 0.65)
        )
        let completedURL = workDirectory.appendingPathComponent("completed.mp4")
        try await mux(
            video: take.videoURL,
            audio: audioURL,
            destination: completedURL,
            progress: scaledProgress(progress, from: 0.65, to: 0.98)
        )
        try installCompletedFile(completedURL, at: destination)
        progress(1)
    }

    static func exportAudio(
        _ take: RecordingTake,
        volumes: [Int: Float],
        backingTrackVolume: Float,
        effects: AudioEffectChains,
        to destination: URL,
        progress: @escaping ProgressHandler
    ) async throws {
        guard !take.channelURLs.isEmpty || take.backingTrack != nil else {
            throw ExportError.noAudioTracks
        }
        let workDirectory = try createExportDirectory(near: destination)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        progress(0)
        let audioURL = workDirectory.appendingPathComponent("mix.m4a")
        try await encodeMixedAAC(
            take,
            volumes: volumes,
            backingTrackVolume: backingTrackVolume,
            effects: effects,
            destination: audioURL,
            progress: scaledProgress(progress, from: 0, to: 0.98)
        )
        try installCompletedFile(audioURL, at: destination)
        progress(1)
    }

    private static func encodeMixedAAC(
        _ take: RecordingTake,
        volumes: [Int: Float],
        backingTrackVolume: Float,
        effects: AudioEffectChains,
        destination: URL,
        progress: @escaping ProgressHandler
    ) async throws {
        let videoAsset = AVURLAsset(url: take.videoURL)
        let videoDuration = try await videoAsset.load(.duration).seconds
        var sources = take.channelURLs.sorted(by: { $0.key < $1.key }).map { channel, url in
            OfflineMixSource(
                url: url,
                startTime: 0,
                timelineOffset: 0,
                volume: volumes[channel] ?? 1,
                effects: effects[.channel(channel)] ?? []
            )
        }
        if let backingTrack = take.backingTrack {
            sources.append(
                OfflineMixSource(
                    url: backingTrack.sourceURL,
                    startTime: backingTrack.effectiveStartTime,
                    timelineOffset: backingTrack.effectiveTimelineOffset,
                    volume: backingTrackVolume,
                    effects: effects[.backingTrack] ?? []
                )
            )
        }

        guard !sources.isEmpty else { throw ExportError.noAudioTracks }
        let pcmURL = destination.deletingPathExtension().appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        try await renderStereoMix(
            sources,
            duration: videoDuration,
            destination: pcmURL,
            progress: scaledProgress(progress, from: 0, to: 0.55)
        )
        try await encodeAAC(
            source: pcmURL,
            destination: destination,
            progress: scaledProgress(progress, from: 0.55, to: 1)
        )
    }

    private static func encodeAAC(
        source: URL,
        destination: URL,
        progress: @escaping ProgressHandler
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else { throw ExportError.cannotCreateExporter }
        try? FileManager.default.removeItem(at: destination)
        try await run(
            exporter,
            to: destination,
            as: .m4a,
            progress: progress
        )
    }

    private static func renderStereoMix(
        _ sources: [OfflineMixSource],
        duration: Double,
        destination: URL,
        progress: ProgressHandler
    ) async throws {
        guard duration.isFinite, duration > 0,
              let stereoFormat = AVAudioFormat(
                standardFormatWithSampleRate: 48_000,
                channels: 2
              ) else {
            throw ExportError.exportFailed("invalid recording duration")
        }

        try? FileManager.default.removeItem(at: destination)
        let engine = AVAudioEngine()
        var scheduled: [(player: AVAudioPlayerNode, file: AVAudioFile)] = []
        for source in sources {
            let file = try AVAudioFile(forReading: source.url)
            let timelineOffset = max(0, source.timelineOffset)
            let availableDuration = max(0, duration - timelineOffset)
            guard availableDuration > 0 else { continue }
            let startFrame = min(
                AVAudioFramePosition(max(0, source.startTime * file.processingFormat.sampleRate)),
                file.length
            )
            let requestedFrames = AVAudioFramePosition(
                (availableDuration * file.processingFormat.sampleRate).rounded(.up)
            )
            let availableFrames = min(file.length - startFrame, requestedFrames)
            guard availableFrames > 0 else { continue }
            guard availableFrames <= AVAudioFramePosition(UInt32.max) else {
                throw ExportError.exportFailed("audio source is too long to mix")
            }

            let player = AVAudioPlayerNode()
            engine.attach(player)
            if !source.effects.isEmpty {
                var instantiatedEffects: [AVAudioUnit] = []
                for configuration in source.effects {
                    instantiatedEffects.append(try await configuration.instantiate())
                }
                let inputMixer = AVAudioMixerNode()
                let outputMixer = AVAudioMixerNode()
                outputMixer.outputVolume = min(1, max(0, source.volume))
                engine.attach(inputMixer)
                engine.attach(outputMixer)
                engine.connect(player, to: inputMixer, format: file.processingFormat)
                var previousNode: AVAudioNode = inputMixer
                for effect in instantiatedEffects {
                    engine.attach(effect)
                    engine.connect(previousNode, to: effect, format: stereoFormat)
                    previousNode = effect
                }
                engine.connect(previousNode, to: outputMixer, format: stereoFormat)
                engine.connect(outputMixer, to: engine.mainMixerNode, format: stereoFormat)
            } else {
                player.volume = min(1, max(0, source.volume))
                engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            }
            player.scheduleSegment(
                file,
                startingFrame: startFrame,
                frameCount: AVAudioFrameCount(availableFrames),
                at: AVAudioTime(
                    sampleTime: AVAudioFramePosition(
                        (timelineOffset * file.processingFormat.sampleRate).rounded()
                    ),
                    atRate: file.processingFormat.sampleRate
                ),
                completionCallbackType: .dataConsumed,
                completionHandler: nil
            )
            scheduled.append((player, file))
        }
        guard !scheduled.isEmpty else { throw ExportError.noAudioTracks }

        let maximumFrameCount: AVAudioFrameCount = 4_096
        try engine.enableManualRenderingMode(
            .offline,
            format: stereoFormat,
            maximumFrameCount: maximumFrameCount
        )
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: stereoFormat.sampleRate,
            AVNumberOfChannelsKey: Int(stereoFormat.channelCount),
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = try AVAudioFile(
            forWriting: destination,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: maximumFrameCount
        ) else {
            throw ExportError.exportFailed("could not allocate an audio mixing buffer")
        }

        engine.prepare()
        try engine.start()
        scheduled.forEach { $0.player.play() }
        defer {
            scheduled.forEach { $0.player.stop() }
            engine.stop()
        }

        let targetFrames = AVAudioFramePosition(
            (duration * stereoFormat.sampleRate).rounded(.up)
        )
        progress(0)
        var lastReportedProgress = 0.0
        var retryCount = 0
        while engine.manualRenderingSampleTime < targetFrames {
            let remaining = targetFrames - engine.manualRenderingSampleTime
            let frames = AVAudioFrameCount(
                min(AVAudioFramePosition(maximumFrameCount), remaining)
            )
            switch try engine.renderOffline(frames, to: buffer) {
            case .success:
                try output.write(from: buffer)
                retryCount = 0
                let currentProgress = min(
                    1,
                    Double(engine.manualRenderingSampleTime) / Double(targetFrames)
                )
                if currentProgress - lastReportedProgress >= 0.01 {
                    progress(currentProgress)
                    lastReportedProgress = currentProgress
                }
            case .cannotDoInCurrentContext:
                retryCount += 1
                if retryCount > 100 {
                    throw ExportError.exportFailed("audio mixer repeatedly could not render")
                }
            case .insufficientDataFromInputNode:
                throw ExportError.exportFailed("audio mixer ran out of input data")
            case .error:
                throw ExportError.exportFailed("offline audio mixing failed")
            @unknown default:
                throw ExportError.exportFailed("offline audio mixing returned an unknown state")
            }
        }
        progress(1)
    }

    private static func mux(
        video: URL,
        audio: URL,
        destination: URL,
        progress: @escaping ProgressHandler
    ) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
              let destinationVideo = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else { throw ExportError.missingVideoTrack }
        let videoDuration = try await videoAsset.load(.duration)
        try destinationVideo.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: sourceVideo,
            at: .zero
        )
        destinationVideo.preferredTransform = try await sourceVideo.load(.preferredTransform)

        if let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let destinationAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let audioDuration = try await audioAsset.load(.duration)
            try destinationAudio.insertTimeRange(
                CMTimeRange(
                    start: .zero,
                    duration: CMTimeMinimum(videoDuration, audioDuration)
                ),
                of: sourceAudio,
                at: .zero
            )
        }

        try? FileManager.default.removeItem(at: destination)
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else { throw ExportError.cannotCreateExporter }
        exporter.shouldOptimizeForNetworkUse = true
        try await run(
            exporter,
            to: destination,
            as: .mp4,
            progress: progress
        )
    }

    private static func run(
        _ exporter: AVAssetExportSession,
        to destination: URL,
        as fileType: AVFileType,
        progress: @escaping ProgressHandler
    ) async throws {
        progress(0)
        let states = exporter.states(updateInterval: 0.1)
        let progressMonitor = Task {
            for await state in states {
                guard !Task.isCancelled else { return }
                if case .exporting(let exportProgress) = state {
                    progress(exportProgress.fractionCompleted)
                }
            }
        }
        defer { progressMonitor.cancel() }
        try await exporter.export(to: destination, as: fileType)
        progressMonitor.cancel()
        await progressMonitor.value
        progress(1)
    }

    private static func copyReplacing(_ source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private static func installCompletedFile(_ source: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: source)
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    private static func createExportDirectory(near destination: URL) throws -> URL {
        let directory = destination.deletingLastPathComponent().appendingPathComponent(
            ".MixTake-export-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

    private static func scaledProgress(
        _ progress: @escaping ProgressHandler,
        from start: Double,
        to end: Double
    ) -> ProgressHandler {
        { value in
            progress(start + min(1, max(0, value)) * (end - start))
        }
    }

    private static func exportBackingTrack(
        _ backingTrack: BackingTrackReference,
        videoURL: URL,
        destination: URL,
        progress: ProgressHandler
    ) async throws {
        let source = try AVAudioFile(forReading: backingTrack.sourceURL)
        let format = source.processingFormat
        let startFrame = AVAudioFramePosition(
            max(0, backingTrack.effectiveStartTime * format.sampleRate)
        )
        source.framePosition = min(startFrame, source.length)

        let videoAsset = AVURLAsset(url: videoURL)
        let videoDuration = try await videoAsset.load(.duration).seconds
        let targetFrames = AVAudioFramePosition(max(0, videoDuration * format.sampleRate))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = try AVAudioFile(
            forWriting: destination,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let leadingFrames = min(
            targetFrames,
            AVAudioFramePosition(
                backingTrack.effectiveTimelineOffset * format.sampleRate
            )
        )
        if leadingFrames > 0 {
            try writeSilence(frames: AVAudioFrameCount(leadingFrames), to: output)
        }
        var written = leadingFrames
        progress(targetFrames == 0 ? 1 : Double(written) / Double(targetFrames))
        var lastReportedProgress = targetFrames == 0 ? 1 : Double(written) / Double(targetFrames)
        while written < targetFrames {
            let count = AVAudioFrameCount(min(8_192, targetFrames - written))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: count
            ) else { break }
            try source.read(into: buffer, frameCount: count)
            if buffer.frameLength > 0 {
                try output.write(from: buffer)
                written += AVAudioFramePosition(buffer.frameLength)
            }
            if buffer.frameLength < count {
                let missing = AVAudioFrameCount(
                    min(AVAudioFramePosition(count - buffer.frameLength), targetFrames - written)
                )
                try writeSilence(frames: missing, to: output)
                written += AVAudioFramePosition(missing)
            }
            let currentProgress = Double(written) / Double(targetFrames)
            if currentProgress - lastReportedProgress >= 0.01 {
                progress(currentProgress)
                lastReportedProgress = currentProgress
            }
        }
        progress(1)
    }

    private static func writeSilence(
        frames: AVAudioFrameCount,
        to file: AVAudioFile
    ) throws {
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: frames
              ) else { return }
        buffer.frameLength = frames
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                channels[channel].initialize(repeating: 0, count: Int(frames))
            }
        }
        try file.write(from: buffer)
    }

}
