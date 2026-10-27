import AppKit
import SwiftUI

struct TransportView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var playback: PlaybackController
    @ObservedObject var backingTrack: BackingTrackController

    var body: some View {
        VStack(spacing: 7) {
            if model.state == .ready {
                HStack(spacing: 8) {
                    Text(time(playback.currentTime))
                        .frame(width: 48, alignment: .trailing)
                    Slider(
                        value: Binding(
                            get: { playback.currentTime },
                            set: { model.seek(to: $0) }
                        ),
                        in: 0...max(0.01, playback.duration)
                    )
                    .focusable(false)
                    Text(time(playback.duration))
                        .frame(width: 48, alignment: .leading)
                }
                .font(.caption.monospacedDigit())
            }

            if backingTrack.isLoaded && backingTrack.controlsVisible {
                BackingTrackStartView(
                    backingTrack: backingTrack,
                    onTogglePreview: model.toggleBackingTrackPreview,
                    onCandidateChanged: model.seekBackingTrackCandidate,
                    onSetStart: { model.setBackingTrackStart() },
                    onStartChanged: { model.setBackingTrackStart(to: $0) },
                    onSyncChanged: { model.setBackingTrackSyncAdjustment(to: $0) },
                    onRemove: model.removeBackingTrack
                )
                .disabled(!model.canEditBackingTrack)
            }

            ZStack {
                HStack(spacing: 10) {
                    TransportCircleButton(
                        title: playback.isPlaying ? "Pause (Space)" : "Play (Space)",
                        systemImage: playback.isPlaying ? "pause.fill" : "play.fill",
                        fill: Color.accentColor.opacity(0.82),
                        action: model.togglePlayback
                    )
                    .disabled(model.state != .ready)

                    TransportCircleButton(
                        title: model.state == .recording ? "Stop Recording (Space)" : "Record (Space)",
                        systemImage: model.state == .recording ? "stop.fill" : "circle.fill",
                        fill: model.state == .recording ? .red : .red.opacity(0.58),
                        size: 38
                    ) {
                        if model.state == .recording {
                            model.stopRecording()
                        } else {
                            model.startRecording()
                        }
                    }
                    .disabled(model.state != .empty && model.state != .recording)

                    TransportCircleButton(
                        title: "Reset (R)",
                        systemImage: "xmark",
                        fill: Color.secondary.opacity(0.5),
                        action: model.clear
                    )
                    .disabled(
                        model.state == .empty ||
                            model.state == .finalizing ||
                            model.state == .exporting
                    )

                    TransportCircleButton(
                        title: "Retake (Backspace)",
                        systemImage: "arrow.counterclockwise",
                        fill: Color.secondary.opacity(0.5),
                        action: model.retake
                    )
                    .disabled(
                        model.state == .finalizing ||
                            model.state == .exporting
                    )

                    TransportCircleButton(
                        title: backingTrack.isLoaded
                            ? "Show / Hide Backing Track (⌘B)"
                            : "Add Backing Track (⌘B)",
                        systemImage: "music.note",
                        fill: backingTrack.isLoaded
                            ? Color.blue.opacity(0.82)
                            : Color.secondary.opacity(0.5),
                        action: model.toggleBackingTrackControls
                    )
                    .disabled(!model.canEditBackingTrack)
                }

                HStack {
                    Spacer()
                    status
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .empty:
            Text("Ready")
        case .recording:
            Label("Recording", systemImage: "circle.fill").foregroundStyle(.red)
        case .finalizing:
            ProgressView().controlSize(.small)
            Text("Finishing")
        case .ready:
            Text("Take ready")
        case .exporting:
            ExportProgressWheel(progress: model.exportProgress)
            Text("Exporting \(Int((model.exportProgress * 100).rounded()))%")
        }
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct ExportProgressWheel: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.22), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 15, height: 15)
        .animation(.linear(duration: 0.1), value: progress)
        .accessibilityLabel("Export progress")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }
}

private struct BackingTrackStartView: View {
    @ObservedObject var backingTrack: BackingTrackController
    let onTogglePreview: () -> Void
    let onCandidateChanged: (Double) -> Void
    let onSetStart: () -> Void
    let onStartChanged: (Double) -> Double
    let onSyncChanged: (Double) -> Double
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("BT")
                .font(.caption.bold())

            Text(backingTrack.displayName)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 100, alignment: .leading)
                .help(backingTrack.displayName)

            Text(time(backingTrack.candidateTime))
                .frame(width: 48, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { backingTrack.candidateTime },
                    set: onCandidateChanged
                ),
                in: 0...max(0.01, backingTrack.duration)
            )
            .frame(minWidth: 50, idealWidth: 90, maxWidth: 120)
            .focusable(false)

            Text(time(backingTrack.duration))
                .frame(width: 48, alignment: .leading)

            Button {
                NSApp.keyWindow?.makeFirstResponder(nil)
                onTogglePreview()
            } label: {
                Image(systemName: backingTrack.isPreviewing ? "pause.fill" : "play.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .background(Color.secondary.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(backingTrack.isPreviewing ? "Stop backing-track preview" : "Preview from this position")
            .accessibilityLabel(backingTrack.isPreviewing ? "Stop preview" : "Preview backing track")

            Button("Set Start") {
                NSApp.keyWindow?.makeFirstResponder(nil)
                onSetStart()
            }
            .controlSize(.small)
            .focusable(false)

            StartTimeField(
                startTime: backingTrack.startTime,
                duration: backingTrack.duration,
                onChanged: onStartChanged
            )

            Text("Sync")
                .foregroundStyle(.secondary)

            SyncNudgeButton(
                systemImage: "minus",
                help: "Move backing track 10 ms earlier"
            ) {
                onSyncChanged(backingTrack.syncAdjustment - 0.010)
            }

            SyncAdjustmentField(
                adjustment: backingTrack.syncAdjustment,
                onChanged: onSyncChanged
            )

            Text("ms")
                .foregroundStyle(.secondary)

            SyncNudgeButton(
                systemImage: "plus",
                help: "Move backing track 10 ms later"
            ) {
                onSyncChanged(backingTrack.syncAdjustment + 0.010)
            }

            SyncNudgeButton(
                systemImage: "arrow.counterclockwise",
                help: "Reset backing-track sync adjustment"
            ) {
                onSyncChanged(0)
            }

            Button {
                NSApp.keyWindow?.makeFirstResponder(nil)
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 14, height: 17)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Remove backing track")
            .accessibilityLabel("Remove backing track")
        }
        .frame(maxWidth: .infinity)
        .font(.caption.monospacedDigit())
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct StartTimeField: View {
    let startTime: Double
    let duration: Double
    let onChanged: (Double) -> Double

    @StateObject private var editor: StartTimeEditorState
    @FocusState private var isFocused: Bool

    init(startTime: Double, duration: Double, onChanged: @escaping (Double) -> Double) {
        self.startTime = startTime
        self.duration = duration
        self.onChanged = onChanged
        _editor = StateObject(
            wrappedValue: StartTimeEditorState(draft: Self.formatted(startTime))
        )
    }

    var body: some View {
        TextField("Start", text: $editor.draft)
            .font(.system(size: 9, design: .monospaced))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .focused($isFocused)
            .onSubmit {
                isFocused = false
            }
            .onExitCommand {
                isFocused = false
            }
            .padding(.horizontal, 4)
            .frame(width: 62, height: 17)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.primary.opacity(0.25), lineWidth: 1)
            }
            .onChange(of: isFocused) { focused in
                if !focused {
                    commit()
                }
            }
            .onChange(of: startTime) { value in
                if !isFocused {
                    editor.draft = Self.formatted(value)
                }
            }
            .help("Backing-track start time; a negative value delays its start")
    }

    private func commit() {
        guard let value = Self.parse(editor.draft), value.isFinite else {
            editor.draft = Self.formatted(startTime)
            return
        }
        editor.draft = Self.formatted(onChanged(min(max(-duration, value), duration)))
    }

    private static func parse(_ value: String) -> Double? {
        let normalized = value
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sign = normalized.hasPrefix("-") ? -1.0 : 1.0
        let unsigned = normalized.hasPrefix("-") || normalized.hasPrefix("+")
            ? String(normalized.dropFirst())
            : normalized
        let components = unsigned
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else { return nil }

        var seconds = 0.0
        for (index, component) in components.enumerated() {
            guard let part = Double(component), part >= 0 else { return nil }
            if index > 0, part >= 60 { return nil }
            seconds = seconds * 60 + part
        }
        return sign * seconds
    }

    private static func formatted(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.000" }
        let prefix = seconds < 0 ? "-" : ""
        let totalMilliseconds = Int((abs(seconds) * 1_000).rounded())
        let totalSeconds = totalMilliseconds / 1_000
        let milliseconds = totalMilliseconds % 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60
        if hours > 0 {
            return prefix + String(
                format: "%d:%02d:%02d.%03d",
                hours,
                minutes,
                remainingSeconds,
                milliseconds
            )
        }
        return prefix + String(
            format: "%d:%02d.%03d",
            minutes,
            remainingSeconds,
            milliseconds
        )
    }
}

private final class StartTimeEditorState: ObservableObject {
    @Published var draft: String

    init(draft: String) {
        self.draft = draft
    }
}

private struct SyncAdjustmentField: View {
    let adjustment: Double
    let onChanged: (Double) -> Double

    @StateObject private var editor: StartTimeEditorState
    @FocusState private var isFocused: Bool

    init(adjustment: Double, onChanged: @escaping (Double) -> Double) {
        self.adjustment = adjustment
        self.onChanged = onChanged
        _editor = StateObject(
            wrappedValue: StartTimeEditorState(draft: Self.formatted(adjustment))
        )
    }

    var body: some View {
        TextField("Sync", text: $editor.draft)
            .font(.system(size: 9, design: .monospaced))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .focused($isFocused)
            .onSubmit {
                isFocused = false
            }
            .onExitCommand {
                isFocused = false
            }
            .padding(.horizontal, 4)
            .frame(width: 40, height: 17)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.primary.opacity(0.25), lineWidth: 1)
            }
            .onChange(of: isFocused) { focused in
                if !focused {
                    commit()
                }
            }
            .onChange(of: adjustment) { value in
                if !isFocused {
                    editor.draft = Self.formatted(value)
                }
            }
            .help("Backing-track sync adjustment in milliseconds; positive values move it later")
    }

    private func commit() {
        let value = editor.draft
            .lowercased()
            .replacingOccurrences(of: "ms", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let milliseconds = Double(value), milliseconds.isFinite else {
            editor.draft = Self.formatted(adjustment)
            return
        }
        editor.draft = Self.formatted(onChanged(milliseconds / 1_000))
    }

    private static func formatted(_ seconds: Double) -> String {
        String(format: "%+d", Int((seconds * 1_000).rounded()))
    }
}

private struct SyncNudgeButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button {
            NSApp.keyWindow?.makeFirstResponder(nil)
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 16, height: 16)
                .background(Color.secondary.opacity(0.14), in: Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct TransportCircleButton: View {
    let title: String
    let systemImage: String
    let fill: Color
    var size: CGFloat = 32
    let action: () -> Void

    var body: some View {
        Button {
            NSApp.keyWindow?.makeFirstResponder(nil)
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(fill, in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(title)
        .accessibilityLabel(title)
    }
}
