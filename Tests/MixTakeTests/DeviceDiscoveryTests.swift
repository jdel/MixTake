import Testing
@testable import MixTake

@Suite("Device discovery")
struct DeviceDiscoveryTests {
    @Test("An exact device identifier wins over duplicate names")
    func exactIdentifierWinsOverDuplicateNames() {
        let candidates = [
            (id: "core-a", name: "USB Audio"),
            (id: "core-b", name: "USB Audio")
        ]

        let match = DeviceDiscovery.matchingIdentifier(
            id: "core-b",
            name: "USB Audio",
            candidates: candidates
        )

        #expect(match == "core-b")
    }

    @Test("An ambiguous device name is not used as an identity")
    func ambiguousDeviceNameDoesNotMatch() {
        let candidates = [
            (id: "core-a", name: "USB Audio"),
            (id: "core-b", name: "USB Audio")
        ]

        let match = DeviceDiscovery.matchingIdentifier(
            id: "capture-id",
            name: "USB Audio",
            candidates: candidates
        )

        #expect(match == nil)
    }

    @Test("A unique device name remains a valid fallback")
    func uniqueDeviceNameMatches() {
        let candidates = [
            (id: "core-a", name: "Built-in Microphone"),
            (id: "core-b", name: "USB Audio")
        ]

        let match = DeviceDiscovery.matchingIdentifier(
            id: "capture-id",
            name: "usb audio",
            candidates: candidates
        )

        #expect(match == "core-b")
    }
}
