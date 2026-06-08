//
//  PureQDiagnosticsReportBuilder.swift
//  PureQ
//

import CoreAudio
import CryptoKit
import Foundation

enum PureQDiagnosticsReportBuilder {
    static func makeReport(
        generatedAt: Date,
        powerEnabled: Bool,
        debugModeEnabled: Bool,
        highFrameRateUIEnabled: Bool,
        spectrumAnalyzerEnabled: Bool,
        soundIndicatorsEnabled: Bool,
        graphBandEditingEnabled: Bool,
        graphWidthScale: Double,
        graphHeightScale: Double,
        activeEQTitle: String,
        activeEQMode: EqualizerMode,
        activeEQSelection: EqualizerSelection,
        activeEQBandLayout: EqualizerBandLayout,
        activeEQPreamp: Double,
        activeEQBalance: Double,
        activeEQAutoGainEnabled: Bool,
        activeEQClippingStatus: EQClippingStatus,
        activeEQBands: [EqualizerBand],
        audioEngineRunState: AudioEngineRunState,
        audioEngineStatus: AudioEngineStatus,
        audioEngineConfiguration: AudioEngineConfiguration,
        audioEngineTelemetry: AudioEngineTelemetry,
        outputClippingStatus: OutputClippingStatus,
        outputDevices: [AudioOutputDevice],
        outputDiagnostics: [AudioOutputDeviceDiagnostic],
        defaultOutputUID: String?,
        defaultSystemOutputUID: String?,
        availableAudioSources: [AudioSourceItem],
        routingNodes: [RoutingNode],
        routingConnections: [RoutingConnection],
        selectedRoutingNodeID: RoutingNode.ID?,
        activeEQNodeID: RoutingNode.ID?,
        readinessItems: [TestReadinessItem],
        readinessSummary: TestReadinessState,
        driverInstallInProgress: Bool,
        driverInstallMessage: String?,
        autoStartEngineEnabled: Bool,
        pureQSystemVolume: Float,
        pureQSystemMuted: Bool,
        capturedSourceNodeIDs: Set<RoutingNode.ID>,
        visibleGraphicalSurfaceCount: Int
    ) -> String {
        var lines: [String] = []
        let nodeByID = Dictionary(uniqueKeysWithValues: routingNodes.map { ($0.id, $0) })
        let deviceByUID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.uid, $0) })

        appendHeader(to: &lines, title: "PureQ Debug Snapshot")
        lines.append("Generated: \(timestamp(generatedAt))")
        lines.append("App: \(appSummary)")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Host: \(hostSummary)")
        lines.append("Debug mode: \(onOff(debugModeEnabled))")
        lines.append("Power: \(onOff(powerEnabled))")
        lines.append("Auto-start engine: \(onOff(autoStartEngineEnabled))")
        lines.append("Visible graphical surfaces: \(visibleGraphicalSurfaceCount)")
        lines.append("")

        appendHeader(to: &lines, title: "Failure Hints")
        let hints = failureHints(
            configuration: audioEngineConfiguration,
            runState: audioEngineRunState,
            status: audioEngineStatus,
            telemetry: audioEngineTelemetry,
            outputClippingStatus: outputClippingStatus,
            diagnostics: outputDiagnostics,
            outputDevices: outputDevices,
            defaultOutputUID: defaultOutputUID,
            defaultSystemOutputUID: defaultSystemOutputUID,
            sources: availableAudioSources,
            readinessItems: readinessItems
        )
        if hints.isEmpty {
            lines.append("No obvious failure hints in this snapshot.")
        } else {
            hints.forEach { lines.append("- \($0)") }
        }
        lines.append("")

        appendHeader(to: &lines, title: "Readiness")
        lines.append("Summary: \(readinessSummary.title)")
        readinessItems.forEach { item in
            lines.append("- \(item.title): \(item.state.title) - \(item.detail)")
        }
        lines.append("")

        appendHeader(to: &lines, title: "Audio Engine")
        lines.append("Run state: \(audioEngineRunState.title) - \(audioEngineRunState.detail)")
        lines.append("Evaluated state: \(audioEngineStatus.state.title)")
        lines.append("Status title: \(audioEngineStatus.title)")
        lines.append("Status detail: \(audioEngineStatus.detail)")
        lines.append("Process taps available: \(yesNo(audioEngineStatus.processTapsAvailable))")
        lines.append("Driver installed: \(yesNo(audioEngineStatus.driverInstalled))")
        lines.append("Driver bundled: \(yesNo(audioEngineStatus.driverBundled))")
        lines.append("Driver install in progress: \(yesNo(driverInstallInProgress))")
        lines.append("Driver install message: \(driverInstallMessage ?? "none")")
        lines.append("Prefers driver capture: \(yesNo(audioEngineConfiguration.prefersDriverCapture))")
        lines.append("Mutes original audio: \(yesNo(audioEngineConfiguration.mutesOriginalAudio))")
        lines.append("Virtual capture: \(audioEngineConfiguration.virtualCaptureName ?? "none") [uid: \(audioEngineConfiguration.virtualCaptureUID ?? "none")]")
        lines.append("Primary output: \(audioEngineConfiguration.outputName) [uid: \(audioEngineConfiguration.outputUID ?? "none")]")
        lines.append("System volume bridge: \(percent(Double(pureQSystemVolume))) muted=\(yesNo(pureQSystemMuted))")
        lines.append("Visual analyzers: fft=\(onOff(spectrumAnalyzerEnabled)), meters=\(onOff(soundIndicatorsEnabled)), highFPS=\(onOff(highFrameRateUIEnabled)), frameRate=\(format(audioEngineConfiguration.visualAnalyzerFrameRate, digits: 1))")
        lines.append("")

        appendHeader(to: &lines, title: "Output Sound Telemetry")
        lines.append("Telemetry sample rate: \(rate(audioEngineTelemetry.sampleRate))")
        lines.append("Captured frames: \(audioEngineTelemetry.capturedFrames)")
        lines.append("Rendered frames: \(audioEngineTelemetry.renderedFrames)")
        lines.append("Buffered frames: \(audioEngineTelemetry.bufferedFrames)")
        lines.append("Underrun frames: \(audioEngineTelemetry.underrunFrames)")
        lines.append("Input callbacks: \(audioEngineTelemetry.inputCallbacks)")
        lines.append("Render callbacks: \(audioEngineTelemetry.renderCallbacks)")
        lines.append("Output peak: \(db(audioEngineTelemetry.outputPeakDecibels)) level=\(format(audioEngineTelemetry.outputPeakLevel, digits: 5))")
        lines.append("Clipped samples: \(audioEngineTelemetry.clippedSampleCount)")
        lines.append("Clipped callbacks: \(audioEngineTelemetry.clippedCallbackCount)")
        lines.append("Output clip risk: \(outputRiskTitle(outputClippingStatus.risk)) peak=\(db(outputClippingStatus.peakDecibels)) recentSamples=\(outputClippingStatus.recentClippedSamples) held=\(yesNo(outputClippingStatus.isClipHeld))")
        lines.append("Band meter levels: \(levelSummary(audioEngineTelemetry.bandLevels))")
        lines.append("Spectrum levels: count=\(audioEngineTelemetry.spectrumLevels.count) top=\(spectrumSummary(audioEngineTelemetry.spectrumLevels))")
        lines.append("")

        appendHeader(to: &lines, title: "Current Curve")
        lines.append("Target: \(activeEQTitle)")
        lines.append("Mode: \(activeEQMode.rawValue)")
        lines.append("Selection: \(activeEQSelection.title)")
        lines.append("Layout: \(activeEQBandLayout.title)")
        lines.append("Preamp: \(db(activeEQPreamp))")
        lines.append("Balance: \(format(activeEQBalance, digits: 3))")
        lines.append("Auto preamp: \(onOff(activeEQAutoGainEnabled))")
        lines.append("Graph editing: \(onOff(graphBandEditingEnabled))")
        lines.append("Graph scale: width=\(format(graphWidthScale, digits: 2)) height=\(format(graphHeightScale, digits: 2))")
        lines.append("Estimated EQ peak: \(db(activeEQClippingStatus.peakDecibels)) risk=\(eqRiskTitle(activeEQClippingStatus.risk))")
        lines.append("Bands: \(activeEQBands.count) total, \(activeEQBands.filter(\.isEnabled).count) enabled")
        activeEQBands.sorted { $0.frequency < $1.frequency }.forEach { band in
            lines.append("  - \(bandID(band.id)) freq=\(rate(band.frequency)) slot=\(rate(band.slotFrequency)) gain=\(db(band.gain)) q=\(format(band.q, digits: 3)) shape=\(band.shape.rawValue) enabled=\(yesNo(band.isEnabled)) linked=\(yesNo(band.isStereoLinked)) custom=\(yesNo(band.isCustom))")
        }
        lines.append("")

        appendHeader(to: &lines, title: "Engine Filters")
        lines.append("Primary filters: \(audioEngineConfiguration.filters.count)")
        audioEngineConfiguration.filters.forEach { filter in
            lines.append("  - \(bandID(filter.id)) freq=\(rate(filter.frequency)) gain=\(db(filter.gain)) q=\(format(filter.q, digits: 3)) shape=\(filter.shape.rawValue)")
        }
        lines.append("")

        appendHeader(to: &lines, title: "macOS Audio Settings")
        lines.append("Default output UID: \(defaultOutputUID ?? "none") name=\(deviceByUID[defaultOutputUID ?? ""]?.name ?? "unknown")")
        lines.append("Default system output UID: \(defaultSystemOutputUID ?? "none") name=\(deviceByUID[defaultSystemOutputUID ?? ""]?.name ?? "unknown")")
        lines.append("Discovered output devices: \(outputDiagnostics.count)")
        outputDiagnostics.forEach { device in
            lines.append("  - \(device.name) [id=\(device.audioObjectID), uid=\(device.uid)]")
            lines.append("    channels=\(device.outputChannelCount) pureQ=\(yesNo(device.isPureQVirtualOutput)) hidden=\(optionalYesNo(device.isHidden)) default=\(yesNo(device.isDefaultOutput)) systemDefault=\(yesNo(device.isDefaultSystemOutput))")
            lines.append("    nominal=\(optionalRate(device.nominalSampleRate)) actual=\(optionalRate(device.actualSampleRate)) streams=\(rateList(device.streamSampleRates)) buffer=\(optionalFrames(device.bufferFrameSize)) bufferRange=\(frameRange(device.bufferFrameSizeRange))")
            lines.append("    volumeScalar=\(optionalFloat(device.volumeScalar)) outputGain=\(optionalFloat(device.outputGain)) muted=\(yesNo(device.isMuted)) supportsMute=\(yesNo(device.supportsMute))")
            lines.append("    availableRates=\(rateRanges(device.availableNominalSampleRateRanges))")
        }
        lines.append("")

        appendHeader(to: &lines, title: "Driver Details")
        driverDetails().forEach { lines.append($0) }
        lines.append("")

        appendHeader(to: &lines, title: "Routing Graph")
        lines.append("Nodes: \(routingNodes.count)")
        routingNodes.sorted { lhs, rhs in
            if lhs.position.x == rhs.position.x {
                return lhs.position.y < rhs.position.y
            }
            return lhs.position.x < rhs.position.x
        }.forEach { node in
            lines.append("  - \(node.kind.rawValue) \(node.title) [\(nodeID(node.id))]")
            lines.append("    subtitle=\(node.subtitle)")
            lines.append("    position=(\(format(Double(node.position.x), digits: 1)), \(format(Double(node.position.y), digits: 1))) protected=\(yesNo(node.isProtected)) selected=\(yesNo(node.id == selectedRoutingNodeID)) activeEQ=\(yesNo(node.id == activeEQNodeID))")
            if node.kind == .source {
                let source = availableAudioSources.first { $0.id == (node.audioSourceID ?? AudioSourceItem.systemMixID) }
                lines.append("    sourceID=\(node.audioSourceID ?? AudioSourceItem.systemMixID) sourceTitle=\(source?.title ?? "unknown") volume=\(percent(node.sourceVolumeValue)) muted=\(yesNo(node.sourceMutedValue)) soloed=\(yesNo(node.sourceSoloedValue)) captured=\(yesNo(capturedSourceNodeIDs.contains(node.id)))")
            }
            if node.kind == .output {
                lines.append("    outputUID=\(node.audioOutputUID ?? "none") outputName=\(deviceByUID[node.audioOutputUID ?? ""]?.name ?? "unknown")")
            }
            if node.kind == .equalizer {
                lines.append("    eqMode=\(node.eqMode.rawValue) eqSelection=\(node.eqSelection.title) usesMain=\(yesNo(node.eqUsesMainEqualizer)) bands=\(node.eqBands.count) enabled=\(node.eqBands.filter(\.isEnabled).count) preamp=\(db(node.eqPreamp)) balance=\(format(node.eqBalance, digits: 3)) auto=\(yesNo(node.eqAutoGainEnabled))")
            }
        }
        lines.append("Connections: \(routingConnections.count)")
        routingConnections.forEach { connection in
            lines.append("  - \(nodeLabel(connection.from, nodeByID: nodeByID)) -> \(nodeLabel(connection.to, nodeByID: nodeByID)) [\(nodeID(connection.id))]")
        }
        lines.append("")

        appendHeader(to: &lines, title: "Driver Flow Snapshot")
        lines.append("Source routes: \(audioEngineConfiguration.sourceRoutes.count)")
        audioEngineConfiguration.sourceRoutes.forEach { route in
            lines.append("  - \(route.title) [node=\(nodeID(route.sourceNodeID)), sourceID=\(route.sourceID)] reachesOutput=\(yesNo(route.reachesOutput)) volume=\(percent(route.volume)) muted=\(yesNo(route.isMuted)) soloed=\(yesNo(route.isSoloed))")
            lines.append("    bundle=\(route.bundleIdentifier ?? "none") bundles=\(route.bundleIdentifiers.joined(separator: ", ")) pid=\(route.processIdentifier.map(String.init) ?? "none") processObjects=\(objectIDList(route.processObjectIDs))")
        }
        lines.append("Suppression routes: \(audioEngineConfiguration.suppressionSourceRoutes.count)")
        audioEngineConfiguration.suppressionSourceRoutes.forEach { route in
            lines.append("  - \(route.title) [node=\(nodeID(route.sourceNodeID))] reachesOutput=\(yesNo(route.reachesOutput)) muted=\(yesNo(route.isMuted)) soloed=\(yesNo(route.isSoloed))")
        }
        lines.append("Route plans: \(audioEngineConfiguration.routePlans.count)")
        audioEngineConfiguration.routePlans.forEach { plan in
            lines.append("  - source=\(plan.title) output=\(plan.outputName) [uid=\(plan.outputUID ?? "none")] filters=\(plan.filters.count) preamp=\(db(plan.preamp)) sourceGain=\(db(plan.sourceGainDecibels))")
            lines.append("    path=\(plan.nodePath.map { nodeLabel($0, nodeByID: nodeByID) }.joined(separator: " -> "))")
            lines.append("    eqNodes=\(plan.eqNodeIDs.map { nodeLabel($0, nodeByID: nodeByID) }.joined(separator: ", "))")
            lines.append("    bundle=\(plan.bundleIdentifier ?? "none") bundles=\(plan.bundleIdentifiers.joined(separator: ", ")) pid=\(plan.processIdentifier.map(String.init) ?? "none") processObjects=\(objectIDList(plan.processObjectIDs)) muted=\(yesNo(plan.isMuted)) soloed=\(yesNo(plan.isSoloed))")
        }
        lines.append("Render targets: \(audioEngineConfiguration.renderTargets.count)")
        audioEngineConfiguration.renderTargets.forEach { target in
            lines.append("  - \(target.outputName) [uid=\(target.outputUID)] routes=\(target.routeCount) filters=\(target.filters.count) preamp=\(db(target.preamp)) balance=\(format(target.balance, digits: 3)) systemVolume=\(percent(Double(target.systemVolume))) systemMuted=\(yesNo(target.systemMuted))")
        }
        lines.append("")

        appendHeader(to: &lines, title: "Audio Sources")
        availableAudioSources.forEach { source in
            lines.append("  - \(source.title) [id=\(source.id)] kind=\(source.kind.rawValue) running=\(yesNo(source.isRunning))")
            lines.append("    bundle=\(source.bundleIdentifier ?? "none") pid=\(source.processIdentifier.map(String.init) ?? "none") processObjects=\(objectIDList(source.processObjectIDs)) tapBundles=\(source.tapBundleIdentifiers.joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
    }

    private static func appendHeader(to lines: inout [String], title: String) {
        lines.append("==== \(title) ====")
    }

    private static func failureHints(
        configuration: AudioEngineConfiguration,
        runState: AudioEngineRunState,
        status: AudioEngineStatus,
        telemetry: AudioEngineTelemetry,
        outputClippingStatus: OutputClippingStatus,
        diagnostics: [AudioOutputDeviceDiagnostic],
        outputDevices: [AudioOutputDevice],
        defaultOutputUID: String?,
        defaultSystemOutputUID: String?,
        sources: [AudioSourceItem],
        readinessItems: [TestReadinessItem]
    ) -> [String] {
        var hints: [String] = []

        if case .failed(let message) = runState {
            hints.append("Audio engine failed: \(message)")
        }
        if status.state != .ready {
            hints.append("Audio engine status is \(status.state.title): \(status.detail)")
        }
        readinessItems.filter { $0.state != .ready }.forEach { item in
            hints.append("\(item.title) is \(item.state.title): \(item.detail)")
        }
        if let driverHint = installedDriverMismatchHint() {
            hints.append(driverHint)
        }

        let outputUIDs = Set(outputDevices.map(\.uid))
        let missingTargets = configuration.renderTargets.filter { !outputUIDs.contains($0.outputUID) }
        missingTargets.forEach { target in
            hints.append("Render target is not currently resolvable: \(target.outputName) [\(target.outputUID)]")
        }

        if let virtualUID = configuration.virtualCaptureUID {
            if defaultOutputUID != virtualUID || defaultSystemOutputUID != virtualUID {
                hints.append("PureQ virtual capture is configured, but macOS defaults are output=\(defaultOutputUID ?? "none") system=\(defaultSystemOutputUID ?? "none") instead of \(virtualUID).")
            }
        }

        diagnostics.forEach { device in
            if let nominal = device.nominalSampleRate,
               let actual = device.actualSampleRate,
               !sampleRatesMatch(nominal, actual) {
                hints.append("\(device.name) nominal/actual sample rate mismatch: nominal \(rate(nominal)), actual \(rate(actual)).")
            }
        }

        if runState == .running, telemetry.renderCallbacks == 0 {
            hints.append("Engine says running, but render callback count is zero.")
        }
        if runState == .running, telemetry.renderedFrames == 0 {
            hints.append("Engine says running, but rendered frames are zero.")
        }
        if configuration.prefersDriverCapture && runState == .running && telemetry.capturedFrames == 0 {
            hints.append("Driver capture path is active, but captured frames are zero.")
        }
        if telemetry.underrunFrames > 0 {
            hints.append("Underrun frames detected: \(telemetry.underrunFrames).")
        }
        if telemetry.clippedSampleCount > 0 || outputClippingStatus.risk == .clipping {
            hints.append("Output clipping detected: \(telemetry.clippedSampleCount) clipped samples, \(telemetry.clippedCallbackCount) clip callbacks.")
        }

        let sourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        configuration.sourceRoutes.filter(\.reachesOutput).forEach { route in
            if route.sourceID != AudioSourceItem.systemMixID,
               sourceByID[route.sourceID]?.isRunning != true {
                hints.append("Routed app source is not currently running: \(route.title).")
            }
            if route.sourceID != AudioSourceItem.systemMixID,
               route.processIdentifier == nil,
               route.processObjectIDs.isEmpty {
                hints.append("Routed app source has no CoreAudio process identity yet: \(route.title).")
            }
        }

        return Array(NSOrderedSet(array: hints)) as? [String] ?? hints
    }

    private static func driverDetails() -> [String] {
        let bundledURL = Bundle.main.url(forResource: "PureQ", withExtension: "driver")
        let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/PureQ.driver")
        return [
            "Bundled driver: \(bundleSummary(url: bundledURL))",
            "Installed driver: \(bundleSummary(url: installedURL))",
            "Driver executable match: \(driverExecutableMatchSummary(bundledURL: bundledURL, installedURL: installedURL))",
            "Driver bundle identifier expected: Sean-s-Apps.PureQ.driver",
            "Virtual output UID expected: \(AudioOutputDevice.pureQVirtualOutputUID)"
        ]
    }

    private static func installedDriverMismatchHint() -> String? {
        let bundledURL = Bundle.main.url(forResource: "PureQ", withExtension: "driver")
        let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/PureQ.driver")
        guard FileManager.default.fileExists(atPath: installedURL.path) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: bundledURL?.path ?? "") else {
            return "This PureQ app build does not bundle PureQ.driver, so Repair Driver cannot update the installed HAL driver."
        }
        guard let bundledFingerprint = driverExecutableFingerprint(bundleURL: bundledURL),
              let installedFingerprint = driverExecutableFingerprint(bundleURL: installedURL) else {
            return nil
        }
        guard bundledFingerprint != installedFingerprint else {
            return nil
        }
        return "Installed PureQ.driver does not match the driver bundled with this app. Run Repair Driver from this app build or reinstall the package."
    }

    private static func bundleSummary(url: URL?) -> String {
        guard let url else { return "missing" }
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard exists else { return "\(url.path) missing" }

        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        let executableURL = url.appendingPathComponent("Contents/MacOS/PureQ")
        let info = NSDictionary(contentsOf: infoURL) as? [String: Any] ?? [:]
        let bundleID = info["CFBundleIdentifier"] as? String ?? "unknown"
        let version = info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "unknown"
        let executableAttributes = try? FileManager.default.attributesOfItem(atPath: executableURL.path)
        let executableSize = (executableAttributes?[.size] as? NSNumber)?.int64Value
        let modified = executableAttributes?[.modificationDate] as? Date
        return "\(url.path) exists bundleID=\(bundleID) version=\(version) executableSize=\(executableSize.map { formatBytes($0) } ?? "unknown") executableModified=\(modified.map { timestamp($0) } ?? "unknown")"
    }

    private static func driverExecutableMatchSummary(bundledURL: URL?, installedURL: URL) -> String {
        guard let bundledURL,
              FileManager.default.fileExists(atPath: bundledURL.path) else {
            return "bundled driver missing"
        }
        guard FileManager.default.fileExists(atPath: installedURL.path) else {
            return "installed driver missing"
        }
        guard let bundledFingerprint = driverExecutableFingerprint(bundleURL: bundledURL),
              let installedFingerprint = driverExecutableFingerprint(bundleURL: installedURL) else {
            return "unknown"
        }
        if bundledFingerprint == installedFingerprint {
            return "yes (\(fingerprintSummary(bundledFingerprint)))"
        }
        return "no (bundled \(fingerprintSummary(bundledFingerprint)); installed \(fingerprintSummary(installedFingerprint)))"
    }

    private struct DriverExecutableFingerprint: Equatable {
        let byteCount: Int
        let sha256: String
    }

    private static func driverExecutableFingerprint(bundleURL: URL?) -> DriverExecutableFingerprint? {
        guard let executableURL = bundleURL?.appendingPathComponent("Contents/MacOS/PureQ"),
              let data = try? Data(contentsOf: executableURL) else {
            return nil
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return DriverExecutableFingerprint(byteCount: data.count, sha256: digest)
    }

    private static func fingerprintSummary(_ fingerprint: DriverExecutableFingerprint) -> String {
        let digestPrefix = String(fingerprint.sha256.prefix(12))
        return "\(formatBytes(Int64(fingerprint.byteCount))) sha256=\(digestPrefix)..."
    }

    private static var appSummary: String {
        let bundle = Bundle.main
        let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "PureQ"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(name) \(version) (\(build)) bundleID=\(bundle.bundleIdentifier ?? "unknown")"
    }

    private static var hostSummary: String {
        "\(Host.current().localizedName ?? "unknown") arch=\(ProcessInfo.processInfo.processorCount)c active=\(ProcessInfo.processInfo.activeProcessorCount)c"
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func nodeLabel(_ id: RoutingNode.ID, nodeByID: [RoutingNode.ID: RoutingNode]) -> String {
        guard let node = nodeByID[id] else { return "missing:\(nodeID(id))" }
        return "\(node.title)(\(node.kind.rawValue):\(nodeID(id)))"
    }

    private static func nodeID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private static func bandID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private static func objectIDList(_ objectIDs: [AudioObjectID]) -> String {
        objectIDs.isEmpty ? "none" : objectIDs.map(String.init).joined(separator: ",")
    }

    private static func rate(_ value: Double) -> String {
        if value >= 1_000 {
            let khz = value / 1_000
            return "\(format(khz, digits: khz >= 100 ? 1 : 3)) kHz"
        }
        return "\(format(value, digits: 1)) Hz"
    }

    private static func sampleRatesMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        let tolerance = max(5.0, max(abs(lhs), abs(rhs)) * 0.00005)
        return abs(lhs - rhs) <= tolerance
    }

    private static func optionalRate(_ value: Double?) -> String {
        value.map { rate($0) } ?? "unknown"
    }

    private static func db(_ value: Double) -> String {
        "\(format(value, digits: 2)) dB"
    }

    private static func percent(_ value: Double) -> String {
        "\(format(value * 100, digits: 1))%"
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private static func optionalYesNo(_ value: Bool?) -> String {
        value.map { yesNo($0) } ?? "unknown"
    }

    private static func onOff(_ value: Bool) -> String {
        value ? "on" : "off"
    }

    private static func optionalFloat(_ value: Float?) -> String {
        value.map { format(Double($0), digits: 4) } ?? "unknown"
    }

    private static func optionalFrames(_ value: UInt32?) -> String {
        value.map(String.init) ?? "unknown"
    }

    private static func frameRange(_ range: ClosedRange<UInt32>?) -> String {
        guard let range else { return "unknown" }
        return "\(range.lowerBound)...\(range.upperBound)"
    }

    private static func rateRanges(_ ranges: [ClosedRange<Double>]) -> String {
        guard !ranges.isEmpty else { return "unknown" }
        return ranges.map { "\($0.lowerBound == $0.upperBound ? rate($0.lowerBound) : "\(rate($0.lowerBound))...\(rate($0.upperBound))")" }
            .joined(separator: ", ")
    }

    private static func rateList(_ rates: [Double]) -> String {
        guard !rates.isEmpty else { return "unknown" }
        return rates.map { rate($0) }.joined(separator: ", ")
    }

    private static func levelSummary(_ levels: [Double]) -> String {
        guard !levels.isEmpty else { return "none" }
        return levels.enumerated()
            .map { index, level in "\(index)=\(format(level, digits: 3))" }
            .joined(separator: ", ")
    }

    private static func spectrumSummary(_ levels: [Double]) -> String {
        guard !levels.isEmpty else { return "none" }
        return levels
            .enumerated()
            .sorted { $0.element > $1.element }
            .prefix(8)
            .map { index, level in "\(index)=\(format(level, digits: 3))" }
            .joined(separator: ", ")
    }

    private static func eqRiskTitle(_ risk: EQClippingRisk) -> String {
        switch risk {
        case .safe: return "safe"
        case .caution: return "caution"
        case .clipping: return "clipping"
        }
    }

    private static func outputRiskTitle(_ risk: OutputClippingRisk) -> String {
        switch risk {
        case .idle: return "idle"
        case .safe: return "safe"
        case .hot: return "hot"
        case .clipping: return "clipping"
        }
    }

    private static func format(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
