#!/usr/bin/env swift

import AppKit
import CoreAudio
import Foundation

private let pureQAppBundleIdentifier = "Sean-s-Apps.PureQ"
private let pureQDriverBundleIdentifier = "Sean-s-Apps.PureQ.driver"
private let pureQVirtualOutputUID = "Sean-s-Apps.PureQ.driver.device"
private let pureQVirtualOutputName = "PureQ Virtual Output"

private struct RecoveryState: Decodable {
    var lastHardwareOutputUID: String?
    var lastHardwareOutputName: String?
}

private struct OutputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isHidden: Bool

    var isPureQVirtualOutput: Bool {
        uid == pureQVirtualOutputUID || name == pureQVirtualOutputName
    }
}

private enum PureQAudioRecovery {
    static func restoreIfNeeded() {
        guard !pureQAppIsRunning() else {
            return
        }

        let devices = outputDevices()
        let pureQDevice = devices.first(where: \.isPureQVirtualOutput) ?? hiddenPureQDevice()
        let defaultOutputID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let defaultSystemOutputID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        let pureQIsDefault = pureQDevice.map { device in
            device.id == defaultOutputID || device.id == defaultSystemOutputID
        } ?? false
        let pureQNeedsHiding = pureQDevice?.isHidden == false

        guard pureQIsDefault || pureQNeedsHiding else {
            return
        }

        if pureQIsDefault,
           let fallback = preferredHardwareOutput(from: devices) {
            setDefaultDevice(fallback.id, selector: kAudioHardwarePropertyDefaultOutputDevice)
            setDefaultDevice(fallback.id, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        }

        if let pureQDevice {
            setHidden(true, deviceID: pureQDevice.id)
        }
    }

    private static func pureQAppIsRunning() -> Bool {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: pureQAppBundleIdentifier)
            .contains { !$0.isTerminated }
    }

    private static func preferredHardwareOutput(from devices: [OutputDevice]) -> OutputDevice? {
        let hardwareOutputs = devices.filter { !$0.isPureQVirtualOutput && !$0.isHidden }
        guard !hardwareOutputs.isEmpty else {
            return nil
        }

        if let preferredUID = recoveryState()?.lastHardwareOutputUID,
           let preferred = hardwareOutputs.first(where: { $0.uid == preferredUID }) {
            return preferred
        }

        if let defaultOutputID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice),
           let defaultHardware = hardwareOutputs.first(where: { $0.id == defaultOutputID }) {
            return defaultHardware
        }

        if let defaultSystemOutputID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultSystemOutputDevice),
           let defaultSystemHardware = hardwareOutputs.first(where: { $0.id == defaultSystemOutputID }) {
            return defaultSystemHardware
        }

        return hardwareOutputs.first
    }

    private static func recoveryState() -> RecoveryState? {
        let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("PureQ", isDirectory: true)
            .appendingPathComponent("AudioRecoveryState.json")

        guard let data = try? Data(contentsOf: appSupportURL) else {
            return nil
        }
        return try? JSONDecoder().decode(RecoveryState.self, from: data)
    }

    private static func outputDevices() -> [OutputDevice] {
        allDeviceIDs().compactMap { deviceID in
            guard outputChannelCount(for: deviceID) > 0,
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID) else {
                return nil
            }

            return OutputDevice(
                id: deviceID,
                uid: uid,
                name: stringProperty(kAudioObjectPropertyName, for: deviceID) ?? "Output \(deviceID)",
                isHidden: isHidden(deviceID: deviceID)
            )
        }
    }

    private static func hiddenPureQDevice() -> OutputDevice? {
        guard let deviceID = deviceID(
            forUID: pureQVirtualOutputUID,
            includeHidden: true
        ) else {
            return nil
        }

        return OutputDevice(
            id: deviceID,
            uid: pureQVirtualOutputUID,
            name: stringProperty(kAudioObjectPropertyName, for: deviceID) ?? pureQVirtualOutputName,
            isHidden: isHidden(deviceID: deviceID)
        )
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
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

    private static func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &dataSize, &deviceID)
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    @discardableResult
    private static func setDefaultDevice(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDeviceID = deviceID
        let status = AudioObjectSetPropertyData(
            systemObjectID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableDeviceID
        )
        return status == noErr
    }

    private static func deviceID(forUID uid: String, includeHidden: Bool) -> AudioDeviceID? {
        if let listedDeviceID = allDeviceIDs().first(where: {
            stringProperty(kAudioDevicePropertyDeviceUID, for: $0) == uid
        }) {
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

    private static func translateUIDToDevice(
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
              stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID) == uid else {
            return nil
        }
        return deviceID
    }

    private static func pureQPluginObjectID() -> AudioObjectID? {
        allPluginIDs().first { pluginID in
            stringProperty(kAudioPlugInPropertyBundleID, for: pluginID) == pureQDriverBundleIdentifier
        }
    }

    private static func allPluginIDs() -> [AudioObjectID] {
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

    private static func outputChannelCount(for deviceID: AudioDeviceID) -> Int {
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

    private static func stringProperty(_ selector: AudioObjectPropertySelector, for objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else {
            return nil
        }

        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, pointer)
        }

        guard status == noErr, let value else {
            return nil
        }
        return value.takeRetainedValue() as String
    }

    private static func isHidden(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        return status == noErr && value != 0
    }

    @discardableResult
    private static func setHidden(_ hidden: Bool, deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var value: UInt32 = hidden ? 1 : 0
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &value
        )
        return status == noErr
    }

    private static var systemObjectID: AudioObjectID {
        AudioObjectID(kAudioObjectSystemObject)
    }
}

private func printUsage() {
    print("Usage: PureQAudioRecovery [--restore-if-needed]")
}

switch CommandLine.arguments.dropFirst().first {
case nil, "--restore-if-needed":
    PureQAudioRecovery.restoreIfNeeded()
case "--help", "-h":
    printUsage()
default:
    printUsage()
    exit(64)
}
