//
//  PureQOutputRenderer.swift
//  PureQ
//

import AudioToolbox
import AVFoundation
import CoreAudio
import Darwin
import Foundation

final class PureQOutputRenderer {
    private let ringBuffer = StereoRingBuffer(
        capacityFrames: 48_000,
        startThresholdFrames: 2_048,
        targetFrames: 4_096
    )

    private var audioUnit: AudioComponentInstance?
    private var recordRender: ((AVAudioFrameCount, UInt32, Float, UInt32) -> Void)?
    private var recordCapture: ((UInt32) -> Void)?
    private var observeInput: ((UnsafePointer<AudioBufferList>, UInt32) -> Void)?
    private let configurationLock = NSLock()
    private var pendingConfiguration: PureQRendererConfiguration?
    private var renderState = PureQRenderState()
    private var driverCaptureReader: PureQDriverSharedMemoryReader?
    private var isStopping = false
    private var lastStagedTarget: AudioEngineRenderTarget?
    private var lastStagedEnabled: Bool?
    private var lastStagedSampleRate: Double?
    private var driverCaptureOutputGain: Float = 0
    private var lastDriverCaptureOutputLeft: Float = 0
    private var lastDriverCaptureOutputRight: Float = 0

    init(target: AudioEngineRenderTarget) {
        pendingConfiguration = PureQRendererConfiguration(
            target: target,
            enabled: true,
            sampleRate: 48_000
        )
    }

    var availableFrameCount: Int {
        if let driverCaptureReader {
            return driverCaptureReader.availableFrameCount
        }
        return ringBuffer.availableFrameCount
    }

    var outputUID: String {
        lastStagedTarget?.outputUID ?? ""
    }

    func start(
        target: AudioEngineRenderTarget,
        enabled: Bool,
        outputDeviceID: AudioDeviceID,
        sampleRate: Double,
        driverCaptureReader: PureQDriverSharedMemoryReader? = nil,
        recordCapture: @escaping (UInt32) -> Void,
        observeInput: @escaping (UnsafePointer<AudioBufferList>, UInt32) -> Void,
        recordRender: @escaping (AVAudioFrameCount, UInt32, Float, UInt32) -> Void
    ) throws {
        stop()
        isStopping = false
        self.recordRender = recordRender
        self.recordCapture = recordCapture
        self.observeInput = observeInput
        self.driverCaptureReader = driverCaptureReader
        stageConfiguration(target: target, enabled: enabled, sampleRate: sampleRate)

        do {
            let unit = try makeHALOutputUnit()
            audioUnit = unit
            try configureHALOutputUnit(
                unit,
                outputDeviceID: outputDeviceID,
                sampleRate: sampleRate.clamped(to: 8_000...768_000)
            )
            try startHALOutputUnit(unit)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        isStopping = true
        if let audioUnit {
            AudioOutputUnitStop(audioUnit)
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
        }
        audioUnit = nil
        recordRender = nil
        recordCapture = nil
        observeInput = nil
        driverCaptureReader = nil
        renderState = PureQRenderState()
        lastStagedTarget = nil
        lastStagedEnabled = nil
        lastStagedSampleRate = nil
        driverCaptureOutputGain = 0
        lastDriverCaptureOutputLeft = 0
        lastDriverCaptureOutputRight = 0
        ringBuffer.reset()
    }

    func ingest(inputData: UnsafePointer<AudioBufferList>, frameCount: UInt32) {
        guard driverCaptureReader == nil else {
            return
        }
        ringBuffer.write(from: inputData, frameCount: frameCount)
    }

    func update(target: AudioEngineRenderTarget, enabled: Bool) {
        stageConfiguration(target: target, enabled: enabled, sampleRate: renderState.sampleRate)
    }

    func suspendOutput() {
        guard let target = lastStagedTarget else {
            return
        }

        let silentTarget = AudioEngineRenderTarget(
            outputUID: target.outputUID,
            outputName: target.outputName,
            routeCount: 0,
            filters: [],
            preamp: -80,
            balance: target.balance,
            systemVolume: 0,
            systemMuted: true
        )
        stageConfiguration(target: silentTarget, enabled: true, sampleRate: renderState.sampleRate)
    }

    private func stageConfiguration(target: AudioEngineRenderTarget, enabled: Bool, sampleRate: Double) {
        let resolvedSampleRate = sampleRate.clamped(to: 8_000...768_000)
        configurationLock.lock()
        if lastStagedTarget == target,
           lastStagedEnabled == enabled,
           lastStagedSampleRate == resolvedSampleRate {
            configurationLock.unlock()
            return
        }
        lastStagedTarget = target
        lastStagedEnabled = enabled
        lastStagedSampleRate = resolvedSampleRate
        pendingConfiguration = PureQRendererConfiguration(
            target: target,
            enabled: enabled,
            sampleRate: resolvedSampleRate
        )
        configurationLock.unlock()
    }

    private func makeHALOutputUnit() throws -> AudioComponentInstance {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw PureQAudioEngineError.outputAudioUnitUnavailable
        }

        var unit: AudioComponentInstance?
        let status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else {
            throw PureQAudioEngineError.outputAudioUnitCreationFailed(status)
        }
        return unit
    }

    private func configureHALOutputUnit(
        _ unit: AudioComponentInstance,
        outputDeviceID: AudioDeviceID,
        sampleRate: Double
    ) throws {
        var enableOutput: UInt32 = 1
        let enableStatus = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &enableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard enableStatus == noErr else {
            throw PureQAudioEngineError.outputAudioUnitStartFailed(enableStatus)
        }

        var deviceID = outputDeviceID
        let deviceStatus = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard deviceStatus == noErr else {
            throw PureQAudioEngineError.outputDeviceSelectionFailed(deviceStatus)
        }

        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 2,
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )
        let formatStatus = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard formatStatus == noErr else {
            throw PureQAudioEngineError.outputAudioUnitFormatFailed(formatStatus)
        }

        var maximumFramesPerSlice = Self.preferredMaximumFramesPerSlice(for: sampleRate)
        _ = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maximumFramesPerSlice,
            UInt32(MemoryLayout<UInt32>.size)
        )

        var callback = AURenderCallbackStruct(
            inputProc: Self.renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let callbackStatus = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard callbackStatus == noErr else {
            throw PureQAudioEngineError.outputAudioUnitCallbackFailed(callbackStatus)
        }
    }

    private static func preferredMaximumFramesPerSlice(for sampleRate: Double) -> UInt32 {
        let targetFrames = Int((sampleRate.clamped(to: 44_100...768_000) / 100).rounded(.up))
        var powerOfTwo = 512
        while powerOfTwo < targetFrames, powerOfTwo < 4_096 {
            powerOfTwo <<= 1
        }
        return UInt32(powerOfTwo.clamped(to: 512...4_096))
    }

    private func startHALOutputUnit(_ unit: AudioComponentInstance) throws {
        let initializeStatus = AudioUnitInitialize(unit)
        guard initializeStatus == noErr else {
            throw PureQAudioEngineError.outputAudioUnitStartFailed(initializeStatus)
        }

        let startStatus = AudioOutputUnitStart(unit)
        guard startStatus == noErr else {
            throw PureQAudioEngineError.outputAudioUnitStartFailed(startStatus)
        }
    }

    private static let renderCallback: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
        guard let ioData else {
            return noErr
        }
        let renderer = Unmanaged<PureQOutputRenderer>
            .fromOpaque(refCon)
            .takeUnretainedValue()
        return renderer.render(into: ioData, frameCount: frameCount)
    }

    private func render(into ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) -> OSStatus {
        guard !isStopping else {
            PureQAudioBufferTools.fillSilence(ioData, frameCount: frameCount)
            recordRender?(AVAudioFrameCount(frameCount), 0, 0, 0)
            return noErr
        }

        applyPendingConfigurationIfNeeded()

        let usesDriverCapture = driverCaptureReader != nil
        let renderedFrameCount: UInt32
        if let driverCaptureReader {
            renderedFrameCount = driverCaptureReader.read(into: ioData, frameCount: frameCount)
            if renderedFrameCount > 0 {
                observeInput?(UnsafePointer(ioData), renderedFrameCount)
                recordCapture?(driverCaptureReader.consumedFrameCount)
            }
        } else {
            renderedFrameCount = ringBuffer.read(
                into: ioData,
                frameCount: AVAudioFrameCount(frameCount),
                balance: 0
            )
        }

        var metering = PureQRenderMetering.silent
        if renderedFrameCount > 0 {
            metering = renderState.process(ioData, frameCount: renderedFrameCount)
        }
        if usesDriverCapture {
            applyDriverCaptureContinuity(
                to: ioData,
                renderedFrameCount: renderedFrameCount,
                requestedFrameCount: frameCount
            )
        }

        recordRender?(
            AVAudioFrameCount(frameCount),
            renderedFrameCount,
            metering.peakLevel,
            metering.clippedSampleCount
        )
        return noErr
    }

    private func applyPendingConfigurationIfNeeded() {
        guard configurationLock.try() else {
            return
        }
        if let pendingConfiguration {
            renderState.apply(configuration: pendingConfiguration)
            self.pendingConfiguration = nil
        }
        configurationLock.unlock()
    }

    private func applyDriverCaptureContinuity(
        to ioData: UnsafeMutablePointer<AudioBufferList>,
        renderedFrameCount: UInt32,
        requestedFrameCount: UInt32
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        let requestedFrames = Int(requestedFrameCount)
        let renderedFrames = Int(min(renderedFrameCount, requestedFrameCount))
        guard requestedFrames > 0, !buffers.isEmpty else {
            return
        }

        if renderedFrames > 0 {
            let previousLeft = lastDriverCaptureOutputLeft
            let previousRight = lastDriverCaptureOutputRight
            let renderedPeak = peakMagnitude(in: buffers, frameCount: renderedFrames)
            if renderedPeak < 0.000_05,
               driverCaptureOutputGain > 0.000_1 {
                fadeDriverCaptureOutputToSilence(
                    in: buffers,
                    startFrame: 0,
                    requestedFrames: requestedFrames,
                    left: previousLeft,
                    right: previousRight
                )
                return
            }

            if driverCaptureOutputGain < 0.999 {
                let rampFrames = min(renderedFrames, driverCaptureDeClickFrameCount)
                let startGain = driverCaptureOutputGain.clamped(to: 0...1)
                for frame in 0..<rampFrames {
                    let amount = Float(frame + 1) / Float(rampFrames)
                    let gain = startGain + ((1 - startGain) * amount)
                    scaleFrame(in: buffers, frame: frame, gain: gain)
                }
            }

            let lastFrame = readFrame(from: buffers, frame: renderedFrames - 1)
            lastDriverCaptureOutputLeft = lastFrame.left
            lastDriverCaptureOutputRight = lastFrame.right
            driverCaptureOutputGain = 1

            if renderedFrames < requestedFrames {
                fadeDriverCaptureOutputToSilence(
                    in: buffers,
                    startFrame: renderedFrames,
                    requestedFrames: requestedFrames,
                    left: lastFrame.left,
                    right: lastFrame.right
                )
            } else {
                updateByteSizes(buffers: buffers, frameCount: requestedFrames)
            }
            return
        }

        guard driverCaptureOutputGain > 0.000_1 ||
              abs(lastDriverCaptureOutputLeft) > 0.000_01 ||
              abs(lastDriverCaptureOutputRight) > 0.000_01 else {
            updateByteSizes(buffers: buffers, frameCount: requestedFrames)
            return
        }

        fadeDriverCaptureOutputToSilence(
            in: buffers,
            startFrame: 0,
            requestedFrames: requestedFrames,
            left: lastDriverCaptureOutputLeft,
            right: lastDriverCaptureOutputRight
        )
    }

    private var driverCaptureDeClickFrameCount: Int {
        Int((renderState.sampleRate * 0.0015).clamped(to: 32...512))
    }

    private func fadeDriverCaptureOutputToSilence(
        in buffers: UnsafeMutableAudioBufferListPointer,
        startFrame: Int,
        requestedFrames: Int,
        left: Float,
        right: Float
    ) {
        let availableFrames = max(0, requestedFrames - startFrame)
        let fadeFrames = min(availableFrames, driverCaptureDeClickFrameCount)
        if fadeFrames > 0 {
            for offset in 0..<fadeFrames {
                let amount = 1 - (Float(offset + 1) / Float(fadeFrames + 1))
                writeFrame(
                    left: left * amount,
                    right: right * amount,
                    into: buffers,
                    frame: startFrame + offset
                )
            }
        }
        if startFrame + fadeFrames < requestedFrames {
            zeroFrames(
                in: buffers,
                startFrame: startFrame + fadeFrames,
                frameCount: requestedFrames - startFrame - fadeFrames
            )
        }
        driverCaptureOutputGain = 0
        lastDriverCaptureOutputLeft = 0
        lastDriverCaptureOutputRight = 0
        updateByteSizes(buffers: buffers, frameCount: requestedFrames)
    }

    private func readFrame(
        from buffers: UnsafeMutableAudioBufferListPointer,
        frame: Int
    ) -> (left: Float, right: Float) {
        if buffers.count == 1 {
            let buffer = buffers[0]
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                return (0, 0)
            }
            let channelCount = Int(max(buffer.mNumberChannels, 1))
            let base = frame * channelCount
            let left = data[base]
            let right = channelCount > 1 ? data[base + 1] : left
            return (left, right)
        }

        let left = buffers[0].mData?.assumingMemoryBound(to: Float.self)[frame] ?? 0
        let right = buffers.count > 1
            ? (buffers[1].mData?.assumingMemoryBound(to: Float.self)[frame] ?? left)
            : left
        return (left, right)
    }

    private func peakMagnitude(
        in buffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int
    ) -> Float {
        var peak: Float = 0
        if buffers.count == 1 {
            let buffer = buffers[0]
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                return 0
            }
            let channelCount = Int(max(buffer.mNumberChannels, 1))
            let sampleCount = frameCount * channelCount
            for sampleIndex in 0..<sampleCount {
                peak = max(peak, abs(data[sampleIndex]))
            }
            return peak
        }

        for bufferIndex in 0..<buffers.count {
            guard let data = buffers[bufferIndex].mData?.assumingMemoryBound(to: Float.self) else {
                continue
            }
            for frame in 0..<frameCount {
                peak = max(peak, abs(data[frame]))
            }
        }
        return peak
    }

    private func writeFrame(
        left: Float,
        right: Float,
        into buffers: UnsafeMutableAudioBufferListPointer,
        frame: Int
    ) {
        if buffers.count == 1 {
            let buffer = buffers[0]
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                return
            }
            let channelCount = Int(max(buffer.mNumberChannels, 1))
            let base = frame * channelCount
            data[base] = left
            if channelCount > 1 {
                data[base + 1] = right
            }
            if channelCount > 2 {
                for channel in 2..<channelCount {
                    data[base + channel] = 0
                }
            }
            return
        }

        if let leftData = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
            leftData[frame] = left
        }
        if buffers.count > 1 {
            if let rightData = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                rightData[frame] = right
            }
        }
        if buffers.count > 2 {
            for bufferIndex in 2..<buffers.count {
                if let data = buffers[bufferIndex].mData?.assumingMemoryBound(to: Float.self) {
                    data[frame] = 0
                }
            }
        }
    }

    private func scaleFrame(
        in buffers: UnsafeMutableAudioBufferListPointer,
        frame: Int,
        gain: Float
    ) {
        if buffers.count == 1 {
            let buffer = buffers[0]
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                return
            }
            let channelCount = Int(max(buffer.mNumberChannels, 1))
            let base = frame * channelCount
            for channel in 0..<channelCount {
                data[base + channel] *= gain
            }
            return
        }

        for bufferIndex in 0..<buffers.count {
            if let data = buffers[bufferIndex].mData?.assumingMemoryBound(to: Float.self) {
                data[frame] *= gain
            }
        }
    }

    private func zeroFrames(
        in buffers: UnsafeMutableAudioBufferListPointer,
        startFrame: Int,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        for bufferIndex in 0..<buffers.count {
            let channelCount = Int(max(buffers[bufferIndex].mNumberChannels, 1))
            guard let data = buffers[bufferIndex].mData?.assumingMemoryBound(to: Float.self) else {
                continue
            }
            memset(
                UnsafeMutableRawPointer(data.advanced(by: startFrame * channelCount)),
                0,
                frameCount * channelCount * MemoryLayout<Float>.size
            )
        }
    }

    private func updateByteSizes(
        buffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int
    ) {
        for bufferIndex in 0..<buffers.count {
            let channelCount = buffers[bufferIndex].mNumberChannels
            buffers[bufferIndex].mDataByteSize = UInt32(frameCount) * channelCount * UInt32(MemoryLayout<Float>.size)
        }
    }
}

private struct PureQRendererConfiguration {
    let enabled: Bool
    let filters: [PureQBiquad]
    let preamp: Double
    let balance: Double
    let systemVolume: Float
    let systemMuted: Bool
    let sampleRate: Double

    init(target: AudioEngineRenderTarget, enabled: Bool, sampleRate: Double) {
        let resolvedSampleRate = sampleRate.clamped(to: 8_000...768_000)
        self.enabled = enabled
        filters = target.filters.compactMap { descriptor in
            PureQBiquad(descriptor: descriptor, sampleRate: resolvedSampleRate)
        }
        preamp = target.preamp
        balance = target.balance
        systemVolume = target.systemVolume.clamped(to: 0...1)
        systemMuted = target.systemMuted
        self.sampleRate = resolvedSampleRate
    }
}

private struct PureQRenderMetering {
    static let silent = PureQRenderMetering(peakLevel: 0, clippedSampleCount: 0)

    var peakLevel: Float = 0
    var clippedSampleCount: UInt32 = 0

    mutating func observe(left: Float, right: Float) {
        observe(sample: left)
        observe(sample: right)
    }

    private mutating func observe(sample: Float) {
        guard sample.isFinite else {
            peakLevel = .infinity
            clippedSampleCount += 1
            return
        }

        let level = abs(sample)
        peakLevel = max(peakLevel, level)
        if level >= 0.999_9 {
            clippedSampleCount += 1
        }
    }
}

private struct PureQRenderState {
    private var filters: [PureQBiquad] = []
    private var targetPreampGain: Float = 1
    private var currentPreampGain: Float = 0
    private var targetBalance: Float = 0
    private var currentBalance: Float = 0
    private var targetSystemGain: Float = 1
    private var currentSystemGain: Float = 1
    private var isProcessingEnabled = true
    private var hasConfigured = false
    private(set) var sampleRate = 48_000.0

    mutating func apply(configuration: PureQRendererConfiguration) {
        sampleRate = configuration.sampleRate
        isProcessingEnabled = configuration.enabled
        var nextFilters = configuration.filters
        let previousFiltersByID = Dictionary(grouping: filters, by: \.sourceID).mapValues { $0[0] }
        for index in nextFilters.indices {
            guard let previousFilter = previousFiltersByID[nextFilters[index].sourceID] else {
                continue
            }
            nextFilters[index].inheritDelayState(from: previousFilter)
        }
        filters = nextFilters
        targetPreampGain = configuration.enabled
            ? Float(pow(10, configuration.preamp.clamped(to: -24...24) / 20))
            : 1
        targetBalance = Float(configuration.balance.clamped(to: -1...1))
        targetSystemGain = configuration.systemMuted ? 0 : configuration.systemVolume

        if !hasConfigured {
            currentPreampGain = 0
            currentBalance = targetBalance
            currentSystemGain = targetSystemGain
            hasConfigured = true
        } else if targetSystemGain <= 0.000_1 {
            currentSystemGain = 0
        }
    }

    mutating func process(_ ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) -> PureQRenderMetering {
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        guard frameCount > 0, !buffers.isEmpty else { return .silent }

        if buffers.count == 1 {
            return processInterleaved(buffer: buffers[0], frameCount: Int(frameCount))
        } else {
            return processNonInterleaved(buffers: buffers, frameCount: Int(frameCount))
        }
    }

    private mutating func processInterleaved(buffer: AudioBuffer, frameCount: Int) -> PureQRenderMetering {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return .silent }
        let channelCount = Int(max(buffer.mNumberChannels, 1))
        var metering = PureQRenderMetering.silent
        for frame in 0..<frameCount {
            let base = frame * channelCount
            var left = data[base]
            var right = channelCount > 1 ? data[base + 1] : left
            processFrame(left: &left, right: &right, metering: &metering)
            data[base] = left
            if channelCount > 1 {
                data[base + 1] = right
            }
        }
        return metering
    }

    private mutating func processNonInterleaved(
        buffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int
    ) -> PureQRenderMetering {
        guard let leftData = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return .silent }
        let rightData = buffers.count > 1
            ? buffers[1].mData?.assumingMemoryBound(to: Float.self)
            : nil

        var metering = PureQRenderMetering.silent
        for frame in 0..<frameCount {
            var left = leftData[frame]
            var right = rightData?[frame] ?? left
            processFrame(left: &left, right: &right, metering: &metering)
            leftData[frame] = left
            rightData?[frame] = right
        }
        return metering
    }

    private mutating func processFrame(left: inout Float, right: inout Float, metering: inout PureQRenderMetering) {
        let smoothing: Float = 0.0015
        currentPreampGain += (targetPreampGain - currentPreampGain) * smoothing
        currentBalance += (targetBalance - currentBalance) * smoothing
        currentSystemGain += (targetSystemGain - currentSystemGain) * smoothing

        if isProcessingEnabled {
            for index in filters.indices {
                filters[index].process(left: &left, right: &right)
            }
            left *= currentPreampGain
            right *= currentPreampGain
        }

        if currentBalance > 0 {
            left *= 1 - currentBalance
        } else if currentBalance < 0 {
            right *= 1 + currentBalance
        }

        left *= currentSystemGain
        right *= currentSystemGain

        metering.observe(left: left, right: right)
        sanitizeFinalOutput(&left)
        sanitizeFinalOutput(&right)
    }

    private func sanitizeFinalOutput(_ sample: inout Float) {
        guard sample.isFinite else {
            sample = 0
            return
        }

        sample = sample.clamped(to: -1...1)
    }
}

private struct PureQBiquad {
    let sourceID: EqualizerBand.ID
    private let b0: Double
    private let b1: Double
    private let b2: Double
    private let a1: Double
    private let a2: Double
    private var leftZ1: Double = 0
    private var leftZ2: Double = 0
    private var rightZ1: Double = 0
    private var rightZ2: Double = 0

    init?(descriptor: AudioEngineFilterDescriptor, sampleRate: Double) {
        guard abs(descriptor.gain) > 0.01 || descriptor.shape == .notch else {
            return nil
        }
        let rate = sampleRate.clamped(to: 8_000...768_000)
        guard let coefficients = PureQBiquadMath.coefficients(for: descriptor, sampleRate: rate) else {
            return nil
        }

        sourceID = descriptor.id
        b0 = coefficients.b0
        b1 = coefficients.b1
        b2 = coefficients.b2
        a1 = coefficients.a1
        a2 = coefficients.a2
    }

    mutating func process(left: inout Float, right: inout Float) {
        left = Self.processSample(
            left,
            b0: b0,
            b1: b1,
            b2: b2,
            a1: a1,
            a2: a2,
            z1: &leftZ1,
            z2: &leftZ2
        )
        right = Self.processSample(
            right,
            b0: b0,
            b1: b1,
            b2: b2,
            a1: a1,
            a2: a2,
            z1: &rightZ1,
            z2: &rightZ2
        )
    }

    mutating func inheritDelayState(from previous: PureQBiquad) {
        leftZ1 = previous.leftZ1.isFinite ? previous.leftZ1 : 0
        leftZ2 = previous.leftZ2.isFinite ? previous.leftZ2 : 0
        rightZ1 = previous.rightZ1.isFinite ? previous.rightZ1 : 0
        rightZ2 = previous.rightZ2.isFinite ? previous.rightZ2 : 0
    }

    private static func processSample(
        _ input: Float,
        b0: Double,
        b1: Double,
        b2: Double,
        a1: Double,
        a2: Double,
        z1: inout Double,
        z2: inout Double
    ) -> Float {
        let input = Double(input)
        let output = (b0 * input) + z1
        let nextZ1 = (b1 * input) - (a1 * output) + z2
        let nextZ2 = (b2 * input) - (a2 * output)
        guard output.isFinite,
              nextZ1.isFinite,
              nextZ2.isFinite,
              abs(output) < 128,
              abs(nextZ1) < 128,
              abs(nextZ2) < 128 else {
            z1 = 0
            z2 = 0
            return 0
        }
        z1 = nextZ1
        z2 = nextZ2
        return Float(output)
    }
}

private enum PureQAudioBufferTools {
    static func fillSilence(_ ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        for bufferIndex in 0..<buffers.count {
            let channelCount = max(buffers[bufferIndex].mNumberChannels, 1)
            let byteSize = frameCount * channelCount * UInt32(MemoryLayout<Float>.size)
            if let data = buffers[bufferIndex].mData {
                memset(data, 0, Int(byteSize))
            }
            buffers[bufferIndex].mDataByteSize = byteSize
        }
    }
}
