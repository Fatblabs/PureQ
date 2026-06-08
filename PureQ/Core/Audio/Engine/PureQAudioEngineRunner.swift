//
//  PureQAudioEngineRunner.swift
//  PureQ
//

import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

enum PureQAudioEngineError: LocalizedError {
    case processTapsUnavailable
    case noRoutedSources
    case noOutputDevice
    case noRunningProcessSource
    case loopbackCaptureStartFailed(OSStatus)
    case processObjectLookupFailed(pid_t)
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case tapStartFailed(OSStatus)
    case outputDeviceSelectionFailed(OSStatus)
    case outputAudioUnitCreationFailed(OSStatus)
    case outputAudioUnitFormatFailed(OSStatus)
    case outputAudioUnitCallbackFailed(OSStatus)
    case outputAudioUnitStartFailed(OSStatus)
    case outputAudioUnitUnavailable
    case outputSampleRateMismatch(String)

    var errorDescription: String? {
        switch self {
        case .processTapsUnavailable:
            return "Process taps require macOS 14.2 or newer."
        case .noRoutedSources:
            return "No routed source reaches an output node."
        case .noOutputDevice:
            return "No CoreAudio output device is selected."
        case .noRunningProcessSource:
            return "The selected app/game source is not running, so macOS cannot expose a process tap for it yet."
        case .loopbackCaptureStartFailed(let status):
            return "PureQ Virtual Output could not start its loopback input stream. OSStatus \(status)."
        case .processObjectLookupFailed(let pid):
            return "Could not resolve CoreAudio's process object for pid \(pid)."
        case .tapCreationFailed(let status):
            return "AudioHardwareCreateProcessTap failed with OSStatus \(status)."
        case .aggregateCreationFailed(let status):
            return "AudioHardwareCreateAggregateDevice failed with OSStatus \(status)."
        case .ioProcCreationFailed(let status):
            return "AudioDeviceCreateIOProcID failed with OSStatus \(status)."
        case .tapStartFailed(let status):
            return "AudioDeviceStart failed with OSStatus \(status)."
        case .outputDeviceSelectionFailed(let status):
            return "Could not bind PureQ's output renderer to the selected output device. OSStatus \(status)."
        case .outputAudioUnitCreationFailed(let status):
            return "Could not create PureQ's HAL output unit. OSStatus \(status)."
        case .outputAudioUnitFormatFailed(let status):
            return "Could not configure PureQ's HAL output format. OSStatus \(status)."
        case .outputAudioUnitCallbackFailed(let status):
            return "Could not attach PureQ's HAL render callback. OSStatus \(status)."
        case .outputAudioUnitStartFailed(let status):
            return "PureQ's HAL output renderer could not start. OSStatus \(status)."
        case .outputAudioUnitUnavailable:
            return "PureQ's HAL output audio unit is unavailable."
        case .outputSampleRateMismatch(let message):
            return message
        }
    }
}

final class PureQAudioEngineRunner {
    private var outputRenderers: [String: PureQOutputRenderer] = [:]
    private var realtimeOutputRenderers: [PureQOutputRenderer] = []
    private let outputRendererLock = NSLock()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var suppressionTapID = AudioObjectID(kAudioObjectUnknown)
    private var suppressionAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var suppressionIOProcID: AudioDeviceIOProcID?
    private var loopbackDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var loopbackIOProcID: AudioDeviceIOProcID?
    private var driverCapture: PureQDriverSharedMemoryCapture?
    private var selfReference: Unmanaged<PureQAudioEngineRunner>?
    private let telemetryLock = NSLock()
    private var spectrumAnalyzerEnabledFlag = PureQAtomicInt64()
    private var bandMetersEnabledFlag = PureQAtomicInt64()
    private var capturedFrames: UInt64 = 0
    private var renderedFrames: UInt64 = 0
    private var underrunFrames: UInt64 = 0
    private var inputCallbacks: UInt64 = 0
    private var renderCallbacks: UInt64 = 0
    private var outputPeakLevelSinceLastSnapshot: Double = 0
    private var clippedSampleCount: UInt64 = 0
    private var clippedCallbackCount: UInt64 = 0
    private var currentRenderSampleRate: Double = 48_000
    private let bandAnalyzer = PureQBandLevelAnalyzer(frequencies: AudioEngineTelemetry.activityMeterFrequencies)
    private let spectrumAnalyzer = PureQSpectrumAnalyzer()

    private(set) var runState: AudioEngineRunState = .stopped

    init() {
        PureQAtomicInt64Initialize(&spectrumAnalyzerEnabledFlag, 0)
        PureQAtomicInt64Initialize(&bandMetersEnabledFlag, 0)
    }

    deinit {
        driverCapture?.disconnect()
    }

    var telemetry: AudioEngineTelemetry {
        let bufferedFrames = UInt64(outputRendererSnapshot().map(\.availableFrameCount).max() ?? 0)
        let meterFlags = meterFeatureFlagsSnapshot()
        let bandLevels = meterFlags.bandMetersEnabled ? bandAnalyzer.levelSnapshot() : []
        let spectrumLevels = meterFlags.spectrumAnalyzerEnabled ? spectrumAnalyzer.levelSnapshot() : []
        telemetryLock.lock()
            let peakLevel = outputPeakLevelSinceLastSnapshot
            outputPeakLevelSinceLastSnapshot = 0
            let snapshot = AudioEngineTelemetry(
                sampleRate: currentRenderSampleRate,
                capturedFrames: capturedFrames,
                renderedFrames: renderedFrames,
                underrunFrames: underrunFrames,
                bufferedFrames: bufferedFrames,
                inputCallbacks: inputCallbacks,
                renderCallbacks: renderCallbacks,
                outputPeakLevel: peakLevel,
                clippedSampleCount: clippedSampleCount,
                clippedCallbackCount: clippedCallbackCount,
                bandLevels: bandLevels,
                spectrumLevels: spectrumLevels
            )
        telemetryLock.unlock()
        return snapshot
    }

    func start(
        configuration: AudioEngineConfiguration,
        outputDeviceIDsByUID: [String: AudioDeviceID],
        captureDeviceID: AudioDeviceID?
    ) throws {
        let wasActive = runState != .stopped ||
            !outputRenderers.isEmpty ||
            tapID != kAudioObjectUnknown ||
            aggregateDeviceID != kAudioObjectUnknown ||
            suppressionTapID != kAudioObjectUnknown ||
            suppressionAggregateDeviceID != kAudioObjectUnknown
        stop()
        if wasActive {
            Thread.sleep(forTimeInterval: 0.08)
        }

        guard captureDeviceID != nil || processTapsAreAvailable else {
            throw PureQAudioEngineError.processTapsUnavailable
        }
        let outputDeviceIDs = Dictionary(uniqueKeysWithValues: configuration.renderTargets.compactMap { target in
            outputDeviceIDsByUID[target.outputUID].map { (target.outputUID, $0) }
        })
        guard outputDeviceIDs.count == configuration.renderTargets.count else {
            throw PureQAudioEngineError.noOutputDevice
        }

        let routedSources = configuration.sourceRoutes.filter(\.reachesOutput)
        let suppressedSources = configuration.suppressionSourceRoutes.filter(\.reachesOutput)
        guard !routedSources.isEmpty || !suppressedSources.isEmpty else {
            throw PureQAudioEngineError.noRoutedSources
        }

        resetTelemetry()
        setSpectrumAnalyzerEnabled(configuration.spectrumAnalyzerEnabled)
        setBandMetersEnabled(configuration.bandMetersEnabled)

        do {
            let renderSampleRate: Double
            let startCapture: () throws -> Void
            let usesDriverCapture = configuration.prefersDriverCapture && captureDeviceID != nil
            if usesDriverCapture, let captureDeviceID {
                renderSampleRate = outputDeviceIDs.values
                    .compactMap { effectiveSampleRate(for: $0) }
                    .filter { $0 >= 8_000 }
                    .max() ?? nominalSampleRate(for: captureDeviceID) ?? 48_000
                if let mismatch = driverCaptureSampleRateMismatchDescription(
                    captureDeviceID: captureDeviceID,
                    outputDeviceIDs: Array(outputDeviceIDs.values),
                    targetSampleRate: renderSampleRate
                ) {
                    throw PureQAudioEngineError.outputSampleRateMismatch(mismatch)
                }
                let capture: PureQDriverSharedMemoryCapture
                if let existingCapture = driverCapture, existingCapture.deviceID == captureDeviceID {
                    capture = existingCapture
                } else {
                    driverCapture?.disconnect()
                    capture = PureQDriverSharedMemoryCapture(deviceID: captureDeviceID)
                }
                if !capture.isConnected {
                    try capture.connect()
                }
                driverCapture = capture
                startCapture = {}
            } else if #available(macOS 14.2, *) {
                if routedSources.isEmpty {
                    renderSampleRate = try prepareSilenceSuppressionTap(
                        for: suppressedSources,
                        mutesOriginalAudio: configuration.mutesOriginalAudio
                    )
                } else {
                    renderSampleRate = try prepareTapCapture(
                        for: routedSources,
                        mutesOriginalAudio: configuration.mutesOriginalAudio
                    )
                }
                startCapture = {
                    try self.startPreparedTapCapture()
                }
            } else if let captureDeviceID {
                renderSampleRate = nominalSampleRate(for: captureDeviceID) ?? 48_000
                try prepareLoopbackCapture(deviceID: captureDeviceID)
                startCapture = {
                    try self.startPreparedLoopbackCapture()
                }
            } else {
                throw PureQAudioEngineError.processTapsUnavailable
            }
            setRenderSampleRate(renderSampleRate)
            configureAnalyzers(sampleRate: renderSampleRate, frameRate: configuration.visualAnalyzerFrameRate)
            var shouldObserveDriverInput = true
            for target in configuration.renderTargets {
                guard let outputDeviceID = outputDeviceIDs[target.outputUID] else {
                    throw PureQAudioEngineError.noOutputDevice
                }
                let outputSampleRate = usesDriverCapture
                    ? (effectiveSampleRate(for: outputDeviceID) ?? renderSampleRate)
                    : renderSampleRate
                let observesDriverInput = driverCapture == nil || shouldObserveDriverInput
                if driverCapture != nil {
                    shouldObserveDriverInput = false
                }
                let renderer = PureQOutputRenderer(target: target)
                try renderer.start(
                    target: target,
                    enabled: configuration.enabled,
                    outputDeviceID: outputDeviceID,
                    sampleRate: outputSampleRate,
                    driverCaptureReader: driverCapture?.makeReader(outputSampleRate: outputSampleRate),
                    recordCapture: { [weak self] frameCount in
                        guard observesDriverInput else { return }
                        self?.recordCapture(frameCount: frameCount)
                    },
                    observeInput: { [weak self] inputData, frameCount in
                        guard observesDriverInput else { return }
                        self?.analyze(inputData: inputData, frameCount: frameCount)
                    },
                    recordRender: { [weak self] requestedFrames, renderedFrames, peakLevel, clippedSamples in
                        self?.recordRender(
                            requestedFrames: requestedFrames,
                            renderedFrames: renderedFrames,
                            peakLevel: peakLevel,
                            clippedSamples: clippedSamples
                        )
                    }
                )
                setOutputRenderer(renderer, for: target.outputUID)
            }
            try startCapture()
            runState = .running
        } catch {
            stop()
            runState = .failed(error.localizedDescription)
            throw error
        }
    }

    func stop() {
        if let loopbackIOProcID, loopbackDeviceID != kAudioObjectUnknown {
            _ = AudioDeviceStop(loopbackDeviceID, loopbackIOProcID)
            _ = AudioDeviceDestroyIOProcID(loopbackDeviceID, loopbackIOProcID)
        }
        loopbackIOProcID = nil
        loopbackDeviceID = AudioDeviceID(kAudioObjectUnknown)

        if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        ioProcID = nil

        if let suppressionIOProcID, suppressionAggregateDeviceID != kAudioObjectUnknown {
            _ = AudioDeviceStop(suppressionAggregateDeviceID, suppressionIOProcID)
            _ = AudioDeviceDestroyIOProcID(suppressionAggregateDeviceID, suppressionIOProcID)
        }
        suppressionIOProcID = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if suppressionAggregateDeviceID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(suppressionAggregateDeviceID)
            suppressionAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                _ = AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        if suppressionTapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                _ = AudioHardwareDestroyProcessTap(suppressionTapID)
            }
            suppressionTapID = AudioObjectID(kAudioObjectUnknown)
        }

        clearOutputRenderers().forEach { $0.stop() }
        selfReference = nil
        resetTelemetry()
        setSpectrumAnalyzerEnabled(false)
        setBandMetersEnabled(false)

        if runState != .stopped {
            runState = .stopped
        }
    }

    func ingest(inputData: UnsafePointer<AudioBufferList>?, frameCount: UInt32) {
        guard let inputData, frameCount > 0 else {
            return
        }
        for renderer in realtimeOutputRenderers {
            renderer.ingest(inputData: inputData, frameCount: frameCount)
        }
        analyze(inputData: inputData, frameCount: frameCount)
        recordCapture(frameCount: frameCount)
    }

    func analyze(inputData: UnsafePointer<AudioBufferList>, frameCount: UInt32) {
        if bandMetersEnabledSnapshot() {
            bandAnalyzer.process(inputData: inputData, frameCount: frameCount)
        }
        if spectrumAnalyzerEnabledSnapshot() {
            spectrumAnalyzer.process(inputData: inputData, frameCount: frameCount)
        }
    }

    func update(configuration: AudioEngineConfiguration) {
        guard runState == .running else {
            return
        }
        configureAnalyzers(sampleRate: currentRenderSampleRate, frameRate: configuration.visualAnalyzerFrameRate)
        setSpectrumAnalyzerEnabled(configuration.spectrumAnalyzerEnabled)
        setBandMetersEnabled(configuration.bandMetersEnabled)
        let activeOutputUIDs = Set(configuration.renderTargets.map(\.outputUID))
        for target in configuration.renderTargets {
            outputRenderer(for: target.outputUID)?.update(target: target, enabled: configuration.enabled)
        }
        for renderer in outputRendererSnapshot() where !activeOutputUIDs.contains(renderer.outputUID) {
            renderer.suspendOutput()
        }
    }

    private func outputRendererSnapshot() -> [PureQOutputRenderer] {
        guard outputRendererLock.try() else {
            return []
        }
        let renderers = Array(outputRenderers.values)
        outputRendererLock.unlock()
        return renderers
    }

    private func outputRenderer(for outputUID: String) -> PureQOutputRenderer? {
        outputRendererLock.lock()
        let renderer = outputRenderers[outputUID]
        outputRendererLock.unlock()
        return renderer
    }

    private func setOutputRenderer(_ renderer: PureQOutputRenderer, for outputUID: String) {
        outputRendererLock.lock()
        outputRenderers[outputUID] = renderer
        realtimeOutputRenderers = Array(outputRenderers.values)
        outputRendererLock.unlock()
    }

    private func clearOutputRenderers() -> [PureQOutputRenderer] {
        outputRendererLock.lock()
        let renderers = Array(outputRenderers.values)
        outputRenderers.removeAll(keepingCapacity: true)
        realtimeOutputRenderers.removeAll(keepingCapacity: true)
        outputRendererLock.unlock()
        return renderers
    }

    private func setSpectrumAnalyzerEnabled(_ isEnabled: Bool) {
        PureQAtomicInt64StoreRelease(&spectrumAnalyzerEnabledFlag, isEnabled ? 1 : 0)

        if !isEnabled {
            spectrumAnalyzer.reset()
        }
    }

    private func setBandMetersEnabled(_ isEnabled: Bool) {
        PureQAtomicInt64StoreRelease(&bandMetersEnabledFlag, isEnabled ? 1 : 0)

        if !isEnabled {
            bandAnalyzer.reset()
        }
    }

    private func configureAnalyzers(sampleRate: Double, frameRate: Double) {
        bandAnalyzer.configure(sampleRate: sampleRate, frameRate: frameRate)
        spectrumAnalyzer.configure(sampleRate: sampleRate, frameRate: frameRate)
    }

    private func spectrumAnalyzerEnabledSnapshot() -> Bool {
        PureQAtomicInt64LoadAcquire(&spectrumAnalyzerEnabledFlag) != 0
    }

    private func bandMetersEnabledSnapshot() -> Bool {
        PureQAtomicInt64LoadAcquire(&bandMetersEnabledFlag) != 0
    }

    private func meterFeatureFlagsSnapshot() -> (spectrumAnalyzerEnabled: Bool, bandMetersEnabled: Bool) {
        (
            spectrumAnalyzerEnabled: spectrumAnalyzerEnabledSnapshot(),
            bandMetersEnabled: bandMetersEnabledSnapshot()
        )
    }

    private func prepareLoopbackCapture(deviceID: AudioDeviceID) throws {
        selfReference = Unmanaged.passUnretained(self)

        var createdIOProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(
            deviceID,
            pureQLoopbackIOProc,
            selfReference?.toOpaque(),
            &createdIOProcID
        )
        guard createStatus == noErr, let createdIOProcID else {
            throw PureQAudioEngineError.ioProcCreationFailed(createStatus)
        }

        loopbackDeviceID = deviceID
        loopbackIOProcID = createdIOProcID
    }

    private func startPreparedLoopbackCapture() throws {
        guard let loopbackIOProcID, loopbackDeviceID != kAudioObjectUnknown else {
            throw PureQAudioEngineError.outputAudioUnitUnavailable
        }

        let startStatus = AudioDeviceStart(loopbackDeviceID, loopbackIOProcID)
        guard startStatus == noErr else {
            throw PureQAudioEngineError.loopbackCaptureStartFailed(startStatus)
        }
    }

    @available(macOS 14.2, *)
    private func prepareTapCapture(for routedSources: [AudioEngineSourceRoute], mutesOriginalAudio: Bool) throws -> Double {
        let tapDescription = try makeTapDescription(for: routedSources, mutesOriginalAudio: mutesOriginalAudio)
        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &createdTapID)
        guard tapStatus == noErr else {
            throw PureQAudioEngineError.tapCreationFailed(tapStatus)
        }
        tapID = createdTapID

        var createdAggregateID = AudioObjectID(kAudioObjectUnknown)
        let subTapDescription: [String: Any] = [
            kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationMediumQuality
        ]
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PureQ Render Tap",
            kAudioAggregateDeviceUIDKey: "Sean-s-Apps.PureQ.render.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [subTapDescription],
            kAudioAggregateDeviceTapAutoStartKey: true
        ]
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &createdAggregateID)
        guard aggregateStatus == noErr else {
            throw PureQAudioEngineError.aggregateCreationFailed(aggregateStatus)
        }
        aggregateDeviceID = createdAggregateID

        selfReference = Unmanaged.passUnretained(self)
        var createdIOProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcID(
            aggregateDeviceID,
            pureQTapIOProc,
            selfReference?.toOpaque(),
            &createdIOProcID
        )
        guard ioStatus == noErr, let createdIOProcID else {
            throw PureQAudioEngineError.ioProcCreationFailed(ioStatus)
        }
        ioProcID = createdIOProcID

        try prepareSuppressionTapIfNeeded(for: routedSources, mutesOriginalAudio: mutesOriginalAudio)

        return nominalSampleRate(for: aggregateDeviceID) ?? 48_000
    }

    @available(macOS 14.2, *)
    private func prepareSilenceSuppressionTap(
        for suppressedSources: [AudioEngineSourceRoute],
        mutesOriginalAudio: Bool
    ) throws -> Double {
        guard mutesOriginalAudio, !suppressedSources.isEmpty else {
            throw PureQAudioEngineError.noRoutedSources
        }

        try prepareSuppressionTap(description: try makeSilenceSuppressionTapDescription(for: suppressedSources))
        return nominalSampleRate(for: suppressionAggregateDeviceID) ?? 48_000
    }

    @available(macOS 14.2, *)
    private func startPreparedTapCapture() throws {
        if let suppressionIOProcID, suppressionAggregateDeviceID != kAudioObjectUnknown {
            let suppressionStartStatus = AudioDeviceStart(suppressionAggregateDeviceID, suppressionIOProcID)
            guard suppressionStartStatus == noErr else {
                throw PureQAudioEngineError.tapStartFailed(suppressionStartStatus)
            }
        }

        guard aggregateDeviceID != kAudioObjectUnknown, let ioProcID else {
            return
        }

        let startStatus = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard startStatus == noErr else {
            throw PureQAudioEngineError.tapStartFailed(startStatus)
        }
    }

    @available(macOS 14.2, *)
    private func makeTapDescription(for routedSources: [AudioEngineSourceRoute], mutesOriginalAudio: Bool) throws -> CATapDescription {
        let includesSystemMix = routedSources.contains { $0.sourceID == AudioSourceItem.systemMixID }

        let description: CATapDescription
        if includesSystemMix {
            let selfPID = ProcessInfo.processInfo.processIdentifier
            guard let selfProcessObjectID = processObjectID(for: selfPID) else {
                throw PureQAudioEngineError.processObjectLookupFailed(selfPID)
            }
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [selfProcessObjectID])
        } else {
            let bundleIDs = sourceBundleIDs(from: routedSources)
            let processObjectIDs = sourceProcessObjectIDs(from: routedSources)
            if !processObjectIDs.isEmpty {
                description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
            } else if !sourceProcessIDs(from: routedSources).isEmpty {
                    description = CATapDescription(stereoMixdownOfProcesses: try resolveProcessObjectIDs(for: sourceProcessIDs(from: routedSources)))
            } else if #available(macOS 26.0, *), !bundleIDs.isEmpty {
                description = makeBundleTapDescription(bundleIDs: bundleIDs, isExclusive: false)
            } else {
                throw PureQAudioEngineError.noRunningProcessSource
            }
        }

        description.name = "PureQ Source Tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = mutesOriginalAudio ? CATapMuteBehavior.mutedWhenTapped : CATapMuteBehavior.unmuted
        return description
    }

    @available(macOS 14.2, *)
    private func prepareSuppressionTapIfNeeded(
        for routedSources: [AudioEngineSourceRoute],
        mutesOriginalAudio: Bool
    ) throws {
        guard mutesOriginalAudio,
              !routedSources.contains(where: { $0.sourceID == AudioSourceItem.systemMixID }),
              let suppressionDescription = try makeSuppressionTapDescription(for: routedSources) else {
            return
        }

        try prepareSuppressionTap(description: suppressionDescription)
    }

    @available(macOS 14.2, *)
    private func prepareSuppressionTap(description: CATapDescription) throws {
        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &createdTapID)
        guard tapStatus == noErr else {
            throw PureQAudioEngineError.tapCreationFailed(tapStatus)
        }
        suppressionTapID = createdTapID

        var createdAggregateID = AudioObjectID(kAudioObjectUnknown)
        let subTapDescription: [String: Any] = [
            kAudioSubTapUIDKey: description.uuid.uuidString,
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationMediumQuality
        ]
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PureQ Suppression Tap",
            kAudioAggregateDeviceUIDKey: "Sean-s-Apps.PureQ.suppression.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [subTapDescription],
            kAudioAggregateDeviceTapAutoStartKey: true
        ]
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &createdAggregateID)
        guard aggregateStatus == noErr else {
            throw PureQAudioEngineError.aggregateCreationFailed(aggregateStatus)
        }
        suppressionAggregateDeviceID = createdAggregateID

        var createdIOProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcID(
            suppressionAggregateDeviceID,
            pureQSuppressionTapIOProc,
            nil,
            &createdIOProcID
        )
        guard ioStatus == noErr, let createdIOProcID else {
            throw PureQAudioEngineError.ioProcCreationFailed(ioStatus)
        }
        suppressionIOProcID = createdIOProcID
    }

    @available(macOS 14.2, *)
    private func makeFullSuppressionTapDescription() throws -> CATapDescription {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        guard let selfProcessObjectID = processObjectID(for: selfPID) else {
            throw PureQAudioEngineError.processObjectLookupFailed(selfPID)
        }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [selfProcessObjectID])
        description.name = "PureQ Source Suppression Tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.mutedWhenTapped
        return description
    }

    @available(macOS 14.2, *)
    private func makeSilenceSuppressionTapDescription(for suppressedSources: [AudioEngineSourceRoute]) throws -> CATapDescription {
        if suppressedSources.contains(where: { $0.sourceID == AudioSourceItem.systemMixID }) {
            return try makeFullSuppressionTapDescription()
        }

        let processObjectIDs = sourceProcessObjectIDs(from: suppressedSources)
        if !processObjectIDs.isEmpty {
            let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
            configureSuppressionTapDescription(description)
            return description
        }

        let processIDs = sourceProcessIDs(from: suppressedSources)
        if !processIDs.isEmpty {
            let description = CATapDescription(stereoMixdownOfProcesses: try resolveProcessObjectIDs(for: processIDs))
            configureSuppressionTapDescription(description)
            return description
        }

        let bundleIDs = sourceBundleIDs(from: suppressedSources)
        if #available(macOS 26.0, *), !bundleIDs.isEmpty {
            let description = makeBundleTapDescription(bundleIDs: bundleIDs, isExclusive: false)
            configureSuppressionTapDescription(description)
            return description
        }

        throw PureQAudioEngineError.noRunningProcessSource
    }

    @available(macOS 14.2, *)
    private func makeSuppressionTapDescription(for routedSources: [AudioEngineSourceRoute]) throws -> CATapDescription? {
        let selfBundleID = Bundle.main.bundleIdentifier
        let selfPID = ProcessInfo.processInfo.processIdentifier
        guard let selfProcessObjectID = processObjectID(for: selfPID) else {
            throw PureQAudioEngineError.processObjectLookupFailed(selfPID)
        }

        let processObjectIDs = sourceProcessObjectIDs(from: routedSources)
        if !processObjectIDs.isEmpty {
            let description = CATapDescription(
                stereoGlobalTapButExcludeProcesses: [selfProcessObjectID] + processObjectIDs
            )
            configureSuppressionTapDescription(description)
            return description
        }

        let processIDs = sourceProcessIDs(from: routedSources)
        if !processIDs.isEmpty {
            let description = CATapDescription(
                stereoGlobalTapButExcludeProcesses: [selfProcessObjectID] + (try resolveProcessObjectIDs(for: processIDs))
            )
            configureSuppressionTapDescription(description)
            return description
        }

        let bundleIDs = sourceBundleIDs(from: routedSources)
        if #available(macOS 26.0, *), !bundleIDs.isEmpty {
            var excludedBundleIDs = Set(bundleIDs)
            if let selfBundleID {
                excludedBundleIDs.insert(selfBundleID)
            }
            let description = makeBundleTapDescription(
                bundleIDs: Array(excludedBundleIDs).sorted(),
                isExclusive: true
            )
            configureSuppressionTapDescription(description)
            return description
        }

        return nil
    }

    @available(macOS 14.2, *)
    private func configureSuppressionTapDescription(_ description: CATapDescription) {
        description.name = "PureQ Source Suppression Tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.mutedWhenTapped
    }

    @available(macOS 14.2, *)
    private func resolveProcessObjectIDs(for processIDs: [pid_t]) throws -> [AudioObjectID] {
        try processIDs.map { pid -> AudioObjectID in
            guard let objectID = processObjectID(for: pid) else {
                throw PureQAudioEngineError.processObjectLookupFailed(pid)
            }
            return objectID
        }
    }

    private func sourceBundleIDs(from sources: [AudioEngineSourceRoute]) -> [String] {
        Array(Set(sources.flatMap(\.bundleIdentifiers))).sorted()
    }

    private func sourceProcessIDs(from sources: [AudioEngineSourceRoute]) -> [pid_t] {
        Array(Set(sources.compactMap(\.processIdentifier))).sorted()
    }

    private func sourceProcessObjectIDs(from sources: [AudioEngineSourceRoute]) -> [AudioObjectID] {
        Array(Set(sources.flatMap(\.processObjectIDs))).sorted()
    }

    @available(macOS 26.0, *)
    private func makeBundleTapDescription(bundleIDs: [String], isExclusive: Bool) -> CATapDescription {
        let description = CATapDescription()
        description.bundleIDs = bundleIDs
        description.isProcessRestoreEnabled = true
        description.isExclusive = isExclusive
        description.isMixdown = true
        description.isMono = false
        return description
    }

    private func resetTelemetry() {
        bandAnalyzer.reset()
        spectrumAnalyzer.reset()
        telemetryLock.lock()
        currentRenderSampleRate = 48_000
        capturedFrames = 0
        renderedFrames = 0
        underrunFrames = 0
        inputCallbacks = 0
        renderCallbacks = 0
        outputPeakLevelSinceLastSnapshot = 0
        clippedSampleCount = 0
        clippedCallbackCount = 0
        telemetryLock.unlock()
    }

    private func setRenderSampleRate(_ sampleRate: Double) {
        telemetryLock.lock()
        currentRenderSampleRate = sampleRate.clamped(to: 8_000...768_000)
        telemetryLock.unlock()
    }

    private func recordCapture(frameCount: UInt32) {
        guard telemetryLock.try() else {
            return
        }
        capturedFrames += UInt64(frameCount)
        inputCallbacks += 1
        telemetryLock.unlock()
    }

    private func recordRender(
        requestedFrames: AVAudioFrameCount,
        renderedFrames renderedFrameCount: UInt32,
        peakLevel: Float,
        clippedSamples: UInt32
    ) {
        guard telemetryLock.try() else {
            return
        }
        renderedFrames += UInt64(renderedFrameCount)
        if renderedFrameCount < requestedFrames {
            underrunFrames += UInt64(requestedFrames - renderedFrameCount)
        }
        let finitePeakLevel = peakLevel.isFinite ? Double(peakLevel) : 8
        outputPeakLevelSinceLastSnapshot = max(outputPeakLevelSinceLastSnapshot, finitePeakLevel.clamped(to: 0...8))
        if clippedSamples > 0 {
            clippedSampleCount += UInt64(clippedSamples)
            clippedCallbackCount += 1
        }
        renderCallbacks += 1
        telemetryLock.unlock()
    }

    private func processObjectID(for pid: pid_t) -> AudioObjectID? {
        var processID = pid
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            qualifierSize,
            &processID,
            &dataSize,
            &processObjectID
        )
        guard status == noErr, processObjectID != kAudioObjectUnknown else {
            return nil
        }
        return processObjectID
    }

    private func nominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var sampleRate = Float64(0)
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate)
        guard status == noErr, sampleRate > 0 else {
            return nil
        }
        return sampleRate
    }

    private func actualSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyActualSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var sampleRate = Float64(0)
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate)
        guard status == noErr, sampleRate > 0 else {
            return nil
        }
        return sampleRate
    }

    private func effectiveSampleRate(for deviceID: AudioDeviceID) -> Double? {
        actualSampleRate(for: deviceID) ?? nominalSampleRate(for: deviceID)
    }

    private func driverCaptureSampleRateMismatchDescription(
        captureDeviceID: AudioDeviceID,
        outputDeviceIDs: [AudioDeviceID],
        targetSampleRate: Double
    ) -> String? {
        let resolvedTarget = targetSampleRate.clamped(to: 8_000...768_000)
        var captureMismatches: [String] = []
        if let nominalRate = nominalSampleRate(for: captureDeviceID),
           !sampleRatesMatch(nominalRate, resolvedTarget) {
            captureMismatches.append("nominal \(sampleRateDescription(nominalRate))")
        }
        if let captureRate = effectiveSampleRate(for: captureDeviceID),
           !sampleRatesMatch(captureRate, resolvedTarget) {
            captureMismatches.append("actual \(sampleRateDescription(captureRate))")
        }
        let streamRates = streamSampleRates(for: captureDeviceID)
        let mismatchedStreamRates = streamRates.filter { !sampleRatesMatch($0, resolvedTarget) }
        if !mismatchedStreamRates.isEmpty {
            captureMismatches.append("stream \(sampleRateListDescription(mismatchedStreamRates))")
        }
        if !captureMismatches.isEmpty {
            return "PureQ Virtual Output is not synchronized (\(captureMismatches.joined(separator: ", "))) while the render path expects \(sampleRateDescription(resolvedTarget)). Repair/restart the driver, then start the engine again."
        }

        for outputDeviceID in outputDeviceIDs {
            guard let outputRate = effectiveSampleRate(for: outputDeviceID) else { continue }
            if !sampleRatesMatch(outputRate, resolvedTarget) {
                return "A routed hardware output is running at \(sampleRateDescription(outputRate)) while PureQ Virtual Output is running at \(sampleRateDescription(resolvedTarget)). For now, routed outputs must share one sample rate."
            }
        }

        return nil
    }

    private func streamSampleRates(for deviceID: AudioDeviceID) -> [Double] {
        let scopes = [
            kAudioObjectPropertyScopeInput,
            kAudioObjectPropertyScopeOutput
        ]
        let selectors = [
            kAudioStreamPropertyVirtualFormat,
            kAudioStreamPropertyPhysicalFormat
        ]

        var sampleRates: [Double] = []
        for scope in scopes {
            for streamID in streamIDs(for: deviceID, scope: scope) {
                for selector in selectors {
                    guard let sampleRate = streamSampleRate(for: streamID, selector: selector),
                          sampleRate > 0,
                          sampleRate.isFinite else {
                        continue
                    }
                    if !sampleRates.contains(where: { sampleRatesMatch($0, sampleRate) }) {
                        sampleRates.append(sampleRate)
                    }
                }
            }
        }
        return sampleRates.sorted()
    }

    private func streamIDs(for deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> [AudioObjectID] {
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
        for streamID: AudioObjectID,
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

    private func sampleRatesMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        let tolerance = max(5.0, max(abs(lhs), abs(rhs)) * 0.000_05)
        return abs(lhs - rhs) <= tolerance
    }

    private func sampleRateDescription(_ value: Double) -> String {
        if value >= 1_000 {
            return String(format: "%.3g kHz", value / 1_000)
        }
        return String(format: "%.1f Hz", value)
    }

    private func sampleRateListDescription(_ values: [Double]) -> String {
        let uniqueValues = values.reduce(into: [Double]()) { result, value in
            guard !result.contains(where: { sampleRatesMatch($0, value) }) else { return }
            result.append(value)
        }
        return uniqueValues.map(sampleRateDescription).joined(separator: ", ")
    }

    private var processTapsAreAvailable: Bool {
        if #available(macOS 14.2, *) {
            return true
        }
        return false
    }
}
