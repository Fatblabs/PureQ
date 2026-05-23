//
//  AudioOutputService.swift
//  PureQ
//

import CoreAudio
import Foundation

private let kPureQVirtualMainVolumeProperty = AudioObjectPropertySelector(0x766D_7663) // 'vmvc'
private let pureQMinimumVolumeDecibels: Float = -64
private let pureQMaximumVolumeDecibels: Float = 0

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

    func observeDeviceChanges(handler: @escaping @Sendable () -> Void) {
        stopObservingDeviceChanges()

        let block: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
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
    }

    func stopObservingDeviceChanges() {
        guard !deviceListenerRegistrations.isEmpty else {
            return
        }
        for registration in deviceListenerRegistrations {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(systemObjectID, &address, deviceListenerQueue, registration.block)
        }
        deviceListenerRegistrations.removeAll()
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
            isMuted: isMuted(deviceID: deviceID)
        )
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
        return value.takeUnretainedValue() as String
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
