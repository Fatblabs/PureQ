//
//  AudioEngineService.swift
//  PureQ
//

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
            return "Audio render loop is active."
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
    let id: EqualizerBand.ID
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
    let systemVolume: Float
    let systemMuted: Bool
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
    let bandMetersEnabled: Bool
    let visualAnalyzerFrameRate: Double
    let nodeCount: Int
    let connectionCount: Int
    let mutesOriginalAudio: Bool
    let prefersDriverCapture: Bool
}

struct AudioEngineTelemetry: Equatable {
    static let activityMeterFrequencies = [80.0, 500.0, 2_000.0, 8_000.0]

    let sampleRate: Double
    let capturedFrames: UInt64
    let renderedFrames: UInt64
    let underrunFrames: UInt64
    let bufferedFrames: UInt64
    let inputCallbacks: UInt64
    let renderCallbacks: UInt64
    let bandLevels: [Double]
    let spectrumLevels: [Double]

    static let empty = AudioEngineTelemetry(
        sampleRate: 48_000,
        capturedFrames: 0,
        renderedFrames: 0,
        underrunFrames: 0,
        bufferedFrames: 0,
        inputCallbacks: 0,
        renderCallbacks: 0,
        bandLevels: Array(repeating: 0, count: activityMeterFrequencies.count),
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
        bandMetersEnabled: Bool,
        visualAnalyzerFrameRate: Double,
        systemVolume: Float,
        systemMuted: Bool,
        processedTakeoverEnabled: Bool
    ) -> AudioEngineConfiguration {
        let fallbackFilters = filterDescriptors(from: bands)
        let nodeByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let rawRoutePlans = compileRoutePlans(
            sources: sources,
            nodes: nodes,
            nodeByID: nodeByID,
            connections: connections,
            fallbackOutputUID: outputUID,
            fallbackOutputName: outputName
        )
        let protectedSystemSourceNodeIDs = Set(nodes.compactMap { node -> RoutingNode.ID? in
            guard node.kind == .source,
                  node.isProtected,
                  (node.audioSourceID ?? AudioSourceItem.systemMixID) == AudioSourceItem.systemMixID else {
                return nil
            }
            return node.id
        })
        let hasSpecificSourceRoute = rawRoutePlans.contains { route in
            route.outputUID != nil && route.sourceID != AudioSourceItem.systemMixID
        }
        let routePlans = hasSpecificSourceRoute
            ? rawRoutePlans.filter { !protectedSystemSourceNodeIDs.contains($0.sourceNodeID) }
            : rawRoutePlans
        let routableRoutePlans = routePlans.filter { $0.outputUID != nil }
        let routedSourceNodeIDs = Set(routableRoutePlans.map(\.sourceNodeID))
        let renderTargets = makeRenderTargets(
            from: routableRoutePlans,
            nodeByID: nodeByID,
            fallbackFilters: fallbackFilters,
            fallbackPreamp: preamp,
            fallbackBalance: balance,
            systemVolume: systemVolume,
            systemMuted: systemMuted
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
                    reachesOutput: routedSourceNodeIDs.contains(node.id)
                )
            }

        let prefersDriverCapture = virtualCaptureUID != nil &&
            sourceRoutes.contains { $0.reachesOutput && $0.sourceID == AudioSourceItem.systemMixID }

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
            bandMetersEnabled: bandMetersEnabled,
            visualAnalyzerFrameRate: visualAnalyzerFrameRate.clamped(to: 15...60),
            nodeCount: nodes.count,
            connectionCount: connections.count,
            mutesOriginalAudio: processedTakeoverEnabled,
            prefersDriverCapture: prefersDriverCapture
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

        if configuration.renderTargets.isEmpty {
            if tapsAvailable || configuration.virtualCaptureUID != nil {
                return AudioEngineStatus(
                    state: .ready,
                    title: "Silent Graph Ready",
                    detail: "Routed sources will be captured and muted because no output node is connected.",
                    processTapsAvailable: tapsAvailable,
                    driverInstalled: installed,
                    driverBundled: bundled
                )
            }

            return AudioEngineStatus(
                state: .blocked,
                title: "No Output",
                detail: "Patch at least one route to a hardware output before starting the audio engine.",
                processTapsAvailable: tapsAvailable,
                driverInstalled: installed,
                driverBundled: bundled
            )
        }

        if configuration.prefersDriverCapture {
            let routeCount = configuration.routePlans.count
            let filterCount = configuration.renderTargets.reduce(0) { $0 + $1.filters.count }
            return AudioEngineStatus(
                state: .ready,
                title: "Driver Capture Ready",
                detail: "\(configuration.virtualCaptureName ?? "PureQ Virtual Output") -> shared-memory capture -> EQ -> \(renderTargetSummary(configuration.renderTargets)): \(routeCount) route\(routeCount == 1 ? "" : "s"), \(filterCount) active filter\(filterCount == 1 ? "" : "s").",
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
                title: "Tap Routing Ready",
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
        fallbackBalance: Double,
        systemVolume: Float,
        systemMuted: Bool
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
                balance: balance,
                systemVolume: systemVolume.clamped(to: 0...1),
                systemMuted: systemMuted
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
            .filter { $0.isEnabled && (abs($0.gain) > 0.01 || $0.shape == .notch) }
            .map {
                AudioEngineFilterDescriptor(
                    id: $0.id,
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
