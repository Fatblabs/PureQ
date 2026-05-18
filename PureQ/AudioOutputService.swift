//
//  AudioOutputService.swift
//  PureQ
//

import CoreAudio
import Foundation

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

final class AudioOutputService {
    private let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

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
}
