//
//  AudioEngineService.swift
//  PureQ
//

import AudioToolbox
import Accelerate
import AVFoundation
import CoreAudio
import Darwin
import Foundation

enum AudioEngineRuntimeState: Equatable {
    case ready
    case partial
    case blocked

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .partial: return "Partial"
        case .blocked: return "Blocked"
        }
    }
}

enum AudioEngineRunState: Equatable {
    case stopped
    case running
    case failed(String)

    var title: String {
        switch self {
        case .stopped: return "Stopped"
        case .running: return "Running"
        case .failed: return "Failed"
        }
    }

    var detail: String {
        switch self {
        case .stopped:
            return "The render engine is stopped."
        case .running:
            return "Process tap render loop is active."
        case .failed(let message):
            return message
        }
    }
}

struct AudioEngineStatus: Equatable {
    let state: AudioEngineRuntimeState
    let title: String
    let detail: String
    let processTapsAvailable: Bool
    let driverInstalled: Bool
    let driverBundled: Bool
}

struct AudioEngineFilterDescriptor: Equatable {
    let frequency: Double
    let gain: Double
    let q: Double
    let shape: BandShape
}

struct AudioEngineSourceRoute: Equatable {
    let sourceNodeID: RoutingNode.ID
    let sourceID: String
    let title: String
    let bundleIdentifier: String?
    let processIdentifier: pid_t?
    let reachesOutput: Bool
}

struct AudioEngineRoutePlan: Equatable {
    let sourceNodeID: RoutingNode.ID
    let sourceID: String
    let title: String
    let bundleIdentifier: String?
    let processIdentifier: pid_t?
    let outputUID: String?
    let outputName: String
    let nodePath: [RoutingNode.ID]
    let eqNodeIDs: [RoutingNode.ID]
    let filters: [AudioEngineFilterDescriptor]
    let preamp: Double
}

struct AudioEngineRenderTarget: Equatable {
    let outputUID: String
    let outputName: String
    let routeCount: Int
    let filters: [AudioEngineFilterDescriptor]
    let preamp: Double
    let balance: Double
}

struct AudioEngineConfiguration: Equatable {
    let enabled: Bool
    let filters: [AudioEngineFilterDescriptor]
    let preamp: Double
    let balance: Double
    let sourceRoutes: [AudioEngineSourceRoute]
    let routePlans: [AudioEngineRoutePlan]
    let renderTargets: [AudioEngineRenderTarget]
    let outputUID: String?
    let outputName: String
    let virtualCaptureUID: String?
    let virtualCaptureName: String?
    let spectrumAnalyzerEnabled: Bool
    let nodeCount: Int
    let connectionCount: Int
    let mutesOriginalAudio: Bool
}

struct AudioEngineTelemetry: Equatable {
    let capturedFrames: UInt64
    let renderedFrames: UInt64
    let underrunFrames: UInt64
    let bufferedFrames: UInt64
    let inputCallbacks: UInt64
    let renderCallbacks: UInt64
    let bandLevels: [Double]
    let spectrumLevels: [Double]

    static let empty = AudioEngineTelemetry(
        capturedFrames: 0,
        renderedFrames: 0,
        underrunFrames: 0,
        bufferedFrames: 0,
        inputCallbacks: 0,
        renderCallbacks: 0,
        bandLevels: Array(repeating: 0, count: EqualizerBand.standardFrequencies.count),
        spectrumLevels: []
    )

    var summary: String {
        "Captured \(capturedFrames) / Rendered \(renderedFrames) / Buffered \(bufferedFrames) / Underrun \(underrunFrames)"
    }
}

final class AudioEngineService {
    private let runner = PureQAudioEngineRunner()

    var runState: AudioEngineRunState {
        runner.runState
    }

    var telemetry: AudioEngineTelemetry {
        runner.telemetry
    }

    func makeConfiguration(
        enabled: Bool,
        bands: [EqualizerBand],
        preamp: Double,
        balance: Double,
        sources: [AudioSourceItem],
        nodes: [RoutingNode],
        connections: [RoutingConnection],
        outputUID: String?,
        outputName: String,
        virtualCaptureUID: String?,
        virtualCaptureName: String?,
        spectrumAnalyzerEnabled: Bool,
        processedTakeoverEnabled: Bool
    ) -> AudioEngineConfiguration {
        let fallbackFilters = filterDescriptors(from: bands)
        let nodeByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let routePlans = compileRoutePlans(
            sources: sources,
            nodes: nodes,
            nodeByID: nodeByID,
            connections: connections,
            fallbackOutputUID: outputUID,
            fallbackOutputName: outputName
        )
        let routableRoutePlans = routePlans.filter { $0.outputUID != nil }
        let renderTargets = makeRenderTargets(
            from: routableRoutePlans,
            nodeByID: nodeByID,
            fallbackFilters: fallbackFilters,
            fallbackPreamp: preamp,
            fallbackBalance: balance
        )
        let primaryOutputUID = outputUID ?? renderTargets.first?.outputUID
        let primaryRoutePlans = routableRoutePlans.filter { route in
            guard let primaryOutputUID else { return false }
            return route.outputUID == primaryOutputUID
        }
        let effectiveEQNodeIDs = orderedUnique(primaryRoutePlans.flatMap(\.eqNodeIDs))
        let effectiveEQNodes = effectiveEQNodeIDs.compactMap { nodeByID[$0] }
        let routeFilters = effectiveEQNodes.flatMap { node in
            filterDescriptors(from: renderBands(for: node))
        }
        let filters = Array((effectiveEQNodes.isEmpty ? fallbackFilters : routeFilters).prefix(96))
        let effectivePreamp = effectiveEQNodes.isEmpty
            ? preamp
            : effectiveEQNodes.reduce(0) { partialResult, node in
                partialResult + node.eqPreamp
            }.clamped(to: -24...24)
        let effectiveBalance = (effectiveEQNodes.last?.eqBalance ?? balance).clamped(to: -1...1)

        let sourceRoutes = nodes
            .filter { $0.kind == .source }
            .map { node in
                let source = sources.first(where: { $0.id == node.audioSourceID })
                let sourceID = node.audioSourceID ?? AudioSourceItem.systemMixID
                return AudioEngineSourceRoute(
                    sourceNodeID: node.id,
                    sourceID: sourceID,
                    title: source?.title ?? node.title,
                    bundleIdentifier: source?.bundleIdentifier,
                    processIdentifier: source?.processIdentifier,
                    reachesOutput: routableRoutePlans.contains { route in
                        route.sourceNodeID == node.id
                    }
                )
            }

        return AudioEngineConfiguration(
            enabled: enabled,
            filters: filters,
            preamp: effectivePreamp,
            balance: effectiveBalance,
            sourceRoutes: sourceRoutes,
            routePlans: routableRoutePlans,
            renderTargets: renderTargets,
            outputUID: primaryOutputUID,
            outputName: renderTargets.first(where: { $0.outputUID == primaryOutputUID })?.outputName ?? outputName,
            virtualCaptureUID: virtualCaptureUID,
            virtualCaptureName: virtualCaptureName,
            spectrumAnalyzerEnabled: spectrumAnalyzerEnabled,
            nodeCount: nodes.count,
            connectionCount: connections.count,
            mutesOriginalAudio: processedTakeoverEnabled
        )
    }

    func evaluate(_ configuration: AudioEngineConfiguration) -> AudioEngineStatus {
        let tapsAvailable = processTapsAvailable
        let installed = installedDriverExists
        let bundled = bundledDriverExists
        let routedSources = configuration.sourceRoutes.filter(\.reachesOutput)

        guard !configuration.sourceRoutes.isEmpty else {
            return AudioEngineStatus(
                state: .blocked,
                title: "No Sources",
                detail: "Add at least one source node before starting the audio engine.",
                processTapsAvailable: tapsAvailable,
                driverInstalled: installed,
                driverBundled: bundled
            )
        }

        guard !routedSources.isEmpty else {
            return AudioEngineStatus(
                state: .blocked,
                title: "No Route",
                detail: "Patch a source through the EQ/guard path to an output node.",
                processTapsAvailable: tapsAvailable,
                driverInstalled: installed,
                driverBundled: bundled
            )
        }

        guard !configuration.renderTargets.isEmpty else {
            return AudioEngineStatus(
                state: .blocked,
                title: "No Output",
                detail: "Patch at least one route to a hardware output before starting the audio engine.",
                processTapsAvailable: tapsAvailable,
                driverInstalled: installed,
                driverBundled: bundled
            )
        }

        if configuration.virtualCaptureUID != nil, tapsAvailable {
            let routeCount = configuration.routePlans.count
            let filterCount = configuration.renderTargets.reduce(0) { $0 + $1.filters.count }
            return AudioEngineStatus(
                state: .ready,
                title: "Locked Tap Ready",
                detail: "System output is held on \(configuration.virtualCaptureName ?? "PureQ Virtual Output"); PureQ taps routed sources and renders EQ to \(renderTargetSummary(configuration.renderTargets)): \(routeCount) route\(routeCount == 1 ? "" : "s"), \(filterCount) active filter\(filterCount == 1 ? "" : "s").",
                processTapsAvailable: tapsAvailable,
                driverInstalled: installed,
                driverBundled: bundled
            )
        }

        if configuration.virtualCaptureUID != nil {
            let routeCount = configuration.routePlans.count
            let filterCount = configuration.renderTargets.reduce(0) { $0 + $1.filters.count }
            return AudioEngineStatus(
                state: .ready,
                title: "Virtual Loopback Ready",
                detail: "\(configuration.virtualCaptureName ?? "PureQ Virtual Output") loopback -> EQ -> \(renderTargetSummary(configuration.renderTargets)): \(routeCount) route\(routeCount == 1 ? "" : "s"), \(filterCount) active filter\(filterCount == 1 ? "" : "s").",
                processTapsAvailable: tapsAvailable,
                driverInstalled: installed,
                driverBundled: bundled
            )
        }

        if tapsAvailable {
            let hasSystemMix = routedSources.contains { $0.sourceID == AudioSourceItem.systemMixID }
            let runnableAppSources = routedSources.filter { route in
                guard route.sourceID != AudioSourceItem.systemMixID else {
                    return false
                }
                if #available(macOS 26.0, *) {
                    return route.processIdentifier != nil || route.bundleIdentifier != nil
                }
                return route.processIdentifier != nil
            }
            let appSourcesNeedLaunch = !hasSystemMix && runnableAppSources.isEmpty

            if appSourcesNeedLaunch {
                return AudioEngineStatus(
                    state: .partial,
                    title: "Awaiting Source",
                    detail: "The render loop is available, but the selected app/game source must be running before macOS can expose audio for it.",
                    processTapsAvailable: tapsAvailable,
                    driverInstalled: installed,
                    driverBundled: bundled
                )
            }

            let routeCount = configuration.routePlans.count
            let filterCount = configuration.renderTargets.reduce(0) { $0 + $1.filters.count }
            let renderMode = configuration.mutesOriginalAudio ? "Processed takeover" : "Monitor"
            return AudioEngineStatus(
                state: .ready,
                title: "Tap Engine Ready",
                detail: "\(renderMode): \(routeCount) route\(routeCount == 1 ? "" : "s"), \(filterCount) active filter\(filterCount == 1 ? "" : "s"), rendering to \(renderTargetSummary(configuration.renderTargets)).",
                processTapsAvailable: tapsAvailable,
                driverInstalled: installed,
                driverBundled: bundled
            )
        }

        if installed {
            return AudioEngineStatus(
                state: .partial,
                title: "Driver Installed",
                detail: "PureQ's HAL driver is installed. Driver-backed rendering still needs the virtual-device handoff path on this macOS version.",
                processTapsAvailable: tapsAvailable,
                driverInstalled: installed,
                driverBundled: bundled
            )
        }

        if bundled {
            return AudioEngineStatus(
                state: .partial,
                title: "Install Driver",
                detail: "A PureQ driver is bundled, but it is not installed in `/Library/Audio/Plug-Ins/HAL`.",
                processTapsAvailable: tapsAvailable,
                driverInstalled: installed,
                driverBundled: bundled
            )
        }

        return AudioEngineStatus(
            state: .blocked,
            title: "Driver Needed",
            detail: "This macOS version cannot use process taps, and no PureQ HAL driver is installed.",
            processTapsAvailable: tapsAvailable,
            driverInstalled: installed,
            driverBundled: bundled
        )
    }

    func startRendering(
        configuration: AudioEngineConfiguration,
        outputDeviceIDsByUID: [String: AudioDeviceID],
        captureDeviceID: AudioDeviceID?
    ) throws {
        try runner.start(
            configuration: configuration,
            outputDeviceIDsByUID: outputDeviceIDsByUID,
            captureDeviceID: captureDeviceID
        )
    }

    func stopRendering() {
        runner.stop()
    }

    func updateRendering(configuration: AudioEngineConfiguration) {
        runner.update(configuration: configuration)
    }

    var processTapsAvailable: Bool {
        if #available(macOS 14.2, *) {
            return true
        }
        return false
    }

    private var bundledDriverExists: Bool {
        Bundle.main.url(forResource: "PureQ", withExtension: "driver") != nil
    }

    private var installedDriverExists: Bool {
        FileManager.default.fileExists(atPath: "/Library/Audio/Plug-Ins/HAL/PureQ.driver")
    }

    private func renderTargetSummary(_ targets: [AudioEngineRenderTarget]) -> String {
        guard let first = targets.first else { return "no output" }
        if targets.count == 1 {
            return first.outputName
        }
        return "\(first.outputName) + \(targets.count - 1) more"
    }

    private func compileRoutePlans(
        sources: [AudioSourceItem],
        nodes: [RoutingNode],
        nodeByID: [RoutingNode.ID: RoutingNode],
        connections: [RoutingConnection],
        fallbackOutputUID: String?,
        fallbackOutputName: String
    ) -> [AudioEngineRoutePlan] {
        let sourceNodes = nodes.filter { $0.kind == .source }
        let outputNodeIDs = Set(nodes.filter { $0.kind == .output }.map(\.id))

        return sourceNodes.flatMap { sourceNode -> [AudioEngineRoutePlan] in
            let source = sources.first(where: { $0.id == sourceNode.audioSourceID })
            let sourceID = sourceNode.audioSourceID ?? AudioSourceItem.systemMixID
            let paths = outputPaths(
                from: sourceNode.id,
                outputNodeIDs: outputNodeIDs,
                connections: connections
            )

            return paths.map { path in
                let pathNodes = path.compactMap { nodeByID[$0] }
                let eqNodes = pathNodes.filter { $0.kind == .equalizer }
                let outputNode = pathNodes.last(where: { $0.kind == .output })
                let routeFilters = eqNodes.flatMap { node in
                    filterDescriptors(from: renderBands(for: node))
                }
                let routePreamp = eqNodes.isEmpty
                    ? 0
                    : eqNodes.reduce(0) { partialResult, node in
                        partialResult + node.eqPreamp
                    }.clamped(to: -24...24)

                return AudioEngineRoutePlan(
                    sourceNodeID: sourceNode.id,
                    sourceID: sourceID,
                    title: source?.title ?? sourceNode.title,
                    bundleIdentifier: source?.bundleIdentifier,
                    processIdentifier: source?.processIdentifier,
                    outputUID: outputNode?.audioOutputUID ?? fallbackOutputUID,
                    outputName: outputNode?.title ?? fallbackOutputName,
                    nodePath: path,
                    eqNodeIDs: eqNodes.map(\.id),
                    filters: routeFilters,
                    preamp: routePreamp
                )
            }
        }
    }

    private func makeRenderTargets(
        from routePlans: [AudioEngineRoutePlan],
        nodeByID: [RoutingNode.ID: RoutingNode],
        fallbackFilters: [AudioEngineFilterDescriptor],
        fallbackPreamp: Double,
        fallbackBalance: Double
    ) -> [AudioEngineRenderTarget] {
        let groupedPlans = Dictionary(grouping: routePlans) { route in
            route.outputUID ?? ""
        }

        return groupedPlans.compactMap { outputUID, plans -> AudioEngineRenderTarget? in
            guard !outputUID.isEmpty else { return nil }

            let effectiveEQNodeIDs = orderedUnique(plans.flatMap(\.eqNodeIDs))
            let effectiveEQNodes = effectiveEQNodeIDs.compactMap { nodeByID[$0] }
            let filters = effectiveEQNodes.flatMap { node in
                filterDescriptors(from: renderBands(for: node))
            }
            let preamp = effectiveEQNodes.isEmpty
                ? fallbackPreamp
                : effectiveEQNodes.reduce(0) { partialResult, node in
                    partialResult + node.eqPreamp
                }.clamped(to: -24...24)
            let balance = (effectiveEQNodes.last?.eqBalance ?? fallbackBalance).clamped(to: -1...1)
            let outputName = plans.first(where: { $0.outputUID == outputUID })?.outputName ?? "Output"

            return AudioEngineRenderTarget(
                outputUID: outputUID,
                outputName: outputName,
                routeCount: plans.count,
                filters: Array((effectiveEQNodes.isEmpty ? fallbackFilters : filters).prefix(96)),
                preamp: preamp,
                balance: balance
            )
        }
        .sorted { lhs, rhs in
            lhs.outputName.localizedCaseInsensitiveCompare(rhs.outputName) == .orderedAscending
        }
    }

    private func outputPaths(
        from sourceID: RoutingNode.ID,
        outputNodeIDs: Set<RoutingNode.ID>,
        connections: [RoutingConnection]
    ) -> [[RoutingNode.ID]] {
        let adjacency = Dictionary(grouping: connections, by: \.from)
        var paths: [[RoutingNode.ID]] = []

        func walk(currentID: RoutingNode.ID, path: [RoutingNode.ID], visited: Set<RoutingNode.ID>) {
            guard paths.count < 48 else {
                return
            }
            if outputNodeIDs.contains(currentID), path.count > 1 {
                paths.append(path)
                return
            }
            guard !visited.contains(currentID) else {
                return
            }

            var nextVisited = visited
            nextVisited.insert(currentID)
            for connection in adjacency[currentID, default: []] {
                walk(currentID: connection.to, path: path + [connection.to], visited: nextVisited)
            }
        }

        walk(currentID: sourceID, path: [sourceID], visited: [])
        return paths
    }

    private func filterDescriptors(from bands: [EqualizerBand]) -> [AudioEngineFilterDescriptor] {
        bands
            .filter { $0.isEnabled && abs($0.gain) > 0.01 }
            .map {
                AudioEngineFilterDescriptor(
                    frequency: $0.frequency,
                    gain: $0.gain,
                    q: $0.q,
                    shape: $0.shape
                )
            }
    }

    private func renderBands(for node: RoutingNode) -> [EqualizerBand] {
        node.eqBands
    }

    private func orderedUnique(_ ids: [RoutingNode.ID]) -> [RoutingNode.ID] {
        var seen = Set<RoutingNode.ID>()
        return ids.filter { seen.insert($0).inserted }
    }
}

private enum PureQAudioEngineError: LocalizedError {
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
    case renderFormatCreationFailed
    case outputAudioUnitUnavailable
    case avEngineStartFailed(Error)

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
            return "Could not bind AVAudioEngine to the selected output device. OSStatus \(status)."
        case .renderFormatCreationFailed:
            return "Could not create PureQ's stereo render format."
        case .outputAudioUnitUnavailable:
            return "AVAudioEngine's output audio unit is unavailable."
        case .avEngineStartFailed(let error):
            return "AVAudioEngine could not start: \(error.localizedDescription)"
        }
    }
}

private final class PureQAudioEngineRunner {
    private var outputRenderers: [String: PureQOutputRenderer] = [:]
    private let outputRendererLock = NSLock()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var loopbackDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var loopbackIOProcID: AudioDeviceIOProcID?
    private var selfReference: Unmanaged<PureQAudioEngineRunner>?
    private let telemetryLock = NSLock()
    private let parameterLock = NSLock()
    private var currentSpectrumAnalyzerEnabled = false
    private var capturedFrames: UInt64 = 0
    private var renderedFrames: UInt64 = 0
    private var underrunFrames: UInt64 = 0
    private var inputCallbacks: UInt64 = 0
    private var renderCallbacks: UInt64 = 0
    private let bandAnalyzer = PureQBandLevelAnalyzer(frequencies: EqualizerBand.standardFrequencies)
    private let spectrumAnalyzer = PureQSpectrumAnalyzer()

    private(set) var runState: AudioEngineRunState = .stopped

    var telemetry: AudioEngineTelemetry {
        let bufferedFrames = UInt64(outputRendererSnapshot().map(\.availableFrameCount).max() ?? 0)
        let bandLevels = bandAnalyzer.levelSnapshot()
        let spectrumLevels = spectrumAnalyzerEnabledSnapshot() ? spectrumAnalyzer.levelSnapshot() : []
        telemetryLock.lock()
            let snapshot = AudioEngineTelemetry(
                capturedFrames: capturedFrames,
                renderedFrames: renderedFrames,
                underrunFrames: underrunFrames,
                bufferedFrames: bufferedFrames,
                inputCallbacks: inputCallbacks,
                renderCallbacks: renderCallbacks,
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
            aggregateDeviceID != kAudioObjectUnknown
        stop()
        if wasActive {
            Thread.sleep(forTimeInterval: 0.08)
        }

        guard captureDeviceID != nil || processTapsAreAvailable else {
            throw PureQAudioEngineError.processTapsUnavailable
        }
        guard !configuration.renderTargets.isEmpty else {
            throw PureQAudioEngineError.noOutputDevice
        }
        let outputDeviceIDs = Dictionary(uniqueKeysWithValues: configuration.renderTargets.compactMap { target in
            outputDeviceIDsByUID[target.outputUID].map { (target.outputUID, $0) }
        })
        guard outputDeviceIDs.count == configuration.renderTargets.count else {
            throw PureQAudioEngineError.noOutputDevice
        }

        let routedSources = configuration.sourceRoutes.filter(\.reachesOutput)
        guard !routedSources.isEmpty else {
            throw PureQAudioEngineError.noRoutedSources
        }

        resetTelemetry()
        setSpectrumAnalyzerEnabled(configuration.spectrumAnalyzerEnabled)

        do {
            let renderSampleRate: Double
            if #available(macOS 14.2, *) {
                renderSampleRate = try startTapCapture(for: routedSources, mutesOriginalAudio: configuration.mutesOriginalAudio)
            } else if let captureDeviceID {
                try startLoopbackCapture(deviceID: captureDeviceID)
                renderSampleRate = nominalSampleRate(for: captureDeviceID) ?? 48_000
            } else {
                throw PureQAudioEngineError.processTapsUnavailable
            }
            bandAnalyzer.configure(sampleRate: renderSampleRate)
            spectrumAnalyzer.configure(sampleRate: renderSampleRate)
            for target in configuration.renderTargets {
                guard let outputDeviceID = outputDeviceIDs[target.outputUID] else {
                    throw PureQAudioEngineError.noOutputDevice
                }
                let renderer = PureQOutputRenderer(target: target)
                try renderer.start(
                    target: target,
                    enabled: configuration.enabled,
                    outputDeviceID: outputDeviceID,
                    sampleRate: renderSampleRate,
                    recordRender: { [weak self] requestedFrames, renderedFrames in
                        self?.recordRender(requestedFrames: requestedFrames, renderedFrames: renderedFrames)
                    }
                )
                setOutputRenderer(renderer, for: target.outputUID)
            }
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

        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                _ = AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        clearOutputRenderers().forEach { $0.stop() }
        selfReference = nil
        resetTelemetry()
        setSpectrumAnalyzerEnabled(false)

        if runState != .stopped {
            runState = .stopped
        }
    }

    func ingest(inputData: UnsafePointer<AudioBufferList>?, frameCount: UInt32) {
        guard let inputData, frameCount > 0 else {
            return
        }
        for renderer in outputRendererSnapshot() {
            renderer.ingest(inputData: inputData, frameCount: frameCount)
        }
        bandAnalyzer.process(inputData: inputData, frameCount: frameCount)
        if spectrumAnalyzerEnabledSnapshot() {
            spectrumAnalyzer.process(inputData: inputData, frameCount: frameCount)
        }
        recordCapture(frameCount: frameCount)
    }

    func update(configuration: AudioEngineConfiguration) {
        guard runState == .running else {
            return
        }
        setSpectrumAnalyzerEnabled(configuration.spectrumAnalyzerEnabled)
        for target in configuration.renderTargets {
            outputRenderer(for: target.outputUID)?.update(target: target, enabled: configuration.enabled)
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
        outputRendererLock.unlock()
    }

    private func clearOutputRenderers() -> [PureQOutputRenderer] {
        outputRendererLock.lock()
        let renderers = Array(outputRenderers.values)
        outputRenderers.removeAll(keepingCapacity: true)
        outputRendererLock.unlock()
        return renderers
    }

    private func setSpectrumAnalyzerEnabled(_ isEnabled: Bool) {
        parameterLock.lock()
        currentSpectrumAnalyzerEnabled = isEnabled
        parameterLock.unlock()

        if !isEnabled {
            spectrumAnalyzer.reset()
        }
    }

    private func spectrumAnalyzerEnabledSnapshot() -> Bool {
        parameterLock.lock()
        let isEnabled = currentSpectrumAnalyzerEnabled
        parameterLock.unlock()
        return isEnabled
    }

    private func startLoopbackCapture(deviceID: AudioDeviceID) throws {
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

        let startStatus = AudioDeviceStart(deviceID, createdIOProcID)
        guard startStatus == noErr else {
            _ = AudioDeviceDestroyIOProcID(deviceID, createdIOProcID)
            throw PureQAudioEngineError.loopbackCaptureStartFailed(startStatus)
        }

        loopbackDeviceID = deviceID
        loopbackIOProcID = createdIOProcID
    }

    @available(macOS 14.2, *)
    private func startTapCapture(for routedSources: [AudioEngineSourceRoute], mutesOriginalAudio: Bool) throws -> Double {
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

        let startStatus = AudioDeviceStart(aggregateDeviceID, createdIOProcID)
        guard startStatus == noErr else {
            throw PureQAudioEngineError.tapStartFailed(startStatus)
        }

        return nominalSampleRate(for: aggregateDeviceID) ?? 48_000
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
        } else if #available(macOS 26.0, *) {
            let bundleIDs = Array(Set(routedSources.compactMap(\.bundleIdentifier))).sorted()
            guard !bundleIDs.isEmpty else {
                throw PureQAudioEngineError.noRunningProcessSource
            }
            description = CATapDescription()
            description.bundleIDs = bundleIDs
            description.isProcessRestoreEnabled = true
            description.isExclusive = false
            description.isMixdown = true
            description.isMono = false
        } else {
            let processIDs = Array(Set(routedSources.compactMap(\.processIdentifier))).sorted()
            let processObjectIDs = try processIDs.map { pid -> AudioObjectID in
                guard let objectID = processObjectID(for: pid) else {
                    throw PureQAudioEngineError.processObjectLookupFailed(pid)
                }
                return objectID
            }
            guard !processObjectIDs.isEmpty else {
                throw PureQAudioEngineError.noRunningProcessSource
            }
            description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        }

        description.name = "PureQ Source Tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = mutesOriginalAudio ? CATapMuteBehavior.mutedWhenTapped : CATapMuteBehavior.unmuted
        return description
    }

    private func resetTelemetry() {
        bandAnalyzer.reset()
        spectrumAnalyzer.reset()
        telemetryLock.lock()
        capturedFrames = 0
        renderedFrames = 0
        underrunFrames = 0
        inputCallbacks = 0
        renderCallbacks = 0
        telemetryLock.unlock()
    }

    private func recordCapture(frameCount: UInt32) {
        telemetryLock.lock()
        capturedFrames += UInt64(frameCount)
        inputCallbacks += 1
        telemetryLock.unlock()
    }

    private func recordRender(requestedFrames: AVAudioFrameCount, renderedFrames renderedFrameCount: UInt32) {
        telemetryLock.lock()
        renderedFrames += UInt64(renderedFrameCount)
        if renderedFrameCount < requestedFrames {
            underrunFrames += UInt64(requestedFrames - renderedFrameCount)
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

    private var processTapsAreAvailable: Bool {
        if #available(macOS 14.2, *) {
            return true
        }
        return false
    }
}

private final class PureQOutputRenderer {
    private let ringBuffer = StereoRingBuffer(
        capacityFrames: 48_000,
        startThresholdFrames: 2_048,
        targetFrames: 4_096
    )

    private var avEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var eqUnit: AVAudioUnitEQ?
    private let parameterLock = NSLock()
    private var currentBalance: Double

    init(target: AudioEngineRenderTarget) {
        currentBalance = target.balance.clamped(to: -1...1)
    }

    var availableFrameCount: Int {
        ringBuffer.availableFrameCount
    }

    func start(
        target: AudioEngineRenderTarget,
        enabled: Bool,
        outputDeviceID: AudioDeviceID,
        sampleRate: Double,
        recordRender: @escaping (AVAudioFrameCount, UInt32) -> Void
    ) throws {
        let engine = AVAudioEngine()
        guard let renderFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate.clamped(to: 8_000...384_000),
            channels: 2
        ) else {
            throw PureQAudioEngineError.renderFormatCreationFailed
        }

        let source = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let renderedFrameCount = self.ringBuffer.read(
                into: audioBufferList,
                frameCount: frameCount,
                balance: self.currentBalanceSnapshot()
            )
            recordRender(frameCount, renderedFrameCount)
            return noErr
        }
        let eq = AVAudioUnitEQ(numberOfBands: max(target.filters.count, 96))
        configure(eq: eq, filters: target.filters, preamp: target.preamp, enabled: enabled)

        engine.attach(source)
        engine.attach(eq)
        engine.connect(source, to: eq, format: renderFormat)
        engine.connect(eq, to: engine.mainMixerNode, format: renderFormat)
        engine.mainMixerNode.pan = 0

        var deviceID = outputDeviceID
        guard let outputAudioUnit = engine.outputNode.audioUnit else {
            throw PureQAudioEngineError.outputAudioUnitUnavailable
        }
        let status = AudioUnitSetProperty(
            outputAudioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw PureQAudioEngineError.outputDeviceSelectionFailed(status)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw PureQAudioEngineError.avEngineStartFailed(error)
        }

        avEngine = engine
        sourceNode = source
        eqUnit = eq
    }

    func stop() {
        avEngine?.stop()
        avEngine?.reset()
        avEngine = nil
        sourceNode = nil
        eqUnit = nil
        ringBuffer.reset()
    }

    func ingest(inputData: UnsafePointer<AudioBufferList>, frameCount: UInt32) {
        ringBuffer.write(from: inputData, frameCount: frameCount)
    }

    func update(target: AudioEngineRenderTarget, enabled: Bool) {
        setCurrentBalance(target.balance)
        guard let eqUnit else { return }
        configure(
            eq: eqUnit,
            filters: target.filters,
            preamp: target.preamp,
            enabled: enabled
        )
    }

    private func setCurrentBalance(_ balance: Double) {
        parameterLock.lock()
        currentBalance = balance.clamped(to: -1...1)
        parameterLock.unlock()
    }

    private func currentBalanceSnapshot() -> Double {
        parameterLock.lock()
        let balance = currentBalance
        parameterLock.unlock()
        return balance
    }

    private func configure(
        eq: AVAudioUnitEQ,
        filters: [AudioEngineFilterDescriptor],
        preamp: Double,
        enabled: Bool
    ) {
        eq.bypass = !enabled
        eq.globalGain = Float(preamp.clamped(to: -24...24))

        for (index, band) in eq.bands.enumerated() {
            guard index < filters.count else {
                band.bypass = true
                continue
            }

            let descriptor = filters[index]
            band.bypass = false
            band.frequency = Float(descriptor.frequency.clamped(to: 20...20_000))
            band.gain = Float(descriptor.gain.clamped(to: -24...24))
            band.bandwidth = Float(octaveBandwidth(forQ: descriptor.q))

            switch descriptor.shape {
            case .bell:
                band.filterType = .parametric
            case .shelf:
                band.filterType = descriptor.frequency < 1_000 ? .lowShelf : .highShelf
            case .notch:
                band.filterType = .bandStop
            }
        }
    }

    private func octaveBandwidth(forQ q: Double) -> Double {
        let clampedQ = q.clamped(to: 0.1...10)
        let halfWidth = asinh(1 / (2 * clampedQ)) / log(2)
        return (2 * halfWidth).clamped(to: 0.05...5.0)
    }
}

private let pureQLoopbackIOProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
    guard let clientData else {
        return noErr
    }
    let runner = Unmanaged<PureQAudioEngineRunner>.fromOpaque(clientData).takeUnretainedValue()
    let frameCount = pureQFrameCount(from: inputData)
    runner.ingest(inputData: inputData, frameCount: frameCount)
    return noErr
}

private let pureQTapIOProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
    guard let clientData else {
        return noErr
    }
    let runner = Unmanaged<PureQAudioEngineRunner>.fromOpaque(clientData).takeUnretainedValue()
    let frameCount = pureQFrameCount(from: inputData)
    runner.ingest(inputData: inputData, frameCount: frameCount)
    return noErr
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

private final class PureQBandLevelAnalyzer {
    private let frequencies: [Double]
    private var coefficients: [Double]
    private var levels: [Double]
    private var sampleRate = 48_000.0
    private var framesSinceAnalysis = 0
    private var analysisIntervalFrames = 1_600
    private let lock = NSLock()

    init(frequencies: [Double]) {
        self.frequencies = frequencies
        coefficients = Array(repeating: 0, count: frequencies.count)
        levels = Array(repeating: 0, count: frequencies.count)
        configure(sampleRate: sampleRate)
    }

    func configure(sampleRate: Double) {
        lock.lock()
        self.sampleRate = sampleRate.clamped(to: 8_000...384_000)
        analysisIntervalFrames = max(256, Int(self.sampleRate / 30.0))
        coefficients = frequencies.map { frequency in
            2 * cos(2 * .pi * frequency / self.sampleRate)
        }
        resetUnlocked()
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

private final class PureQSpectrumAnalyzer {
    private let fftSize = 2_048
    private let displayBinCount = 96
    private let minimumFrequency = 20.0
    private let maximumDisplayFrequency = 20_000.0
    private let lock = NSLock()

    private var sampleRate = 48_000.0
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
        configure(sampleRate: sampleRate)
    }

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    func configure(sampleRate: Double) {
        lock.lock()
        self.sampleRate = sampleRate.clamped(to: 8_000...384_000)
        rebuildBinRanges()
        resetUnlocked()
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
        for frame in 0..<frames {
            sampleBuffer[writeCursor] = monoSample(in: buffers, frame: frame)
            writeCursor += 1

            if writeCursor >= fftSize {
                performFFTUnlocked()
                writeCursor = 0
            }
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
    }

    private func performFFTUnlocked() {
        guard let fftSetup else { return }

        vDSP.multiply(sampleBuffer, window, result: &windowedSamples)
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
            for fftBin in range where magnitudes.indices.contains(fftBin) {
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

private final class StereoRingBuffer {
    private let lock = NSLock()
    private var storage: [Float]
    private let capacityFrames: Int
    private let startThresholdFrames: Int
    private let targetFrames: Int
    private let maximumBufferedFrames: Int
    private var readIndex = 0
    private var writeIndex = 0
    private var availableFrames = 0
    private var isPrimed = false
    private var fractionalReadFrame = 0.0
    private var smoothedRateStep = 1.0

    init(capacityFrames: Int, startThresholdFrames: Int, targetFrames: Int) {
        self.capacityFrames = max(capacityFrames, 1)
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
        storage = Array(repeating: 0, count: self.capacityFrames * 2)
    }

    var availableFrameCount: Int {
        lock.lock()
        let count = availableFrames
        lock.unlock()
        return count
    }

    func reset() {
        lock.lock()
        readIndex = 0
        writeIndex = 0
        availableFrames = 0
        isPrimed = false
        fractionalReadFrame = 0
        smoothedRateStep = 1
        storage.withUnsafeMutableBufferPointer { pointer in
            pointer.initialize(repeating: 0)
        }
        lock.unlock()
    }

    func write(from inputData: UnsafePointer<AudioBufferList>, frameCount: UInt32) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard !buffers.isEmpty else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        for frame in 0..<Int(frameCount) {
            let left = sample(in: buffers, frame: frame, channel: 0)
            let right = sample(in: buffers, frame: frame, channel: 1)

            storage[writeIndex * 2] = left
            storage[writeIndex * 2 + 1] = right
            writeIndex = (writeIndex + 1) % capacityFrames

            if availableFrames == capacityFrames {
                readIndex = (readIndex + 1) % capacityFrames
                fractionalReadFrame = 0
                smoothedRateStep = 1
            } else {
                availableFrames += 1
            }
        }
        trimExcessBufferIfNeeded()
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

        lock.lock()
        defer { lock.unlock() }

        let requestedFrames = Int(frameCount)
        if !isPrimed {
            guard availableFrames >= startThresholdFrames else {
                fillSilence(buffers: buffers, frameCount: frameCount)
                return 0
            }
            isPrimed = true
            fractionalReadFrame = 0
            smoothedRateStep = 1
        }

        guard availableFrames >= 2 else {
            isPrimed = false
            fractionalReadFrame = 0
            smoothedRateStep = 1
            fillSilence(buffers: buffers, frameCount: frameCount)
            return 0
        }

        let rateStep = adaptiveRateStep()
        var renderedFrames: UInt32 = 0
        for frame in 0..<requestedFrames {
            guard availableFrames >= 2 else {
                isPrimed = false
                fractionalReadFrame = 0
                smoothedRateStep = 1
                fillSilence(buffers: buffers, frameOffset: frame, frameCount: requestedFrames - frame)
                break
            }

            let currentIndex = readIndex
            let nextIndex = (readIndex + 1) % capacityFrames
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
            let framesToConsume = min(Int(fractionalReadFrame), max(availableFrames - 1, 0))
            if framesToConsume > 0 {
                readIndex = (readIndex + framesToConsume) % capacityFrames
                availableFrames -= framesToConsume
                fractionalReadFrame -= Double(framesToConsume)
            }
            renderedFrames += 1
        }

        for bufferIndex in 0..<buffers.count {
            let channelCount = max(buffers[bufferIndex].mNumberChannels, 1)
            buffers[bufferIndex].mDataByteSize = frameCount * channelCount * UInt32(MemoryLayout<Float>.size)
        }

        return renderedFrames
    }

    private func adaptiveRateStep() -> Double {
        let deadbandFrames = max(64.0, Double(targetFrames) * 0.015)
        let rawError = Double(availableFrames - targetFrames)
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

    private func trimExcessBufferIfNeeded() {
        guard availableFrames > maximumBufferedFrames else { return }
        let framesToDrop = availableFrames - maximumBufferedFrames
        readIndex = (readIndex + framesToDrop) % capacityFrames
        availableFrames = maximumBufferedFrames
        fractionalReadFrame = 0
        smoothedRateStep = 1
        isPrimed = availableFrames >= startThresholdFrames
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
}
