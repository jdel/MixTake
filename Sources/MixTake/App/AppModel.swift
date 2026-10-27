import AppKit
import AudioToolbox
import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: NSObject, ObservableObject {
    static let shared = AppModel()
    static let lowMonitoringBufferThreshold = 64
    static let highMonitoringBufferThreshold = 1_024

    enum State: Equatable {
        case empty
        case recording
        case finalizing
        case ready
        case exporting
    }

    private enum AfterStop {
        case keep
        case clear
        case retake
    }

    let captureEngine = CaptureEngine()
    let playback = PlaybackController()
    let backingTrack = BackingTrackController()
    let audioEffects = AudioEffectManager()
    let realtimeAudio = RealtimeAudioEngine()
    let meterLevels = MeterLevels()
    let outputMeter = OutputMeter()

    @Published private(set) var state: State = .empty
    @Published private(set) var cameras: [CameraDevice] = []
    @Published private(set) var audioInterfaces: [AudioInterface] = []
    @Published private(set) var audioOutputs: [AudioOutputDevice] = []
    @Published var selectedCameraID: String?
    @Published var selectedAudioInterfaceID: String?
    @Published var selectedAudioOutputID: String?
    @Published private(set) var enabledChannels = Set<Int>()
    @Published var mixerChannels: [MixerChannel] = []
    @Published var currentTake: RecordingTake?
    @Published var errorMessage: String?
    @Published private(set) var hasExportedCurrentTake = false
    @Published private(set) var exportProgress = 0.0
    @Published private(set) var monitoredChannels = Set<Int>()
    @Published private(set) var monitoringBufferFrames = 128
    @Published private(set) var currentSessionURL: URL?
    @Published private(set) var sessionHasUnsavedChanges = false

    private let defaults = UserDefaults.standard
    private var afterStop: AfterStop = .keep
    private var keyboardMonitor: Any?
    private var needsDeviceRefresh = false
    private var recordingBackingTrack: BackingTrackReference?
    private var audioGraphGeneration = 0

    var selectedAudioInterface: AudioInterface? {
        audioInterfaces.first { $0.id == selectedAudioInterfaceID }
    }

    var selectedAudioOutput: AudioOutputDevice? {
        audioOutputs.first { $0.id == selectedAudioOutputID }
    }

    var hasUnexportedTake: Bool {
        state == .recording || state == .finalizing || state == .exporting ||
            (currentSessionURL != nil && sessionHasUnsavedChanges) ||
            (currentSessionURL == nil && currentTake != nil && !hasExportedCurrentTake)
    }

    var canSaveSession: Bool {
        state == .ready && currentTake != nil
    }

    var terminationWarning: String? {
        if state == .recording || state == .finalizing {
            return "The recording is still being finalized and will be deleted."
        }
        if currentSessionURL != nil, sessionHasUnsavedChanges {
            return "Changes to the current session have not been saved."
        }
        if currentSessionURL == nil, currentTake != nil, !hasExportedCurrentTake {
            return "This take has not been saved or exported and will be deleted."
        }
        if state == .exporting {
            return "The current export has not finished."
        }
        return nil
    }

    var canExport: Bool {
        state == .ready && currentTake != nil
    }

    var canEditBackingTrack: Bool {
        state == .empty || state == .ready
    }

    var canEditEffects: Bool {
        state == .empty || state == .ready
    }

    private override init() {
        super.init()
        CaptureEngine.removeStaleTemporaryRecordings()
        let savedBufferFrames = defaults.integer(forKey: "monitoringBufferFrames")
        if savedBufferFrames > 0, savedBufferFrames <= Int(UInt32.max) {
            monitoringBufferFrames = savedBufferFrames
        }
        captureEngine.delegate = self
        audioEffects.onEffectStateChanged = { [weak self] in
            self?.effectStateChanged()
        }
        playback.onTimeChanged = { [weak self] _ in
            guard let self,
                  !self.playback.isPlaying,
                  self.playback.duration > 0,
                  self.playback.currentTime >= self.playback.duration - 0.05 else { return }
            self.realtimeAudio.stopTake()
        }
        realtimeAudio.onPeak = { [weak self] peak in
            Task { @MainActor in
                self?.outputMeter.update(peak)
            }
        }
        realtimeAudio.onFailure = { [weak self] error in
            Task { @MainActor in
                self?.present(error)
            }
        }
        realtimeAudio.onBackingTrackPosition = { [weak self] seconds in
            Task { @MainActor in
                self?.backingTrack.updatePreviewPosition(seconds)
            }
        }
        realtimeAudio.onBackingTrackEnded = { [weak self] mode in
            Task { @MainActor in
                guard let self else { return }
                switch mode {
                case .preview:
                    self.backingTrack.updatePreviewPosition(
                        self.backingTrack.duration
                    )
                    self.backingTrack.stopPreview()
                case .recording:
                    self.stopRecording()
                }
            }
        }
        captureEngine.onAudioSamples = { [realtimeAudio] audio in
            realtimeAudio.consume(audio)
        }
        installDeviceObservers()
        discoverDevices()
        restoreDeviceSelections()
        Task { await requestCaptureAccessAndConfigure() }
    }

    func refreshDevices() {
        let previousCameraID = selectedCameraID
        let previousAudioID = selectedAudioInterfaceID
        let previousOutputID = selectedAudioOutputID
        let previousInputConfigurationID = selectedAudioInterface?.configurationID
        let previousInputCoreID = selectedAudioInterface?.coreAudioDeviceID
        let previousOutputCoreID = selectedAudioOutput?.coreAudioDeviceID
        discoverDevices()

        var captureChanged = false
        if cameras.contains(where: { $0.id == previousCameraID }) {
            selectedCameraID = previousCameraID
        } else {
            selectedCameraID = DeviceDiscovery.defaultCameraID(in: cameras)
            saveSelection(selectedCameraID, forKey: "selectedCameraID")
            captureChanged = true
        }

        if audioInterfaces.contains(where: { $0.id == previousAudioID }) {
            selectedAudioInterfaceID = previousAudioID
            if previousAudioID == AudioInterface.systemDefaultID,
               selectedAudioInterface?.configurationID != previousInputConfigurationID {
                loadChannelsForSelectedInterface(restoreMonitoring: true)
                captureChanged = true
            }
        } else {
            selectDefaultAudioInterface()
            loadChannelsForSelectedInterface(restoreMonitoring: true)
            captureChanged = true
        }

        if audioOutputs.contains(where: { $0.id == previousOutputID }) {
            selectedAudioOutputID = previousOutputID
        } else {
            selectDefaultAudioOutput()
        }

        let audioRouteChanged =
            selectedAudioInterface?.coreAudioDeviceID != previousInputCoreID ||
            selectedAudioOutput?.coreAudioDeviceID != previousOutputCoreID

        if captureChanged {
            configureCapture()
        }
        if audioRouteChanged {
            configureInputMonitoring()
        }
    }

    private func installDeviceObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(captureDevicesChanged),
            name: AVCaptureDevice.wasConnectedNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(captureDevicesChanged),
            name: AVCaptureDevice.wasDisconnectedNotification,
            object: nil
        )
    }

    @objc private func captureDevicesChanged(_ notification: Notification) {
        if state == .recording || state == .finalizing {
            needsDeviceRefresh = true
        } else {
            refreshDevices()
        }
    }

    private func applyPendingDeviceRefresh() {
        guard needsDeviceRefresh else { return }
        needsDeviceRefresh = false
        refreshDevices()
    }

    private func discoverDevices() {
        cameras = DeviceDiscovery.cameras()
        audioInterfaces = DeviceDiscovery.audioInterfaces()
        audioOutputs = DeviceDiscovery.audioOutputs()
    }

    private func restoreDeviceSelections() {
        let savedCamera = defaults.string(forKey: "selectedCameraID")
        selectedCameraID = cameras.contains(where: { $0.id == savedCamera })
            ? savedCamera
            : DeviceDiscovery.defaultCameraID(in: cameras)
        saveSelection(selectedCameraID, forKey: "selectedCameraID")

        let savedAudio = defaults.string(forKey: "selectedAudioInterfaceID")
        if audioInterfaces.isEmpty {
            selectedAudioInterfaceID = nil
        } else if audioInterfaces.contains(where: { $0.id == savedAudio }) {
            selectedAudioInterfaceID = savedAudio
        } else {
            selectDefaultAudioInterface()
        }
        saveSelection(selectedAudioInterfaceID, forKey: "selectedAudioInterfaceID")
        loadChannelsForSelectedInterface(restoreMonitoring: true)

        let savedOutput = defaults.string(forKey: "selectedAudioOutputID")
        if audioOutputs.contains(where: { $0.id == savedOutput }) {
            selectedAudioOutputID = savedOutput
        } else {
            selectDefaultAudioOutput()
        }
        saveSelection(selectedAudioOutputID, forKey: "selectedAudioOutputID")
        applyAudioOutput()
    }

    func selectCamera(_ id: String) {
        selectedCameraID = id
        defaults.set(id, forKey: "selectedCameraID")
        configureCapture()
    }

    func selectAudioInterface(_ id: String) {
        selectedAudioInterfaceID = id
        defaults.set(id, forKey: "selectedAudioInterfaceID")
        loadChannelsForSelectedInterface(restoreMonitoring: true)
        configureCapture()
        configureInputMonitoring()
        markSessionChanged()
    }

    func selectAudioOutput(_ id: String) {
        selectedAudioOutputID = id
        defaults.set(id, forKey: "selectedAudioOutputID")
        applyAudioOutput()
    }

    func setMonitoringBufferFrames(_ frameCount: Int) {
        guard frameCount > 0,
              frameCount <= Int(UInt32.max),
              frameCount != monitoringBufferFrames else { return }
        monitoringBufferFrames = frameCount
        defaults.set(frameCount, forKey: "monitoringBufferFrames")
        if !monitoredChannels.isEmpty {
            configureInputMonitoring()
        }
    }

    func setChannel(_ index: Int, enabled: Bool) {
        if enabled {
            enabledChannels.insert(index)
        } else {
            enabledChannels.remove(index)
        }
        if !enabled, monitoredChannels.contains(index) {
            var updated = monitoredChannels
            updated.remove(index)
            monitoredChannels = updated
            saveMonitoredChannels()
            configureInputMonitoring()
        }
        saveEnabledChannels()
        rebuildMixerChannels()
        markSessionChanged()
    }

    func setVolume(_ volume: Float, for channel: Int) {
        guard let index = mixerChannels.firstIndex(where: { $0.index == channel }) else { return }
        mixerChannels[index].volume = volume
        defaults.set(volume, forKey: volumeKey(channel))
        realtimeAudio.setVolume(volume, for: .channel(channel))
        markSessionChanged()
    }

    func setBackingTrackVolume(_ volume: Float) {
        backingTrack.setVolume(volume)
        realtimeAudio.setVolume(volume, for: .backingTrack)
        markSessionChanged()
    }

    func attachEffect(
        _ component: AudioEffectComponent,
        to target: AudioEffectTarget,
        slot: Int
    ) {
        guard canEditEffects else { return }
        Task {
            do {
                try await audioEffects.attach(
                    component,
                    to: target,
                    slot: slot,
                    notify: false
                )
                rebuildRealtimeAudioGraph(resumeTransport: true)
                hasExportedCurrentTake = false
                markSessionChanged()
                audioEffects.showEditor(for: target, slot: slot)
            } catch {
                present(error)
            }
        }
    }

    func showEffectEditor(for target: AudioEffectTarget, slot: Int) {
        guard canEditEffects else { return }
        markSessionChanged()
        audioEffects.showEditor(for: target, slot: slot)
    }

    func removeEffect(from target: AudioEffectTarget, slot: Int) {
        guard canEditEffects else { return }
        audioEffects.removeEffect(from: target, slot: slot, notify: false)
        rebuildRealtimeAudioGraph(resumeTransport: true)
        effectStateChanged()
    }

    func moveEffect(
        on target: AudioEffectTarget,
        from sourceSlot: Int,
        to destinationSlot: Int
    ) {
        guard canEditEffects,
              audioEffects.moveEffect(
                on: target,
                from: sourceSlot,
                to: destinationSlot,
                notify: false
              ) else { return }
        rebuildRealtimeAudioGraph(resumeTransport: true)
        effectStateChanged()
    }

    func toggleInputMonitoring(for channel: Int) {
        guard mixerChannels.contains(where: { $0.index == channel }) else { return }
        var updated = monitoredChannels
        if updated.contains(channel) {
            updated.remove(channel)
        } else {
            updated.insert(channel)
        }
        monitoredChannels = updated
        saveMonitoredChannels()
        configureInputMonitoring()
        markSessionChanged()
    }

    @discardableResult
    func setInputGain(_ decibels: Float, for channel: Int) -> Float? {
        guard let audioInterface = selectedAudioInterface,
              let updatedGain = DeviceDiscovery.setInputGain(
            decibels,
            for: audioInterface,
            channel: channel
        ) else { return nil }
        for index in mixerChannels.indices
            where mixerChannels[index].inputGain?.element == updatedGain.element {
            mixerChannels[index].inputGain = updatedGain
        }
        markSessionChanged()
        return updatedGain.decibels
    }

    func performSpaceAction() {
        switch state {
        case .empty:
            startRecording()
        case .recording:
            stopRecording()
        case .ready:
            togglePlayback()
        case .finalizing, .exporting:
            break
        }
    }

    func installKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  NSApp.keyWindow?.title == "MixTake" else {
                return event
            }
            if event.keyCode == 11, event.modifierFlags.contains(.command) {
                self.toggleBackingTrackControls()
                return nil
            }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                return event
            }
            if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
               textView.isFieldEditor {
                return event
            }
            switch event.keyCode {
            case 49:
                self.performSpaceAction()
                return nil
            case 51:
                self.retake()
                return nil
            case 15:
                self.clear()
                return nil
            default:
                return event
            }
        }
    }

    func removeKeyboardMonitor() {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
    }

    func startRecording() {
        guard state == .empty, !enabledChannels.isEmpty else {
            if enabledChannels.isEmpty {
                errorMessage = "Select at least one audio channel in Settings."
            }
            return
        }
        playback.unload()
        realtimeAudio.stopTake()
        meterLevels.reset()
        outputMeter.reset()
        afterStop = .keep
        state = .recording
        hasExportedCurrentTake = false
        recordingBackingTrack = backingTrack.reference
        captureEngine.startRecording(channels: enabledChannels.sorted())
    }

    func stopRecording() {
        guard state == .recording else { return }
        afterStop = .keep
        state = .finalizing
        realtimeAudio.stopBackingTrack()
        backingTrack.stopAndReturnToStart()
        captureEngine.stopRecording()
    }

    func clear() {
        realtimeAudio.stopBackingTrack()
        backingTrack.stopAndReturnToStart()
        switch state {
        case .recording:
            afterStop = .clear
            state = .finalizing
            captureEngine.stopRecording()
        case .ready:
            discardCurrentTake()
        case .empty, .finalizing, .exporting:
            break
        }
    }

    func retake() {
        realtimeAudio.stopBackingTrack()
        backingTrack.stopAndReturnToStart()
        switch state {
        case .recording:
            afterStop = .retake
            state = .finalizing
            captureEngine.stopRecording()
        case .ready:
            discardCurrentTake()
            startRecording()
        case .empty:
            startRecording()
        case .finalizing, .exporting:
            break
        }
    }

    func seek(to seconds: Double) {
        guard state == .ready else { return }
        let shouldResume = playback.isPlaying
        if shouldResume {
            playback.stop()
            realtimeAudio.stopTake()
        }
        playback.seek(to: seconds)
        if shouldResume {
            startTakePlayback()
        }
    }

    func togglePlayback() {
        guard state == .ready else { return }
        stopBackingTrackPreview()
        if playback.isPlaying {
            playback.stop()
            realtimeAudio.stopTake()
        } else {
            startTakePlayback()
        }
    }

    func toggleBackingTrackPreview() {
        guard canEditBackingTrack, backingTrack.isLoaded else { return }
        if backingTrack.isPreviewing {
            stopBackingTrackPreview()
        } else {
            playback.stop()
            realtimeAudio.stopTake()
            backingTrack.beginPreview()
            let times = scheduledPlaybackTimes()
            realtimeAudio.playBackingTrack(
                from: backingTrack.candidateTime,
                mode: .preview,
                atHostTime: times.audio
            )
        }
    }

    func seekBackingTrackCandidate(to seconds: Double) {
        guard canEditBackingTrack else { return }
        let wasPreviewing = backingTrack.isPreviewing
        if wasPreviewing {
            realtimeAudio.stopBackingTrack()
        }
        backingTrack.seekCandidate(to: seconds)
        if wasPreviewing {
            let times = scheduledPlaybackTimes(delay: 0.03)
            realtimeAudio.playBackingTrack(
                from: backingTrack.candidateTime,
                mode: .preview,
                atHostTime: times.audio
            )
        }
    }

    func toggleBackingTrackControls() {
        guard canEditBackingTrack else { return }
        if backingTrack.isLoaded {
            if backingTrack.controlsVisible {
                stopBackingTrackPreview()
            }
            backingTrack.toggleControls()
        } else {
            chooseBackingTrack()
        }
    }

    func setBackingTrackStart(to seconds: Double? = nil) -> Double {
        guard canEditBackingTrack else { return backingTrack.startTime }
        stopBackingTrackPreview()
        let actualTime = backingTrack.setStart(to: seconds)
        synchronizeBackingTrackWithCurrentTake()
        return actualTime
    }

    func setBackingTrackSyncAdjustment(to seconds: Double) -> Double {
        guard canEditBackingTrack else { return backingTrack.syncAdjustment }
        let actualAdjustment = backingTrack.setSyncAdjustment(seconds)
        synchronizeBackingTrackWithCurrentTake()
        return actualAdjustment
    }

    func removeBackingTrack() {
        guard canEditBackingTrack, backingTrack.isLoaded else { return }
        stopBackingTrackPreview()
        audioEffects.removeAllEffects(from: .backingTrack, notify: false)
        backingTrack.remove()
        synchronizeBackingTrackWithCurrentTake()
        if currentTake == nil {
            rebuildRealtimeAudioGraph(resumeTransport: false)
        }
    }

    private func chooseBackingTrack() {
        guard canEditBackingTrack else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Backing Track"
        panel.prompt = "Add Track"
        panel.allowedContentTypes = [.audio]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                try await backingTrack.load(url)
                synchronizeBackingTrackWithCurrentTake()
                if currentTake == nil {
                    rebuildRealtimeAudioGraph(resumeTransport: false)
                }
            } catch {
                present(error)
            }
        }
    }

    func showKeyboardShortcuts() {
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        let shortcuts = """
        Space        Record / Stop / Play / Pause
        Backspace    Retake
        R            Reset
        ⌘B           Add / Show / Hide Backing Track
        ⌘O           Open Session
        ⌘S           Save Session
        ⌘⇧S          Save Session As
        ⌘⇧E          Export Mix
        ⌘⇧A          Export Audio
        ⌘⇧T          Export Tracks
        ⌘,           Settings
        ⌘?           Keyboard Shortcuts
        """
        let shortcutsLabel = NSTextField(wrappingLabelWithString: shortcuts)
        shortcutsLabel.font = NSFont.monospacedSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: .regular
        )
        shortcutsLabel.preferredMaxLayoutWidth = 440
        shortcutsLabel.frame.size = NSSize(
            width: 440,
            height: shortcutsLabel.fittingSize.height
        )
        alert.accessoryView = shortcutsLabel
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func saveSession() {
        guard canSaveSession else { return }
        if let currentSessionURL {
            saveSession(to: currentSessionURL, saveAs: false)
        } else {
            saveSessionAs()
        }
    }

    func saveSessionAs() {
        guard let take = currentTake, canSaveSession else { return }
        let panel = NSSavePanel()
        panel.title = "Save MixTake Session"
        panel.nameFieldStringValue = exportBaseName(for: take) + ".mixtake"
        panel.allowedContentTypes = [.mixTakeSession]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        saveSession(to: destination, saveAs: true)
    }

    func openSession() {
        guard state != .recording, state != .finalizing, state != .exporting,
              confirmDiscardingCurrentWorkIfNeeded() else { return }
        let panel = NSOpenPanel()
        panel.title = "Open MixTake Session"
        panel.allowedContentTypes = [.mixTakeSession]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let manifest = try SessionStore.read(from: url)
                try await loadSession(manifest, from: url)
            } catch {
                present(error)
            }
        }
    }

    func openSession(at url: URL) {
        guard state != .recording, state != .finalizing, state != .exporting,
              confirmDiscardingCurrentWorkIfNeeded() else { return }
        Task {
            do {
                let manifest = try SessionStore.read(from: url)
                try await loadSession(manifest, from: url)
            } catch {
                present(error)
            }
        }
    }

    func saveChannelPreset(for channel: Int) {
        guard canEditEffects,
              let mixerChannel = mixerChannels.first(where: { $0.index == channel }) else {
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Channel Preset"
        panel.nameFieldStringValue = "Channel \(channel + 1).mixtakepreset"
        panel.allowedContentTypes = [.mixTakeChannelPreset]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let effects = try (audioEffects.configurations()[.channel(channel)] ?? [])
                .map(PersistedAudioEffect.init)
            let preset = ChannelStripPreset(
                id: UUID(),
                name: url.deletingPathExtension().lastPathComponent,
                volume: mixerChannel.volume,
                inputGainDecibels: mixerChannel.inputGain?.decibels,
                isMonitored: monitoredChannels.contains(channel),
                effects: effects
            )
            try ChannelPresetStore.save(preset, to: url)
        } catch {
            present(error)
        }
    }

    func loadChannelPreset(for channel: Int) {
        guard canEditEffects,
              mixerChannels.contains(where: { $0.index == channel }) else { return }
        let panel = NSOpenPanel()
        panel.title = "Load Channel Preset"
        panel.allowedContentTypes = [.mixTakeChannelPreset]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let preset = try ChannelPresetStore.load(from: url)
            let configurations = try preset.effects.map { try $0.configuration() }
            Task {
                let failures = await audioEffects.replaceEffects(
                    on: .channel(channel),
                    with: configurations,
                    notify: false
                )
                setVolume(preset.volume, for: channel)
                if let gain = preset.inputGainDecibels {
                    _ = setInputGain(gain, for: channel)
                }
                if preset.isMonitored {
                    monitoredChannels.insert(channel)
                } else {
                    monitoredChannels.remove(channel)
                }
                saveMonitoredChannels()
                applyMonitoringBufferSize()
                rebuildRealtimeAudioGraph(resumeTransport: true)
                effectStateChanged()
                presentEffectRestoreFailures(failures)
            }
        } catch {
            present(error)
        }
    }

    func prepareForTermination(completion: @escaping () -> Void) {
        stopAllPlayback()
        let finish = { [weak self] in
            guard let self else {
                completion()
                return
            }
            if self.currentSessionURL == nil,
               let directory = self.currentTake?.directory {
                try? FileManager.default.removeItem(at: directory)
            }
            try? FileManager.default.removeItem(at: CaptureEngine.temporaryRoot)
            self.currentTake = nil
            completion()
        }
        if state == .recording || state == .finalizing {
            captureEngine.cancelRecording(completion: finish)
        } else {
            finish()
        }
    }

    private func saveSession(to destination: URL, saveAs: Bool) {
        guard let take = currentTake else { return }
        stopAllPlayback()
        let playbackPosition = playback.currentTime
        do {
            let fileManager = FileManager.default
            let sourceDirectory = take.directory
            let packageDirectory: URL
            if currentSessionURL == nil {
                packageDirectory = sourceDirectory
            } else if saveAs, sourceDirectory.standardizedFileURL != destination.standardizedFileURL {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: sourceDirectory, to: destination)
                packageDirectory = destination
            } else {
                packageDirectory = sourceDirectory
            }

            let embeddedBackingTrack = try embedBackingTrack(in: packageDirectory)
            let manifest = try makeSessionManifest(
                take: take,
                backingTrackURL: embeddedBackingTrack,
                playbackPosition: playbackPosition
            )
            try SessionStore.write(manifest, to: packageDirectory)

            var finalDirectory = packageDirectory
            if currentSessionURL == nil {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: packageDirectory, to: destination)
                finalDirectory = destination
            }
            Task {
                await adoptSession(
                    manifest,
                    directory: finalDirectory,
                    playbackPosition: playbackPosition
                )
            }
        } catch {
            present(error)
        }
    }

    private func loadSession(_ manifest: SessionManifest, from directory: URL) async throws {
        let fileManager = FileManager.default
        let videoURL = directory.appendingPathComponent(manifest.videoFileName)
        guard fileManager.fileExists(atPath: videoURL.path) else {
            throw SessionStoreError.missingMedia(manifest.videoFileName)
        }
        var channelURLs: [Int: URL] = [:]
        for channel in manifest.channels {
            let url = directory.appendingPathComponent(channel.fileName)
            guard fileManager.fileExists(atPath: url.path) else {
                throw SessionStoreError.missingMedia(channel.fileName)
            }
            channelURLs[channel.index] = url
        }
        let backingURL = manifest.backingTrack.map {
            directory.appendingPathComponent($0.fileName)
        }
        if let backing = manifest.backingTrack,
           let backingURL,
           !fileManager.fileExists(atPath: backingURL.path) {
            throw SessionStoreError.missingMedia(backing.fileName)
        }
        let chains = try effectChains(from: manifest.effectChains)

        discardCurrentTake()
        state = .finalizing
        let restoredInterface = audioInterfaces.first {
            $0.id == manifest.audioInterfaceID &&
                $0.captureDeviceID == manifest.audioInterfaceDeviceID
        } ?? audioInterfaces.first {
            $0.captureDeviceID == manifest.audioInterfaceDeviceID &&
                $0.id != AudioInterface.systemDefaultID
        }
        if let restoredInterface {
            selectedAudioInterfaceID = restoredInterface.id
            saveSelection(restoredInterface.id, forKey: "selectedAudioInterfaceID")
            configureCapture()
        }
        let restoresInputHardware = restoredInterface != nil
        enabledChannels = Set(manifest.channels.map(\.index))
        mixerChannels = manifest.channels.map { saved in
            let inputGain = restoresInputHardware ? selectedAudioInterface.flatMap { interface in
                interface.channels.contains(saved.index)
                    ? DeviceDiscovery.inputGain(for: interface, channel: saved.index)
                    : nil
            } : nil
            return MixerChannel(
                index: saved.index,
                volume: saved.volume,
                inputGain: inputGain
            )
        }
        monitoredChannels = restoresInputHardware
            ? Set(manifest.channels.filter(\.isMonitored).map(\.index))
                .intersection(Set(selectedAudioInterface?.channels ?? []))
            : []
        saveEnabledChannels()
        saveMonitoredChannels()
        for saved in manifest.channels {
            defaults.set(saved.volume, forKey: volumeKey(saved.index))
            if restoresInputHardware, let gain = saved.inputGainDecibels {
                _ = setInputGain(gain, for: saved.index)
            }
        }

        backingTrack.remove()
        if let savedBacking = manifest.backingTrack, let backingURL {
            try await backingTrack.restore(
                url: backingURL,
                startTime: savedBacking.startTime,
                syncAdjustment: savedBacking.syncAdjustment,
                volume: savedBacking.volume
            )
        }
        let take = RecordingTake(
            directory: directory,
            videoURL: videoURL,
            channelURLs: channelURLs,
            startedAt: manifest.startedAt,
            backingTrack: manifest.backingTrack.flatMap { saved in
                backingURL.map {
                    BackingTrackReference(
                        sourceURL: $0,
                        startTime: saved.startTime,
                        timelineOffset: saved.timelineOffset,
                        syncAdjustment: saved.syncAdjustment
                    )
                }
            }
        )
        currentTake = take
        Task {
            let failures = await audioEffects.replaceAllEffects(with: chains)
            do {
                try await playback.load(take: take)
                playback.seek(to: manifest.playbackPosition)
                currentSessionURL = directory
                sessionHasUnsavedChanges = false
                hasExportedCurrentTake = false
                state = .ready
                rebuildRealtimeAudioGraph(resumeTransport: false)
                presentEffectRestoreFailures(failures)
            } catch {
                state = .empty
                present(error)
            }
        }
    }

    private func adoptSession(
        _ manifest: SessionManifest,
        directory: URL,
        playbackPosition: Double
    ) async {
        let videoURL = directory.appendingPathComponent(manifest.videoFileName)
        let channels = Dictionary(uniqueKeysWithValues: manifest.channels.map {
            ($0.index, directory.appendingPathComponent($0.fileName))
        })
        let backingReference = manifest.backingTrack.map {
            BackingTrackReference(
                sourceURL: directory.appendingPathComponent($0.fileName),
                startTime: $0.startTime,
                timelineOffset: $0.timelineOffset,
                syncAdjustment: $0.syncAdjustment
            )
        }
        let updatedTake = RecordingTake(
            directory: directory,
            videoURL: videoURL,
            channelURLs: channels,
            startedAt: manifest.startedAt,
            backingTrack: backingReference
        )
        currentTake = updatedTake
        if let savedBacking = manifest.backingTrack,
           let backingReference {
            try? await backingTrack.restore(
                url: backingReference.sourceURL,
                startTime: savedBacking.startTime,
                syncAdjustment: savedBacking.syncAdjustment,
                volume: savedBacking.volume
            )
        }
        currentSessionURL = directory
        sessionHasUnsavedChanges = false
        try? await playback.load(take: updatedTake)
        playback.seek(to: playbackPosition)
        rebuildRealtimeAudioGraph(resumeTransport: false)
    }

    private func embedBackingTrack(in directory: URL) throws -> URL? {
        guard let source = backingTrack.fileURL else { return nil }
        if source.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL {
            return source
        }
        let protectedNames = Set(
            [currentTake?.videoURL.lastPathComponent, SessionStore.manifestName]
                .compactMap { $0 }
                + (currentTake?.channelURLs.values.map(\.lastPathComponent) ?? [])
        )
        let fileName = protectedNames.contains(source.lastPathComponent)
            ? "backing-\(source.lastPathComponent)"
            : source.lastPathComponent
        let destination = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func makeSessionManifest(
        take: RecordingTake,
        backingTrackURL: URL?,
        playbackPosition: Double
    ) throws -> SessionManifest {
        let effects = audioEffects.configurations(forDocument: true)
        let effectChains = try effects.map { target, configurations in
            SessionManifest.EffectChain(
                channel: {
                    if case .channel(let channel) = target { return channel }
                    return nil
                }(),
                isBackingTrack: target == .backingTrack,
                effects: try configurations.map(PersistedAudioEffect.init)
            )
        }
        let channels = take.channelURLs.sorted { $0.key < $1.key }.map { channel, url in
            let mixer = mixerChannels.first { $0.index == channel }
            return SessionManifest.Channel(
                index: channel,
                fileName: url.lastPathComponent,
                volume: mixer?.volume ?? 1,
                inputGainDecibels: mixer?.inputGain?.decibels,
                isMonitored: monitoredChannels.contains(channel)
            )
        }
        let savedBacking = take.backingTrack.flatMap { reference in
            backingTrackURL.map {
                SessionManifest.BackingTrack(
                    fileName: $0.lastPathComponent,
                    startTime: reference.startTime,
                    timelineOffset: reference.timelineOffset,
                    syncAdjustment: reference.syncAdjustment,
                    volume: backingTrack.volume
                )
            }
        }
        return SessionManifest(
            version: SessionManifest.currentVersion,
            startedAt: take.startedAt,
            videoFileName: take.videoURL.lastPathComponent,
            audioInterfaceID: selectedAudioInterfaceID,
            audioInterfaceDeviceID: selectedAudioInterface?.captureDeviceID,
            channels: channels,
            backingTrack: savedBacking,
            effectChains: effectChains,
            playbackPosition: playbackPosition
        )
    }

    private func effectChains(
        from persisted: [SessionManifest.EffectChain]
    ) throws -> AudioEffectChains {
        var result: AudioEffectChains = [:]
        for chain in persisted {
            let target: AudioEffectTarget
            if chain.isBackingTrack {
                target = .backingTrack
            } else if let channel = chain.channel {
                target = .channel(channel)
            } else {
                continue
            }
            result[target] = try chain.effects.map { try $0.configuration() }
        }
        return result
    }

    private func confirmDiscardingCurrentWorkIfNeeded() -> Bool {
        guard let warning = terminationWarning else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard the current work?"
        alert.informativeText = warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentEffectRestoreFailures(_ failures: [String]) {
        guard !failures.isEmpty else { return }
        errorMessage = "These Audio Units could not be restored: " + failures.joined(separator: ", ")
    }

    func exportMix() {
        guard let take = currentTake, canExport else { return }
        stopAllPlayback()
        let panel = NSSavePanel()
        panel.title = "Export Mix"
        panel.nameFieldStringValue = exportBaseName(for: take) + ".mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let effects = audioEffects.configurations()
        beginExport()
        Task {
            do {
                try await ExportService.exportMix(
                    take,
                    volumes: volumes,
                    backingTrackVolume: backingTrack.volume,
                    effects: effects,
                    to: destination,
                    progress: exportProgressHandler()
                )
                hasExportedCurrentTake = true
                finishExport()
            } catch {
                finishExport()
                present(error)
            }
        }
    }

    func exportTracks() {
        guard let take = currentTake, canExport else { return }
        stopAllPlayback()
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder for Exported Tracks"
        panel.prompt = "Export Tracks"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let parent = panel.url else { return }

        let destination = uniqueDirectory(
            named: exportBaseName(for: take),
            inside: parent
        )
        let effects = audioEffects.configurations()
        beginExport()
        Task {
            do {
                try await ExportService.exportTracks(
                    take,
                    effects: effects,
                    to: destination,
                    progress: exportProgressHandler()
                )
                hasExportedCurrentTake = true
                finishExport()
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                finishExport()
                present(error)
            }
        }
    }

    func exportAudio() {
        guard let take = currentTake, canExport else { return }
        stopAllPlayback()
        let panel = NSSavePanel()
        panel.title = "Export Audio"
        panel.nameFieldStringValue = exportBaseName(for: take) + ".m4a"
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let effects = audioEffects.configurations()
        beginExport()
        Task {
            do {
                try await ExportService.exportAudio(
                    take,
                    volumes: volumes,
                    backingTrackVolume: backingTrack.volume,
                    effects: effects,
                    to: destination,
                    progress: exportProgressHandler()
                )
                hasExportedCurrentTake = true
                finishExport()
            } catch {
                finishExport()
                present(error)
            }
        }
    }

    private func beginExport() {
        exportProgress = 0
        state = .exporting
    }

    private func finishExport() {
        exportProgress = 1
        state = .ready
    }

    private func exportProgressHandler() -> ExportService.ProgressHandler {
        { [weak self] progress in
            Task { @MainActor in
                guard let self, self.state == .exporting else { return }
                self.exportProgress = max(
                    self.exportProgress,
                    min(1, max(0, progress))
                )
            }
        }
    }

    func discardCurrentTake() {
        if state == .recording || state == .finalizing {
            captureEngine.cancelRecording()
        }
        realtimeAudio.stopTake()
        playback.unload()
        realtimeAudio.stopBackingTrack()
        backingTrack.stopAndReturnToStart()
        if currentSessionURL == nil, let directory = currentTake?.directory {
            try? FileManager.default.removeItem(at: directory)
        }
        currentTake = nil
        currentSessionURL = nil
        sessionHasUnsavedChanges = false
        recordingBackingTrack = nil
        outputMeter.reset()
        hasExportedCurrentTake = false
        state = .empty
        rebuildRealtimeAudioGraph(resumeTransport: false)
    }

    private func requestCaptureAccessAndConfigure() async {
        let videoAllowed = await requestAccess(for: .video)
        let audioAllowed = await requestAccess(for: .audio)
        guard videoAllowed, audioAllowed else {
            errorMessage = "Camera and microphone access are required. Enable them in System Settings > Privacy & Security."
            return
        }
        discoverDevices()
        restoreDeviceSelections()
        configureCapture()
    }

    private func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: mediaType)
        default:
            return false
        }
    }

    private func configureCapture() {
        guard let cameraID = selectedCameraID,
              let audioID = selectedAudioInterface?.captureDeviceID else { return }
        captureEngine.configure(cameraID: cameraID, audioDeviceID: audioID)
    }

    private func loadChannelsForSelectedInterface(restoreMonitoring: Bool = false) {
        guard let interface = selectedAudioInterface else {
            enabledChannels = []
            monitoredChannels = []
            mixerChannels = []
            return
        }
        if let saved = defaults.array(forKey: channelSelectionKey) as? [Int] {
            enabledChannels = Set(saved.filter { interface.channels.contains($0) })
        } else {
            enabledChannels = Set(interface.channels)
        }
        if restoreMonitoring,
           let saved = defaults.array(forKey: monitoringSelectionKey) as? [Int] {
            monitoredChannels = Set(saved).intersection(enabledChannels)
        } else {
            monitoredChannels.formIntersection(enabledChannels)
        }
        rebuildMixerChannels()
    }

    private func rebuildMixerChannels() {
        guard let interface = selectedAudioInterface else {
            mixerChannels = []
            return
        }
        mixerChannels = enabledChannels.sorted().map { channel in
            let savedVolume = defaults.object(forKey: volumeKey(channel)) == nil
                ? 1
                : defaults.float(forKey: volumeKey(channel))
            return MixerChannel(
                index: channel,
                volume: savedVolume,
                inputGain: DeviceDiscovery.inputGain(
                    for: interface,
                    channel: channel
                )
            )
        }
    }

    private func selectDefaultAudioInterface() {
        selectedAudioInterfaceID = audioInterfaces.first {
            $0.id == AudioInterface.systemDefaultID
        }?.id ?? audioInterfaces.first?.id
        saveSelection(selectedAudioInterfaceID, forKey: "selectedAudioInterfaceID")
    }

    private func selectDefaultAudioOutput() {
        selectedAudioOutputID = audioOutputs.first {
            $0.id == AudioOutputDevice.systemDefaultID
        }?.id ?? audioOutputs.first?.id
        saveSelection(selectedAudioOutputID, forKey: "selectedAudioOutputID")
    }

    private func applyAudioOutput() {
        configureInputMonitoring()
    }

    private func saveSelection(_ id: String?, forKey key: String) {
        if let id {
            defaults.set(id, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func saveEnabledChannels() {
        defaults.set(enabledChannels.sorted(), forKey: channelSelectionKey)
    }

    private func saveMonitoredChannels() {
        defaults.set(monitoredChannels.sorted(), forKey: monitoringSelectionKey)
    }

    private var channelSelectionKey: String {
        "enabledChannels.\(selectedAudioInterface?.configurationID ?? "none")"
    }

    private var monitoringSelectionKey: String {
        "monitoredChannels.\(selectedAudioInterface?.configurationID ?? "none")"
    }

    private func volumeKey(_ channel: Int) -> String {
        "volume.\(selectedAudioInterface?.configurationID ?? "none").\(channel)"
    }

    private var volumes: [Int: Float] {
        Dictionary(uniqueKeysWithValues: mixerChannels.map { ($0.index, $0.volume) })
    }

    private func effectStateChanged() {
        if currentTake != nil {
            hasExportedCurrentTake = false
        }
        markSessionChanged()
    }

    private func markSessionChanged() {
        if currentSessionURL != nil {
            sessionHasUnsavedChanges = true
        }
    }

    private func synchronizeBackingTrackWithCurrentTake() {
        guard let take = currentTake else { return }
        let updatedBackingTrack = backingTrack.reference.map { reference in
            BackingTrackReference(
                sourceURL: reference.sourceURL,
                startTime: reference.startTime,
                timelineOffset: take.backingTrack?.sourceURL == reference.sourceURL
                    ? take.backingTrack?.timelineOffset ?? 0
                    : 0,
                syncAdjustment: reference.syncAdjustment
            )
        }
        let updatedTake = RecordingTake(
            directory: take.directory,
            videoURL: take.videoURL,
            channelURLs: take.channelURLs,
            startedAt: take.startedAt,
            backingTrack: updatedBackingTrack
        )
        currentTake = updatedTake
        hasExportedCurrentTake = false
        markSessionChanged()
        rebuildRealtimeAudioGraph(resumeTransport: true)
    }

    private func configureInputMonitoring() {
        if !monitoredChannels.isEmpty {
            applyMonitoringBufferSize()
        }
        rebuildRealtimeAudioGraph(resumeTransport: true)
    }

    private func rebuildRealtimeAudioGraph(resumeTransport: Bool) {
        audioGraphGeneration &+= 1
        let generation = audioGraphGeneration
        let resumeTake = resumeTransport && playback.isPlaying
        let resumeBackingTrack = resumeTransport && backingTrack.isPreviewing
        if resumeTake {
            playback.stop()
            realtimeAudio.stopTake()
        }
        if resumeBackingTrack {
            realtimeAudio.stopBackingTrack()
        }

        realtimeAudio.configure(
            monitoredChannels: monitoredChannels,
            volumes: volumes,
            backingTrackVolume: backingTrack.volume,
            effects: audioEffects.audioUnitChains(),
            take: currentTake,
            backingTrackURL: backingTrack.fileURL,
            outputDeviceID: selectedAudioOutput?.coreAudioDeviceID
        ) { [weak self] error in
            guard let self, self.audioGraphGeneration == generation else { return }
            if let error {
                self.present(error)
                return
            }
            if resumeTake, self.state == .ready {
                self.startTakePlayback()
            } else if resumeBackingTrack, self.canEditBackingTrack {
                self.backingTrack.beginPreview()
                let times = self.scheduledPlaybackTimes(delay: 0.03)
                self.realtimeAudio.playBackingTrack(
                    from: self.backingTrack.candidateTime,
                    mode: .preview,
                    atHostTime: times.audio
                )
            }
        }
    }

    private func startTakePlayback() {
        if playback.duration > 0,
           playback.currentTime >= playback.duration - 0.05 {
            playback.seek(to: 0)
        }
        let times = scheduledPlaybackTimes()
        realtimeAudio.playTake(
            from: playback.currentTime,
            duration: playback.duration,
            atHostTime: times.audio
        )
        playback.play(atHostTime: times.video)
    }

    private func stopBackingTrackPreview() {
        realtimeAudio.stopBackingTrack()
        backingTrack.stopPreview()
    }

    private func stopAllPlayback() {
        playback.stop()
        realtimeAudio.stopTake()
        stopBackingTrackPreview()
    }

    private func scheduledPlaybackTimes(
        delay: Double = 0.1
    ) -> (audio: UInt64, video: CMTime) {
        let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        let audioTime = AudioGetCurrentHostTime() + AudioConvertNanosToHostTime(nanoseconds)
        let videoTime = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(
            seconds: max(0, delay),
            preferredTimescale: 1_000_000_000
        )
        return (audioTime, videoTime)
    }

    private func applyMonitoringBufferSize() {
        let deviceIDs = Set([
            selectedAudioInterface?.coreAudioDeviceID,
            selectedAudioOutput?.coreAudioDeviceID
        ].compactMap { $0 })
        for deviceID in deviceIDs {
            DeviceDiscovery.setBufferFrameSize(
                monitoringBufferFrames,
                deviceID: deviceID
            )
        }
    }

    private func present(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func exportBaseName(for take: RecordingTake) -> String {
        if let backingTrackName = take.backingTrack?.sourceURL
            .deletingPathExtension()
            .lastPathComponent,
           !backingTrackName.isEmpty {
            return backingTrackName
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "MixTake-\(formatter.string(from: take.startedAt))"
    }

    private func uniqueDirectory(named name: String, inside parent: URL) -> URL {
        var candidate = parent.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(name)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }
}

extension AppModel: CaptureEngineDelegate {
    nonisolated func captureEngine(
        _ engine: CaptureEngine,
        didUpdatePeaks peaks: [Int: Float]
    ) {
        Task { @MainActor in
            meterLevels.update(peaks)
        }
    }

    nonisolated func captureEngine(
        _ engine: CaptureEngine,
        didStartAtHostTime hostTime: CMTime
    ) {
        Task { @MainActor in
            guard state == .recording, backingTrack.isLoaded else { return }
            let times = scheduledPlaybackTimes()
            let timelineOffset = max(
                0,
                CMTimeGetSeconds(times.video - hostTime)
            )
            backingTrack.beginRecordingPlayback(timelineOffset: timelineOffset)
            realtimeAudio.playBackingTrack(
                from: max(0, backingTrack.startTime),
                mode: .recording,
                atHostTime: times.audio,
                after: max(0, -backingTrack.startTime)
            )
        }
    }

    nonisolated func captureEngine(_ engine: CaptureEngine, didFinish take: RecordingTake) {
        Task { @MainActor in
            var shouldRetake = false
            switch afterStop {
            case .keep:
                let completedBackingTrack = backingTrack.recordedReference
                    ?? recordingBackingTrack
                let completedTake = RecordingTake(
                    directory: take.directory,
                    videoURL: take.videoURL,
                    channelURLs: take.channelURLs,
                    startedAt: take.startedAt,
                    backingTrack: completedBackingTrack
                )
                currentTake = completedTake
                currentSessionURL = nil
                sessionHasUnsavedChanges = false
                do {
                    outputMeter.reset()
                    try await playback.load(take: completedTake)
                } catch {
                    outputMeter.reset()
                    present(error)
                }
                state = .ready
                rebuildRealtimeAudioGraph(resumeTransport: false)
            case .clear:
                try? FileManager.default.removeItem(at: take.directory)
                currentTake = nil
                outputMeter.reset()
                state = .empty
                rebuildRealtimeAudioGraph(resumeTransport: false)
            case .retake:
                try? FileManager.default.removeItem(at: take.directory)
                currentTake = nil
                outputMeter.reset()
                state = .empty
                rebuildRealtimeAudioGraph(resumeTransport: false)
                shouldRetake = true
            }
            recordingBackingTrack = nil
            afterStop = .keep
            applyPendingDeviceRefresh()
            if shouldRetake {
                startRecording()
            }
        }
    }

    nonisolated func captureEngine(_ engine: CaptureEngine, didFail error: Error) {
        Task { @MainActor in
            realtimeAudio.stopBackingTrack()
            backingTrack.stopAndReturnToStart()
            recordingBackingTrack = nil
            state = currentTake == nil ? .empty : .ready
            present(error)
            applyPendingDeviceRefresh()
        }
    }
}
