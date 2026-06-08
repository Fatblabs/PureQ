//
//  AudioOutputService.swift
//  PureQ
//

import CoreAudio
import Foundation

private let kPureQVirtualMainVolumeProperty = AudioObjectPropertySelector(0x766D_7663) // 'vmvc'
private let pureQMinimumVolumeDecibels: Float = -64
private let pureQMaximumVolumeDecibels: Float = 0
private let pureQDriverBundleID = "Sean-s-Apps.PureQ.driver"

struct AudioOutputDevice: Identifiable, Equatable {
    static let pureQVirtualOutputUID = "Sean-s-Apps.PureQ.driver.device"

    let audioObjectID: AudioDeviceID
    let uid: String
    let name: String
    let channelCount: Int
    let isDefaultOutput: Bool
    let isDefaultSystemOutput: Bool
    let supportsMute: Bool
    let isMuted: Bool
    let nominalSampleRate: Double?

    var id: String { uid }

    var isPureQVirtualOutput: Bool {
        uid == Self.pureQVirtualOutputUID || name == "PureQ Virtual Output"
    }
}

struct AudioOutputSnapshot {
    let devices: [AudioOutputDevice]
    let defaultOutputUID: String?
    let defaultSystemOutputUID: String?
}

struct AudioOutputDeviceDiagnostic: Identifiable, Equatable {
    let audioObjectID: AudioDeviceID
    let uid: String
    let name: String
    let outputChannelCount: Int
    let isDefaultOutput: Bool
    let isDefaultSystemOutput: Bool
    let isPureQVirtualOutput: Bool
    let isHidden: Bool?
    let supportsMute: Bool
    let isMuted: Bool
    let volumeScalar: Float?
    let outputGain: Float?
    let nominalSampleRate: Double?
    let actualSampleRate: Double?
    let streamSampleRates: [Double]
    let availableNominalSampleRateRanges: [ClosedRange<Double>]
    let bufferFrameSize: UInt32?
    let bufferFrameSizeRange: ClosedRange<UInt32>?

    var id: String { uid }
}

struct AudioOutputVolumeState: Equatable {
    let uid: String
    let muted: Bool
    let scalarValues: [AudioOutputVolumeScalarValue]

    var representativeScalar: Float? {
        guard !scalarValues.isEmpty else { return nil }
        return scalarValues.reduce(Float(0)) { $0 + $1.scalar } / Float(scalarValues.count)
    }
}

struct AudioOutputVolumeScalarValue: Equatable {
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope
    let element: AudioObjectPropertyElement
    let scalar: Float
}

enum AudioOutputDeviceChangeReason: Sendable {
    case topology
    case defaultOutput
    case deviceFormat
}

private struct AudioOutputVolumeControl: Hashable {
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope
    let element: AudioObjectPropertyElement
}

final class AudioOutputService {
    private let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
    private let volumeListenerQueue = DispatchQueue(label: "PureQ.AudioOutputService.volume")
    private let deviceListenerQueue = DispatchQueue(label: "PureQ.AudioOutputService.devices")
    private var volumeListenerRegistrations: [AudioDeviceID: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)]] = [:]
    private var deviceListenerRegistrations: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var deviceFormatListenerRegistrations: [AudioDeviceID: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)]] = [:]

    func snapshot() -> AudioOutputSnapshot {
        let defaultID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let defaultSystemID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        let devices = allDeviceIDs()
            .compactMap {
                makeOutputDevice(
                    from: $0,
                    defaultID: defaultID,
                    defaultSystemID: defaultSystemID
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let defaultUID = devices.first(where: { $0.audioObjectID == defaultID })?.uid
        let defaultSystemUID = devices.first(where: { $0.audioObjectID == defaultSystemID })?.uid
        return AudioOutputSnapshot(
            devices: devices,
            defaultOutputUID: defaultUID,
            defaultSystemOutputUID: defaultSystemUID
        )
    }

    func diagnosticDevices(includeHiddenPureQ: Bool = true) -> [AudioOutputDeviceDiagnostic] {
        let defaultID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let defaultSystemID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        var deviceIDs = allDeviceIDs()

        if includeHiddenPureQ,
           let pureQDeviceID = deviceID(
                forUID: AudioOutputDevice.pureQVirtualOutputUID,
                includeHidden: true
           ),
           !deviceIDs.contains(pureQDeviceID) {
            deviceIDs.append(pureQDeviceID)
        }

        return deviceIDs
            .compactMap { makeDiagnosticDevice(from: $0, defaultID: defaultID, defaultSystemID: defaultSystemID) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func setDefaultOutput(uid: String) -> Bool {
        guard let deviceID = allDeviceIDs().first(where: { deviceUID(for: $0) == uid }) else {
            return false
        }

        var outputDeviceID = deviceID
        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var systemOutputDeviceID = deviceID
        var systemOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let outputStatus = AudioObjectSetPropertyData(
            systemObjectID,
            &outputAddress,
            0,
            nil,
            size,
            &outputDeviceID
        )
        let systemOutputStatus = AudioObjectSetPropertyData(
            systemObjectID,
            &systemOutputAddress,
            0,
            nil,
            size,
            &systemOutputDeviceID
        )

        return outputStatus == noErr && systemOutputStatus == noErr
    }

    func setPureQVirtualOutputHidden(_ hidden: Bool) -> Bool {
        guard let deviceID = deviceID(
            forUID: AudioOutputDevice.pureQVirtualOutputUID,
            includeHidden: true
        ) ?? allDeviceIDs().first(where: { deviceID in
            stringProperty(kAudioObjectPropertyName, for: deviceID) == "PureQ Virtual Output"
        }) else {
            return false
        }

        return setHidden(deviceID: deviceID, hidden: hidden)
    }

    func nominalSampleRate(uid: String, includeHidden: Bool = false) -> Double? {
        guard let deviceID = deviceID(forUID: uid, includeHidden: includeHidden) else {
            return nil
        }
        return nominalSampleRate(deviceID: deviceID)
    }

    func actualSampleRate(uid: String, includeHidden: Bool = false) -> Double? {
        guard let deviceID = deviceID(forUID: uid, includeHidden: includeHidden) else {
            return nil
        }
        return actualSampleRate(deviceID: deviceID)
    }

    func setNominalSampleRate(uid: String, sampleRate: Double, includeHidden: Bool = false) -> Bool {
        guard let deviceID = deviceID(forUID: uid, includeHidden: includeHidden) else {
            return false
        }
        return setNominalSampleRate(deviceID: deviceID, sampleRate: sampleRate)
    }

    func streamSampleRates(uid: String, includeHidden: Bool = false) -> [Double] {
        guard let deviceID = deviceID(forUID: uid, includeHidden: includeHidden) else {
            return []
        }
        return streamSampleRates(deviceID: deviceID)
    }

    func deviceName(uid: String, includeHidden: Bool = false) -> String? {
        guard let deviceID = deviceID(forUID: uid, includeHidden: includeHidden) else {
            return nil
        }
        return stringProperty(kAudioObjectPropertyName, for: deviceID)
    }

    func setDeviceName(uid: String, name: String, includeHidden: Bool = false) -> Bool {
        guard let deviceID = deviceID(forUID: uid, includeHidden: includeHidden) else {
            return false
        }
        return setDeviceName(deviceID: deviceID, name: name)
    }

    func bufferFrameSize(uid: String, includeHidden: Bool = false) -> UInt32? {
        guard let deviceID = deviceID(forUID: uid, includeHidden: includeHidden) else {
            return nil
        }
        return bufferFrameSize(deviceID: deviceID)
    }

    func setBufferFrameSize(uid: String, frames: UInt32, includeHidden: Bool = false) -> Bool {
        guard let deviceID = deviceID(forUID: uid, includeHidden: includeHidden) else {
            return false
        }
        return setBufferFrameSize(deviceID: deviceID, frames: frames)
    }

    func setMute(uid: String, muted: Bool) -> Bool {
        guard let deviceID = allDeviceIDs().first(where: { deviceUID(for: $0) == uid }) else {
            return false
        }
        return setMute(deviceID: deviceID, muted: muted)
    }

    func setVolumeScalar(uid: String, scalar: Float) -> Bool {
        guard let deviceID = allDeviceIDs().first(where: { deviceUID(for: $0) == uid }) else {
            return false
        }
        return setVolumeScalar(deviceID: deviceID, scalar: scalar)
    }

    func volumeState(uid: String) -> AudioOutputVolumeState? {
        guard let deviceID = allDeviceIDs().first(where: { deviceUID(for: $0) == uid }) else {
            return nil
        }
        return volumeState(deviceID: deviceID, uid: uid)
    }

    func restoreVolumeState(_ state: AudioOutputVolumeState) -> Bool {
        guard let deviceID = allDeviceIDs().first(where: { deviceUID(for: $0) == state.uid }) else {
            return false
        }

        var changedVolume = false
        for value in state.scalarValues {
            changedVolume = setScalarProperty(
                value.selector,
                deviceID: deviceID,
                scope: value.scope,
                element: value.element,
                scalar: value.scalar
            ) || changedVolume
        }

        let changedMute = setMute(deviceID: deviceID, muted: state.muted)
        return changedVolume || changedMute
    }

    func volumeScalar(uid: String) -> Float? {
        guard let deviceID = allDeviceIDs().first(where: { deviceUID(for: $0) == uid }) else {
            return nil
        }
        return volumeScalar(deviceID: deviceID)
    }

    func outputGain(uid: String) -> Float? {
        guard let deviceID = allDeviceIDs().first(where: { deviceUID(for: $0) == uid }) else {
            return nil
        }
        return outputGain(deviceID: deviceID)
    }

    func muted(uid: String) -> Bool {
        guard let deviceID = allDeviceIDs().first(where: { deviceUID(for: $0) == uid }) else {
            return false
        }
        return isMuted(deviceID: deviceID)
    }

    func observeVolumeChanges(
        deviceID: AudioDeviceID,
        handler: @escaping @Sendable (Float) -> Void
    ) {
        stopObservingVolumeChanges(deviceID: deviceID)

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self,
                  let gain = self.outputGain(deviceID: deviceID) else {
                return
            }
            handler(gain)
        }

        var registrations: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
        let selectors: [AudioObjectPropertySelector] = [
            kAudioDevicePropertyVolumeScalar,
            kAudioDevicePropertyVolumeDecibels,
            kPureQVirtualMainVolumeProperty,
            kAudioDevicePropertyMute
        ]
        let scopes: [AudioObjectPropertyScope] = [
            kAudioDevicePropertyScopeOutput,
            kAudioObjectPropertyScopeGlobal
        ]

        for selector in selectors {
            for scope in scopes {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: scope,
                    mElement: kAudioObjectPropertyElementMain
                )
                guard AudioObjectHasProperty(deviceID, &address) else { continue }
                let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, volumeListenerQueue, block)
                if status == noErr {
                    registrations.append((address, block))
                }
            }
        }

        if !registrations.isEmpty {
            volumeListenerRegistrations[deviceID] = registrations
        }
    }

    func stopObservingVolumeChanges(deviceID: AudioDeviceID) {
        guard let registrations = volumeListenerRegistrations.removeValue(forKey: deviceID) else {
            return
        }
        for registration in registrations {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, volumeListenerQueue, registration.block)
        }
    }

    func observeDeviceChanges(handler: @escaping @Sendable (AudioOutputDeviceChangeReason) -> Void) {
        stopObservingDeviceChanges()

        let block: AudioObjectPropertyListenerBlock = { [weak self] addressCount, addresses in
            var reason = AudioOutputDeviceChangeReason.topology
            for index in 0..<Int(addressCount) {
                let selector = addresses[index].mSelector
                if selector == kAudioHardwarePropertyDefaultOutputDevice ||
                    selector == kAudioHardwarePropertyDefaultSystemOutputDevice {
                    reason = .defaultOutput
                    break
                }
            }
            self?.installDeviceFormatListeners(handler: handler)
            handler(reason)
        }

        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice
        ]
        var registrations: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(systemObjectID, &address) else { continue }
            let status = AudioObjectAddPropertyListenerBlock(systemObjectID, &address, deviceListenerQueue, block)
            if status == noErr {
                registrations.append((address, block))
            }
        }

        deviceListenerRegistrations = registrations
        installDeviceFormatListeners(handler: handler)
    }

    func stopObservingDeviceChanges() {
        for registration in deviceListenerRegistrations {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(systemObjectID, &address, deviceListenerQueue, registration.block)
        }
        deviceListenerRegistrations.removeAll()

        for (deviceID, registrations) in deviceFormatListenerRegistrations {
            for registration in registrations {
                var address = registration.address
                AudioObjectRemovePropertyListenerBlock(deviceID, &address, deviceListenerQueue, registration.block)
            }
        }
        deviceFormatListenerRegistrations.removeAll()
    }

    private func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObjectID, &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard deviceCount > 0 else {
            return []
        }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        let status = deviceIDs.withUnsafeMutableBufferPointer { pointer in
            AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &dataSize, pointer.baseAddress!)
        }

        return status == noErr ? deviceIDs : []
    }

    private func deviceID(forUID uid: String, includeHidden: Bool = false) -> AudioDeviceID? {
        if let listedDeviceID = allDeviceIDs().first(where: { deviceUID(for: $0) == uid }) {
            return listedDeviceID
        }

        guard includeHidden else {
            return nil
        }

        if let translatedDeviceID = translateUIDToDevice(
            uid,
            objectID: systemObjectID,
            selector: kAudioHardwarePropertyTranslateUIDToDevice
        ) {
            return translatedDeviceID
        }

        if let pluginID = pureQPluginObjectID(),
           let translatedDeviceID = translateUIDToDevice(
                uid,
                objectID: pluginID,
                selector: kAudioPlugInPropertyTranslateUIDToDevice
           ) {
            return translatedDeviceID
        }

        return nil
    }

    private func translateUIDToDevice(
        _ uid: String,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else {
            return nil
        }

        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let qualifierSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                qualifierSize,
                uidPointer,
                &dataSize,
                &deviceID
            )
        }

        guard status == noErr,
              deviceID != kAudioObjectUnknown,
              deviceUID(for: deviceID) == uid else {
            return nil
        }
        return deviceID
    }

    private func pureQPluginObjectID() -> AudioObjectID? {
        allPluginIDs().first { pluginID in
            stringProperty(kAudioPlugInPropertyBundleID, for: pluginID) == pureQDriverBundleID
        }
    }

    private func allPluginIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyPlugInList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObjectID, &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let pluginCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard pluginCount > 0 else {
            return []
        }

        var pluginIDs = [AudioObjectID](repeating: 0, count: pluginCount)
        let status = pluginIDs.withUnsafeMutableBufferPointer { pointer in
            AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &dataSize, pointer.baseAddress!)
        }
        return status == noErr ? pluginIDs : []
    }

    private func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &dataSize, &deviceID)

        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    private func makeOutputDevice(
        from deviceID: AudioDeviceID,
        defaultID: AudioDeviceID?,
        defaultSystemID: AudioDeviceID?
    ) -> AudioOutputDevice? {
        let channelCount = outputChannelCount(for: deviceID)
        guard channelCount > 0, let uid = deviceUID(for: deviceID) else {
            return nil
        }

        let name = stringProperty(kAudioObjectPropertyName, for: deviceID) ?? "Output \(deviceID)"
        return AudioOutputDevice(
            audioObjectID: deviceID,
            uid: uid,
            name: name,
            channelCount: channelCount,
            isDefaultOutput: defaultID == deviceID,
            isDefaultSystemOutput: defaultSystemID == deviceID,
            supportsMute: canSetMute(deviceID: deviceID),
            isMuted: isMuted(deviceID: deviceID),
            nominalSampleRate: nominalSampleRate(deviceID: deviceID)
        )
    }

    private func makeDiagnosticDevice(
        from deviceID: AudioDeviceID,
        defaultID: AudioDeviceID?,
        defaultSystemID: AudioDeviceID?
    ) -> AudioOutputDeviceDiagnostic? {
        let channelCount = outputChannelCount(for: deviceID)
        guard channelCount > 0, let uid = deviceUID(for: deviceID) else {
            return nil
        }

        let name = stringProperty(kAudioObjectPropertyName, for: deviceID) ?? "Output \(deviceID)"
        let isPureQVirtualOutput = uid == AudioOutputDevice.pureQVirtualOutputUID || name == "PureQ Virtual Output"
        return AudioOutputDeviceDiagnostic(
            audioObjectID: deviceID,
            uid: uid,
            name: name,
            outputChannelCount: channelCount,
            isDefaultOutput: defaultID == deviceID,
            isDefaultSystemOutput: defaultSystemID == deviceID,
            isPureQVirtualOutput: isPureQVirtualOutput,
            isHidden: hiddenState(deviceID: deviceID),
            supportsMute: canSetMute(deviceID: deviceID),
            isMuted: isMuted(deviceID: deviceID),
            volumeScalar: volumeScalar(deviceID: deviceID),
            outputGain: outputGain(deviceID: deviceID),
            nominalSampleRate: nominalSampleRate(deviceID: deviceID),
            actualSampleRate: actualSampleRate(deviceID: deviceID),
            streamSampleRates: streamSampleRates(deviceID: deviceID),
            availableNominalSampleRateRanges: availableNominalSampleRateRanges(deviceID: deviceID),
            bufferFrameSize: bufferFrameSize(deviceID: deviceID),
            bufferFrameSizeRange: bufferFrameSizeRange(deviceID: deviceID)
        )
    }

    private func installDeviceFormatListeners(handler: @escaping @Sendable (AudioOutputDeviceChangeReason) -> Void) {
        let currentOutputDeviceIDs = Set(allDeviceIDs().filter { outputChannelCount(for: $0) > 0 })

        for deviceID in Array(deviceFormatListenerRegistrations.keys) where !currentOutputDeviceIDs.contains(deviceID) {
            if let registrations = deviceFormatListenerRegistrations.removeValue(forKey: deviceID) {
                for registration in registrations {
                    var address = registration.address
                    AudioObjectRemovePropertyListenerBlock(deviceID, &address, deviceListenerQueue, registration.block)
                }
            }
        }

        for deviceID in currentOutputDeviceIDs where deviceFormatListenerRegistrations[deviceID] == nil {
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                handler(.deviceFormat)
            }
            var registrations: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
            let addresses = [
                AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyNominalSampleRate,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                ),
                AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyActualSampleRate,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                ),
                AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyStreamConfiguration,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: kAudioObjectPropertyElementMain
                ),
                AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyBufferFrameSize,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            ]

            for var address in addresses {
                guard AudioObjectHasProperty(deviceID, &address) else { continue }
                let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, deviceListenerQueue, block)
                if status == noErr {
                    registrations.append((address, block))
                }
            }

            if !registrations.isEmpty {
                deviceFormatListenerRegistrations[deviceID] = registrations
            }
        }
    }

    private func outputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return 0
        }

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
            return 0
        }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawBuffer)
        guard status == noErr else {
            return 0
        }

        let bufferList = rawBuffer.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(bufferList)
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func deviceUID(for deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID)
    }

    private func stringProperty(_ selector: AudioObjectPropertySelector, for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }

        guard status == noErr, let value else {
            return nil
        }
        return value.takeRetainedValue() as String
    }

    private func canSetMute(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var isSettable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        return status == noErr && isSettable.boolValue
    }

    private func isMuted(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var muted = UInt32(0)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &muted)

        return status == noErr && muted != 0
    }

    private func setMute(deviceID: AudioDeviceID, muted: Bool) -> Bool {
        guard canSetMute(deviceID: deviceID) else {
            return false
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var muteValue = UInt32(muted ? 1 : 0)
        let dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, dataSize, &muteValue)

        return status == noErr
    }

    private func setHidden(deviceID: AudioDeviceID, hidden: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var isSettable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
              isSettable.boolValue else {
            return false
        }

        var hiddenValue = UInt32(hidden ? 1 : 0)
        let dataSize = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, dataSize, &hiddenValue) == noErr
    }

    private func hiddenState(deviceID: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var hiddenValue = UInt32(0)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &hiddenValue)
        return status == noErr ? hiddenValue != 0 : nil
    }

    private func nominalSampleRate(deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var value = Float64(0)
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        guard status == noErr, value > 0 else {
            return nil
        }
        return value
    }

    private func actualSampleRate(deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyActualSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var value = Float64(0)
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        guard status == noErr, value > 0 else {
            return nil
        }
        return value
    }

    private func streamSampleRates(deviceID: AudioDeviceID) -> [Double] {
        let scopes = [
            kAudioObjectPropertyScopeInput,
            kAudioObjectPropertyScopeOutput
        ]
        let selectors = [
            kAudioStreamPropertyVirtualFormat,
            kAudioStreamPropertyPhysicalFormat
        ]

        var rates: [Double] = []
        for scope in scopes {
            for streamID in streamIDs(deviceID: deviceID, scope: scope) {
                for selector in selectors {
                    guard let sampleRate = streamSampleRate(streamID: streamID, selector: selector),
                          sampleRate > 0,
                          sampleRate.isFinite else {
                        continue
                    }
                    if !rates.contains(where: { abs($0 - sampleRate) <= 0.5 }) {
                        rates.append(sampleRate)
                    }
                }
            }
        }
        return rates.sorted()
    }

    private func streamIDs(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return []
        }

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let streamCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard streamCount > 0 else {
            return []
        }

        var streamIDs = [AudioObjectID](repeating: 0, count: streamCount)
        let status = streamIDs.withUnsafeMutableBufferPointer { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer.baseAddress!)
        }
        return status == noErr ? streamIDs : []
    }

    private func streamSampleRate(
        streamID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(streamID, &address) else {
            return nil
        }

        var description = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(streamID, &address, 0, nil, &dataSize, &description)
        guard status == noErr,
              description.mSampleRate > 0,
              description.mSampleRate.isFinite else {
            return nil
        }
        return description.mSampleRate
    }

    private func availableNominalSampleRateRanges(deviceID: AudioDeviceID) -> [ClosedRange<Double>] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return []
        }

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let rangeCount = Int(dataSize) / MemoryLayout<AudioValueRange>.size
        guard rangeCount > 0 else {
            return []
        }

        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: rangeCount)
        let status = ranges.withUnsafeMutableBufferPointer { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer.baseAddress!)
        }
        guard status == noErr else {
            return []
        }

        return ranges.compactMap { range in
            guard range.mMinimum.isFinite,
                  range.mMaximum.isFinite,
                  range.mMinimum > 0,
                  range.mMaximum >= range.mMinimum else {
                return nil
            }
            return range.mMinimum...range.mMaximum
        }
    }

    private func setNominalSampleRate(deviceID: AudioDeviceID, sampleRate: Double) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var isSettable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
              isSettable.boolValue else {
            return false
        }

        var value = Float64(sampleRate.clamped(to: 8_000...768_000))
        let dataSize = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, dataSize, &value) == noErr
    }

    private func setDeviceName(deviceID: AudioDeviceID, name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return false
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var isSettable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
              isSettable.boolValue else {
            return false
        }

        var value = trimmedName as CFString
        let dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, dataSize, pointer)
        }
        guard status == noErr else {
            return false
        }

        return stringProperty(kAudioObjectPropertyName, for: deviceID) == trimmedName
    }

    private func bufferFrameSize(deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var value = UInt32(0)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        guard status == noErr, value > 0 else {
            return nil
        }
        return value
    }

    private func setBufferFrameSize(deviceID: AudioDeviceID, frames: UInt32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var isSettable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
              isSettable.boolValue else {
            return false
        }

        var value = clampedBufferFrameSize(deviceID: deviceID, frames: frames)
        guard bufferFrameSize(deviceID: deviceID) != value else {
            return false
        }

        let dataSize = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, dataSize, &value) == noErr
    }

    private func clampedBufferFrameSize(deviceID: AudioDeviceID, frames: UInt32) -> UInt32 {
        guard let range = bufferFrameSizeRange(deviceID: deviceID) else {
            return frames.clamped(to: 64...16_384)
        }

        return frames.clamped(to: range)
    }

    private func bufferFrameSizeRange(deviceID: AudioDeviceID) -> ClosedRange<UInt32>? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var range = AudioValueRange()
        var dataSize = UInt32(MemoryLayout<AudioValueRange>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &range)
        guard status == noErr,
              range.mMinimum.isFinite,
              range.mMaximum.isFinite,
              range.mMaximum >= range.mMinimum else {
            return nil
        }

        let lower = UInt32(max(1, range.mMinimum.rounded(.up)))
        let upper = UInt32(max(Double(lower), range.mMaximum.rounded(.down)))
        return lower...upper
    }

    private func volumeScalar(deviceID: AudioDeviceID) -> Float? {
        if let volume = scalarProperty(
            kAudioDevicePropertyVolumeScalar,
            deviceID: deviceID,
            scope: kAudioDevicePropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        ) {
            return volume
        }

        if let volume = scalarProperty(
            kPureQVirtualMainVolumeProperty,
            deviceID: deviceID,
            scope: kAudioDevicePropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        ) {
            return volume
        }

        return volumeState(deviceID: deviceID, uid: deviceUID(for: deviceID) ?? "").representativeScalar
    }

    private func outputGain(deviceID: AudioDeviceID) -> Float? {
        if let decibels = floatProperty(
            kAudioDevicePropertyVolumeDecibels,
            deviceID: deviceID,
            scope: kAudioDevicePropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        ) {
            return Self.linearGain(fromDecibels: decibels)
        }

        if let scalar = volumeScalar(deviceID: deviceID) {
            return Self.linearGain(fromScalar: scalar)
        }

        return nil
    }

    private func scalarProperty(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var value = Float32(1)
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else {
            return nil
        }
        return value.clamped(to: 0...1)
    }

    private func setVolumeScalar(deviceID: AudioDeviceID, scalar: Float) -> Bool {
        let controls = writableVolumeControls(deviceID: deviceID)
        guard !controls.isEmpty else {
            return false
        }

        let nextScalar = scalar.clamped(to: 0...1)
        var didSet = false
        for control in controls {
            didSet = setScalarProperty(
                control.selector,
                deviceID: deviceID,
                scope: control.scope,
                element: control.element,
                scalar: nextScalar
            ) || didSet
        }
        return didSet
    }

    private func volumeState(deviceID: AudioDeviceID, uid: String) -> AudioOutputVolumeState {
        let scalarValues = readableVolumeControls(deviceID: deviceID).compactMap { control -> AudioOutputVolumeScalarValue? in
            guard let scalar = scalarProperty(
                control.selector,
                deviceID: deviceID,
                scope: control.scope,
                element: control.element
            ) else {
                return nil
            }
            return AudioOutputVolumeScalarValue(
                selector: control.selector,
                scope: control.scope,
                element: control.element,
                scalar: scalar
            )
        }
        return AudioOutputVolumeState(uid: uid, muted: isMuted(deviceID: deviceID), scalarValues: scalarValues)
    }

    private func readableVolumeControls(deviceID: AudioDeviceID) -> [AudioOutputVolumeControl] {
        volumeControls(deviceID: deviceID, requireSettable: false)
    }

    private func writableVolumeControls(deviceID: AudioDeviceID) -> [AudioOutputVolumeControl] {
        volumeControls(deviceID: deviceID, requireSettable: true)
    }

    private func volumeControls(deviceID: AudioDeviceID, requireSettable: Bool) -> [AudioOutputVolumeControl] {
        let channelCount = max(2, min(8, outputChannelCount(for: deviceID)))
        let elements = [kAudioObjectPropertyElementMain] + (1...channelCount).map(AudioObjectPropertyElement.init)
        let selectors: [AudioObjectPropertySelector] = [
            kAudioDevicePropertyVolumeScalar,
            kPureQVirtualMainVolumeProperty
        ]
        let scopes: [AudioObjectPropertyScope] = [
            kAudioDevicePropertyScopeOutput,
            kAudioObjectPropertyScopeGlobal
        ]

        var seen = Set<AudioOutputVolumeControl>()
        var controls: [AudioOutputVolumeControl] = []
        for selector in selectors {
            for scope in scopes {
                for element in elements {
                    let control = AudioOutputVolumeControl(selector: selector, scope: scope, element: element)
                    guard !seen.contains(control),
                          hasScalarProperty(control, deviceID: deviceID),
                          !requireSettable || isScalarPropertySettable(control, deviceID: deviceID) else {
                        continue
                    }
                    seen.insert(control)
                    controls.append(control)
                }
            }
        }

        return controls
    }

    private func hasScalarProperty(_ control: AudioOutputVolumeControl, deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: control.selector,
            mScope: control.scope,
            mElement: control.element
        )
        return AudioObjectHasProperty(deviceID, &address)
    }

    private func isScalarPropertySettable(_ control: AudioOutputVolumeControl, deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: control.selector,
            mScope: control.scope,
            mElement: control.element
        )
        var isSettable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        return status == noErr && isSettable.boolValue
    }

    private func setScalarProperty(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement,
        scalar: Float
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var isSettable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
              isSettable.boolValue else {
            return false
        }

        var value = Float32(scalar.clamped(to: 0...1))
        let dataSize = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, dataSize, &value) == noErr
    }

    private func floatProperty(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var value = Float32(0)
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else {
            return nil
        }
        return value
    }

    private static func linearGain(fromScalar scalar: Float) -> Float {
        let clampedScalar = scalar.clamped(to: 0...1)
        let decibels = clampedScalar * (pureQMaximumVolumeDecibels - pureQMinimumVolumeDecibels) + pureQMinimumVolumeDecibels
        return linearGain(fromDecibels: decibels)
    }

    private static func linearGain(fromDecibels decibels: Float) -> Float {
        if decibels <= pureQMinimumVolumeDecibels {
            return 0
        }
        return pow(10, decibels.clamped(to: pureQMinimumVolumeDecibels...pureQMaximumVolumeDecibels) / 20).clamped(to: 0...1)
    }
}
