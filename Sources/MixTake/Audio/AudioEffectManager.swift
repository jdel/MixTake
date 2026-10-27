import AppKit
import AudioToolbox
import AVFoundation
import CoreAudioKit
import SwiftUI

enum AudioEffectTarget: Hashable {
    case channel(Int)
    case backingTrack
}

struct AudioEffectSlotID: Hashable {
    let target: AudioEffectTarget
    let index: Int
}

struct AudioEffectComponent: Identifiable {
    let id: String
    let name: String
    let manufacturer: String
    let componentDescription: AudioComponentDescription

    var menuTitle: String {
        manufacturer.isEmpty ? name : "\(manufacturer) — \(name)"
    }
}

struct AudioEffectConfiguration {
    let name: String
    let componentDescription: AudioComponentDescription
    let fullState: [String: Any]?
    let isDocumentState: Bool

    init(
        name: String,
        componentDescription: AudioComponentDescription,
        fullState: [String: Any]?,
        isDocumentState: Bool = false
    ) {
        self.name = name
        self.componentDescription = componentDescription
        self.fullState = fullState
        self.isDocumentState = isDocumentState
    }

    func instantiate() async throws -> AVAudioUnit {
        let unit = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<AVAudioUnit, Error>) in
            AVAudioUnit.instantiate(with: componentDescription) { unit, error in
                if let unit {
                    continuation.resume(returning: unit)
                } else {
                    continuation.resume(
                        throwing: error ?? AudioEffectError.cannotInstantiate(name)
                    )
                }
            }
        }
        if let fullState {
            if isDocumentState {
                unit.auAudioUnit.fullStateForDocument = fullState
            } else {
                unit.auAudioUnit.fullState = fullState
            }
        }
        return unit
    }
}

typealias AudioEffectChains = [AudioEffectTarget: [AudioEffectConfiguration]]

enum AudioEffectError: LocalizedError {
    case cannotInstantiate(String)

    var errorDescription: String? {
        switch self {
        case .cannotInstantiate(let name):
            return "MixTake could not load the \(name) Audio Unit."
        }
    }
}

@MainActor
final class AudioEffectManager: ObservableObject {
    static let maximumEffectsPerTrack = 3

    private final class LoadedEffect {
        let component: AudioEffectComponent
        let audioUnit: AVAudioUnit

        init(component: AudioEffectComponent, audioUnit: AVAudioUnit) {
            self.component = component
            self.audioUnit = audioUnit
        }

        func configuration(forDocument: Bool) -> AudioEffectConfiguration {
            AudioEffectConfiguration(
                name: component.name,
                componentDescription: component.componentDescription,
                fullState: forDocument
                    ? audioUnit.auAudioUnit.fullStateForDocument
                        ?? audioUnit.auAudioUnit.fullState
                    : audioUnit.auAudioUnit.fullState,
                isDocumentState: forDocument
            )
        }
    }

    @Published private(set) var availableComponents: [AudioEffectComponent] = []
    @Published private var slots: [AudioEffectSlotID: LoadedEffect] = [:]

    var onEffectStateChanged: (() -> Void)?

    private var editorWindows: [AudioEffectSlotID: NSWindow] = [:]
    private var editorControllers: [AudioEffectSlotID: NSViewController] = [:]
    private var editorDelegates: [AudioEffectSlotID: EffectWindowDelegate] = [:]
    private var pendingEditorRequests = Set<AudioEffectSlotID>()

    init() {
        refreshComponents()
    }

    func effectName(for target: AudioEffectTarget, slot index: Int) -> String? {
        slots[AudioEffectSlotID(target: target, index: index)]?.component.name
    }

    func visibleSlotCount(for target: AudioEffectTarget) -> Int {
        let highestIndex = slots.keys
            .filter { $0.target == target }
            .map(\.index)
            .max()
        guard let highestIndex else { return 1 }
        return min(Self.maximumEffectsPerTrack, highestIndex + 2)
    }

    func effectCount(for target: AudioEffectTarget) -> Int {
        slots.keys.filter { $0.target == target }.count
    }

    func audioUnits(for target: AudioEffectTarget) -> [AVAudioUnit] {
        slots
            .filter { $0.key.target == target }
            .sorted { $0.key.index < $1.key.index }
            .map { $0.value.audioUnit }
    }

    func audioUnitChains() -> [AudioEffectTarget: [AVAudioUnit]] {
        var indexed: [AudioEffectTarget: [(Int, AVAudioUnit)]] = [:]
        for (id, effect) in slots {
            indexed[id.target, default: []].append((id.index, effect.audioUnit))
        }
        return indexed.mapValues { effects in
            effects.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    func configurations(forDocument: Bool = false) -> AudioEffectChains {
        var indexed: [AudioEffectTarget: [(Int, AudioEffectConfiguration)]] = [:]
        for (id, effect) in slots {
            indexed[id.target, default: []].append((
                id.index,
                effect.configuration(forDocument: forDocument)
            ))
        }
        return indexed.mapValues { effects in
            effects.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    func replaceEffects(
        on target: AudioEffectTarget,
        with configurations: [AudioEffectConfiguration],
        notify: Bool = true
    ) async -> [String] {
        removeAllEffects(from: target, notify: false)
        var failures: [String] = []
        for (index, configuration) in configurations
            .prefix(Self.maximumEffectsPerTrack)
            .enumerated() {
            do {
                let audioUnit = try await configuration.instantiate()
                let component = availableComponents.first {
                    Self.matches(
                        $0.componentDescription,
                        configuration.componentDescription
                    )
                } ?? AudioEffectComponent(
                    id: Self.identifier(for: configuration.componentDescription),
                    name: configuration.name,
                    manufacturer: "",
                    componentDescription: configuration.componentDescription
                )
                slots[AudioEffectSlotID(target: target, index: index)] = LoadedEffect(
                    component: component,
                    audioUnit: audioUnit
                )
            } catch {
                failures.append(configuration.name)
            }
        }
        if notify {
            onEffectStateChanged?()
        }
        return failures
    }

    func replaceAllEffects(with chains: AudioEffectChains) async -> [String] {
        for id in Array(slots.keys) {
            closeEditor(for: id)
        }
        slots.removeAll()
        var failures: [String] = []
        for (target, configurations) in chains {
            failures += await replaceEffects(
                on: target,
                with: configurations,
                notify: false
            )
        }
        onEffectStateChanged?()
        return failures
    }

    func attach(
        _ component: AudioEffectComponent,
        to target: AudioEffectTarget,
        slot index: Int,
        notify: Bool = true
    ) async throws {
        guard (0..<Self.maximumEffectsPerTrack).contains(index) else { return }
        let audioUnit = try await AudioEffectConfiguration(
            name: component.name,
            componentDescription: component.componentDescription,
            fullState: nil
        ).instantiate()
        let id = AudioEffectSlotID(target: target, index: index)
        closeEditor(for: id)
        slots[id] = LoadedEffect(component: component, audioUnit: audioUnit)
        if notify {
            onEffectStateChanged?()
        }
    }

    func removeEffect(
        from target: AudioEffectTarget,
        slot index: Int,
        notify: Bool = true
    ) {
        let id = AudioEffectSlotID(target: target, index: index)
        closeEditor(for: id)
        slots[id] = nil
        if notify {
            onEffectStateChanged?()
        }
    }

    func removeAllEffects(from target: AudioEffectTarget, notify: Bool = true) {
        for id in slots.keys.filter({ $0.target == target }) {
            closeEditor(for: id)
            slots[id] = nil
        }
        if notify {
            onEffectStateChanged?()
        }
    }

    @discardableResult
    func moveEffect(
        on target: AudioEffectTarget,
        from sourceSlot: Int,
        to destinationSlot: Int,
        notify: Bool = true
    ) -> Bool {
        let indexedEffects = slots
            .filter { $0.key.target == target }
            .sorted { $0.key.index < $1.key.index }
        guard let sourceIndex = indexedEffects.firstIndex(where: {
            $0.key.index == sourceSlot
        }), !indexedEffects.isEmpty else { return false }
        var effects = indexedEffects.map { $0.value }

        let boundedDestination = indexedEffects.firstIndex(where: {
            $0.key.index == destinationSlot
        }) ?? (destinationSlot < sourceSlot
            ? max(0, sourceIndex - 1)
            : min(effects.count - 1, sourceIndex + 1))
        guard sourceIndex != boundedDestination else { return false }
        for id in Array(slots.keys.filter { $0.target == target }) {
            closeEditor(for: id)
        }
        let effect = effects.remove(at: sourceIndex)
        effects.insert(effect, at: boundedDestination)
        for id in Array(slots.keys.filter { $0.target == target }) {
            slots[id] = nil
        }
        for (index, effect) in effects.enumerated() {
            slots[AudioEffectSlotID(target: target, index: index)] = effect
        }
        if notify {
            onEffectStateChanged?()
        }
        return true
    }

    func showEditor(for target: AudioEffectTarget, slot index: Int) {
        let id = AudioEffectSlotID(target: target, index: index)
        if let window = editorWindows[id] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if let controller = editorControllers[id],
           let effect = slots[id] {
            presentEditor(
                controller,
                title: "\(effect.component.name) — FX \(index + 1)",
                id: id
            )
            return
        }
        guard !pendingEditorRequests.contains(id) else { return }
        guard let effect = slots[id] else { return }
        pendingEditorRequests.insert(id)
        let requestIdentity = ObjectIdentifier(effect)

        effect.audioUnit.auAudioUnit.requestViewController { [weak self] viewController in
            Task { @MainActor in
                guard let self,
                      let effect = self.slots[id],
                      ObjectIdentifier(effect) == requestIdentity else { return }
                self.pendingEditorRequests.remove(id)
                let controller = viewController ?? NSHostingController(
                    rootView: GenericAudioEffectEditor(audioUnit: effect.audioUnit.auAudioUnit)
                )
                self.editorControllers[id] = controller
                self.presentEditor(
                    controller,
                    title: "\(effect.component.name) — FX \(index + 1)",
                    id: id
                )
            }
        }
    }

    private func refreshComponents() {
        let manager = AVAudioUnitComponentManager.shared()
        let types: [OSType] = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
        var seen = Set<String>()
        availableComponents = types.flatMap { type in
            manager.components(
                matching: AudioComponentDescription(
                    componentType: type,
                    componentSubType: 0,
                    componentManufacturer: 0,
                    componentFlags: 0,
                    componentFlagsMask: 0
                )
            )
        }
        .compactMap { component in
            let description = component.audioComponentDescription
            let id = Self.identifier(for: description)
            guard seen.insert(id).inserted else { return nil }
            return AudioEffectComponent(
                id: id,
                name: component.name,
                manufacturer: component.manufacturerName,
                componentDescription: description
            )
        }
        .sorted {
            if $0.manufacturer == $1.manufacturer {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.manufacturer.localizedCaseInsensitiveCompare($1.manufacturer) == .orderedAscending
        }
    }

    private func presentEditor(
        _ viewController: NSViewController,
        title: String,
        id: AudioEffectSlotID
    ) {
        let contentView = viewController.view
        contentView.layoutSubtreeIfNeeded()
        let preferredSize = viewController.preferredContentSize
        let fittingSize = contentView.fittingSize
        let currentSize = contentView.bounds.size
        let minimumSize = viewController.preferredMinimumSize
        let contentSize = [preferredSize, currentSize, fittingSize, minimumSize].first {
            $0.width > 0 && $0.height > 0
        } ?? NSSize(width: 360, height: 240)

        let window = NSWindow(contentViewController: viewController)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(contentSize)
        window.center()

        let delegate = EffectWindowDelegate { [weak self] in
            // Keep the window and its plug-in controller together for reopening.
            // closeEditor releases both when the effect itself is removed.
            self?.onEffectStateChanged?()
        }
        window.delegate = delegate
        editorWindows[id] = window
        editorDelegates[id] = delegate
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeEditor(for id: AudioEffectSlotID) {
        pendingEditorRequests.remove(id)
        let window = editorWindows[id]
        window?.delegate = nil
        window?.contentViewController = nil
        editorControllers[id] = nil
        window?.close()
        editorWindows[id] = nil
        editorDelegates[id] = nil
    }

    private static func identifier(for description: AudioComponentDescription) -> String {
        [
            description.componentType,
            description.componentSubType,
            description.componentManufacturer
        ]
        .map(String.init)
        .joined(separator: "-")
    }

    private static func matches(
        _ lhs: AudioComponentDescription,
        _ rhs: AudioComponentDescription
    ) -> Bool {
        lhs.componentType == rhs.componentType &&
            lhs.componentSubType == rhs.componentSubType &&
            lhs.componentManufacturer == rhs.componentManufacturer
    }
}

@MainActor
private final class EffectWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

private struct GenericAudioEffectEditor: View {
    let parameters: [AUParameter]
    @StateObject private var model: AudioEffectParameterValues

    init(audioUnit: AUAudioUnit) {
        let parameters = audioUnit.parameterTree?.allParameters ?? []
        self.parameters = parameters
        _model = StateObject(
            wrappedValue: AudioEffectParameterValues(
                values: Dictionary(
                    uniqueKeysWithValues: parameters.map { ($0.address, $0.value) }
                )
            )
        )
    }

    var body: some View {
        Group {
            if parameters.isEmpty {
                Text("This Audio Unit does not provide an editor or editable parameters.")
                    .foregroundStyle(.secondary)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(parameters, id: \.address) { parameter in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(parameter.displayName)
                                    Spacer()
                                    Text(
                                        Double(model.values[parameter.address] ?? parameter.value),
                                        format: .number.precision(.fractionLength(2))
                                    )
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                }
                                Slider(
                                    value: Binding(
                                        get: {
                                            Double(model.values[parameter.address] ?? parameter.value)
                                        },
                                        set: { value in
                                            let newValue = Float(value)
                                            model.values[parameter.address] = newValue
                                            parameter.value = newValue
                                        }
                                    ),
                                    in: Double(parameter.minValue)...Double(parameter.maxValue)
                                )
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 240)
    }
}

@MainActor
private final class AudioEffectParameterValues: ObservableObject {
    @Published var values: [AUParameterAddress: Float]

    init(values: [AUParameterAddress: Float]) {
        self.values = values
    }
}
