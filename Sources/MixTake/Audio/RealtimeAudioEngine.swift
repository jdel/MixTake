import Accelerate
import AudioToolbox
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

enum RealtimeAudioError: LocalizedError {
    case cannotSelectOutput
    case cannotCreateBuffer

    var errorDescription: String? {
        switch self {
        case .cannotSelectOutput:
            return "MixTake could not use the selected audio output."
        case .cannotCreateBuffer:
            return "MixTake could not allocate a real-time audio buffer."
        }
    }
}

final class RealtimeAudioEngine {
    private final class RetiredEffects {
        private var effects: [AVAudioUnit]

        init(_ effects: [AVAudioUnit]) {
            self.effects = effects
        }

        func release() {
            guard !effects.isEmpty else { return }
            if Thread.isMainThread {
                effects.removeAll()
            } else {
                DispatchQueue.main.sync {
                    self.effects.removeAll()
                }
            }
        }
    }

    private final class Route {
        let target: AudioEffectTarget
        let sourceMixer: AVAudioMixerNode
        let fader: AVAudioMixerNode
        let effects: [AVAudioUnit]
        let livePlayer: AVAudioPlayerNode?
        let filePlayer: AVAudioPlayerNode?
        let file: AVAudioFile?
        let initialVolume: Float

        init(
            target: AudioEffectTarget,
            sourceMixer: AVAudioMixerNode,
            fader: AVAudioMixerNode,
            effects: [AVAudioUnit],
            livePlayer: AVAudioPlayerNode?,
            filePlayer: AVAudioPlayerNode?,
            file: AVAudioFile?,
            initialVolume: Float
        ) {
            self.target = target
            self.sourceMixer = sourceMixer
            self.fader = fader
            self.effects = effects
            self.livePlayer = livePlayer
            self.filePlayer = filePlayer
            self.file = file
            self.initialVolume = initialVolume
        }
    }

    private struct Configuration {
        let monitoredChannels: Set<Int>
        let volumes: [Int: Float]
        let backingTrackVolume: Float
        let effects: [AudioEffectTarget: [AVAudioUnit]]
        let take: RecordingTake?
        let backingTrackURL: URL?
        let outputDeviceID: AudioDeviceID?
    }

    enum BackingTrackPlaybackMode: Equatable {
        case preview
        case recording
    }

    var onPeak: ((Float) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onBackingTrackPosition: ((Double) -> Void)?
    var onBackingTrackEnded: ((BackingTrackPlaybackMode) -> Void)?

    private let queue = DispatchQueue(
        label: "MixTake.audio.realtime",
        qos: .userInitiated
    )
    private var configuration: Configuration?
    private var engine: AVAudioEngine?
    private var routes: [AudioEffectTarget: Route] = [:]
    private var liveSampleRate = 48_000.0
    private var failed = false
    private var backingTrackStartTime = 0.0
    private var backingTrackPlaybackToken = UUID()
    private var backingTrackTimer: DispatchSourceTimer?

    func configure(
        monitoredChannels: Set<Int>,
        volumes: [Int: Float],
        backingTrackVolume: Float,
        effects: [AudioEffectTarget: [AVAudioUnit]],
        take: RecordingTake?,
        backingTrackURL: URL?,
        outputDeviceID: AudioDeviceID?,
        completion: ((Error?) -> Void)? = nil
    ) {
        let configuration = Configuration(
            monitoredChannels: monitoredChannels,
            volumes: volumes,
            backingTrackVolume: backingTrackVolume,
            effects: effects,
            take: take,
            backingTrackURL: backingTrackURL,
            outputDeviceID: outputDeviceID
        )
        queue.async { [weak self] in
            guard let self else { return }
            let retiredEffects = RetiredEffects(
                self.configuration?.effects.values.flatMap { $0 } ?? []
            )
            defer { retiredEffects.release() }
            self.configuration = configuration
            self.failed = false
            do {
                try self.rebuildGraph()
                if let completion {
                    DispatchQueue.main.async { completion(nil) }
                }
            } catch {
                self.failed = true
                self.tearDown()
                if let completion {
                    DispatchQueue.main.async { completion(error) }
                } else {
                    self.onFailure?(error)
                }
            }
        }
    }

    func consume(_ audio: ExtractedAudio) {
        queue.async { [weak self] in
            guard let self else { return }
            self.liveSampleRate = audio.sampleRate
            guard let configuration = self.configuration,
                  !configuration.monitoredChannels.isEmpty,
                  !self.failed else { return }
            do {
                if self.engine == nil {
                    try self.rebuildGraph()
                }
                try self.scheduleLiveAudio(audio)
            } catch {
                self.failed = true
                self.tearDown()
                self.onFailure?(error)
            }
        }
    }

    func setVolume(_ volume: Float, for target: AudioEffectTarget) {
        queue.async { [weak self] in
            self?.routes[target]?.fader.outputVolume = min(1, max(0, volume))
        }
    }

    func playTake(
        from seconds: Double,
        duration: Double,
        atHostTime hostTime: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, let take = self.configuration?.take else { return }
            self.stopFilePlayers()
            let remainingTakeDuration = duration - seconds
            guard remainingTakeDuration > 0 else { return }
            for (channel, _) in take.channelURLs {
                self.schedule(
                    target: .channel(channel),
                    sourceTime: max(0, seconds),
                    maximumDuration: remainingTakeDuration,
                    atHostTime: hostTime
                )
            }
            if let backingTrack = take.backingTrack {
                let offset = backingTrack.effectiveTimelineOffset
                let sourceTime: Double
                let delay: Double
                if seconds < offset {
                    sourceTime = backingTrack.effectiveStartTime
                    delay = offset - seconds
                } else {
                    sourceTime = backingTrack.effectiveStartTime + seconds - offset
                    delay = 0
                }
                schedule(
                    target: .backingTrack,
                    sourceTime: sourceTime,
                    maximumDuration: duration - max(seconds, offset),
                    atHostTime: hostTime,
                    after: delay
                )
            }
        }
    }

    func stopTake() {
        queue.async { [weak self] in
            self?.stopFilePlayers()
        }
    }

    func playBackingTrack(
        from seconds: Double,
        mode: BackingTrackPlaybackMode,
        atHostTime hostTime: UInt64,
        after delay: Double = 0
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopFilePlayers()
            guard let route = self.routes[.backingTrack],
                  let player = route.filePlayer,
                  let file = route.file else { return }

            let startFrame = AVAudioFramePosition(
                max(0, seconds) * file.processingFormat.sampleRate
            )
            guard startFrame < file.length else {
                self.onBackingTrackEnded?(mode)
                return
            }
            let token = UUID()
            self.backingTrackPlaybackToken = token
            self.backingTrackStartTime = max(0, seconds)
            let frameCount = AVAudioFrameCount(
                min(AVAudioFramePosition(UInt32.max), file.length - startFrame)
            )
            player.scheduleSegment(
                file,
                startingFrame: startFrame,
                frameCount: frameCount,
                at: nil,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self, self.backingTrackPlaybackToken == token else { return }
                    self.stopBackingTrackTimer()
                    self.onBackingTrackEnded?(mode)
                }
            }
            player.play(at: AVAudioTime(hostTime: Self.adding(seconds: delay, to: hostTime)))
            if mode == .preview {
                self.startBackingTrackTimer(player: player, file: file, token: token)
            }
        }
    }

    func stopBackingTrack() {
        queue.async { [weak self] in
            guard let self else { return }
            self.backingTrackPlaybackToken = UUID()
            self.routes[.backingTrack]?.filePlayer?.stop()
            self.stopBackingTrackTimer()
        }
    }

    private func rebuildGraph() throws {
        tearDown()
        guard let configuration else { return }

        var channelTargets = configuration.monitoredChannels
        if let take = configuration.take {
            channelTargets.formUnion(take.channelURLs.keys)
        }
        let hasBackingTrack = configuration.backingTrackURL != nil ||
            configuration.take?.backingTrack != nil
        guard !channelTargets.isEmpty || hasBackingTrack else {
            onPeak?(0)
            return
        }

        let engine = AVAudioEngine()
        if var outputDeviceID = configuration.outputDeviceID,
           let outputUnit = engine.outputNode.audioUnit {
            let status = AudioUnitSetProperty(
                outputUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &outputDeviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw RealtimeAudioError.cannotSelectOutput }
        }

        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let outputSampleRate = outputFormat.sampleRate > 0
            ? outputFormat.sampleRate
            : liveSampleRate
        guard let stereoFormat = AVAudioFormat(
            standardFormatWithSampleRate: outputSampleRate,
            channels: 2
        ), let liveFormat = AVAudioFormat(
            standardFormatWithSampleRate: liveSampleRate,
            channels: 1
        ) else {
            throw RealtimeAudioError.cannotCreateBuffer
        }

        var routes: [AudioEffectTarget: Route] = [:]
        var mainMixerBus: AVAudioNodeBus = 0
        for channel in channelTargets.sorted() {
            let target = AudioEffectTarget.channel(channel)
            let fileURL = configuration.take?.channelURLs[channel]
            let route = try makeRoute(
                target: target,
                live: configuration.monitoredChannels.contains(channel),
                fileURL: fileURL,
                volume: configuration.volumes[channel] ?? 1,
                effects: configuration.effects[target] ?? [],
                liveFormat: liveFormat,
                stereoFormat: stereoFormat,
                engine: engine,
                mainMixerBus: mainMixerBus
            )
            routes[target] = route
            mainMixerBus += 1
        }

        if hasBackingTrack {
            let target = AudioEffectTarget.backingTrack
            let fileURL = configuration.backingTrackURL ??
                configuration.take?.backingTrack?.sourceURL
            let route = try makeRoute(
                target: target,
                live: false,
                fileURL: fileURL,
                volume: configuration.backingTrackVolume,
                effects: configuration.effects[target] ?? [],
                liveFormat: liveFormat,
                stereoFormat: stereoFormat,
                engine: engine,
                mainMixerBus: mainMixerBus
            )
            routes[target] = route
        }

        engine.mainMixerNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: nil
        ) { [weak self] buffer, _ in
            guard let self, let channelData = buffer.floatChannelData else { return }
            var peak: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                var channelPeak: Float = 0
                vDSP_maxmgv(
                    channelData[channel],
                    1,
                    &channelPeak,
                    vDSP_Length(buffer.frameLength)
                )
                peak = max(peak, channelPeak)
            }
            self.onPeak?(peak)
        }

        engine.prepare()
        try engine.start()
        routes.values.forEach { route in
            route.fader.outputVolume = route.initialVolume
        }
        self.engine = engine
        self.routes = routes
    }

    private func makeRoute(
        target: AudioEffectTarget,
        live: Bool,
        fileURL: URL?,
        volume: Float,
        effects: [AVAudioUnit],
        liveFormat: AVAudioFormat,
        stereoFormat: AVAudioFormat,
        engine: AVAudioEngine,
        mainMixerBus: AVAudioNodeBus
    ) throws -> Route {
        let sourceMixer = AVAudioMixerNode()
        let fader = AVAudioMixerNode()
        engine.attach(sourceMixer)
        engine.attach(fader)

        var sourceBus: AVAudioNodeBus = 0
        var livePlayer: AVAudioPlayerNode?
        if live {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(
                player,
                to: sourceMixer,
                fromBus: 0,
                toBus: sourceBus,
                format: liveFormat
            )
            sourceBus += 1
            livePlayer = player
        }

        var filePlayer: AVAudioPlayerNode?
        var file: AVAudioFile?
        if let fileURL {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(
                player,
                to: sourceMixer,
                fromBus: 0,
                toBus: sourceBus,
                format: audioFile.processingFormat
            )
            filePlayer = player
            file = audioFile
        }

        var previousNode: AVAudioNode = sourceMixer
        for effect in effects {
            engine.attach(effect)
            engine.connect(previousNode, to: effect, format: stereoFormat)
            previousNode = effect
        }
        engine.connect(previousNode, to: fader, format: stereoFormat)
        engine.connect(
            fader,
            to: engine.mainMixerNode,
            fromBus: 0,
            toBus: mainMixerBus,
            format: stereoFormat
        )

        return Route(
            target: target,
            sourceMixer: sourceMixer,
            fader: fader,
            effects: effects,
            livePlayer: livePlayer,
            filePlayer: filePlayer,
            file: file,
            initialVolume: min(1, max(0, volume))
        )
    }

    private func scheduleLiveAudio(_ audio: ExtractedAudio) throws {
        for channel in configuration?.monitoredChannels.sorted() ?? [] {
            guard audio.channels.indices.contains(channel),
                  let player = routes[.channel(channel)]?.livePlayer else { continue }
            let samples = audio.channels[channel]
            guard !samples.isEmpty,
                  let format = AVAudioFormat(
                    standardFormatWithSampleRate: audio.sampleRate,
                    channels: 1
                  ),
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(samples.count)
                  ),
                  let destination = buffer.floatChannelData?[0] else {
                throw RealtimeAudioError.cannotCreateBuffer
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                destination.update(from: source.baseAddress!, count: samples.count)
            }
            player.scheduleBuffer(buffer, completionHandler: nil)
            if !player.isPlaying {
                player.play()
            }
        }
    }

    private func schedule(
        target: AudioEffectTarget,
        sourceTime: Double,
        maximumDuration: Double,
        atHostTime hostTime: UInt64,
        after delay: Double = 0
    ) {
        guard let route = routes[target],
              let player = route.filePlayer,
              let file = route.file,
              maximumDuration.isFinite,
              maximumDuration > 0 else { return }
        let startFrame = AVAudioFramePosition(
            max(0, sourceTime) * file.processingFormat.sampleRate
        )
        guard startFrame < file.length else { return }
        let maximumFrames = AVAudioFramePosition(
            maximumDuration * file.processingFormat.sampleRate
        )
        let frameCount = AVAudioFrameCount(
            min(
                AVAudioFramePosition(UInt32.max),
                min(file.length - startFrame, maximumFrames)
            )
        )
        guard frameCount > 0 else { return }
        let silenceFrameCount = AVAudioFrameCount(
            min(
                Double(UInt32.max),
                max(0, delay) * file.processingFormat.sampleRate
            )
        )
        if silenceFrameCount > 0,
           let silence = AVAudioPCMBuffer(
               pcmFormat: file.processingFormat,
               frameCapacity: silenceFrameCount
           ) {
            silence.frameLength = silenceFrameCount
            for buffer in UnsafeMutableAudioBufferListPointer(
                silence.mutableAudioBufferList
            ) {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            player.scheduleBuffer(silence)
        }
        player.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil,
            completionHandler: nil
        )
        player.play(at: AVAudioTime(hostTime: hostTime))
    }

    private func stopFilePlayers() {
        backingTrackPlaybackToken = UUID()
        stopBackingTrackTimer()
        routes.values.forEach { $0.filePlayer?.stop() }
    }

    private func startBackingTrackTimer(
        player: AVAudioPlayerNode,
        file: AVAudioFile,
        token: UUID
    ) {
        stopBackingTrackTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self, weak player] in
            guard let self,
                  let player,
                  self.backingTrackPlaybackToken == token,
                  let nodeTime = player.lastRenderTime,
                  let playerTime = player.playerTime(forNodeTime: nodeTime) else { return }
            let seconds = self.backingTrackStartTime +
                Double(playerTime.sampleTime) / file.processingFormat.sampleRate
            self.onBackingTrackPosition?(seconds)
        }
        backingTrackTimer = timer
        timer.resume()
    }

    private func stopBackingTrackTimer() {
        backingTrackTimer?.cancel()
        backingTrackTimer = nil
    }

    private func tearDown() {
        let retiredEffects = RetiredEffects(
            routes.values.flatMap { $0.effects }
        )
        stopFilePlayers()
        engine?.stop()
        engine?.mainMixerNode.removeTap(onBus: 0)
        routes.values.forEach { route in
            route.livePlayer?.stop()
            route.filePlayer?.stop()
            if let engine {
                if let livePlayer = route.livePlayer { engine.detach(livePlayer) }
                if let filePlayer = route.filePlayer { engine.detach(filePlayer) }
                engine.detach(route.sourceMixer)
                engine.detach(route.fader)
                route.effects.forEach { engine.detach($0) }
            }
        }
        routes = [:]
        engine = nil
        retiredEffects.release()
        onPeak?(0)
    }

    private static func adding(seconds: Double, to hostTime: UInt64) -> UInt64 {
        hostTime + AudioConvertNanosToHostTime(UInt64(max(0, seconds) * 1_000_000_000))
    }
}
