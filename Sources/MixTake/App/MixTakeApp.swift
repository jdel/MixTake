import AppKit
import SwiftUI

@main
@MainActor
struct MixTakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("MixTake") {
            MainView(model: model)
        }
        .defaultSize(width: 860, height: 520)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Session…") { model.openSession() }
                    .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Close Window") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.saveSession() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.canSaveSession)
                Button("Save As…") { model.saveSessionAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.canSaveSession)
            }

            CommandGroup(after: .saveItem) {
                Menu("Export") {
                    Button("Export Mix…") { model.exportMix() }
                        .disabled(!model.canExport)
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                    Button("Export Audio…") { model.exportAudio() }
                        .disabled(!model.canExport)
                        .keyboardShortcut("a", modifiers: [.command, .shift])
                    Button("Export Tracks…") { model.exportTracks() }
                        .disabled(!model.canExport)
                        .keyboardShortcut("t", modifiers: [.command, .shift])
                }
            }

            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts…") {
                    model.showKeyboardShortcuts()
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationPending = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let sessionURL = urls.first(where: {
            $0.pathExtension.caseInsensitiveCompare("mixtake") == .orderedSame
        }) else { return }
        AppModel.shared.openSession(at: sessionURL)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        if let warning = AppModel.shared.terminationWarning {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Quit MixTake?"
            alert.informativeText = warning
            alert.addButton(withTitle: "Quit and Discard")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return .terminateCancel
            }
        }
        terminationPending = true
        AppModel.shared.prepareForTermination {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
