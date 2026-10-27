import AppKit
import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                ZStack {
                    Color.black
                    if model.state == .ready || model.state == .exporting {
                        PlayerView(player: model.playback.player)
                    } else {
                        CameraPreview(session: model.captureEngine.session)
                    }
                }
                .frame(minWidth: 450, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }

                Divider()

                MixerView(
                    model: model,
                    backingTrack: model.backingTrack,
                    audioEffects: model.audioEffects,
                    meterLevels: model.meterLevels
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            TransportView(
                model: model,
                playback: model.playback,
                backingTrack: model.backingTrack
            )
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 680, minHeight: 430)
        .onAppear(perform: model.installKeyboardMonitor)
        .onDisappear(perform: model.removeKeyboardMonitor)
        .alert(
            "MixTake",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
