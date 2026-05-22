//
//  PureQAudioCallbacks.swift
//  PureQ
//

import AudioToolbox

let pureQLoopbackIOProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
    guard let clientData else {
        return noErr
    }
    let runner = Unmanaged<PureQAudioEngineRunner>.fromOpaque(clientData).takeUnretainedValue()
    let frameCount = pureQFrameCount(from: inputData)
    runner.ingest(inputData: inputData, frameCount: frameCount)
    return noErr
}

let pureQTapIOProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
    guard let clientData else {
        return noErr
    }
    let runner = Unmanaged<PureQAudioEngineRunner>.fromOpaque(clientData).takeUnretainedValue()
    let frameCount = pureQFrameCount(from: inputData)
    runner.ingest(inputData: inputData, frameCount: frameCount)
    return noErr
}

let pureQSuppressionTapIOProc: AudioDeviceIOProc = { _, _, _, _, _, _, _ in
    noErr
}

private func pureQFrameCount(from inputData: UnsafePointer<AudioBufferList>?) -> UInt32 {
    guard let inputData else {
        return 0
    }
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    guard let firstBuffer = buffers.first else {
        return 0
    }
    let channels = max(firstBuffer.mNumberChannels, 1)
    return firstBuffer.mDataByteSize / (UInt32(MemoryLayout<Float>.size) * channels)
}
