import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

protocol CaptureEngineDelegate: AnyObject {
    func captureEngine(_ engine: CaptureEngine, didUpdatePeaks peaks: [Int: Float])
    func captureEngine(_ engine: CaptureEngine, didStartAtHostTime hostTime: CMTime)
    func captureEngine(_ engine: CaptureEngine, didFinish take: RecordingTake)
    func captureEngine(_ engine: CaptureEngine, didFail error: Error)
}

enum CaptureEngineError: LocalizedError {
    case cameraUnavailable
    case audioInterfaceUnavailable
    case cannotAddInput(String)
    case cannotAddOutput(String)
    case cannotCreateWriter(String)
    case recordingDidNotReceiveVideo

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "The selected camera is unavailable."
        case .audioInterfaceUnavailable:
            return "The selected audio interface is unavailable."
        case .cannotAddInput(let name):
            return "MixTake could not use the \(name) input."
        case .cannotAddOutput(let name):
            return "MixTake could not create the \(name) output."
        case .cannotCreateWriter(let reason):
            return "The video writer could not start: \(reason)"
        case .recordingDidNotReceiveVideo:
            return "No video frames were received."
        }
    }
}

final class CaptureEngine: NSObject {
    static var temporaryRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MixTake", isDirectory: true)
    }

    static func removeStaleTemporaryRecordings() {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    let session = AVCaptureSession()
    weak var delegate: CaptureEngineDelegate?
    var onAudioSamples: ((ExtractedAudio) -> Void)?

    private let configurationQueue = DispatchQueue(label: "MixTake.capture.configuration")
    private let sampleQueue = DispatchQueue(label: "MixTake.capture.samples", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    private var isRecording = false
    private var recordingDirectory: URL?
    private var recordingStartedAt = Date()
    private var selectedChannels: [Int] = []
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var stemWriter: AudioStemWriter?
    private var startTime: CMTime?
    private var lastVideoEndTime: CMTime?
    private var videoTimestampCorrection = CMTime.zero
    private var pendingAudio: [ExtractedAudio] = []
    private var lastMeterUpdate = 0.0

    override init() {
        super.init()
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)

        audioOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true
        ]
        audioOutput.setSampleBufferDelegate(self, queue: sampleQueue)
    }

    func configure(cameraID: String?, audioDeviceID: String?) {
        configurationQueue.async { [weak self] in
            guard let self else { return }
            do {
                let cameras = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
                    mediaType: .video,
                    position: .unspecified
                ).devices.filter { $0.isConnected && !$0.isSuspended }
                let audioDevices = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.builtInMicrophone, .externalUnknown],
                    mediaType: .audio,
                    position: .unspecified
                ).devices.filter { $0.isConnected && !$0.isSuspended }
                guard let camera = cameras.first(where: { $0.uniqueID == cameraID }) ?? cameras.first else {
                    throw CaptureEngineError.cameraUnavailable
                }
                guard let audioDevice = audioDevices.first(where: { $0.uniqueID == audioDeviceID }) ?? audioDevices.first else {
                    throw CaptureEngineError.audioInterfaceUnavailable
                }

                let cameraInput = try AVCaptureDeviceInput(device: camera)
                let audioInput = try AVCaptureDeviceInput(device: audioDevice)

                self.session.beginConfiguration()
                do {
                    self.session.sessionPreset = .high
                    self.session.inputs.forEach(self.session.removeInput)
                    self.session.outputs.forEach(self.session.removeOutput)

                    guard self.session.canAddInput(cameraInput) else {
                        throw CaptureEngineError.cannotAddInput("camera")
                    }
                    self.session.addInput(cameraInput)
                    guard self.session.canAddInput(audioInput) else {
                        throw CaptureEngineError.cannotAddInput("audio")
                    }
                    self.session.addInput(audioInput)

                    guard self.session.canAddOutput(self.videoOutput) else {
                        throw CaptureEngineError.cannotAddOutput("video")
                    }
                    self.session.addOutput(self.videoOutput)
                    guard self.session.canAddOutput(self.audioOutput) else {
                        throw CaptureEngineError.cannotAddOutput("audio")
                    }
                    self.session.addOutput(self.audioOutput)
                    self.session.commitConfiguration()
                } catch {
                    self.session.commitConfiguration()
                    throw error
                }

                if !self.session.isRunning {
                    self.session.startRunning()
                }
            } catch {
                self.report(error)
            }
        }
    }

    func startRecording(channels: [Int]) {
        sampleQueue.async { [weak self] in
            guard let self, !self.isRecording else { return }
            do {
                let directory = Self.temporaryRoot
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )

                self.recordingDirectory = directory
                self.recordingStartedAt = Date()
                self.selectedChannels = channels.sorted()
                self.stemWriter = AudioStemWriter(
                    directory: directory,
                    selectedChannels: self.selectedChannels
                )
                self.writer = nil
                self.videoInput = nil
                self.startTime = nil
                self.lastVideoEndTime = nil
                self.videoTimestampCorrection = .zero
                self.pendingAudio.removeAll(keepingCapacity: true)
                self.isRecording = true
            } catch {
                self.report(error)
            }
        }
    }

    func stopRecording() {
        sampleQueue.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.isRecording = false

            guard let writer = self.writer,
                  let videoInput = self.videoInput,
                  let directory = self.recordingDirectory,
                  let startTime = self.startTime,
                  let lastVideoEndTime = self.lastVideoEndTime else {
                self.resetRecording(deleteFiles: true)
                self.report(CaptureEngineError.recordingDidNotReceiveVideo)
                return
            }

            let duration = lastVideoEndTime - startTime
            do {
                try self.stemWriter?.finalize(to: duration)
            } catch {
                self.resetRecording(deleteFiles: true)
                self.report(error)
                return
            }
            let channelURLs = self.stemWriter?.channelURLs ?? [:]
            self.stemWriter = nil
            videoInput.markAsFinished()

            writer.finishWriting { [weak self] in
                guard let self else { return }
                if writer.status == .completed {
                    let take = RecordingTake(
                        directory: directory,
                        videoURL: directory.appendingPathComponent("video.mp4"),
                        channelURLs: channelURLs,
                        startedAt: self.recordingStartedAt,
                        backingTrack: nil
                    )
                    self.resetRecording(deleteFiles: false)
                    DispatchQueue.main.async {
                        self.delegate?.captureEngine(self, didFinish: take)
                    }
                } else {
                    let error = writer.error ?? CaptureEngineError.cannotCreateWriter("unknown error")
                    self.resetRecording(deleteFiles: true)
                    self.report(error)
                }
            }
        }
    }

    func cancelRecording(completion: (() -> Void)? = nil) {
        sampleQueue.async { [weak self] in
            if let self {
                self.isRecording = false
                self.writer?.cancelWriting()
                self.resetRecording(deleteFiles: true)
            }
            if let completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording else { return }
        let sourcePresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        do {
            if writer == nil {
                try startWriter(with: sampleBuffer, at: sourcePresentationTime)
                for audio in pendingAudio {
                    try stemWriter?.append(audio, relativeTo: sourcePresentationTime)
                }
                pendingAudio.removeAll(keepingCapacity: true)
            }
            guard let videoInput, videoInput.isReadyForMoreMediaData else { return }
            let frameDuration = validFrameDuration(for: sampleBuffer)
            var presentationTime = sourcePresentationTime + videoTimestampCorrection
            if let lastVideoEndTime {
                let gap = CMTimeGetSeconds(presentationTime - lastVideoEndTime)
                if !gap.isFinite || gap < -0.1 || gap > 2 {
                    videoTimestampCorrection = lastVideoEndTime - sourcePresentationTime
                    presentationTime = lastVideoEndTime
                }
            }
            let buffer = try videoSample(
                sampleBuffer,
                retimedTo: presentationTime,
                duration: frameDuration
            )
            if videoInput.append(buffer) {
                lastVideoEndTime = presentationTime + frameDuration
            }
        } catch {
            isRecording = false
            writer?.cancelWriting()
            resetRecording(deleteFiles: true)
            report(error)
        }
    }

    private func validFrameDuration(for sampleBuffer: CMSampleBuffer) -> CMTime {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        guard duration.isValid,
              duration.isNumeric,
              CMTimeGetSeconds(duration) > 0 else {
            return CMTime(value: 1, timescale: 30)
        }
        return duration
    }

    private func videoSample(
        _ sampleBuffer: CMSampleBuffer,
        retimedTo presentationTime: CMTime,
        duration: CMTime
    ) throws -> CMSampleBuffer {
        let originalTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime != originalTime ||
                CMSampleBufferGetDuration(sampleBuffer) != duration else {
            return sampleBuffer
        }
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        guard status == noErr, let copy else {
            throw CaptureEngineError.cannotCreateWriter("could not normalize video timestamps")
        }
        return copy
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let audio = AudioSampleExtractor.extract(sampleBuffer) else { return }
        onAudioSamples?(audio)
        publishMeters(audio)
        guard isRecording else { return }
        do {
            if let startTime {
                try stemWriter?.append(audio, relativeTo: startTime)
            } else {
                pendingAudio.append(audio)
                if pendingAudio.count > 100 { pendingAudio.removeFirst() }
            }
        } catch {
            isRecording = false
            writer?.cancelWriting()
            resetRecording(deleteFiles: true)
            report(error)
        }
    }

    private func startWriter(with sampleBuffer: CMSampleBuffer, at time: CMTime) throws {
        guard let directory = recordingDirectory,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw CaptureEngineError.cannotCreateWriter("missing video format")
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        guard dimensions.width > 0, dimensions.height > 0 else {
            throw CaptureEngineError.cannotCreateWriter("invalid video dimensions")
        }

        let outputURL = directory.appendingPathComponent("video.mp4")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let pixelCount = Int(dimensions.width) * Int(dimensions.height)
        let bitrate = min(100_000_000, max(12_000_000, pixelCount * 10))
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dimensions.width),
            AVVideoHeightKey: Int(dimensions.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 2
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw CaptureEngineError.cannotCreateWriter("unsupported H.264 settings")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CaptureEngineError.cannotCreateWriter("startWriting failed")
        }
        writer.startSession(atSourceTime: time)
        self.writer = writer
        videoInput = input
        startTime = time

        let hostClock = CMClockGetHostTimeClock()
        let recordingHostTime: CMTime
        if let captureClock = session.masterClock {
            recordingHostTime = CMSyncConvertTime(
                time,
                from: captureClock,
                to: hostClock
            )
        } else {
            recordingHostTime = CMClockGetTime(hostClock)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.captureEngine(self, didStartAtHostTime: recordingHostTime)
        }
    }

    private func publishMeters(_ audio: ExtractedAudio) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMeterUpdate >= 0.05 else { return }
        lastMeterUpdate = now
        var peaks: [Int: Float] = [:]
        for (index, samples) in audio.channels.enumerated() {
            peaks[index] = samples.reduce(0) { max($0, abs($1)) }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.captureEngine(self, didUpdatePeaks: peaks)
        }
    }

    private func resetRecording(deleteFiles: Bool) {
        let directory = recordingDirectory
        writer = nil
        videoInput = nil
        stemWriter?.close()
        stemWriter = nil
        startTime = nil
        lastVideoEndTime = nil
        videoTimestampCorrection = .zero
        pendingAudio.removeAll(keepingCapacity: false)
        recordingDirectory = nil
        if deleteFiles, let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func report(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.captureEngine(self, didFail: error)
        }
    }
}

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === videoOutput {
            handleVideo(sampleBuffer)
        } else if output === audioOutput {
            handleAudio(sampleBuffer)
        }
    }
}
