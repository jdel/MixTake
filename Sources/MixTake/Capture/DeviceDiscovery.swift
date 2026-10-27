import AVFoundation
import CoreAudio
import Foundation

enum DeviceDiscovery {
    @discardableResult
    static func setBufferFrameSize(_ frameCount: Int, deviceID: UInt32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isSettable: DarwinBoolean = false
        guard AudioObjectHasProperty(AudioDeviceID(deviceID), &address),
              AudioObjectIsPropertySettable(
                AudioDeviceID(deviceID),
                &address,
                &isSettable
              ) == noErr,
              isSettable.boolValue else {
            return false
        }

        var requestedFrames = UInt32(frameCount)
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(
            AudioDeviceID(deviceID),
            &address,
            0,
            nil,
            size,
            &requestedFrames
        ) == noErr
    }

    static func cameras() -> [CameraDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )

        return session.devices
            .filter { $0.isConnected && !$0.isSuspended }
            .map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func defaultCameraID(in cameras: [CameraDevice]) -> String? {
        let preferredID = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .unspecified
        )?.uniqueID ?? AVCaptureDevice.default(for: .video)?.uniqueID
        return cameras.first(where: { $0.id == preferredID })?.id ?? cameras.first?.id
    }

    static func matchingIdentifier(
        id: String,
        name: String,
        candidates: [(id: String, name: String)]
    ) -> String? {
        if let exactMatch = candidates.first(where: { $0.id == id }) {
            return exactMatch.id
        }
        let nameMatches = candidates.filter {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        return nameMatches.count == 1 ? nameMatches[0].id : nil
    }

    static func audioInterfaces() -> [AudioInterface] {
        let captureDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.filter { $0.isConnected && !$0.isSuspended }
        let coreDevices = coreAudioDevices()
        let inputDevices = coreDevices.filter { $0.inputChannels > 0 }
        let inputIdentities = inputDevices.map { (id: $0.uid, name: $0.name) }

        var interfaces: [AudioInterface] = []
        for captureDevice in captureDevices {
            let captureID = captureDevice.uniqueID
            let captureName = captureDevice.localizedName
            let matchingID = matchingIdentifier(
                id: captureID,
                name: captureName,
                candidates: inputIdentities
            )
            guard let matchingID,
                  let matchingDevice = inputDevices.first(where: { $0.uid == matchingID }) else {
                continue
            }
            interfaces.append(
                AudioInterface(
                    id: matchingDevice.uid,
                    configurationID: matchingDevice.uid,
                    name: captureName,
                    captureDeviceID: captureID,
                    coreAudioDeviceID: matchingDevice.deviceID,
                    channelCount: matchingDevice.inputChannels
                )
            )
        }
        interfaces.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        var defaultInterface: AudioInterface?
        if let defaultID = defaultInputDeviceID(),
           let defaultDevice = coreDevices.first(where: { $0.deviceID == defaultID }),
           let matchingID = matchingIdentifier(
               id: defaultDevice.uid,
               name: defaultDevice.name,
               candidates: interfaces.map { (id: $0.id, name: $0.name) }
           ) {
            defaultInterface = interfaces.first { $0.id == matchingID }
        }
        if defaultInterface == nil,
           let captureDefaultID = AVCaptureDevice.default(for: .audio)?.uniqueID {
            defaultInterface = interfaces.first { $0.captureDeviceID == captureDefaultID }
        }

        guard let defaultInterface else { return interfaces }
        let systemDefault = AudioInterface(
            id: AudioInterface.systemDefaultID,
            configurationID: defaultInterface.configurationID,
            name: "System Default — \(defaultInterface.name)",
            captureDeviceID: defaultInterface.captureDeviceID,
            coreAudioDeviceID: defaultInterface.coreAudioDeviceID,
            channelCount: defaultInterface.channelCount
        )
        return [systemDefault] + interfaces
    }

    static func audioOutputs() -> [AudioOutputDevice] {
        let coreDevices = coreAudioDevices()
        let outputs = coreDevices
            .filter { $0.outputChannels > 0 }
            .map {
                AudioOutputDevice(
                    id: $0.uid,
                    name: $0.name,
                    deviceUID: $0.uid,
                    coreAudioDeviceID: $0.deviceID
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        guard let defaultID = defaultOutputDeviceID(),
              let defaultDevice = coreDevices.first(where: { $0.deviceID == defaultID }) else {
            return outputs
        }
        let systemDefault = AudioOutputDevice(
            id: AudioOutputDevice.systemDefaultID,
            name: "System Default — \(defaultDevice.name)",
            deviceUID: nil,
            coreAudioDeviceID: defaultDevice.deviceID
        )
        return [systemDefault] + outputs
    }

    static func inputGain(for audioInterface: AudioInterface, channel: Int) -> InputGain? {
        let deviceID = AudioDeviceID(audioInterface.coreAudioDeviceID)
        let channelElement = AudioObjectPropertyElement(channel + 1)
        if let gain = readInputGain(deviceID: deviceID, element: channelElement) {
            return gain
        }
        return readInputGain(
            deviceID: deviceID,
            element: kAudioObjectPropertyElementMain
        )
    }

    private static func readInputGain(
        deviceID: AudioDeviceID,
        element: AudioObjectPropertyElement
    ) -> InputGain? {
        var valueAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeDecibels,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &valueAddress) else { return nil }

        var isSettable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &valueAddress, &isSettable) == noErr,
              isSettable.boolValue else { return nil }

        var decibels: Float32 = 0
        var valueSize = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &valueAddress,
            0,
            nil,
            &valueSize,
            &decibels
        ) == noErr else { return nil }

        var rangeAddress = valueAddress
        rangeAddress.mSelector = kAudioDevicePropertyVolumeRangeDecibels
        var range = AudioValueRange()
        var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &rangeAddress,
            0,
            nil,
            &rangeSize,
            &range
        ) == noErr else { return nil }

        return InputGain(
            decibels: decibels,
            minimumDecibels: Float(range.mMinimum),
            maximumDecibels: Float(range.mMaximum),
            element: element
        )
    }

    @discardableResult
    static func setInputGain(
        _ decibels: Float,
        for audioInterface: AudioInterface,
        channel: Int
    ) -> InputGain? {
        guard let current = inputGain(for: audioInterface, channel: channel) else { return nil }
        var value = min(current.maximumDecibels, max(current.minimumDecibels, decibels))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeDecibels,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: current.element
        )
        let size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectSetPropertyData(
            AudioDeviceID(audioInterface.coreAudioDeviceID),
            &address,
            0,
            nil,
            size,
            &value
        ) == noErr else { return current }
        return readInputGain(
            deviceID: AudioDeviceID(audioInterface.coreAudioDeviceID),
            element: current.element
        ) ?? current
    }

    private struct CoreDevice {
        let deviceID: AudioDeviceID
        let uid: String
        let name: String
        let inputChannels: Int
        let outputChannels: Int
    }

    private static func coreAudioDevices() -> [CoreDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard deviceIsAlive(deviceID),
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID),
                  let name = stringProperty(kAudioObjectPropertyName, deviceID: deviceID) else {
                return nil
            }
            return CoreDevice(
                deviceID: deviceID,
                uid: uid,
                name: name,
                inputChannels: channelCount(
                    deviceID: deviceID,
                    scope: kAudioDevicePropertyScopeInput
                ),
                outputChannels: channelCount(
                    deviceID: deviceID,
                    scope: kAudioDevicePropertyScopeOutput
                )
            )
        }
    }

    private static func deviceIsAlive(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isAlive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &isAlive
        ) == noErr else {
            return true
        }
        return isAlive != 0
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func channelCount(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return 0
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, storage) == noErr else {
            return 0
        }

        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }
}
