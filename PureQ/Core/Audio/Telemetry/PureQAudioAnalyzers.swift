//
//  PureQAudioAnalyzers.swift
//  PureQ
//

import Accelerate
import AudioToolbox
import Foundation

final class PureQBandLevelAnalyzer {
    private let frequencies: [Double]
    private var coefficients: [Double]
    private var levels: [Double]
    private var sampleRate = 0.0
    private var analysisFrameRate = 30.0
    private var framesSinceAnalysis = 0
    private var analysisIntervalFrames = 1_600
    private let lock = NSLock()

    init(frequencies: [Double]) {
        self.frequencies = frequencies
        coefficients = Array(repeating: 0, count: frequencies.count)
        levels = Array(repeating: 0, count: frequencies.count)
        configure(sampleRate: 48_000)
    }

    func configure(sampleRate: Double, frameRate: Double = 30) {
        let nextSampleRate = sampleRate.clamped(to: 8_000...384_000)
        let nextFrameRate = frameRate.clamped(to: 15...60)
        lock.lock()
        let sampleRateChanged = abs(self.sampleRate - nextSampleRate) > 0.5
        let frameRateChanged = abs(analysisFrameRate - nextFrameRate) > 0.5
        guard sampleRateChanged || frameRateChanged else {
            lock.unlock()
            return
        }

        self.sampleRate = nextSampleRate
        analysisFrameRate = nextFrameRate
        analysisIntervalFrames = max(128, Int(self.sampleRate / analysisFrameRate))
        coefficients = frequencies.map { frequency in
            2 * cos(2 * .pi * frequency / self.sampleRate)
        }
        if sampleRateChanged {
            resetUnlocked()
        } else {
            framesSinceAnalysis = min(framesSinceAnalysis, max(analysisIntervalFrames - 1, 0))
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        resetUnlocked()
        lock.unlock()
    }

    func process(inputData: UnsafePointer<AudioBufferList>, frameCount: UInt32) {
        guard lock.try() else {
            return
        }
        defer { lock.unlock() }

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard !buffers.isEmpty, frameCount > 0 else {
            decayLevels()
            return
        }

        let frames = Int(frameCount)
        framesSinceAnalysis += frames
        guard framesSinceAnalysis >= analysisIntervalFrames else {
            return
        }
        framesSinceAnalysis = 0

        let step = max(1, frames / 512)
        let sampledFrameCount = max(1, (frames + step - 1) / step)

        for bandIndex in frequencies.indices {
            let coefficient = coefficients[bandIndex]
            var previous = 0.0
            var previous2 = 0.0

            var frame = 0
            while frame < frames {
                let sample = Double(monoSample(in: buffers, frame: frame))
                let current = sample + (coefficient * previous) - previous2
                previous2 = previous
                previous = current
                frame += step
            }

            let power = max(previous2 * previous2 + previous * previous - coefficient * previous * previous2, 0)
            let magnitude = sqrt(power) / Double(sampledFrameCount)
            let decibels = 20 * log10(max(magnitude, 0.000_001))
            let normalized = ((decibels + 58) / 58).clamped(to: 0...1)
            levels[bandIndex] = max(normalized, levels[bandIndex] * 0.72)
        }
    }

    func levelSnapshot() -> [Double] {
        lock.lock()
        let snapshot = levels.map { $0 }
        lock.unlock()
        return snapshot
    }

    private func resetUnlocked() {
        levels = Array(repeating: 0, count: frequencies.count)
        framesSinceAnalysis = 0
    }

    private func decayLevels() {
        for index in levels.indices {
            levels[index] *= 0.72
        }
    }

    private func monoSample(in buffers: UnsafeMutableAudioBufferListPointer, frame: Int) -> Float {
        if buffers.count == 1 {
            let buffer = buffers[0]
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                return 0
            }
            let channelCount = Int(max(buffer.mNumberChannels, 1))
            if channelCount == 1 {
                return data[frame]
            }
            let base = frame * channelCount
            return (data[base] + data[base + 1]) * 0.5
        }

        guard let leftData = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
            return 0
        }
        let left = leftData[frame]
        guard buffers.count > 1,
              let rightData = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
            return left
        }
        return (left + rightData[frame]) * 0.5
    }
}

final class PureQSpectrumAnalyzer {
    private let fftSize = 8_192
    private let displayBinCount = 192
    private let minimumFrequency = 20.0
    private let maximumDisplayFrequency = 20_000.0
    private let lock = NSLock()

    private var sampleRate = 0.0
    private var analysisFrameRate = 30.0
    private var analysisHopSize = 2_048
    private var fftSetup: FFTSetup?
    private var log2FFTSize: vDSP_Length = 11
    private var window: [Float]
    private var sampleBuffer: [Float]
    private var windowedSamples: [Float]
    private var realParts: [Float]
    private var imaginaryParts: [Float]
    private var magnitudes: [Float]
    private var levels: [Double]
    private var binRanges: [Range<Int>]
    private var writeCursor = 0
    private var filledSampleCount = 0
    private var samplesSinceLastFFT = 0

    init() {
        window = Array(repeating: 0, count: fftSize)
        sampleBuffer = Array(repeating: 0, count: fftSize)
        windowedSamples = Array(repeating: 0, count: fftSize)
        realParts = Array(repeating: 0, count: fftSize / 2)
        imaginaryParts = Array(repeating: 0, count: fftSize / 2)
        magnitudes = Array(repeating: 0, count: fftSize / 2)
        levels = Array(repeating: 0, count: displayBinCount)
        binRanges = []
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        rebuildFFTSetup()
        configure(sampleRate: 48_000)
    }

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    func configure(sampleRate: Double, frameRate: Double = 30) {
        let nextSampleRate = sampleRate.clamped(to: 8_000...384_000)
        let nextFrameRate = frameRate.clamped(to: 15...60)
        lock.lock()
        let sampleRateChanged = abs(self.sampleRate - nextSampleRate) > 0.5
        let frameRateChanged = abs(analysisFrameRate - nextFrameRate) > 0.5
        guard sampleRateChanged || frameRateChanged else {
            lock.unlock()
            return
        }

        self.sampleRate = nextSampleRate
        analysisFrameRate = nextFrameRate
        analysisHopSize = max(128, Int(self.sampleRate / analysisFrameRate))
        rebuildBinRanges()
        if sampleRateChanged {
            resetUnlocked()
        } else {
            samplesSinceLastFFT = min(samplesSinceLastFFT, max(analysisHopSize - 1, 0))
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        resetUnlocked()
        lock.unlock()
    }

    func process(inputData: UnsafePointer<AudioBufferList>, frameCount: UInt32) {
        guard lock.try() else {
            return
        }
        defer { lock.unlock() }

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard !buffers.isEmpty, frameCount > 0 else {
            decayLevelsUnlocked()
            return
        }

        let frames = Int(frameCount)
        let step = 1
        var frame = 0
        while frame < frames {
            sampleBuffer[writeCursor] = monoSample(in: buffers, frame: frame)
            writeCursor = (writeCursor + 1) % fftSize
            filledSampleCount = min(filledSampleCount + 1, fftSize)
            samplesSinceLastFFT += 1

            if filledSampleCount >= fftSize && samplesSinceLastFFT >= analysisHopSize {
                performFFTUnlocked()
                samplesSinceLastFFT = 0
            }
            frame += step
        }
    }

    func levelSnapshot() -> [Double] {
        lock.lock()
        let snapshot = levels
        lock.unlock()
        return snapshot
    }

    private func rebuildFFTSetup() {
        let exponent = Int(round(log2(Double(fftSize))))
        log2FFTSize = vDSP_Length(exponent)
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
        fftSetup = vDSP_create_fftsetup(log2FFTSize, FFTRadix(kFFTRadix2))
    }

    private func rebuildBinRanges() {
        let nyquist = max(sampleRate * 0.5, minimumFrequency + 1)
        let upperFrequency = min(maximumDisplayFrequency, nyquist * 0.94)
        let minLog = log10(minimumFrequency)
        let maxLog = log10(max(upperFrequency, minimumFrequency + 1))
        let binWidth = sampleRate / Double(fftSize)
        let maxFFTBin = max(1, fftSize / 2)

        binRanges = (0..<displayBinCount).map { index in
            let lowerFraction = Double(index) / Double(displayBinCount)
            let upperFraction = Double(index + 1) / Double(displayBinCount)
            let lowerFrequency = pow(10, minLog + ((maxLog - minLog) * lowerFraction))
            let upperFrequency = pow(10, minLog + ((maxLog - minLog) * upperFraction))
            let lowerIndex = max(1, min(maxFFTBin - 1, Int(floor(lowerFrequency / binWidth))))
            let upperIndex = max(lowerIndex + 1, min(maxFFTBin, Int(ceil(upperFrequency / binWidth))))
            return lowerIndex..<upperIndex
        }
    }

    private func resetUnlocked() {
        sampleBuffer.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: 0)
        }
        windowedSamples.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: 0)
        }
        realParts.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: 0)
        }
        imaginaryParts.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: 0)
        }
        magnitudes.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: 0)
        }
        levels = Array(repeating: 0, count: displayBinCount)
        writeCursor = 0
        filledSampleCount = 0
        samplesSinceLastFFT = 0
    }

    private func performFFTUnlocked() {
        guard let fftSetup else { return }

        for index in 0..<fftSize {
            let sourceIndex = (writeCursor + index) % fftSize
            windowedSamples[index] = sampleBuffer[sourceIndex] * window[index]
        }
        realParts.withUnsafeMutableBufferPointer { realPointer in
            imaginaryParts.withUnsafeMutableBufferPointer { imaginaryPointer in
                guard let realBase = realPointer.baseAddress,
                      let imaginaryBase = imaginaryPointer.baseAddress else {
                    return
                }

                var splitComplex = DSPSplitComplex(realp: realBase, imagp: imaginaryBase)
                windowedSamples.withUnsafeBufferPointer { samplesPointer in
                    guard let sampleBase = samplesPointer.baseAddress else { return }
                    sampleBase.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPointer in
                        vDSP_ctoz(complexPointer, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                    }
                }

                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2FFTSize, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        let magnitudeScale = Double(2.0 / Float(fftSize))
        for (levelIndex, range) in binRanges.enumerated() where levels.indices.contains(levelIndex) {
            var peak = 0.0
            let lowerBound = max(range.lowerBound, magnitudes.startIndex)
            let upperBound = min(range.upperBound, magnitudes.endIndex)
            guard lowerBound < upperBound else {
                continue
            }
            for fftBin in lowerBound..<upperBound {
                peak = max(peak, Double(magnitudes[fftBin]) * magnitudeScale)
            }

            let decibels = 20 * log10(max(peak, 0.000_000_1))
            let normalized = ((decibels + 72) / 72).clamped(to: 0...1)
            let current = levels[levelIndex]
            let response = normalized > current ? 0.38 : 0.12
            levels[levelIndex] = current + ((normalized - current) * response)
        }
    }

    private func decayLevelsUnlocked() {
        for index in levels.indices {
            levels[index] *= 0.86
        }
    }

    private func monoSample(in buffers: UnsafeMutableAudioBufferListPointer, frame: Int) -> Float {
        if buffers.count == 1 {
            let buffer = buffers[0]
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                return 0
            }
            let channelCount = Int(max(buffer.mNumberChannels, 1))
            if channelCount == 1 {
                return data[frame]
            }
            let base = frame * channelCount
            return (data[base] + data[base + 1]) * 0.5
        }

        guard let leftData = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
            return 0
        }
        let left = leftData[frame]
        guard buffers.count > 1,
              let rightData = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
            return left
        }
        return (left + rightData[frame]) * 0.5
    }
}
