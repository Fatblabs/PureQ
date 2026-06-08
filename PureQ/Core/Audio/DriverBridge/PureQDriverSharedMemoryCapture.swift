//
//  PureQDriverSharedMemoryCapture.swift
//  PureQ
//

import AudioToolbox
import CoreAudio
import Darwin
import Foundation

private enum PureQSharedAudioLayout {
    static let magic: UInt32 = 0x50555251
    static let version: UInt32 = 1
    static let fallbackPath = "/tmp/PureQAudioRing.v1"
    static let capacityFrames: UInt32 = 65_536
    static let channelCount: UInt32 = 2
    static let headerSize = 64
    static let samplesOffset = 64
    static let magicOffset = 0
    static let versionOffset = 4
    static let capacityFramesOffset = 8
    static let channelsOffset = 12
    static let frameCountOffset = 16
    static let resetCounterOffset = 20
    static let writeCounterOffset = 24
    static let sampleRateOffset = 32
    static let sharedRingPathSelector = AudioObjectPropertySelector(0x7071_7370) // 'pqsp'

    static var totalSize: Int {
        samplesOffset + Int(capacityFrames) * Int(channelCount) * MemoryLayout<Float>.size
    }
}

enum PureQDriverCaptureError: LocalizedError {
    case createFailed(Int32)
    case truncateFailed(Int32)
    case mmapFailed(Int32)
    case driverPathSetFailed(OSStatus)
    case fallbackUnavailable

    var errorDescription: String? {
        switch self {
        case .createFailed(let code):
            return "Could not create PureQ shared-memory capture file. errno \(code)."
        case .truncateFailed(let code):
            return "Could not size PureQ shared-memory capture file. errno \(code)."
        case .mmapFailed(let code):
            return "Could not map PureQ shared-memory capture file. errno \(code)."
        case .driverPathSetFailed(let status):
            return "PureQ driver rejected the shared-memory capture path. OSStatus \(status)."
        case .fallbackUnavailable:
            return "PureQ driver shared-memory capture is unavailable."
        }
    }
}

final class PureQDriverSharedMemoryCapture: @unchecked Sendable {
    let deviceID: AudioDeviceID
    private nonisolated(unsafe) var descriptor: Int32 = -1
    private nonisolated(unsafe) var mappedAddress: UnsafeMutableRawPointer?
    private nonisolated(unsafe) var mappedSize = 0
    private nonisolated(unsafe) var path = ""
    private nonisolated(unsafe) var ownsPath = false

    init(deviceID: AudioDeviceID) {
        self.deviceID = deviceID
    }

    var isConnected: Bool {
        mappedAddress != nil
    }

    deinit {
        disconnect()
    }

    func connect() throws {
        guard mappedAddress == nil else { return }
        disconnect()

        do {
            try createAppOwnedMapping()
            let status = setDriverSharedMemoryPath(path)
            guard status == noErr else {
                throw PureQDriverCaptureError.driverPathSetFailed(status)
            }
        } catch {
            disconnect()
            try connectToFallbackMapping()
        }
    }

    func makeReader(outputSampleRate: Double) -> PureQDriverSharedMemoryReader? {
        guard let mappedAddress else { return nil }
        return PureQDriverSharedMemoryReader(
            capture: self,
            mappedAddress: mappedAddress,
            outputSampleRate: outputSampleRate
        )
    }

    func disconnect() {
        // Leave the driver mapped until a replacement path is installed; unmapping from the
        // property thread can race with CoreAudio's realtime WriteMix callback.
        if let mappedAddress, mappedSize > 0 {
            munmap(mappedAddress, mappedSize)
        }
        mappedAddress = nil
        mappedSize = 0

        if descriptor >= 0 {
            close(descriptor)
        }
        descriptor = -1

        if ownsPath, !path.isEmpty {
            unlink(path)
        }
        path = ""
        ownsPath = false
    }

    private func createAppOwnedMapping() throws {
        var pathTemplate = Array("/tmp/pureq-audio-\(getpid())-XXXXXX.shm".utf8CString)
        let fd = pathTemplate.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return mkstemps(baseAddress, 4)
        }
        guard fd >= 0 else {
            throw PureQDriverCaptureError.createFailed(errno)
        }
        let capturePath = String(cString: pathTemplate)

        let size = PureQSharedAudioLayout.totalSize
        guard ftruncate(fd, off_t(size)) == 0 else {
            let code = errno
            close(fd)
            unlink(capturePath)
            throw PureQDriverCaptureError.truncateFailed(code)
        }
        fchmod(fd, 0o666)

        guard let address = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              address != MAP_FAILED else {
            let code = errno
            close(fd)
            unlink(capturePath)
            throw PureQDriverCaptureError.mmapFailed(code)
        }

        descriptor = fd
        mappedAddress = address
        mappedSize = size
        path = capturePath
        ownsPath = true
        initialiseHeader(at: address)
    }

    private func connectToFallbackMapping() throws {
        let fd = open(PureQSharedAudioLayout.fallbackPath, O_RDWR, 0)
        guard fd >= 0 else {
            throw PureQDriverCaptureError.fallbackUnavailable
        }

        let size = PureQSharedAudioLayout.totalSize
        guard let address = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              address != MAP_FAILED else {
            let code = errno
            close(fd)
            throw PureQDriverCaptureError.mmapFailed(code)
        }

        guard hasValidHeader(at: address) else {
            munmap(address, size)
            close(fd)
            throw PureQDriverCaptureError.fallbackUnavailable
        }

        descriptor = fd
        mappedAddress = address
        mappedSize = size
        path = PureQSharedAudioLayout.fallbackPath
        ownsPath = false
    }

    private func setDriverSharedMemoryPath(_ path: String) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: PureQSharedAudioLayout.sharedRingPathSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfPath: CFString? = path as CFString
        return withUnsafeMutablePointer(to: &cfPath) { pointer in
            AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<CFString?>.size),
                pointer
            )
        }
    }

    private func initialiseHeader(at address: UnsafeMutableRawPointer) {
        address.storeUInt32(PureQSharedAudioLayout.magic, offset: PureQSharedAudioLayout.magicOffset)
        address.storeUInt32(PureQSharedAudioLayout.version, offset: PureQSharedAudioLayout.versionOffset)
        address.storeUInt32(PureQSharedAudioLayout.capacityFrames, offset: PureQSharedAudioLayout.capacityFramesOffset)
        address.storeUInt32(PureQSharedAudioLayout.channelCount, offset: PureQSharedAudioLayout.channelsOffset)
        address.storeUInt32(0, offset: PureQSharedAudioLayout.frameCountOffset)
        address.storeUInt32(0, offset: PureQSharedAudioLayout.resetCounterOffset)
        address.storeUInt64(0, offset: PureQSharedAudioLayout.writeCounterOffset)
        address.storeFloat64(48_000, offset: PureQSharedAudioLayout.sampleRateOffset)
        memset(address.advanced(by: PureQSharedAudioLayout.samplesOffset), 0, PureQSharedAudioLayout.totalSize - PureQSharedAudioLayout.samplesOffset)
    }

    private func hasValidHeader(at address: UnsafeMutableRawPointer) -> Bool {
        address.loadAtomicUInt32(offset: PureQSharedAudioLayout.magicOffset) == PureQSharedAudioLayout.magic &&
            address.loadAtomicUInt32(offset: PureQSharedAudioLayout.versionOffset) == PureQSharedAudioLayout.version &&
            address.loadAtomicUInt32(offset: PureQSharedAudioLayout.capacityFramesOffset) == PureQSharedAudioLayout.capacityFrames &&
            address.loadAtomicUInt32(offset: PureQSharedAudioLayout.channelsOffset) == PureQSharedAudioLayout.channelCount
    }
}

final class PureQDriverSharedMemoryReader: @unchecked Sendable {
    private let capture: PureQDriverSharedMemoryCapture
    private let mappedAddress: UnsafeMutableRawPointer
    private let outputSampleRate: Double
    private nonisolated(unsafe) var readCounter: UInt64 = 0
    private nonisolated(unsafe) var firstPoll = true
    private nonisolated(unsafe) var lastConsumedFrameCount: UInt32 = 0
    private nonisolated(unsafe) var overflowCount: UInt64 = 0
    private nonisolated(unsafe) var lastResetCounter: UInt32 = 0

    init(capture: PureQDriverSharedMemoryCapture, mappedAddress: UnsafeMutableRawPointer, outputSampleRate: Double) {
        self.capture = capture
        self.mappedAddress = mappedAddress
        self.outputSampleRate = outputSampleRate.clamped(to: 8_000...768_000)
    }

    var availableFrameCount: Int {
        let writeCounter = mappedAddress.loadAtomicUInt64(offset: PureQSharedAudioLayout.writeCounterOffset)
        guard writeCounter >= readCounter else { return 0 }
        return Int(min(UInt64(PureQSharedAudioLayout.capacityFrames), writeCounter - readCounter))
    }

    var consumedFrameCount: UInt32 {
        lastConsumedFrameCount
    }

    @inline(__always)
    func read(into outputData: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) -> UInt32 {
        let requestedFrames = Int(frameCount)
        guard requestedFrames > 0 else { return 0 }
        lastConsumedFrameCount = 0

        let magic = mappedAddress.loadAtomicUInt32(offset: PureQSharedAudioLayout.magicOffset)
        let version = mappedAddress.loadAtomicUInt32(offset: PureQSharedAudioLayout.versionOffset)
        let capacity = mappedAddress.loadAtomicUInt32(offset: PureQSharedAudioLayout.capacityFramesOffset)
        let channels = mappedAddress.loadAtomicUInt32(offset: PureQSharedAudioLayout.channelsOffset)
        let lastFrameCount = mappedAddress.loadAtomicUInt32(offset: PureQSharedAudioLayout.frameCountOffset)
        let resetCounter = mappedAddress.loadAtomicUInt32(offset: PureQSharedAudioLayout.resetCounterOffset)
        let writeCounter = mappedAddress.loadAtomicUInt64(offset: PureQSharedAudioLayout.writeCounterOffset)

        guard magic == PureQSharedAudioLayout.magic,
              version == PureQSharedAudioLayout.version,
              channels == PureQSharedAudioLayout.channelCount,
              capacity == PureQSharedAudioLayout.capacityFrames else {
            zeroFill(outputData, frameOffset: 0, frameCount: requestedFrames)
            return 0
        }

        let sourceSampleRate = mappedAddress
            .loadFloat64(offset: PureQSharedAudioLayout.sampleRateOffset)
            .clamped(to: 8_000...768_000)

        guard sampleRatesMatch(sourceSampleRate, outputSampleRate) else {
            readCounter = writeCounter
            zeroFill(outputData, frameOffset: 0, frameCount: requestedFrames)
            return 0
        }

        if firstPoll {
            firstPoll = false
            lastResetCounter = resetCounter
            readCounter = writeCounter
            zeroFill(outputData, frameOffset: 0, frameCount: requestedFrames)
            return 0
        }

        if resetCounter != lastResetCounter {
            lastResetCounter = resetCounter
            readCounter = writeCounter
            zeroFill(outputData, frameOffset: 0, frameCount: requestedFrames)
            return 0
        }

        if writeCounter < readCounter {
            readCounter = writeCounter
            zeroFill(outputData, frameOffset: 0, frameCount: requestedFrames)
            return 0
        }

        guard lastFrameCount > 0, writeCounter > readCounter else {
            zeroFill(outputData, frameOffset: 0, frameCount: requestedFrames)
            return 0
        }

        let availableFrames = writeCounter - readCounter
        if availableFrames > UInt64(capacity / 2) {
            overflowCount &+= 1
            readCounter = writeCounter
            zeroFill(outputData, frameOffset: 0, frameCount: requestedFrames)
            return 0
        }

        let framesToRead = Int(min(availableFrames, UInt64(requestedFrames)))
        guard framesToRead > 0 else {
            zeroFill(outputData, frameOffset: 0, frameCount: requestedFrames)
            return 0
        }

        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        let samples = mappedAddress
            .advanced(by: PureQSharedAudioLayout.samplesOffset)
            .assumingMemoryBound(to: Float.self)

        let capacityFrames = UInt64(capacity)
        var localReadCounter = readCounter
        for frame in 0..<framesToRead {
            let currentFrame = Int(localReadCounter % capacityFrames)
            let currentOffset = currentFrame * Int(channels)
            let left = sanitizedSample(samples[currentOffset])
            let right = sanitizedSample(samples[currentOffset + 1])
            writeFrame(left: left, right: right, into: buffers, frame: frame)
            localReadCounter &+= 1
        }

        readCounter = localReadCounter
        lastConsumedFrameCount = UInt32(framesToRead.clamped(to: 0...Int(UInt32.max)))
        if framesToRead < requestedFrames {
            zeroFill(outputData, frameOffset: framesToRead, frameCount: requestedFrames - framesToRead)
        } else {
            updateByteSizes(outputData, frameCount: framesToRead)
        }
        return UInt32(framesToRead.clamped(to: 0...Int(UInt32.max)))
    }

    @inline(__always)
    private func writeFrame(
        left: Float,
        right: Float,
        into buffers: UnsafeMutableAudioBufferListPointer,
        frame: Int
    ) {
        if buffers.count == 1 {
            guard let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let channelCount = Int(max(buffers[0].mNumberChannels, 1))
            let targetOffset = frame * channelCount
            data[targetOffset] = left
            if channelCount > 1 {
                data[targetOffset + 1] = right
            }
            if channelCount > 2 {
                for channel in 2..<channelCount {
                    data[targetOffset + channel] = 0
                }
            }
        } else {
            buffers[0].mData?.assumingMemoryBound(to: Float.self)[frame] = left
            if buffers.count > 1 {
                buffers[1].mData?.assumingMemoryBound(to: Float.self)[frame] = right
            }
            if buffers.count > 2 {
                for bufferIndex in 2..<buffers.count {
                    buffers[bufferIndex].mData?.assumingMemoryBound(to: Float.self)[frame] = 0
                }
            }
        }
    }

    @inline(__always)
    private func sanitizedSample(_ sample: Float) -> Float {
        guard sample.isFinite else { return 0 }
        return sample.clamped(to: -1...1)
    }

    @inline(__always)
    private func sampleRatesMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        let tolerance = max(5.0, max(abs(lhs), abs(rhs)) * 0.000_05)
        return abs(lhs - rhs) <= tolerance
    }

    @inline(__always)
    private func zeroFill(
        _ outputData: UnsafeMutablePointer<AudioBufferList>,
        frameOffset: Int,
        frameCount: Int
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        for bufferIndex in 0..<buffers.count {
            let channelCount = Int(max(buffers[bufferIndex].mNumberChannels, 1))
            guard let data = buffers[bufferIndex].mData?.assumingMemoryBound(to: Float.self) else {
                continue
            }
            let sampleOffset = frameOffset * channelCount
            memset(data.advanced(by: sampleOffset), 0, frameCount * channelCount * MemoryLayout<Float>.size)
        }
        updateByteSizes(outputData, frameCount: frameOffset + frameCount)
    }

    @inline(__always)
    private func updateByteSizes(_ outputData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        for bufferIndex in 0..<buffers.count {
            let channelCount = buffers[bufferIndex].mNumberChannels
            buffers[bufferIndex].mDataByteSize = UInt32(frameCount) * channelCount * UInt32(MemoryLayout<Float>.size)
        }
    }
}

private extension UnsafeMutableRawPointer {
    func loadAtomicUInt32(offset: Int) -> UInt32 {
        PureQAtomicUInt32LoadAcquire(advanced(by: offset))
    }

    func loadAtomicUInt64(offset: Int) -> UInt64 {
        PureQAtomicUInt64LoadAcquire(advanced(by: offset))
    }

    func loadUInt32(offset: Int) -> UInt32 {
        advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee
    }

    func loadUInt64(offset: Int) -> UInt64 {
        advanced(by: offset).assumingMemoryBound(to: UInt64.self).pointee
    }

    func loadFloat64(offset: Int) -> Float64 {
        advanced(by: offset).assumingMemoryBound(to: Float64.self).pointee
    }

    func storeUInt32(_ value: UInt32, offset: Int) {
        advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee = value
    }

    func storeUInt64(_ value: UInt64, offset: Int) {
        advanced(by: offset).assumingMemoryBound(to: UInt64.self).pointee = value
    }

    func storeFloat64(_ value: Float64, offset: Int) {
        advanced(by: offset).assumingMemoryBound(to: Float64.self).pointee = value
    }
}
