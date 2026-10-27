import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct MixerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var backingTrack: BackingTrackController
    @ObservedObject var audioEffects: AudioEffectManager
    let meterLevels: MeterLevels

    private var width: CGFloat {
        let sourceCount = model.mixerChannels.count + (backingTrack.isLoaded ? 1 : 0)
        let stripCount = sourceCount == 0 ? 0 : sourceCount + 1
        guard stripCount > 0 else { return 140 }
        let strips = CGFloat(stripCount) * MixerLayout.stripWidth
        let gaps = CGFloat(max(0, stripCount - 1)) * MixerLayout.spacing
        return strips + gaps + MixerLayout.horizontalPadding * 2
    }

    var body: some View {
        Group {
            if model.mixerChannels.isEmpty && !backingTrack.isLoaded {
                VStack(spacing: 8) {
                    Image(systemName: "slider.vertical.3")
                        .font(.title2)
                    Text("No Channels")
                        .font(.headline)
                    Text("Choose channels in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: MixerLayout.spacing) {
                    ForEach(model.mixerChannels) { channel in
                        MixerStrip(
                            channel: channel,
                            meterLevels: meterLevels,
                            onVolumeChanged: { model.setVolume($0, for: channel.index) },
                            onGainChanged: { model.setInputGain($0, for: channel.index) },
                            isMonitoring: model.monitoredChannels.contains(channel.index),
                            onToggleMonitoring: {
                                model.toggleInputMonitoring(for: channel.index)
                            },
                            onSavePreset: {
                                model.saveChannelPreset(for: channel.index)
                            },
                            onLoadPreset: {
                                model.loadChannelPreset(for: channel.index)
                            },
                            presetsEnabled: model.canEditEffects,
                            effectSlotCount: audioEffects.visibleSlotCount(
                                for: .channel(channel.index)
                            ),
                            effectControls: effectControls(for: .channel(channel.index))
                        )
                    }
                    if backingTrack.isLoaded {
                        BackingTrackStrip(
                            backingTrack: backingTrack,
                            onVolumeChanged: model.setBackingTrackVolume,
                            effectSlotCount: audioEffects.visibleSlotCount(for: .backingTrack),
                            effectControls: effectControls(for: .backingTrack)
                        )
                    }
                    OutputStrip(outputMeter: model.outputMeter)
                }
                .padding(.horizontal, MixerLayout.horizontalPadding)
                .padding(.vertical, 10)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
    }

    private func effectControls(for target: AudioEffectTarget) -> EffectChainControl {
        EffectChainControl(
            audioEffects: audioEffects,
            target: target,
            isEnabled: model.canEditEffects,
            onAttach: { component, slot in
                model.attachEffect(component, to: target, slot: slot)
            },
            onOpen: { slot in model.showEffectEditor(for: target, slot: slot) },
            onRemove: { slot in model.removeEffect(from: target, slot: slot) },
            onMove: { source, destination in
                model.moveEffect(on: target, from: source, to: destination)
            }
        )
    }
}

private struct BackingTrackStrip: View {
    @ObservedObject var backingTrack: BackingTrackController
    let onVolumeChanged: (Float) -> Void
    let effectSlotCount: Int
    let effectControls: EffectChainControl

    var body: some View {
        GeometryReader { geometry in
            let effectHeight = MixerLayout.effectHeight(for: effectSlotCount)
            let fixedHeight: CGFloat = 68 + effectHeight
            let faderHeight = max(8, geometry.size.height - fixedHeight)

            VStack(spacing: 8) {
                Text("BT")
                    .font(.caption.bold())
                    .frame(height: 14)

                VerticalFader(
                    value: Binding(
                        get: { Double(backingTrack.volume) },
                        set: { onVolumeChanged(Float($0)) }
                    )
                )
                .frame(width: 28, height: faderHeight)

                Text(backingTrack.volume, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 14)

                effectControls
                    .frame(height: effectHeight)
            }
            .padding(.vertical, 8)
            .frame(width: MixerLayout.stripWidth, height: geometry.size.height, alignment: .top)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .help(backingTrack.displayName)
        }
        .frame(width: MixerLayout.stripWidth)
    }
}

private enum MixerLayout {
    static let stripWidth: CGFloat = 66
    static let spacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 10

    static func effectHeight(for slotCount: Int) -> CGFloat {
        CGFloat(slotCount) * 18 + CGFloat(max(0, slotCount - 1)) * 3
    }
}

private struct EffectChainControl: View {
    @ObservedObject var audioEffects: AudioEffectManager
    let target: AudioEffectTarget
    let isEnabled: Bool
    let onAttach: (AudioEffectComponent, Int) -> Void
    let onOpen: (Int) -> Void
    let onRemove: (Int) -> Void
    let onMove: (Int, Int) -> Void

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<audioEffects.visibleSlotCount(for: target), id: \.self) { slot in
                EffectSlotControl(
                    slotNumber: slot + 1,
                    effectName: audioEffects.effectName(for: target, slot: slot),
                    availableComponents: audioEffects.availableComponents,
                    isEnabled: isEnabled,
                    canMoveEarlier: slot > 0,
                    canMoveLater: slot < audioEffects.effectCount(for: target) - 1,
                    onAttach: { onAttach($0, slot) },
                    onOpen: { onOpen(slot) },
                    onRemove: { onRemove(slot) },
                    onMoveEarlier: { onMove(slot, slot - 1) },
                    onMoveLater: { onMove(slot, slot + 1) },
                    onMoveFrom: { source in
                        guard source != slot else { return }
                        onMove(source, slot)
                    }
                )
                .frame(height: 18)
            }
        }
    }
}

private struct EffectSlotControl: View {
    let slotNumber: Int
    let effectName: String?
    let availableComponents: [AudioEffectComponent]
    let isEnabled: Bool
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let onAttach: (AudioEffectComponent) -> Void
    let onOpen: () -> Void
    let onRemove: () -> Void
    let onMoveEarlier: () -> Void
    let onMoveLater: () -> Void
    let onMoveFrom: (Int) -> Void

    var body: some View {
        HStack(spacing: 3) {
            if let effectName {
                Button("FX \(slotNumber)", action: onOpen)
                    .font(.system(size: 9, weight: .semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.accentColor)
                    .focusable(false)
                    .help("Open FX \(slotNumber): \(effectName). Drag or right-click to reorder.")

                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .semibold))
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Remove FX \(slotNumber): \(effectName)")
                .accessibilityLabel("Remove audio effect \(slotNumber)")
            } else {
                Menu {
                    if availableComponents.isEmpty {
                        Text("No Audio Units Found")
                    } else {
                        ForEach(availableComponents) { component in
                            Button(component.menuTitle) {
                                onAttach(component)
                            }
                        }
                    }
                } label: {
                    Text("FX \(slotNumber)")
                        .font(.system(size: 9, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 40)
                .focusable(false)
                .help("Choose Audio Unit effect \(slotNumber)")
            }
        }
        .disabled(!isEnabled)
        .contextMenu {
            if effectName != nil {
                Button("Move Earlier", action: onMoveEarlier)
                    .disabled(!canMoveEarlier)
                Button("Move Later", action: onMoveLater)
                    .disabled(!canMoveLater)
            }
        }
        .onDrag {
            guard effectName != nil else { return NSItemProvider() }
            return NSItemProvider(object: String(slotNumber - 1) as NSString)
        }
        .onDrop(of: [UTType.text], isTargeted: nil) { providers in
            guard effectName != nil, let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let value = object as? NSString,
                      let source = Int(value as String) else { return }
                DispatchQueue.main.async {
                    onMoveFrom(source)
                }
            }
            return true
        }
    }
}

private struct MixerStrip: View {
    let channel: MixerChannel
    let meterLevels: MeterLevels
    let onVolumeChanged: (Float) -> Void
    let onGainChanged: (Float) -> Float?
    let isMonitoring: Bool
    let onToggleMonitoring: () -> Void
    let onSavePreset: () -> Void
    let onLoadPreset: () -> Void
    let presetsEnabled: Bool
    let effectSlotCount: Int
    let effectControls: EffectChainControl

    var body: some View {
        GeometryReader { geometry in
            let effectHeight = MixerLayout.effectHeight(for: effectSlotCount)
            let fixedHeight: CGFloat = (channel.inputGain == nil ? 100 : 137) + effectHeight
            let flexibleHeight = max(24, (geometry.size.height - fixedHeight) / 2)

            VStack(spacing: 8) {
                Menu {
                    Button("Save Preset…", action: onSavePreset)
                    Button("Load Preset…", action: onLoadPreset)
                } label: {
                    Text("CH \(channel.number)")
                        .font(.caption.bold())
                        .monospacedDigit()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .frame(height: 14)
                .disabled(!presetsEnabled)
                .help("Save or load a channel-strip preset")

                HStack(spacing: 4) {
                    InputMonitorButton(
                        isMonitoring: isMonitoring,
                        action: onToggleMonitoring
                    )
                    ChannelClipIndicator(meterLevels: meterLevels, channel: channel.index)
                }
                .frame(height: 16)

                ChannelLevelMeter(meterLevels: meterLevels, channel: channel.index)
                    .frame(width: 12, height: flexibleHeight)

                if let gain = channel.inputGain {
                    GainValueField(gain: gain, onChanged: onGainChanged)
                        .frame(height: 29)
                }

                VerticalFader(
                    value: Binding(
                        get: { Double(channel.volume) },
                        set: { onVolumeChanged(Float($0)) }
                    )
                )
                .frame(width: 28, height: flexibleHeight)

                Text(channel.volume, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 14)

                effectControls
                    .frame(height: effectHeight)
            }
            .padding(.vertical, 8)
            .frame(width: MixerLayout.stripWidth, height: geometry.size.height, alignment: .top)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        }
        .frame(width: MixerLayout.stripWidth)
    }
}

private struct InputMonitorButton: View {
    let isMonitoring: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "headphones")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isMonitoring ? Color.accentColor : Color.secondary)
                .frame(width: 15, height: 16)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(isMonitoring ? "Turn input monitoring off" : "Monitor input through FX")
        .accessibilityLabel("Input monitoring")
        .accessibilityValue(isMonitoring ? "On" : "Off")
    }
}

private struct OutputStrip: View {
    @ObservedObject var outputMeter: OutputMeter

    var body: some View {
        GeometryReader { geometry in
            let meterHeight = max(24, geometry.size.height - 55)

            VStack(spacing: 8) {
                Text("OUT")
                    .font(.caption.bold())
                    .frame(height: 14)

                ClipIndicator(
                    clipped: outputMeter.clipped,
                    action: outputMeter.resetClipping
                )

                LevelMeter(
                    peak: outputMeter.peak,
                    accessibilityLabel: "Output level"
                )
                .frame(width: 12, height: meterHeight)
            }
            .padding(.vertical, 8)
            .frame(width: MixerLayout.stripWidth, height: geometry.size.height, alignment: .top)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        }
        .frame(width: MixerLayout.stripWidth)
    }
}

private struct ChannelClipIndicator: View {
    @ObservedObject var meterLevels: MeterLevels
    let channel: Int

    var body: some View {
        ClipIndicator(
            clipped: meterLevels.clippedChannels.contains(channel),
            action: { meterLevels.resetClipping(for: channel) }
        )
    }
}

private struct ChannelLevelMeter: View {
    @ObservedObject var meterLevels: MeterLevels
    let channel: Int

    var body: some View {
        LevelMeter(peak: meterLevels.peaks[channel] ?? 0)
    }
}

private struct ClipIndicator: View {
    let clipped: Bool
    let action: () -> Void

    var body: some View {
        Button {
            NSApp.keyWindow?.makeFirstResponder(nil)
            action()
        } label: {
            Circle()
                .fill(clipped ? Color.red : Color(nsColor: .controlColor))
                .overlay {
                    Circle()
                        .stroke(Color.primary.opacity(0.42), lineWidth: 1)
                }
                .shadow(color: .white.opacity(0.5), radius: 0.5, x: -0.5, y: -0.5)
                .shadow(color: .black.opacity(0.35), radius: 0.5, x: 0.5, y: 0.5)
                .frame(width: 9, height: 9)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(clipped ? "Clipping detected. Click to reset." : "No clipping detected")
        .accessibilityLabel("Clipping indicator")
        .accessibilityValue(clipped ? "Clipping detected" : "No clipping detected")
        .accessibilityHint("Click to reset")
    }
}

private struct GainValueField: View {
    let gain: InputGain
    let onChanged: (Float) -> Float?

    @StateObject private var editor: GainEditorState
    @FocusState private var isFocused: Bool

    init(gain: InputGain, onChanged: @escaping (Float) -> Float?) {
        self.gain = gain
        self.onChanged = onChanged
        _editor = StateObject(
            wrappedValue: GainEditorState(draft: Self.formatted(gain.decibels))
        )
    }

    var body: some View {
        HStack(spacing: 2) {
            VStack(spacing: 0) {
                TextField("Gain", text: $editor.draft)
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
                    .frame(width: 37, height: 17)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 3))
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.primary.opacity(0.25), lineWidth: 1)
                    }

                Text("dB")
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
                    .frame(height: 9)
            }

            Button(action: reset) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 7, weight: .semibold))
                    .frame(width: 11, height: 17)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Reset hardware input gain to 0 dB")
            .accessibilityLabel("Reset input gain")
        }
        .onChange(of: isFocused) { _, focused in
            if !focused {
                commit()
            }
        }
        .onChange(of: gain.decibels) { _, decibels in
            if !isFocused {
                editor.draft = Self.formatted(decibels)
            }
        }
        .help(
            Text(
                String(
                    format: "Hardware input gain (%.1f to %.1f dB)",
                    gain.minimumDecibels,
                    gain.maximumDecibels
                )
            )
        )
    }

    private func commit() {
        let normalized = editor.draft.replacingOccurrences(of: ",", with: ".")
        guard let value = Float(normalized), value.isFinite else {
            editor.draft = Self.formatted(gain.decibels)
            return
        }
        let actualValue = onChanged(value) ?? gain.decibels
        editor.draft = Self.formatted(actualValue)
    }

    private func reset() {
        isFocused = false
        let actualValue = onChanged(0) ?? gain.decibels
        editor.draft = Self.formatted(actualValue)
    }

    private static func formatted(_ value: Float) -> String {
        String(format: "%.1f", value)
    }
}

private final class GainEditorState: ObservableObject {
    @Published var draft: String

    init(draft: String) {
        self.draft = draft
    }
}

private struct VerticalFader: View {
    @Binding var value: Double

    private let thumbHeight: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.height - thumbHeight)
            let thumbY = thumbHeight / 2 + travel * (1 - value)

            ZStack {
                Capsule()
                    .fill(Color.primary.opacity(0.22))
                    .frame(width: 4, height: travel)

                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.white.opacity(0.65), lineWidth: 1)
                    }
                    .frame(width: 24, height: thumbHeight)
                    .position(x: geometry.size.width / 2, y: thumbY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let position = (gesture.location.y - thumbHeight / 2) / travel
                        value = min(1, max(0, 1 - position))
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Channel volume")
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                value = min(1, value + 0.01)
            case .decrement:
                value = max(0, value - 0.01)
            @unknown default:
                break
            }
        }
    }
}

private struct LevelMeter: View {
    let peak: Float
    let accessibilityLabel: String

    init(peak: Float, accessibilityLabel: String = "Input level") {
        self.peak = peak
        self.accessibilityLabel = accessibilityLabel
    }

    private var normalizedLevel: CGFloat {
        guard peak > 0 else { return 0 }
        let decibels = 20 * log10(Double(peak))
        return CGFloat(min(1, max(0, (decibels + 60) / 60)))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.black.opacity(0.45))
                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: [.green, .green, .yellow, .red],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(height: geometry.size.height * normalizedLevel)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }
}
