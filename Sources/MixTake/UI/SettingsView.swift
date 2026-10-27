import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            DevicesSettingsView(model: model)
                .tabItem { Label("Devices", systemImage: "waveform.and.mic") }

            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(18)
        .frame(width: 680, height: 430)
    }
}

private struct DevicesSettingsView: View {
    @ObservedObject var model: AppModel

    private var settingsAreLocked: Bool {
        model.state == .recording ||
            model.state == .finalizing
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Devices")
                        .font(.headline)
                    Spacer()
                    Button(action: model.refreshDevices) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .foregroundStyle(.secondary)
                    .help("Refresh available devices")
                }

                GroupBox("Input Device") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Camera", selection: cameraSelection) {
                            ForEach(model.cameras) { camera in
                                Text(camera.name).tag(Optional(camera.id))
                            }
                        }

                        Picker("Audio", selection: audioSelection) {
                            ForEach(model.audioInterfaces) { device in
                                Text(device.name).tag(Optional(device.id))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                GroupBox("Output Device") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Audio", selection: outputSelection) {
                            ForEach(model.audioOutputs) { device in
                                Text(device.name).tag(Optional(device.id))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                GroupBox("Monitoring Buffer") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField(
                                "Frames",
                                value: monitoringBufferSelection,
                                format: .number
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)

                            Text("frames")
                                .foregroundStyle(.secondary)

                            Spacer()
                        }

                        if model.monitoringBufferFrames < AppModel.lowMonitoringBufferThreshold {
                            Label(
                                "Very low values may cause clicks or dropouts.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                        } else if model.monitoringBufferFrames > AppModel.highMonitoringBufferThreshold {
                            Label(
                                "Very high values add noticeable monitoring latency.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                        } else {
                            Text("Lower values reduce monitoring latency but require more processing power.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            .frame(width: 290)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Input Channels")
                    .font(.headline)

                if let audioInterface = model.selectedAudioInterface {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(
                                Array(audioInterface.channels.enumerated()),
                                id: \.element
                            ) { position, channel in
                                HStack(spacing: 8) {
                                    Image(systemName: "waveform")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)

                                    Text("Input \(channel + 1)")

                                    Spacer()

                                    Toggle(
                                        "Input \(channel + 1)",
                                        isOn: Binding(
                                            get: { model.enabledChannels.contains(channel) },
                                            set: { model.setChannel(channel, enabled: $0) }
                                        )
                                    )
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)

                                if position < audioInterface.channels.count - 1 {
                                    Divider()
                                        .padding(.leading, 36)
                                }
                            }
                        }
                    }
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("No Core Audio input device is available.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(settingsAreLocked)
    }

    private var cameraSelection: Binding<String?> {
        Binding(
            get: { model.selectedCameraID },
            set: { if let value = $0 { model.selectCamera(value) } }
        )
    }

    private var audioSelection: Binding<String?> {
        Binding(
            get: { model.selectedAudioInterfaceID },
            set: { if let value = $0 { model.selectAudioInterface(value) } }
        )
    }

    private var outputSelection: Binding<String?> {
        Binding(
            get: { model.selectedAudioOutputID },
            set: { if let value = $0 { model.selectAudioOutput(value) } }
        )
    }

    private var monitoringBufferSelection: Binding<Int> {
        Binding(
            get: { model.monitoringBufferFrames },
            set: { model.setMonitoringBufferFrames($0) }
        )
    }
}

private struct AboutSettingsView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private var buildDate: String {
        Bundle.main.object(forInfoDictionaryKey: "MixTakeBuildDate") as? String ?? "Unknown"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.badge.waveform")
                .font(.system(size: 54))
                .foregroundColor(.accentColor)
            Text("MixTake")
                .font(.title2.bold())
            Text("Version \(version) (\(build))")
            Text("Built \(buildDate)")
                .foregroundStyle(.secondary)
            Text("BSD 2-Clause License")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
