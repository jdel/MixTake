import AppKit
import AudioToolbox
import AVFoundation
import Foundation
import Testing
@testable import MixTake

@Suite("Audio effect editor")
@MainActor
struct AudioEffectEditorTests {
    @Test("Editor opens for the attached effect")
    func editorOpensForAttachedEffect() async throws {
        let application = NSApplication.shared
        let manager = AudioEffectManager()
        let component = Self.peakLimiter(named: "Test Peak Limiter \(UUID())")
        let title = "\(component.name) — FX 1"
        defer {
            application.windows.filter { $0.title == title }.forEach { $0.close() }
            manager.removeAllEffects(from: .channel(0), notify: false)
        }

        try await manager.attach(component, to: .channel(0), slot: 0, notify: false)
        manager.showEditor(for: .channel(0), slot: 0)

        let window = await Self.waitForWindow(titled: title, in: application)
        #expect(window != nil)
    }

    @Test("Removing an effect rejects its pending editor request")
    func removingEffectRejectsPendingEditorRequest() async throws {
        let application = NSApplication.shared
        let manager = AudioEffectManager()
        let component = Self.peakLimiter(named: "Removed Peak Limiter \(UUID())")
        let title = "\(component.name) — FX 1"
        defer {
            application.windows.filter { $0.title == title }.forEach { $0.close() }
            manager.removeAllEffects(from: .channel(0), notify: false)
        }

        try await manager.attach(component, to: .channel(0), slot: 0, notify: false)
        manager.showEditor(for: .channel(0), slot: 0)
        manager.removeEffect(from: .channel(0), slot: 0, notify: false)
        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(manager.effectCount(for: .channel(0)) == 0)
        #expect(!application.windows.contains { $0.title == title })
    }

    @Test("AUDelay editor reopens after closing")
    func audioUnitDelayEditorReopensAfterClosing() async throws {
        let application = NSApplication.shared
        let manager = AudioEffectManager()
        let component = Self.audioUnitDelay(named: "Test AUDelay \(UUID())")
        let title = "\(component.name) — FX 1"
        defer {
            application.windows.filter { $0.title == title }.forEach { $0.close() }
            manager.removeAllEffects(from: .channel(0), notify: false)
        }

        try await manager.attach(component, to: .channel(0), slot: 0, notify: false)
        manager.showEditor(for: .channel(0), slot: 0)

        let firstWindow = await Self.waitForWindow(titled: title, in: application)
        #expect(firstWindow != nil)
        firstWindow?.close()

        manager.showEditor(for: .channel(0), slot: 0)
        let reopenedWindow = await Self.waitForWindow(titled: title, in: application)
        reopenedWindow?.displayIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(reopenedWindow?.isVisible == true)
    }

    private static func peakLimiter(named name: String) -> AudioEffectComponent {
        AudioEffectComponent(
            id: name,
            name: name,
            manufacturer: "Apple",
            componentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: kAudioUnitSubType_PeakLimiter,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )
        )
    }

    private static func audioUnitDelay(named name: String) -> AudioEffectComponent {
        AudioEffectComponent(
            id: name,
            name: name,
            manufacturer: "Apple",
            componentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: kAudioUnitSubType_Delay,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )
        )
    }

    private static func waitForWindow(
        titled title: String,
        in application: NSApplication
    ) async -> NSWindow? {
        for _ in 0..<100 {
            if let window = application.windows.first(where: {
                $0.title == title && $0.isVisible
            }) {
                return window
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }
}
