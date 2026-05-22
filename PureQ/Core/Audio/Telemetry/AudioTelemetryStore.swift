//
//  AudioTelemetryStore.swift
//  PureQ
//

import Combine
import Foundation

final class AudioTelemetryStore: ObservableObject {
    @Published private(set) var telemetry: AudioEngineTelemetry = .empty

    private var smoothedBandLevels = Array(repeating: 0.0, count: AudioEngineTelemetry.activityMeterFrequencies.count)
    private var smoothedSpectrumLevels: [Double] = []
    private var meterIndexByRoundedFrequency: [Int: Int] = [:]
    private var lastPublishTime = 0.0

    func reset() {
        smoothedBandLevels = Array(repeating: 0.0, count: AudioEngineTelemetry.activityMeterFrequencies.count)
        smoothedSpectrumLevels.removeAll(keepingCapacity: true)
        meterIndexByRoundedFrequency.removeAll(keepingCapacity: true)
        lastPublishTime = 0
        telemetry = .empty
    }

    func publish(_ snapshot: AudioEngineTelemetry, smoothMeters: Bool, forceVisualRefresh: Bool = false) {
        let levels = smoothedLevels(from: snapshot.bandLevels, smoothMeters: smoothMeters)
        let spectrum = smoothedSpectrum(from: snapshot.spectrumLevels, smoothMeters: smoothMeters)
        let next = AudioEngineTelemetry(
            sampleRate: snapshot.sampleRate,
            capturedFrames: snapshot.capturedFrames,
            renderedFrames: snapshot.renderedFrames,
            underrunFrames: snapshot.underrunFrames,
            bufferedFrames: snapshot.bufferedFrames,
            inputCallbacks: snapshot.inputCallbacks,
            renderCallbacks: snapshot.renderCallbacks,
            bandLevels: levels,
            spectrumLevels: spectrum
        )

        if forceVisualRefresh {
            guard next != telemetry else { return }
            lastPublishTime = Date.timeIntervalSinceReferenceDate
        } else {
            guard shouldPublish(next) else { return }
        }
        telemetry = next
    }

    func bandActivityLevel(for frequency: Double) -> Double {
        let cacheKey = Int(frequency.rounded())
        let index: Int

        if let cachedIndex = meterIndexByRoundedFrequency[cacheKey] {
            index = cachedIndex
        } else if let nearestIndex = AudioEngineTelemetry.activityMeterFrequencies.indices.min(by: { lhs, rhs in
            let lhsDistance = abs(log10(AudioEngineTelemetry.activityMeterFrequencies[lhs]) - log10(frequency))
            let rhsDistance = abs(log10(AudioEngineTelemetry.activityMeterFrequencies[rhs]) - log10(frequency))
            return lhsDistance < rhsDistance
        }) {
            meterIndexByRoundedFrequency[cacheKey] = nearestIndex
            index = nearestIndex
        } else {
            return 0
        }

        guard telemetry.bandLevels.indices.contains(index) else {
            return 0
        }
        return telemetry.bandLevels[index]
    }

    private func smoothedLevels(from rawLevels: [Double], smoothMeters: Bool) -> [Double] {
        if smoothedBandLevels.count != rawLevels.count {
            smoothedBandLevels = Array(repeating: 0.0, count: rawLevels.count)
        }

        guard smoothMeters else {
            smoothedBandLevels = rawLevels
            return rawLevels
        }

        for index in rawLevels.indices {
            let current = smoothedBandLevels[index]
            let target = rawLevels[index].clamped(to: 0...1)
            let response = target > current ? 0.32 : 0.075
            smoothedBandLevels[index] = current + ((target - current) * response)
        }
        return smoothedBandLevels
    }

    private func smoothedSpectrum(from rawLevels: [Double], smoothMeters: Bool) -> [Double] {
        guard !rawLevels.isEmpty else {
            smoothedSpectrumLevels.removeAll(keepingCapacity: true)
            return []
        }

        if smoothedSpectrumLevels.count != rawLevels.count {
            smoothedSpectrumLevels = Array(repeating: 0.0, count: rawLevels.count)
        }

        guard smoothMeters else {
            smoothedSpectrumLevels = rawLevels
            return rawLevels
        }

        for index in rawLevels.indices {
            let current = smoothedSpectrumLevels[index]
            let target = rawLevels[index].clamped(to: 0...1)
            let response = target > current ? 0.28 : 0.085
            smoothedSpectrumLevels[index] = current + ((target - current) * response)
        }
        return smoothedSpectrumLevels
    }

    private func shouldPublish(_ next: AudioEngineTelemetry) -> Bool {
        let levelsChanged = bandLevelsChangedSignificantly(next.bandLevels)
        let spectrumChanged = spectrumLevelsChangedSignificantly(next.spectrumLevels)
        guard levelsChanged || spectrumChanged else { return false }

        let now = Date.timeIntervalSinceReferenceDate
        if levelsChanged || spectrumChanged || now - lastPublishTime >= 0.25 {
            lastPublishTime = now
            return true
        }
        return false
    }

    private func bandLevelsChangedSignificantly(_ nextLevels: [Double]) -> Bool {
        guard telemetry.bandLevels.count == nextLevels.count else { return true }
        return zip(telemetry.bandLevels, nextLevels).contains { oldValue, newValue in
            abs(oldValue - newValue) > 0.008
        }
    }

    private func spectrumLevelsChangedSignificantly(_ nextLevels: [Double]) -> Bool {
        guard telemetry.spectrumLevels.count == nextLevels.count else { return true }
        return zip(telemetry.spectrumLevels, nextLevels).contains { oldValue, newValue in
            abs(oldValue - newValue) > 0.012
        }
    }
}
