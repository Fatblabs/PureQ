//
//  StereoRingBuffer.swift
//  PureQ
//

import AudioToolbox
import AVFoundation
import Darwin
import Foundation

final class StereoRingBuffer {
    private let storage: UnsafeMutablePointer<Float>
    private let capacityFrames: Int
    private let capacityMask: Int
    private let startThresholdFrames: Int
    private let targetFrames: Int
    private let maximumBufferedFrames: Int
    private var readCursor = PureQAtomicInt64()
    private var writeCursor = PureQAtomicInt64()
    private var isPrimed = false
    private var fractionalReadFrame = 0.0
    private var smoothedRateStep = 1.0

    init(capacityFrames: Int, startThresholdFrames: Int, targetFrames: Int) {
        self.capacityFrames = Self.nextPowerOfTwo(max(capacityFrames, 1))
        capacityMask = self.capacityFrames - 1
        self.startThresholdFrames = min(
            max(startThresholdFrames, 1),
            max(self.capacityFrames / 2, 1)
        )
        self.targetFrames = min(
            max(targetFrames, self.startThresholdFrames),
            max(self.capacityFrames / 2, self.startThresholdFrames)
        )
        maximumBufferedFrames = max(1, min(
            max(self.capacityFrames - 2, 1),
            max(self.targetFrames * 2, self.startThresholdFrames + self.targetFrames)
        ))
        storage = UnsafeMutablePointer<Float>.allocate(capacity: self.capacityFrames * 2)
        storage.initialize(repeating: 0, count: self.capacityFrames * 2)
        PureQAtomicInt64Initialize(&readCursor, 0)
        PureQAtomicInt64Initialize(&writeCursor, 0)
    }

    deinit {
        storage.deinitialize(count: capacityFrames * 2)
        storage.deallocate()
    }

    var availableFrameCount: Int {
        availableFramesSnapshot()
    }

    func reset() {
        PureQAtomicInt64StoreRelease(&readCursor, 0)
        PureQAtomicInt64StoreRelease(&writeCursor, 0)
        isPrimed = false
        fractionalReadFrame = 0
        smoothedRateStep = 1
        storage.initialize(repeating: 0, count: capacityFrames * 2)
    }

    func write(from inputData: UnsafePointer<AudioBufferList>, frameCount: UInt32) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard !buffers.isEmpty else {
            return
        }

        let requestedFrames = Int(frameCount)
        guard requestedFrames > 0 else { return }

        let writeStart = Int(PureQAtomicInt64LoadRelaxed(&writeCursor))
        let readStart = Int(PureQAtomicInt64LoadAcquire(&readCursor))
        let bufferedFrames = max(0, min(capacityFrames, writeStart - readStart))
        let writableFrames = min(requestedFrames, capacityFrames - bufferedFrames)
        guard writableFrames > 0 else { return }

        // If the producer is briefly ahead, keep the newest input block rather than
        // extending latency with old samples. The consumer owns readCursor trimming.
        let sourceFrameOffset = requestedFrames - writableFrames

        for frame in 0..<writableFrames {
            let sourceFrame = sourceFrameOffset + frame
            let targetIndex = (writeStart + frame) & capacityMask
            let left = sample(in: buffers, frame: sourceFrame, channel: 0)
            let right = sample(in: buffers, frame: sourceFrame, channel: 1)

            storage[targetIndex * 2] = left
            storage[targetIndex * 2 + 1] = right
        }

        PureQAtomicInt64StoreRelease(&writeCursor, Int64(writeStart + writableFrames))
    }

    func read(
        into outputData: UnsafeMutablePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount,
        balance: Double = 0
    ) -> UInt32 {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard !buffers.isEmpty else {
            return 0
        }

        let requestedFrames = Int(frameCount)
        var readStart = Int(PureQAtomicInt64LoadRelaxed(&readCursor))
        let writeStart = Int(PureQAtomicInt64LoadAcquire(&writeCursor))
        var bufferedFrames = max(0, min(capacityFrames, writeStart - readStart))

        if bufferedFrames > maximumBufferedFrames {
            readStart = max(0, writeStart - targetFrames)
            bufferedFrames = min(targetFrames, writeStart - readStart)
            PureQAtomicInt64StoreRelease(&readCursor, Int64(readStart))
            fractionalReadFrame = 0
            smoothedRateStep = 1
            isPrimed = bufferedFrames >= startThresholdFrames
        }

        if !isPrimed {
            guard bufferedFrames >= startThresholdFrames else {
                fillSilence(buffers: buffers, frameCount: frameCount)
                return 0
            }
            isPrimed = true
            fractionalReadFrame = 0
            smoothedRateStep = 1
        }

        guard bufferedFrames >= 2 else {
            isPrimed = false
            fractionalReadFrame = 0
            smoothedRateStep = 1
            fillSilence(buffers: buffers, frameCount: frameCount)
            return 0
        }

        let rateStep = adaptiveRateStep(bufferedFrames: bufferedFrames)
        var localReadCursor = readStart
        var localBufferedFrames = bufferedFrames
        var renderedFrames: UInt32 = 0
        for frame in 0..<requestedFrames {
            guard localBufferedFrames >= 2 else {
                isPrimed = false
                fractionalReadFrame = 0
                smoothedRateStep = 1
                fillSilence(buffers: buffers, frameOffset: frame, frameCount: requestedFrames - frame)
                break
            }

            let currentIndex = localReadCursor & capacityMask
            let nextIndex = (localReadCursor + 1) & capacityMask
            var left = interpolatedSample(
                current: storage[currentIndex * 2],
                next: storage[nextIndex * 2],
                fraction: fractionalReadFrame
            )
            var right = interpolatedSample(
                current: storage[currentIndex * 2 + 1],
                next: storage[nextIndex * 2 + 1],
                fraction: fractionalReadFrame
            )
            applyBalance(balance, left: &left, right: &right)

            for bufferIndex in 0..<buffers.count {
                guard let data = buffers[bufferIndex].mData?.assumingMemoryBound(to: Float.self) else {
                    continue
                }
                let channelCount = Int(max(buffers[bufferIndex].mNumberChannels, 1))

                if buffers.count == 1 {
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
                } else {
                    data[frame] = bufferIndex == 0 ? left : right
                }
            }

            fractionalReadFrame += rateStep
            let framesToConsume = min(Int(fractionalReadFrame), max(localBufferedFrames - 1, 0))
            if framesToConsume > 0 {
                localReadCursor += framesToConsume
                localBufferedFrames -= framesToConsume
                fractionalReadFrame -= Double(framesToConsume)
            }
            renderedFrames += 1
        }

        PureQAtomicInt64StoreRelease(&readCursor, Int64(localReadCursor))

        for bufferIndex in 0..<buffers.count {
            let channelCount = max(buffers[bufferIndex].mNumberChannels, 1)
            buffers[bufferIndex].mDataByteSize = frameCount * channelCount * UInt32(MemoryLayout<Float>.size)
        }

        return renderedFrames
    }

    private func adaptiveRateStep(bufferedFrames: Int) -> Double {
        let deadbandFrames = max(64.0, Double(targetFrames) * 0.015)
        let rawError = Double(bufferedFrames - targetFrames)
        let activeError: Double
        if rawError > deadbandFrames {
            activeError = rawError - deadbandFrames
        } else if rawError < -deadbandFrames {
            activeError = rawError + deadbandFrames
        } else {
            activeError = 0
        }

        let correction = (activeError / 180_000.0).clamped(to: -0.006...0.006)
        let targetStep = 1.0 + correction
        smoothedRateStep += (targetStep - smoothedRateStep) * 0.04
        if activeError == 0, abs(smoothedRateStep - 1.0) < 0.000_01 {
            smoothedRateStep = 1
        }
        return smoothedRateStep
    }

    private func interpolatedSample(current: Float, next: Float, fraction: Double) -> Float {
        let amount = Float(fraction.clamped(to: 0...1))
        return current + ((next - current) * amount)
    }

    private func applyBalance(_ balance: Double, left: inout Float, right: inout Float) {
        let clampedBalance = balance.clamped(to: -1...1)
        if clampedBalance > 0 {
            left *= Float(1 - clampedBalance)
        } else if clampedBalance < 0 {
            right *= Float(1 + clampedBalance)
        }
    }

    private func fillSilence(buffers: UnsafeMutableAudioBufferListPointer, frameCount: AVAudioFrameCount) {
        fillSilence(buffers: buffers, frameOffset: 0, frameCount: Int(frameCount))
    }

    private func fillSilence(buffers: UnsafeMutableAudioBufferListPointer, frameOffset: Int, frameCount: Int) {
        for bufferIndex in 0..<buffers.count {
            let channelCount = max(buffers[bufferIndex].mNumberChannels, 1)
            let byteSize = UInt32(frameCount) * channelCount * UInt32(MemoryLayout<Float>.size)
            if let data = buffers[bufferIndex].mData?.assumingMemoryBound(to: Float.self) {
                let sampleOffset = frameOffset * Int(channelCount)
                memset(
                    UnsafeMutableRawPointer(data.advanced(by: sampleOffset)),
                    0,
                    Int(byteSize)
                )
            }
            buffers[bufferIndex].mDataByteSize = UInt32(frameOffset) * channelCount * UInt32(MemoryLayout<Float>.size) + byteSize
        }
    }

    private func sample(in buffers: UnsafeMutableAudioBufferListPointer, frame: Int, channel: Int) -> Float {
        if buffers.count == 1 {
            let buffer = buffers[0]
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                return 0
            }
            let channelCount = Int(max(buffer.mNumberChannels, 1))
            let safeChannel = min(channel, channelCount - 1)
            return data[frame * channelCount + safeChannel]
        }

        let bufferIndex = min(channel, buffers.count - 1)
        let buffer = buffers[bufferIndex]
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
            return 0
        }
        return data[frame]
    }

    private func availableFramesSnapshot() -> Int {
        let write = Int(PureQAtomicInt64LoadAcquire(&writeCursor))
        let read = Int(PureQAtomicInt64LoadAcquire(&readCursor))
        return max(0, min(capacityFrames, write - read))
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        var result = 1
        while result < value {
            result <<= 1
        }
        return result
    }
}
