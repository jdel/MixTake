import AVFoundation
import CoreMedia
import Foundation

enum AudioStemWriterError: LocalizedError {
    case noAudioSamples

    var errorDescription: String? {
        "No audio samples were received from the selected interface."
    }
}

final class AudioStemWriter {
    private let directory: URL
    private let selectedChannels: [Int]
    private var files: [Int: AVAudioFile] = [:]
    private var sampleRate: Double?

    init(directory: URL, selectedChannels: [Int]) {
        self.directory = directory
        self.selectedChannels = selectedChannels.sorted()
    }

    var channelURLs: [Int: URL] {
        Dictionary(uniqueKeysWithValues: selectedChannels.map { ($0, url(for: $0)) })
    }

    func append(_ audio: ExtractedAudio, relativeTo startTime: CMTime) throws {
        if sampleRate == nil {
            try openFiles(sampleRate: audio.sampleRate)
        }
        guard let sampleRate else { return }

        let relativeSeconds = CMTimeGetSeconds(audio.presentationTime - startTime)
        guard relativeSeconds.isFinite else { return }
        var sourceOffset = 0
        var requestedTargetFrame = Int64((relativeSeconds * sampleRate).rounded())
        let maximumTimestampGap = Int64(sampleRate * 2)
        let timestampIsFarBeforeTimeline = requestedTargetFrame < -maximumTimestampGap
        if requestedTargetFrame < 0, !timestampIsFarBeforeTimeline {
            sourceOffset = min(audio.frameCount, Int(-requestedTargetFrame))
            requestedTargetFrame = 0
        }
        guard sourceOffset < audio.frameCount else { return }

        for channel in selectedChannels {
            guard channel < audio.channels.count, let file = files[channel] else { continue }
            let targetFrame = timestampIsFarBeforeTimeline ||
                requestedTargetFrame - file.length > maximumTimestampGap
                ? file.length
                : requestedTargetFrame
            if file.length < targetFrame {
                try writeSilence(frames: AVAudioFrameCount(targetFrame - file.length), to: file)
            }

            let skipForOverlap = max(0, Int(file.length - targetFrame))
            let offset = sourceOffset + skipForOverlap
            guard offset < audio.frameCount else { continue }
            let samples = Array(audio.channels[channel][offset...])
            try write(samples: samples, to: file)
        }
    }

    func finalize(to duration: CMTime) throws {
        guard let sampleRate else { throw AudioStemWriterError.noAudioSamples }
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite else { throw AudioStemWriterError.noAudioSamples }
        let requestedLength = Int64(max(0, durationSeconds * sampleRate))
        let longestWritten = files.values.map(\.length).max() ?? 0
        let targetLength = min(
            requestedLength,
            longestWritten + Int64(sampleRate * 2)
        )
        for file in files.values where file.length < targetLength {
            try writeSilence(frames: AVAudioFrameCount(targetLength - file.length), to: file)
        }
        close()
        for url in channelURLs.values {
            try trim(url: url, to: targetLength)
        }
    }

    func close() {
        files.removeAll()
    }

    private func openFiles(sampleRate: Double) throws {
        self.sampleRate = sampleRate
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        for channel in selectedChannels {
            files[channel] = try AVAudioFile(
                forWriting: url(for: channel),
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        }
    }

    private func write(samples: [Float], to file: AVAudioFile) throws {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let destination = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            destination.update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    private func writeSilence(frames: AVAudioFrameCount, to file: AVAudioFile) throws {
        var remaining = frames
        while remaining > 0 {
            let count = min(remaining, 8_192)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: count
            ) else { return }
            buffer.frameLength = count
            if let samples = buffer.floatChannelData?[0] {
                samples.initialize(repeating: 0, count: Int(count))
            }
            try file.write(from: buffer)
            remaining -= count
        }
    }

    private func trim(url: URL, to targetLength: AVAudioFramePosition) throws {
        let temporaryURL = url
            .deletingPathExtension()
            .appendingPathExtension("trimmed.wav")
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        var needsReplacement = false
        do {
            let source = try AVAudioFile(forReading: url)
            guard source.length > targetLength else { return }
            needsReplacement = true
            let output = try AVAudioFile(
                forWriting: temporaryURL,
                settings: source.fileFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            var remaining = targetLength
            while remaining > 0 {
                let count = AVAudioFrameCount(min(8_192, remaining))
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: source.processingFormat,
                    frameCapacity: count
                ) else { break }
                try source.read(into: buffer, frameCount: count)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
                remaining -= AVAudioFramePosition(buffer.frameLength)
            }
        }
        if needsReplacement {
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temporaryURL, to: url)
        }
    }

    private func url(for channel: Int) -> URL {
        directory.appendingPathComponent(
            String(format: "channel-%02d.wav", channel + 1)
        )
    }
}
