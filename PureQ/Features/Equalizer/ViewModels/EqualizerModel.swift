//
//  EqualizerModel.swift
//  PureQ
//

import AppKit
import Combine
import CoreAudio
import Foundation
import SwiftUI

final class EqualizerModel: ObservableObject {
    let telemetryStore = AudioTelemetryStore()

    private static let graphWidthScaleKey = "PureQ.GraphWidthScale"
    private static let graphHeightScaleKey = "PureQ.GraphHeightScale"
    private static let graphScaleRange = 0.75...1.65

    @Published var powerEnabled = true {
        didSet {
            updateAudioEngineRendering()
        }
    }
    @Published var mode: EqualizerMode = .expert
    @Published var selection: EqualizerSelection = .flat
    @Published var preamp: Double = 0
    @Published var balance: Double = 0
    @Published var autoGainEnabled = true
    @Published var highFrameRateUIEnabled = true {
        didSet {
            if audioEngineRunState == .running {
                startEngineTelemetryPolling()
                updateAudioEngineRendering(scheduleSave: false)
            }
        }
    }
    @Published var spectrumAnalyzerEnabled = false {
        didSet {
            if audioEngineRunState == .running {
                startEngineTelemetryPolling()
            }
            updateAudioEngineRendering(scheduleSave: false)
            if !spectrumAnalyzerEnabled && !soundIndicatorsEnabled {
                telemetryStore.reset()
            }
        }
    }
    @Published var soundIndicatorsEnabled = false {
        didSet {
            if audioEngineRunState == .running {
                startEngineTelemetryPolling()
                updateAudioEngineRendering(scheduleSave: false)
            }
            if !soundIndicatorsEnabled {
                telemetryStore.reset()
            }
        }
    }
    @Published var graphBandEditingEnabled = false
    @Published private(set) var graphWidthScale = EqualizerModel.persistedGraphScale(forKey: graphWidthScaleKey)
    @Published private(set) var graphHeightScale = EqualizerModel.persistedGraphScale(forKey: graphHeightScaleKey)
    @Published var autoStartEngineEnabled = true {
        didSet {
            if autoStartEngineEnabled {
                manualStopSuppressesAutoStart = false
                scheduleAutoStartIfNeeded()
            } else {
                autoStartWorkItem?.cancel()
                autoStartWorkItem = nil
            }
        }
    }
    @Published private(set) var bands = EqualizerBand.makeStandardBands()

    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published private(set) var defaultOutputUID: String?
    @Published private(set) var defaultSystemOutputUID: String?
    @Published private(set) var availableAudioSources: [AudioSourceItem] = [AudioSourceItem.systemMix] + AudioSourceItem.commonSources
    @Published var routingNodes: [RoutingNode] = []
    @Published var routingConnections: [RoutingConnection] = []
    @Published var selectedRoutingNodeID: RoutingNode.ID?
    @Published var activeEQNodeID: RoutingNode.ID?
    @Published var patchStartNodeID: RoutingNode.ID?
    @Published private(set) var eqFileMessage: String?
    @Published private(set) var audioEngineRunState: AudioEngineRunState = .stopped
    @Published private(set) var driverInstallInProgress = false
    @Published private(set) var driverInstallMessage: String?
    @Published private(set) var canUndoActiveScope = false
    private(set) var audioEngineTelemetry: AudioEngineTelemetry = .empty
    @Published private(set) var audioEngineSampleRate: Double = 48_000
    @Published private(set) var pureQSystemVolume: Float = 1
    @Published private(set) var pureQSystemMuted = false

    private let audioService = AudioOutputService()
    private let audioEngine = AudioEngineService()
    private let persistenceQueue = DispatchQueue(label: "PureQ.Persistence", qos: .utility)
    private var pollTimer: Timer?
    private var engineTelemetryTimer: Timer?
    private var autoStartWorkItem: DispatchWorkItem?
    private var persistenceWorkItem: DispatchWorkItem?
    private var lifecycleObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var persistenceSaveToken: UUID?
    private var lastQueuedSessionSnapshot: PureQSessionSnapshot?
    private var lastWrittenSessionSnapshot: PureQSessionSnapshot?
    private var isRestoringPersistentState = false
    private var isApplyingUndoSnapshot = false
    private var activeUndoScope: PureQUndoScope? = .equalizer
    private var equalizerUndoStack: [PureQSessionSnapshot] = []
    private var routingUndoStack: [PureQSessionSnapshot] = []
    private var equalizerContinuousUndoTokens = Set<String>()
    private var equalizerContinuousUndoResetWorkItems: [String: DispatchWorkItem] = [:]
    private var lastAutoStartFailureSignature: String?
    private var isStartingAudioEngine = false
    private var manualStopSuppressesAutoStart = false
    private var preVirtualDefaultOutputUID: String?
    private var normalizedHardwareOutputVolumeStates: [String: AudioOutputVolumeState] = [:]
    private var observedPureQVolumeDeviceID: AudioDeviceID?
    private var manualMode: EqualizerMode = .expert
    private var manualPreamp: Double = 0
    private var manualBalance: Double = 0
    private var manualBands = EqualizerBand.makeStandardBands()
    private var manualAutoGainEnabled = true
    private var visibleGraphicalSurfaceIDs = Set<UUID>()

    var visibleBands: [EqualizerBand] {
        sortedBands(bands)
    }

    func visibleEQBands(for node: RoutingNode) -> [EqualizerBand] {
        sortedBands(node.eqBands)
    }

    func eqBandLayoutTitle(for node: RoutingNode) -> String {
        bandLayout(for: node.eqMode, bands: node.eqBands).title
    }

    func bandActivityLevel(for frequency: Double) -> Double {
        guard soundIndicatorsEnabled else { return 0 }
        return telemetryStore.bandActivityLevel(for: frequency)
    }

    var eqRoutingNodes: [RoutingNode] {
        routingNodes.filter { $0.kind == .equalizer }
    }

    var activeEQNode: RoutingNode? {
        guard let activeEQNodeID else { return nil }
        return routingNodes.first { $0.id == activeEQNodeID && $0.kind == .equalizer }
    }

    var activeEQTitle: String {
        activeEQNode?.title ?? "Main Equalizer"
    }

    var activeEQMode: EqualizerMode {
        activeEQNode?.eqMode ?? mode
    }

    var activeEQBandLayoutTitle: String {
        activeEQBandLayout.title
    }

    var activeEQBandLayout: EqualizerBandLayout {
        if let activeEQNode {
            return bandLayout(for: activeEQNode.eqMode, bands: activeEQNode.eqBands)
        }
        return bandLayout(for: mode, bands: bands)
    }

    var activeEQSelection: EqualizerSelection {
        activeEQNode?.eqSelection ?? selection
    }

    var activeEQPreamp: Double {
        activeEQNode?.eqPreamp ?? preamp
    }

    var activeEQBalance: Double {
        activeEQNode?.eqBalance ?? balance
    }

    var activeEQVisibleBands: [EqualizerBand] {
        if let activeEQNode {
            return visibleEQBands(for: activeEQNode)
        }
        return visibleBands
    }

    var activeEQGraphBands: [EqualizerBand] {
        activeEQNode?.eqBands ?? bands
    }

    var activeEQUsesMainEqualizer: Bool {
        activeEQNode?.eqUsesMainEqualizer ?? false
    }

    var activeEQAutoGainEnabled: Bool {
        activeEQNode?.eqAutoGainEnabled ?? autoGainEnabled
    }

    var activeEQProfileSummary: String {
        guard let activeEQNode else {
            return "Main profile"
        }
        let activeCount = activeEQNode.eqBands.filter { $0.isEnabled && abs($0.gain) > 0.01 }.count
        let autoLabel = activeEQNode.eqAutoGainEnabled ? "Auto" : "Manual"
        let layoutLabel = bandLayout(for: activeEQNode.eqMode, bands: activeEQNode.eqBands).title
        return "\(layoutLabel) / \(activeCount) active / \(autoLabel)"
    }

    var hardwareOutputDevices: [AudioOutputDevice] {
        outputDevices.filter { !$0.isPureQVirtualOutput }
    }

    var pureQVirtualOutputDevice: AudioOutputDevice? {
        outputDevices.first(where: \.isPureQVirtualOutput)
    }

    var defaultOutputName: String {
        outputDevices.first(where: { $0.uid == defaultOutputUID })?.name ?? "Unknown output"
    }

    var routingRenderOutputSummary: String {
        let routedUIDs = routedHardwareOutputUIDs()
        let outputNames = hardwareOutputDevices
            .filter { routedUIDs.contains($0.uid) }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        if outputNames.isEmpty {
            return "Silent until an output node is connected"
        }
        return outputNames.joined(separator: ", ")
    }

    var menuBarSystemImage: String {
        return powerEnabled ? "slider.horizontal.3" : "power"
    }

    var readinessItems: [TestReadinessItem] {
        [
            sourceReadiness,
            engineReadiness,
            outputDeviceReadiness,
            routingGraphReadiness,
            routingLayoutReadiness,
            driverReadiness
        ]
    }

    var readinessSummary: TestReadinessState {
        if readinessItems.contains(where: { $0.state == .blocked }) {
            return .blocked
        }
        if readinessItems.contains(where: { $0.state == .caution }) {
            return .caution
        }
        return .ready
    }

    var audioEngineConfiguration: AudioEngineConfiguration {
        let virtualCapture = virtualCaptureDeviceForEngine
        return audioEngine.makeConfiguration(
            enabled: powerEnabled,
            bands: bands,
            preamp: preamp,
            balance: balance,
            sources: availableAudioSources,
            nodes: routingNodes,
            connections: routingConnections,
            outputUID: nil,
            outputName: "Unrouted",
            virtualCaptureUID: virtualCapture?.uid,
            virtualCaptureName: virtualCapture?.name,
            spectrumAnalyzerEnabled: spectrumAnalyzerEnabled && !visibleGraphicalSurfaceIDs.isEmpty,
            bandMetersEnabled: soundIndicatorsEnabled && !visibleGraphicalSurfaceIDs.isEmpty,
            visualAnalyzerFrameRate: visualAnalyzerFrameRate,
            systemVolume: pureQSystemVolume,
            systemMuted: pureQSystemMuted,
            processedTakeoverEnabled: true
        )
    }

    var audioEngineStatus: AudioEngineStatus {
        audioEngine.evaluate(audioEngineConfiguration)
    }

    var canStartAudioEngine: Bool {
        let configuration = audioEngineConfiguration
        return audioEngineStatus.state != .blocked &&
            resolvedOutputDeviceIDs(for: configuration).count == configuration.renderTargets.count
    }

    var audioEngineTakeoverActive: Bool {
        audioEngine.processTapsAvailable || pureQVirtualOutputDevice != nil
    }

    init() {
        refreshAudioSources()
        refreshAudioDevices(enforceLock: false)
        if !restorePersistedSessionIfAvailable() {
            seedRoutingGraphIfNeeded()
        }
        startDevicePolling()
        startLifecycleRefreshObservers()
        scheduleAutoStartIfNeeded()
    }

    deinit {
        restoreNormalizedHardwareOutputVolumes()
        pollTimer?.invalidate()
        engineTelemetryTimer?.invalidate()
        autoStartWorkItem?.cancel()
        persistenceWorkItem?.cancel()
        equalizerContinuousUndoResetWorkItems.values.forEach { $0.cancel() }
        if let observedPureQVolumeDeviceID {
            let audioService = audioService
            Task { @MainActor in
                audioService.stopObservingVolumeChanges(deviceID: observedPureQVolumeDeviceID)
            }
        }
        for (center, observer) in lifecycleObservers {
            center.removeObserver(observer)
        }
    }

    func setActiveUndoScope(_ scope: PureQUndoScope?) {
        activeUndoScope = scope
        updateUndoAvailability()
    }

    func setGraphWidthScale(_ scale: Double) {
        setGraphScale(scale, key: Self.graphWidthScaleKey) { graphWidthScale = $0 }
    }

    func setGraphHeightScale(_ scale: Double) {
        setGraphScale(scale, key: Self.graphHeightScaleKey) { graphHeightScale = $0 }
    }

    func resetGraphScale() {
        setGraphWidthScale(1)
        setGraphHeightScale(1)
    }

    private static func persistedGraphScale(forKey key: String) -> Double {
        let value = UserDefaults.standard.object(forKey: key) as? Double ?? 1
        return value.clamped(to: graphScaleRange)
    }

    private func setGraphScale(_ scale: Double, key: String, assign: (Double) -> Void) {
        let clampedScale = scale.clamped(to: Self.graphScaleRange)
        let currentScale = UserDefaults.standard.object(forKey: key) as? Double ?? 1
        guard abs(currentScale - clampedScale) > 0.000_1 else { return }
        assign(clampedScale)
        UserDefaults.standard.set(clampedScale, forKey: key)
    }

    func undoActiveScope() {
        guard let activeUndoScope else { return }
        undo(scope: activeUndoScope)
    }

    func undo(scope: PureQUndoScope) {
        guard let snapshot = popUndoSnapshot(for: scope) else {
            updateUndoAvailability()
            return
        }

        isApplyingUndoSnapshot = true
        defer {
            isApplyingUndoSnapshot = false
            updateUndoAvailability()
        }

        do {
            equalizerContinuousUndoTokens.removeAll()
            equalizerContinuousUndoResetWorkItems.values.forEach { $0.cancel() }
            equalizerContinuousUndoResetWorkItems.removeAll()
            try applyPersistedSession(snapshot)
            lastQueuedSessionSnapshot = makeSessionSnapshot()
            lastWrittenSessionSnapshot = nil
            switch scope {
            case .equalizer:
                syncLinkedEQNodes()
                syncRoutingOutputNodes()
                updateAudioEngineRendering()
            case .routing:
                restartAudioEngineIfNeeded()
                schedulePersistedStateSave()
            }
        } catch {
            eqFileMessage = "Could not undo: \(error.localizedDescription)"
        }
    }

    func setGraphicalSurface(id: UUID, visible: Bool) {
        let changed: Bool
        if visible {
            changed = visibleGraphicalSurfaceIDs.insert(id).inserted
        } else {
            changed = visibleGraphicalSurfaceIDs.remove(id) != nil
        }

        guard changed, audioEngineRunState == .running else { return }
        startEngineTelemetryPolling()
        audioEngine.updateRendering(configuration: audioEngineConfiguration)
        if visible {
            refreshAudioEngineTelemetry()
        } else if visibleGraphicalSurfaceIDs.isEmpty {
            telemetryStore.reset()
        }
    }

    func exportActiveEQProfile(to url: URL) throws {
        let file = EQProfileFile(profile: activeEQProfileSnapshot())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: url, options: .atomic)
        eqFileMessage = "Exported \(file.profile.title)."
    }

    func importEQProfile(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if url.pathExtension.lowercased() == "eqpreset" {
            do {
                try importEqualiserPreset(data: data, decoder: decoder)
                return
            } catch let externalError {
                do {
                    try importPureQProfile(data: data, decoder: decoder)
                    return
                } catch {
                    throw externalError
                }
            }
        }

        do {
            try importPureQProfile(data: data, decoder: decoder)
        } catch let pureQError {
            do {
                try importEqualiserPreset(data: data, decoder: decoder)
            } catch {
                throw pureQError
            }
        }
    }

    private func importPureQProfile(data: Data, decoder: JSONDecoder) throws {
        let file = try decoder.decode(EQProfileFile.self, from: data)
        guard file.schemaVersion <= EQProfileFile.currentSchemaVersion else {
            throw EQProfileFileError.unsupportedVersion(file.schemaVersion)
        }
        let profile = try sanitizedProfile(file.profile)
        applyProfileToActiveEQ(profile)
        eqFileMessage = "Imported \(profile.title)."
    }

    private func importEqualiserPreset(data: Data, decoder: JSONDecoder) throws {
        let result = try EqualiserPresetImporter.importProfile(from: data, decoder: decoder)
        let profile = try sanitizedProfile(result.profile)
        applyProfileToActiveEQ(profile)
        eqFileMessage = result.statusMessage
    }

    func flushPersistedState() {
        persistenceWorkItem?.cancel()
        persistenceWorkItem = nil
        persistenceSaveToken = nil

        let snapshot = makeSessionSnapshot()
        guard snapshot != lastWrittenSessionSnapshot else { return }
        persistenceQueue.sync {
            try? PureQPersistenceStore.writeSessionSnapshot(snapshot)
        }
        lastQueuedSessionSnapshot = snapshot
        lastWrittenSessionSnapshot = snapshot
    }

    private func restorePersistedSessionIfAvailable() -> Bool {
        let url = PureQPersistenceStore.sessionSnapshotURL
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(PureQSessionSnapshot.self, from: data)
            guard snapshot.schemaVersion <= PureQSessionSnapshot.currentSchemaVersion else {
                throw EQProfileFileError.unsupportedVersion(snapshot.schemaVersion)
            }

            try applyPersistedSession(snapshot)
            lastQueuedSessionSnapshot = makeSessionSnapshot()
            lastWrittenSessionSnapshot = lastQueuedSessionSnapshot
            return true
        } catch {
            eqFileMessage = "Could not restore last EQ session: \(error.localizedDescription)"
            return false
        }
    }

    private func applyPersistedSession(_ snapshot: PureQSessionSnapshot) throws {
        isRestoringPersistentState = true
        defer { isRestoringPersistentState = false }

        applyMainProfile(try sanitizedProfile(snapshot.mainProfile))

        routingNodes = snapshot.routingNodes.map { node in
            var sanitizedNode = node
            sanitizedNode.eqBands = normalizedBands(sanitizedBands(node.eqBands), for: node.eqMode)
            sanitizedNode.eqManualBands = normalizedBands(
                sanitizedBands(node.eqManualBands.isEmpty ? node.eqBands : node.eqManualBands),
                for: node.eqManualMode
            )
            sanitizedNode.eqPreamp = node.eqPreamp.clamped(to: -20...20)
            sanitizedNode.eqBalance = node.eqBalance.clamped(to: -1...1)
            sanitizedNode.eqManualPreamp = node.eqManualPreamp.clamped(to: -20...20)
            sanitizedNode.eqManualBalance = node.eqManualBalance.clamped(to: -1...1)
            return sanitizedNode
        }

        if routingNodes.isEmpty {
            seedRoutingGraphIfNeeded()
        }

        let validNodeIDs = Set(routingNodes.map(\.id))
        routingConnections = snapshot.routingConnections.filter { connection in
            validNodeIDs.contains(connection.from) && validNodeIDs.contains(connection.to)
        }
        integrateLegacyPureQBusNodes()

        if let activeID = snapshot.activeEQNodeID,
           routingNodes.contains(where: { $0.id == activeID && $0.kind == .equalizer }) {
            activeEQNodeID = activeID
        } else {
            activeEQNodeID = routingNodes.first(where: { $0.kind == .equalizer })?.id
        }
        selectedRoutingNodeID = activeEQNodeID
        patchStartNodeID = nil

        syncRoutingSourceNodes()
        syncRoutingOutputNodes()
        pruneInvalidRoutingConnections()
    }

    private func schedulePersistedStateSave(after delay: TimeInterval = 0.7) {
        guard !isRestoringPersistentState else { return }

        persistenceWorkItem?.cancel()
        let token = UUID()
        persistenceSaveToken = token

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.persistenceSaveToken == token,
                      !self.isRestoringPersistentState else {
                    return
                }

                self.persistenceWorkItem = nil
                let snapshot = self.makeSessionSnapshot()
                guard snapshot != self.lastQueuedSessionSnapshot else { return }
                self.lastQueuedSessionSnapshot = snapshot

                guard snapshot != self.lastWrittenSessionSnapshot else { return }
                self.persistenceQueue.async { [snapshot] in
                    do {
                        try PureQPersistenceStore.writeSessionSnapshot(snapshot)
                        Task { @MainActor [weak self] in
                            self?.lastWrittenSessionSnapshot = snapshot
                        }
                    } catch {
                        Task { @MainActor [weak self] in
                            self?.lastQueuedSessionSnapshot = self?.lastWrittenSessionSnapshot
                        }
                    }
                }
            }
        }
        persistenceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func makeSessionSnapshot() -> PureQSessionSnapshot {
        PureQSessionSnapshot(
            mainProfile: mainProfileSnapshot(),
            routingNodes: routingNodes,
            routingConnections: routingConnections,
            activeEQNodeID: activeEQNodeID
        )
    }

    private func rememberUndo(_ scope: PureQUndoScope) {
        guard !isRestoringPersistentState, !isApplyingUndoSnapshot else { return }
        let snapshot = makeSessionSnapshot()
        switch scope {
        case .equalizer:
            guard equalizerUndoStack.last != snapshot else { return }
            equalizerUndoStack.append(snapshot)
            if equalizerUndoStack.count > 80 {
                equalizerUndoStack.removeFirst(equalizerUndoStack.count - 80)
            }
        case .routing:
            guard routingUndoStack.last != snapshot else { return }
            routingUndoStack.append(snapshot)
            if routingUndoStack.count > 80 {
                routingUndoStack.removeFirst(routingUndoStack.count - 80)
            }
        }
        updateUndoAvailability()
    }

    private func rememberEqualizerUndo(persist: Bool = true, continuousToken: String? = nil) {
        guard persist else {
            guard let continuousToken else { return }
            if equalizerContinuousUndoTokens.insert(continuousToken).inserted {
                rememberUndo(.equalizer)
            }
            scheduleEqualizerContinuousUndoReset(for: continuousToken)
            return
        }

        if let continuousToken,
           equalizerContinuousUndoTokens.remove(continuousToken) != nil {
            equalizerContinuousUndoResetWorkItems[continuousToken]?.cancel()
            equalizerContinuousUndoResetWorkItems[continuousToken] = nil
            return
        }
        rememberUndo(.equalizer)
    }

    private func scheduleEqualizerContinuousUndoReset(for token: String) {
        equalizerContinuousUndoResetWorkItems[token]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.equalizerContinuousUndoTokens.remove(token)
                self?.equalizerContinuousUndoResetWorkItems[token] = nil
            }
        }
        equalizerContinuousUndoResetWorkItems[token] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
    }

    private func popUndoSnapshot(for scope: PureQUndoScope) -> PureQSessionSnapshot? {
        switch scope {
        case .equalizer:
            return equalizerUndoStack.popLast()
        case .routing:
            return routingUndoStack.popLast()
        }
    }

    private func updateUndoAvailability() {
        guard let activeUndoScope else {
            canUndoActiveScope = false
            return
        }
        switch activeUndoScope {
        case .equalizer:
            canUndoActiveScope = !equalizerUndoStack.isEmpty
        case .routing:
            canUndoActiveScope = !routingUndoStack.isEmpty
        }
    }

    private func activeEQProfileSnapshot() -> EQProfileSnapshot {
        if let activeEQNode {
            return profileSnapshot(from: activeEQNode)
        }
        return mainProfileSnapshot()
    }

    private func mainProfileSnapshot() -> EQProfileSnapshot {
        EQProfileSnapshot(
            title: "Main Equalizer",
            mode: mode,
            selection: selection,
            preamp: preamp,
            balance: balance,
            autoGainEnabled: autoGainEnabled,
            bands: bands,
            manualMode: manualMode,
            manualPreamp: manualPreamp,
            manualBalance: manualBalance,
            manualBands: manualBands,
            manualAutoGainEnabled: manualAutoGainEnabled
        )
    }

    private func profileSnapshot(from node: RoutingNode) -> EQProfileSnapshot {
        EQProfileSnapshot(
            title: node.title,
            mode: node.eqMode,
            selection: node.eqSelection,
            preamp: node.eqPreamp,
            balance: node.eqBalance,
            autoGainEnabled: node.eqAutoGainEnabled,
            bands: node.eqBands,
            manualMode: node.eqManualMode,
            manualPreamp: node.eqManualPreamp,
            manualBalance: node.eqManualBalance,
            manualBands: node.eqManualBands,
            manualAutoGainEnabled: node.eqManualAutoGainEnabled
        )
    }

    private func applyProfileToActiveEQ(_ profile: EQProfileSnapshot) {
        rememberUndo(.equalizer)
        if let nodeID = activeEQNode?.id {
            updateEQNode(id: nodeID) { node in
                node.eqUsesMainEqualizer = false
                applyProfile(profile, to: &node)
            }
        } else {
            applyMainProfile(profile)
            syncLinkedEQNodes()
            syncRoutingOutputNodes()
            updateAudioEngineRendering()
        }
    }

    private func applyMainProfile(_ profile: EQProfileSnapshot) {
        mode = profile.mode
        selection = profile.selection
        preamp = profile.preamp
        balance = profile.balance
        autoGainEnabled = profile.autoGainEnabled
        bands = profile.bands
        manualMode = profile.manualMode
        manualPreamp = profile.manualPreamp
        manualBalance = profile.manualBalance
        manualBands = profile.manualBands
        manualAutoGainEnabled = profile.manualAutoGainEnabled
    }

    private func applyProfile(_ profile: EQProfileSnapshot, to node: inout RoutingNode) {
        node.eqMode = profile.mode
        node.eqSelection = profile.selection
        node.eqPreamp = profile.preamp
        node.eqBalance = profile.balance
        node.eqAutoGainEnabled = profile.autoGainEnabled
        node.eqBands = profile.bands
        node.eqManualMode = profile.manualMode
        node.eqManualPreamp = profile.manualPreamp
        node.eqManualBalance = profile.manualBalance
        node.eqManualBands = profile.manualBands
        node.eqManualAutoGainEnabled = profile.manualAutoGainEnabled
    }

    private func sanitizedProfile(_ profile: EQProfileSnapshot) throws -> EQProfileSnapshot {
        guard !profile.bands.isEmpty else {
            throw EQProfileFileError.emptyProfile
        }

        let cleanedBands = normalizedBands(sanitizedBands(profile.bands), for: profile.mode)
        let cleanedManualBands = normalizedBands(
            sanitizedBands(profile.manualBands.isEmpty ? profile.bands : profile.manualBands),
            for: profile.manualMode
        )
        return EQProfileSnapshot(
            title: profile.title.isEmpty ? "Imported EQ" : profile.title,
            mode: profile.mode,
            selection: profile.selection,
            preamp: profile.preamp.clamped(to: -20...20),
            balance: profile.balance.clamped(to: -1...1),
            autoGainEnabled: profile.autoGainEnabled,
            bands: cleanedBands,
            manualMode: profile.manualMode,
            manualPreamp: profile.manualPreamp.clamped(to: -20...20),
            manualBalance: profile.manualBalance.clamped(to: -1...1),
            manualBands: cleanedManualBands,
            manualAutoGainEnabled: profile.manualAutoGainEnabled
        )
    }

    private func sanitizedBands(_ sourceBands: [EqualizerBand]) -> [EqualizerBand] {
        sortedBands(sourceBands.map { band in
            var sanitizedBand = band
            sanitizedBand.frequency = sanitizedBand.frequency.clamped(to: 20...20_000)
            sanitizedBand.gain = sanitizedBand.gain.clamped(to: -20...20)
            sanitizedBand.q = sanitizedBand.q.clamped(to: 0.1...10)
            return sanitizedBand
        })
    }

    private func normalizedBands(_ sourceBands: [EqualizerBand], for mode: EqualizerMode) -> [EqualizerBand] {
        guard !hasCustomBandConfiguration(sourceBands) else {
            return sortedBands(sourceBands)
        }

        switch mode {
        case .basic where !matchesLayout(sourceBands, frequencies: EqualizerMode.basic.frequencies):
            return retargetedBands(for: EqualizerMode.basic.frequencies, from: sourceBands)
        case .expert where !matchesLayout(sourceBands, frequencies: EqualizerMode.expert.frequencies):
            return retargetedBands(for: EqualizerMode.expert.frequencies, from: sourceBands)
        default:
            return sortedBands(sourceBands)
        }
    }

    func setMode(_ newMode: EqualizerMode) {
        rememberUndo(.equalizer)
        bands = retargetedBands(for: newMode.frequencies, from: bands)
        mode = newMode
        applyAutoGainIfNeeded()
        saveMainManualProfileIfNeeded()
        syncLinkedEQNodes()
        syncRoutingOutputNodes()
        updateAudioEngineRendering()
    }

    func setBandLayout(_ layout: EqualizerBandLayout) {
        rememberUndo(.equalizer)
        let currentLayout = bandLayout(for: mode, bands: bands)
        switch layout {
        case .bands10:
            bands = retargetedBands(for: EqualizerMode.basic.frequencies, from: bands)
            mode = .basic
        case .bands31:
            bands = retargetedBands(for: EqualizerMode.expert.frequencies, from: bands)
            mode = .expert
        case .custom:
            if currentLayout != .custom {
                bands.append(EqualizerBand(
                    frequency: suggestedCustomBandFrequency(in: bands),
                    gain: 0,
                    q: 0.5,
                    isCustom: true
                ))
                sortBands(&bands)
                mode = .advanced
            }
        }

        applyAutoGainIfNeeded()
        saveMainManualProfileIfNeeded()
        syncLinkedEQNodes()
        syncRoutingOutputNodes()
        updateAudioEngineRendering()
    }

    func applySelection(_ newSelection: EqualizerSelection) {
        rememberUndo(.equalizer)
        if newSelection == .manual {
            restoreMainManualProfile()
            syncLinkedEQNodes()
            syncRoutingOutputNodes()
            updateAudioEngineRendering()
            return
        }

        selection = newSelection

        switch newSelection {
        case .manual:
            break
        case .bands31, .bands10, .basic:
            break
        case .flat:
            setAllGains(to: 0)
        case .bassLift:
            applyPreset { frequency in
                if frequency <= 80 { return 5.0 }
                if frequency <= 160 { return 3.2 }
                if frequency >= 8_000 { return 1.2 }
                return frequency >= 400 && frequency <= 1_250 ? -1.0 : 0
            }
        case .vocalFocus:
            applyPreset { frequency in
                if (800...3_150).contains(frequency) { return 3.0 }
                if frequency <= 100 { return -2.2 }
                if frequency >= 10_000 { return 1.0 }
                return 0
            }
        case .crispAir:
            applyPreset { frequency in
                if frequency >= 6_300 { return 4.0 }
                if (2_000...5_000).contains(frequency) { return 1.6 }
                if frequency <= 80 { return -1.0 }
                return 0
            }
        case .lateNight:
            applyPreset { frequency in
                if frequency <= 80 { return -5.0 }
                if frequency >= 8_000 { return -3.0 }
                if (400...2_500).contains(frequency) { return 1.4 }
                return -1.0
            }
        }
        applyAutoGainIfNeeded()
        syncLinkedEQNodes()
        syncRoutingOutputNodes()
        updateAudioEngineRendering()
    }

    func setPreamp(_ value: Double) {
        rememberEqualizerUndo(persist: false, continuousToken: "main-preamp")
        preamp = value.clamped(to: -20...20)
        selection = .manual
        saveMainManualProfile()
        syncLinkedEQNodes()
        updateAudioEngineRendering()
    }

    func setBalance(_ value: Double) {
        rememberEqualizerUndo(persist: false, continuousToken: "main-balance")
        balance = value.clamped(to: -1...1)
        selection = .manual
        saveMainManualProfile()
        syncLinkedEQNodes()
        updateAudioEngineRendering()
    }

    func setAutoGain(_ enabled: Bool) {
        rememberUndo(.equalizer)
        autoGainEnabled = enabled
        applyAutoGainIfNeeded()
        selection = .manual
        saveMainManualProfile()
        syncLinkedEQNodes()
        updateAudioEngineRendering()
    }

    func setBandGain(id: EqualizerBand.ID, gain: Double, persist: Bool = true) {
        rememberEqualizerUndo(persist: persist, continuousToken: "band-gain-\(id.uuidString)")
        updateBand(id: id) { band in
            band.gain = gain.clamped(to: -20...20)
        }
        selection = .manual
        if persist {
            applyAutoGainIfNeeded()
            saveMainManualProfile()
        }
        syncLinkedEQNodes()
        updateAudioEngineRendering(scheduleSave: persist)
    }

    func setBandFrequency(id: EqualizerBand.ID, frequency: Double) {
        rememberUndo(.equalizer)
        updateBand(id: id) { band in
            band.frequency = frequency.clamped(to: 20...20_000)
        }
        sortBands(&bands)
        selection = .manual
        saveMainManualProfile()
        syncLinkedEQNodes()
        updateAudioEngineRendering()
    }

    func setBandGraphPosition(id: EqualizerBand.ID, frequency: Double, gain: Double, persist: Bool = true) {
        rememberEqualizerUndo(persist: persist, continuousToken: "band-graph-\(id.uuidString)")
        updateBand(id: id) { band in
            guard band.isEnabled else { return }
            band.frequency = frequency.clamped(to: 20...20_000)
            band.gain = gain.clamped(to: -20...20)
        }
        if persist {
            sortBands(&bands)
        }
        selection = .manual
        if persist {
            applyAutoGainIfNeeded()
            saveMainManualProfile()
        }
        syncLinkedEQNodes()
        updateAudioEngineRendering(scheduleSave: persist)
    }

    func setBandQ(id: EqualizerBand.ID, q: Double, persist: Bool = true) {
        rememberEqualizerUndo(persist: persist, continuousToken: "band-q-\(id.uuidString)")
        updateBand(id: id) { band in
            band.q = q.clamped(to: 0.1...10)
        }
        selection = .manual
        if persist {
            saveMainManualProfile()
        }
        syncLinkedEQNodes()
        updateAudioEngineRendering(scheduleSave: persist)
    }

    func addBand() {
        rememberUndo(.equalizer)
        let frequency = suggestedCustomBandFrequency(in: bands)
        bands.append(EqualizerBand(frequency: frequency, gain: 0, q: 0.5, isCustom: true))
        sortBands(&bands)
        selection = .manual
        saveMainManualProfile()
        syncLinkedEQNodes()
        updateAudioEngineRendering()
    }

    func toggleBand(id: EqualizerBand.ID) {
        rememberUndo(.equalizer)
        updateBand(id: id) { band in
            band.isEnabled.toggle()
        }
        selection = .manual
        applyAutoGainIfNeeded()
        saveMainManualProfile()
        syncLinkedEQNodes()
        updateAudioEngineRendering()
    }

    func toggleStereoLink(id: EqualizerBand.ID) {
        rememberUndo(.equalizer)
        updateBand(id: id) { band in
            band.isStereoLinked.toggle()
        }
        selection = .manual
        saveMainManualProfile()
        syncLinkedEQNodes()
        updateAudioEngineRendering()
    }

    func cycleShape(id: EqualizerBand.ID) {
        rememberUndo(.equalizer)
        updateBand(id: id) { band in
            switch band.shape {
            case .bell:
                band.shape = .shelf
            case .shelf:
                band.shape = .notch
            case .notch:
                band.shape = .bell
            }
        }
        selection = .manual
        saveMainManualProfile()
        syncLinkedEQNodes()
        updateAudioEngineRendering()
    }

    func setActiveEQNode(id: RoutingNode.ID?) {
        guard let id else {
            activeEQNodeID = nil
            schedulePersistedStateSave()
            return
        }
        guard routingNodes.contains(where: { $0.id == id && $0.kind == .equalizer }) else {
            activeEQNodeID = nil
            schedulePersistedStateSave()
            return
        }
        activeEQNodeID = id
        schedulePersistedStateSave()
    }

    func setActiveEQMode(_ newMode: EqualizerMode) {
        if let nodeID = activeEQNode?.id {
            setEQNodeMode(id: nodeID, mode: newMode)
        } else {
            setMode(newMode)
        }
    }

    func setActiveEQBandLayout(_ layout: EqualizerBandLayout) {
        if let nodeID = activeEQNode?.id {
            setEQNodeBandLayout(id: nodeID, layout: layout)
        } else {
            setBandLayout(layout)
        }
    }

    func applyActiveEQSelection(_ newSelection: EqualizerSelection) {
        if let nodeID = activeEQNode?.id {
            applyEQNodeSelection(id: nodeID, selection: newSelection)
        } else {
            applySelection(newSelection)
        }
    }

    func setActiveEQPreamp(_ value: Double) {
        if let nodeID = activeEQNode?.id {
            setEQNodePreamp(id: nodeID, preamp: value)
        } else {
            setPreamp(value)
        }
    }

    func setActiveEQBalance(_ value: Double) {
        if let nodeID = activeEQNode?.id {
            setEQNodeBalance(id: nodeID, balance: value)
        } else {
            setBalance(value)
        }
    }

    func setActiveEQAutoGain(_ enabled: Bool) {
        if let nodeID = activeEQNode?.id {
            setEQNodeAutoGain(id: nodeID, enabled: enabled)
        } else {
            setAutoGain(enabled)
        }
    }

    func setActiveEQUsesMainEqualizer(_ enabled: Bool) {
        guard let nodeID = activeEQNode?.id else { return }
        setEQNodeUsesMainEqualizer(id: nodeID, enabled: enabled)
    }

    func copyMainEqualizerToActiveNode() {
        guard let nodeID = activeEQNode?.id,
              let index = routingNodes.firstIndex(where: { $0.id == nodeID && $0.kind == .equalizer }) else {
            return
        }

        rememberUndo(.equalizer)
        routingNodes[index].eqUsesMainEqualizer = false
        routingNodes[index].eqMode = mode
        routingNodes[index].eqSelection = selection
        routingNodes[index].eqPreamp = preamp
        routingNodes[index].eqBalance = balance
        routingNodes[index].eqBands = bands
        routingNodes[index].eqAutoGainEnabled = autoGainEnabled
        routingNodes[index].eqManualMode = manualMode
        routingNodes[index].eqManualPreamp = manualPreamp
        routingNodes[index].eqManualBalance = manualBalance
        routingNodes[index].eqManualBands = manualBands
        routingNodes[index].eqManualAutoGainEnabled = manualAutoGainEnabled
        syncRoutingOutputNodes()
        updateAudioEngineRendering()
    }

    func setActiveEQBandGain(id: EqualizerBand.ID, gain: Double, persist: Bool = true) {
        if let nodeID = activeEQNode?.id {
            setEQNodeBandGain(nodeID: nodeID, bandID: id, gain: gain, persist: persist)
        } else {
            setBandGain(id: id, gain: gain, persist: persist)
        }
    }

    func setActiveEQBandFrequency(id: EqualizerBand.ID, frequency: Double) {
        if let nodeID = activeEQNode?.id {
            setEQNodeBandFrequency(nodeID: nodeID, bandID: id, frequency: frequency)
        } else {
            setBandFrequency(id: id, frequency: frequency)
        }
    }

    func setActiveEQBandGraphPosition(id: EqualizerBand.ID, frequency: Double, gain: Double, persist: Bool = true) {
        if let nodeID = activeEQNode?.id {
            setEQNodeBandGraphPosition(nodeID: nodeID, bandID: id, frequency: frequency, gain: gain, persist: persist)
        } else {
            setBandGraphPosition(id: id, frequency: frequency, gain: gain, persist: persist)
        }
    }

    func setActiveEQBandQ(id: EqualizerBand.ID, q: Double, persist: Bool = true) {
        if let nodeID = activeEQNode?.id {
            setEQNodeBandQ(nodeID: nodeID, bandID: id, q: q, persist: persist)
        } else {
            setBandQ(id: id, q: q, persist: persist)
        }
    }

    func addActiveEQBand() {
        if let nodeID = activeEQNode?.id {
            addEQNodeBand(nodeID: nodeID)
        } else {
            addBand()
        }
    }

    func toggleActiveEQBand(id: EqualizerBand.ID) {
        if let nodeID = activeEQNode?.id {
            toggleEQNodeBand(nodeID: nodeID, bandID: id)
        } else {
            toggleBand(id: id)
        }
    }

    func toggleActiveEQStereoLink(id: EqualizerBand.ID) {
        if let nodeID = activeEQNode?.id {
            toggleEQNodeStereoLink(nodeID: nodeID, bandID: id)
        } else {
            toggleStereoLink(id: id)
        }
    }

    func cycleActiveEQShape(id: EqualizerBand.ID) {
        if let nodeID = activeEQNode?.id {
            cycleEQNodeBandShape(nodeID: nodeID, bandID: id)
        } else {
            cycleShape(id: id)
        }
    }

    func refreshAudioSources() {
        let runningApplications = NSWorkspace.shared.runningApplications
            .filter { application in
                application.activationPolicy == .regular &&
                application.bundleIdentifier != Bundle.main.bundleIdentifier &&
                application.bundleIdentifier != nil
            }
            .compactMap { application -> AudioSourceItem? in
                guard let bundleIdentifier = application.bundleIdentifier else { return nil }
                return AudioSourceItem(
                    id: bundleIdentifier,
                    title: application.localizedName ?? bundleIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: application.processIdentifier,
                    kind: sourceKind(for: bundleIdentifier),
                    systemImage: sourceSystemImage(for: bundleIdentifier),
                    isRunning: true
                )
            }

        var merged: [String: AudioSourceItem] = [:]
        merged[AudioSourceItem.systemMix.id] = AudioSourceItem.systemMix

        for source in AudioSourceItem.commonSources {
            merged[source.id] = source
        }

        for runningSource in runningApplications {
            if var existing = merged[runningSource.id] {
                existing.isRunning = true
                existing.processIdentifier = runningSource.processIdentifier
                merged[runningSource.id] = existing
            } else {
                merged[runningSource.id] = runningSource
            }
        }

        let stableSources = [AudioSourceItem.systemMix] + AudioSourceItem.commonSources.compactMap { merged.removeValue(forKey: $0.id) }
        let runningOnlySources = merged.values
            .filter { $0.id != AudioSourceItem.systemMix.id }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let nextSources = stableSources + runningOnlySources
        guard availableAudioSources != nextSources else { return }
        availableAudioSources = nextSources
        syncRoutingSourceNodes()
    }

    func refreshAudioDevices(enforceLock: Bool = true) {
        let previousTakeoverActive = audioEngineTakeoverActive
        let snapshot = audioService.snapshot()
        if outputDevices != snapshot.devices {
            outputDevices = snapshot.devices
        }
        if defaultOutputUID != snapshot.defaultOutputUID {
            defaultOutputUID = snapshot.defaultOutputUID
        }
        if defaultSystemOutputUID != snapshot.defaultSystemOutputUID {
            defaultSystemOutputUID = snapshot.defaultSystemOutputUID
        }

        syncRoutingOutputNodes()
        updatePureQVolumeBridge()
        if previousTakeoverActive != audioEngineTakeoverActive {
            restartAudioEngineIfNeeded()
        } else {
            scheduleAutoStartIfNeeded()
        }
    }

    private func updatePureQVolumeBridge() {
        guard let virtualOutput = pureQVirtualOutputDevice else {
            if let observedPureQVolumeDeviceID {
                audioService.stopObservingVolumeChanges(deviceID: observedPureQVolumeDeviceID)
                self.observedPureQVolumeDeviceID = nil
            }
            pureQSystemVolume = 1
            pureQSystemMuted = false
            return
        }

        refreshPureQSystemVolume(from: virtualOutput)
        if observedPureQVolumeDeviceID != virtualOutput.audioObjectID {
            if let observedPureQVolumeDeviceID {
                audioService.stopObservingVolumeChanges(deviceID: observedPureQVolumeDeviceID)
            }
            observedPureQVolumeDeviceID = virtualOutput.audioObjectID
            audioService.observeVolumeChanges(deviceID: virtualOutput.audioObjectID) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.refreshPureQSystemVolumeAndApply()
                }
            }
        }
    }

    private func refreshPureQSystemVolumeAndApply() {
        guard let virtualOutput = pureQVirtualOutputDevice else { return }
        let changed = refreshPureQSystemVolume(from: virtualOutput)
        if changed {
            updateAudioEngineRendering(scheduleSave: false)
        }
    }

    @discardableResult
    private func refreshPureQSystemVolume(from virtualOutput: AudioOutputDevice) -> Bool {
        let nextVolume = audioService.outputGain(uid: virtualOutput.uid) ?? 1
        let nextMuted = audioService.muted(uid: virtualOutput.uid)
        let changed = abs(pureQSystemVolume - nextVolume) > 0.001 || pureQSystemMuted != nextMuted
        pureQSystemVolume = nextVolume
        pureQSystemMuted = nextMuted
        return changed
    }

    func installBundledAudioDriver() {
        guard !driverInstallInProgress else { return }
        guard let driverURL = Bundle.main.url(forResource: "PureQ", withExtension: "driver") else {
            driverInstallMessage = "PureQ.driver is not bundled in this app build."
            return
        }

        driverInstallInProgress = true
        driverInstallMessage = audioEngineStatus.driverInstalled ? "Repairing PureQ audio driver..." : "Installing PureQ audio driver..."
        let sourcePath = driverURL.path
        let shouldResumeEngine = audioEngineRunState == .running
        if shouldResumeEngine {
            stopAudioEngine(manual: false)
        }

        DispatchQueue.global(qos: .userInitiated).async { [sourcePath, shouldResumeEngine] in
            let result = Result {
                try Self.runPrivilegedShellCommand(Self.driverInstallCommand(sourcePath: sourcePath))
            }
            DispatchQueue.main.async { [weak self] in
                self?.finishDriverInstall(result: result, shouldResumeEngine: shouldResumeEngine)
            }
        }
    }

    func uninstallAudioDriver() {
        guard !driverInstallInProgress else { return }
        driverInstallInProgress = true
        driverInstallMessage = "Removing PureQ audio driver..."
        let shouldResumeEngine = audioEngineRunState == .running
        if shouldResumeEngine {
            stopAudioEngine(manual: false)
        }

        DispatchQueue.global(qos: .userInitiated).async { [shouldResumeEngine] in
            let result = Result {
                try Self.runPrivilegedShellCommand(Self.driverUninstallCommand())
            }
            DispatchQueue.main.async { [weak self] in
                self?.finishDriverUninstall(result: result, shouldResumeEngine: shouldResumeEngine)
            }
        }
    }

    func startAudioEngine(manual: Bool = true) {
        guard !isStartingAudioEngine else { return }
        isStartingAudioEngine = true
        defer { isStartingAudioEngine = false }
        autoStartWorkItem?.cancel()
        autoStartWorkItem = nil
        if manual {
            manualStopSuppressesAutoStart = false
            lastAutoStartFailureSignature = nil
        }

        refreshAudioSources()
        refreshAudioDevices(enforceLock: false)
        selectDefaultEQNodeIfNeeded()

        let configuration = audioEngineConfiguration
        let virtualCapture = virtualCaptureDeviceForEngine
        let shouldDeferVirtualSwitch = virtualCapture != nil && configuration.prefersDriverCapture
        var switchedDefaultToVirtual = false
        var didStartRendering = false
        let outputDeviceIDs = resolvedOutputDeviceIDs(for: configuration)
        do {
            if virtualCapture != nil && !shouldDeferVirtualSwitch {
                switchedDefaultToVirtual = try ensureSystemDefaultForVirtualCapture()
            }
            try audioEngine.startRendering(
                configuration: configuration,
                outputDeviceIDsByUID: outputDeviceIDs,
                captureDeviceID: virtualCapture?.audioObjectID
            )
            didStartRendering = true
            if shouldDeferVirtualSwitch {
                switchedDefaultToVirtual = try ensureSystemDefaultForVirtualCapture()
            }
            normalizeRoutedHardwareOutputVolumes(for: configuration)
            lastAutoStartFailureSignature = nil
            setAudioEngineRunState(audioEngine.runState)
            refreshAudioEngineTelemetry()
            startEngineTelemetryPolling()
        } catch {
            if didStartRendering {
                audioEngine.stopRendering()
            }
            if switchedDefaultToVirtual {
                restoreSystemDefaultAfterVirtualCapture()
            }
            setAudioEngineRunState(.failed(error.localizedDescription))
            if !manual {
                lastAutoStartFailureSignature = autoStartSignature
            }
            stopEngineTelemetryPolling()
            refreshAudioEngineTelemetry()
        }
    }

    func stopAudioEngine(manual: Bool = true) {
        if manual {
            manualStopSuppressesAutoStart = true
            autoStartWorkItem?.cancel()
            autoStartWorkItem = nil
        }
        audioEngine.stopRendering()
        restoreNormalizedHardwareOutputVolumes()
        setAudioEngineRunState(audioEngine.runState)
        stopEngineTelemetryPolling()
        refreshAudioEngineTelemetry()
        if manual {
            restoreSystemDefaultAfterVirtualCapture()
        }
    }

    private func updateAudioEngineRendering(scheduleSave: Bool = true) {
        if scheduleSave {
            schedulePersistedStateSave()
        }

        guard audioEngineRunState == .running else {
            scheduleAutoStartIfNeeded()
            return
        }
        let configuration = audioEngineConfiguration
        audioEngine.updateRendering(configuration: configuration)
        normalizeRoutedHardwareOutputVolumes(for: configuration)
        setAudioEngineRunState(audioEngine.runState)
        refreshAudioEngineTelemetry()
    }

    private func setAudioEngineRunState(_ newValue: AudioEngineRunState) {
        guard audioEngineRunState != newValue else { return }
        audioEngineRunState = newValue
    }

    private func finishDriverInstall(result: Result<Void, Error>, shouldResumeEngine: Bool) {
        driverInstallInProgress = false
        switch result {
        case .success:
            driverInstallMessage = "PureQ audio driver installed. CoreAudio was restarted."
            refreshAudioDevices(enforceLock: false)
            if shouldResumeEngine {
                startAudioEngine(manual: false)
            } else {
                scheduleAutoStartIfNeeded()
            }
        case .failure(let error):
            driverInstallMessage = "Driver install failed: \(error.localizedDescription)"
            refreshAudioDevices(enforceLock: false)
        }
    }

    private func finishDriverUninstall(result: Result<Void, Error>, shouldResumeEngine: Bool) {
        driverInstallInProgress = false
        switch result {
        case .success:
            driverInstallMessage = "PureQ audio driver removed. CoreAudio was restarted."
            refreshAudioDevices(enforceLock: false)
        case .failure(let error):
            driverInstallMessage = "Driver uninstall failed: \(error.localizedDescription)"
            refreshAudioDevices(enforceLock: false)
            if shouldResumeEngine {
                startAudioEngine(manual: false)
            }
        }
    }

    nonisolated private static func driverInstallCommand(sourcePath: String) -> String {
        let source = shellQuoted(sourcePath)
        let destination = shellQuoted("/Library/Audio/Plug-Ins/HAL/PureQ.driver")
        let destinationDirectory = shellQuoted("/Library/Audio/Plug-Ins/HAL")
        return [
            "/bin/mkdir -p \(destinationDirectory)",
            "/bin/rm -rf \(destination)",
            "/usr/bin/ditto --norsrc --noextattr \(source) \(destination)",
            "/usr/sbin/chown -R root:wheel \(destination)",
            "/bin/chmod -R go-w \(destination)",
            "(/usr/bin/xattr -cr \(destination) >/dev/null 2>&1 || true)",
            "(/usr/bin/killall coreaudiod >/dev/null 2>&1 || true)"
        ].joined(separator: " && ")
    }

    nonisolated private static func driverUninstallCommand() -> String {
        let destination = shellQuoted("/Library/Audio/Plug-Ins/HAL/PureQ.driver")
        return [
            "/bin/rm -rf \(destination)",
            "(/usr/bin/killall coreaudiod >/dev/null 2>&1 || true)"
        ].joined(separator: " && ")
    }

    nonisolated private static func runPrivilegedShellCommand(_ command: String) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \(appleScriptStringLiteral(command)) with administrator privileges"
        ]
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DriverInstallError.privilegedCommandFailed(message?.isEmpty == false ? message! : "Administrator authorization was cancelled or failed.")
        }
    }

    nonisolated private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    nonisolated private static func appleScriptStringLiteral(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func resolvedOutputDeviceIDs(for configuration: AudioEngineConfiguration) -> [String: AudioDeviceID] {
        var deviceIDsByUID: [String: AudioDeviceID] = [:]
        for target in configuration.renderTargets {
            guard let device = hardwareOutputDevices.first(where: { $0.uid == target.outputUID }) else {
                continue
            }
            deviceIDsByUID[target.outputUID] = device.audioObjectID
        }
        return deviceIDsByUID
    }

    private func restartAudioEngineIfNeeded() {
        guard audioEngineRunState == .running else {
            scheduleAutoStartIfNeeded()
            return
        }
        stopAudioEngine(manual: false)
        startAudioEngine(manual: false)
    }

    private func scheduleAutoStartIfNeeded() {
        guard autoStartEngineEnabled,
              !isStartingAudioEngine,
              !manualStopSuppressesAutoStart,
              audioEngineRunState != .running,
              audioEngineStatus.state == .ready,
              canStartAudioEngine else {
            return
        }

        let signature = autoStartSignature
        guard signature != lastAutoStartFailureSignature else {
            return
        }

        autoStartWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.autoStartEngineEnabled,
                      !self.manualStopSuppressesAutoStart,
                      self.audioEngineRunState != .running,
                      self.audioEngineStatus.state == .ready,
                      self.canStartAudioEngine,
                      self.autoStartSignature == signature else {
                    return
                }
                self.startAudioEngine(manual: false)
            }
        }
        autoStartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private var autoStartSignature: String {
        let configuration = audioEngineConfiguration
        let renderTargetSignature = configuration.renderTargets
            .map { target in
                [
                    target.outputUID,
                    String(target.routeCount),
                    String(format: "%.2f", target.preamp),
                    String(format: "%.2f", target.balance),
                    String(target.filters.count)
                ].joined(separator: ":")
            }
            .sorted()
            .joined(separator: "|")
        let connectionSignature = routingConnections
            .map { "\($0.from.uuidString):\($0.to.uuidString)" }
            .sorted()
            .joined(separator: "|")
        let nodeSignature = routingNodes
            .map { node in
                [
                    node.id.uuidString,
                    node.kind.rawValue,
                    node.audioSourceID ?? "",
                    node.audioOutputUID ?? "",
                    node.eqSelection.rawValue,
                    String(format: "%.2f", node.eqPreamp),
                    String(format: "%.2f", node.eqBalance)
                ].joined(separator: ":")
            }
            .sorted()
            .joined(separator: "|")
        return [
            configuration.outputUID ?? "no-output",
            configuration.virtualCaptureUID ?? "no-capture",
            "\(configuration.sourceRoutes.filter(\.reachesOutput).count)",
            "\(configuration.routePlans.count)",
            "\(configuration.filters.count)",
            "\(configuration.mutesOriginalAudio)",
            "\(powerEnabled)",
            renderTargetSignature,
            nodeSignature,
            connectionSignature
        ].joined(separator: "#")
    }

    func addSourceRoutingNode(sourceID: String) {
        rememberUndo(.routing)
        let source = availableAudioSources.first(where: { $0.id == sourceID }) ?? .systemMix
        if source.id != AudioSourceItem.systemMixID,
           replaceSeededSystemMixSource(with: source) {
            restartAudioEngineIfNeeded()
            schedulePersistedStateSave()
            return
        }

        let sourceCount = routingNodes.filter { $0.kind == .source }.count
        let node = RoutingNode(
            title: source.title,
            subtitle: source.subtitle,
            kind: .source,
            position: CGPoint(x: 145, y: 150 + CGFloat(sourceCount * 154)),
            audioSourceID: source.id
        )
        routingNodes.append(node)
        selectedRoutingNodeID = node.id
        restartAudioEngineIfNeeded()
        schedulePersistedStateSave()
    }

    private func replaceSeededSystemMixSource(with source: AudioSourceItem) -> Bool {
        guard !routingNodes.contains(where: {
            $0.kind == .source &&
            ($0.audioSourceID ?? AudioSourceItem.systemMixID) != AudioSourceItem.systemMixID
        }),
            let index = routingNodes.firstIndex(where: {
                $0.kind == .source &&
                $0.isProtected &&
                ($0.audioSourceID ?? AudioSourceItem.systemMixID) == AudioSourceItem.systemMixID
            }) else {
            return false
        }

        routingNodes[index].audioSourceID = source.id
        routingNodes[index].title = source.title
        routingNodes[index].subtitle = source.subtitle
        routingNodes[index].isProtected = false
        selectedRoutingNodeID = routingNodes[index].id
        patchStartNodeID = nil
        return true
    }

    func addRoutingNode(kind: RoutingNodeKind) {
        rememberUndo(.routing)
        let count = routingNodes.count
        let kindCount = routingNodes.filter { $0.kind == kind }.count + 1
        let position = CGPoint(
            x: 145 + CGFloat((count % 4) * 255),
            y: 150 + CGFloat((count / 4) * 154)
        )
        let node = RoutingNode(
            title: kind == .equalizer ? "EQ \(kindCount)" : kind.title,
            subtitle: subtitle(for: kind),
            kind: kind,
            position: position
        )
        routingNodes.append(node)
        selectedRoutingNodeID = node.id
        if kind == .equalizer {
            activeEQNodeID = node.id
        }
        restartAudioEngineIfNeeded()
        schedulePersistedStateSave()
    }

    func addOutputRoutingNode(
        uid: String?,
        restartEngine: Bool = true,
        scheduleSave: Bool = true,
        selectNode: Bool = true
    ) {
        if scheduleSave {
            rememberUndo(.routing)
        }
        let device = uid.flatMap { targetUID in hardwareOutputDevices.first(where: { $0.uid == targetUID }) }
        let outputCount = routingNodes.filter { $0.kind == .output }.count
        let outputPosition = CGPoint(x: 910, y: 310 + CGFloat(outputCount * 154))
        let node = RoutingNode(
            title: device?.name ?? "Output",
            subtitle: outputSubtitle(for: device),
            kind: .output,
            position: outputPosition,
            audioOutputUID: device?.uid
        )
        routingNodes.append(node)
        if selectNode {
            selectedRoutingNodeID = node.id
        }
        if restartEngine {
            restartAudioEngineIfNeeded()
        }
        if scheduleSave {
            schedulePersistedStateSave()
        }
    }

    func removeRoutingNode(id: RoutingNode.ID) {
        guard routingNodes.contains(where: { $0.id == id }) else { return }
        rememberUndo(.routing)
        routingNodes.removeAll { $0.id == id }
        routingConnections.removeAll { $0.from == id || $0.to == id }
        if selectedRoutingNodeID == id { selectedRoutingNodeID = nil }
        if activeEQNodeID == id { activeEQNodeID = nil }
        if patchStartNodeID == id { patchStartNodeID = nil }
        restartAudioEngineIfNeeded()
        schedulePersistedStateSave()
    }

    func moveRoutingNode(id: RoutingNode.ID, to position: CGPoint, in canvasSize: CGSize) {
        guard let index = routingNodes.firstIndex(where: { $0.id == id }) else { return }
        let clampedPosition = CGPoint(
            x: position.x.clamped(to: 118...max(118, canvasSize.width - 118)),
            y: position.y.clamped(to: 72...max(72, canvasSize.height - 72))
        )
        guard routingNodes[index].position != clampedPosition else { return }
        rememberUndo(.routing)
        routingNodes[index].position = clampedPosition
        schedulePersistedStateSave(after: 1.0)
    }

    func selectRoutingNode(id: RoutingNode.ID) {
        selectedRoutingNodeID = id
        if routingNodes.contains(where: { $0.id == id && $0.kind == .equalizer }) {
            activeEQNodeID = id
        }
        schedulePersistedStateSave()
    }

    func patchRoutingNode(id: RoutingNode.ID) {
        if patchStartNodeID == id {
            patchStartNodeID = nil
            return
        }

        guard let startID = patchStartNodeID else {
            patchStartNodeID = id
            selectedRoutingNodeID = id
            return
        }

        let connection = RoutingConnection(from: startID, to: id)
        var changedGraph = false
        if isValidRoutingConnection(connection),
           !routingConnections.contains(where: { $0.from == startID && $0.to == id }) {
            rememberUndo(.routing)
            routingConnections.append(connection)
            changedGraph = true
        }
        patchStartNodeID = nil
        selectedRoutingNodeID = id
        if changedGraph {
            restartAudioEngineIfNeeded()
            schedulePersistedStateSave()
        }
    }

    func disconnectRoutingNode(id: RoutingNode.ID) {
        guard routingConnections.contains(where: { $0.from == id || $0.to == id }) else { return }
        rememberUndo(.routing)
        routingConnections.removeAll { $0.from == id || $0.to == id }
        restartAudioEngineIfNeeded()
        schedulePersistedStateSave()
    }

    func renameRoutingNode(id: RoutingNode.ID, title: String) {
        guard let index = routingNodes.firstIndex(where: { $0.id == id }) else { return }
        rememberUndo(.routing)
        routingNodes[index].title = title.isEmpty ? routingNodes[index].kind.title : title
        schedulePersistedStateSave()
    }

    func setRoutingNodeKind(id: RoutingNode.ID, kind: RoutingNodeKind) {
        guard let index = routingNodes.firstIndex(where: { $0.id == id }) else {
            return
        }

        rememberUndo(.routing)
        routingNodes[index].kind = kind
        routingNodes[index].subtitle = subtitle(for: kind)
        if kind == .equalizer {
            ensureEQNodeState(at: index)
            activeEQNodeID = id
        } else if activeEQNodeID == id {
            activeEQNodeID = nil
        }
        if kind == .source, routingNodes[index].audioSourceID == nil {
            routingNodes[index].audioSourceID = AudioSourceItem.systemMixID
        }
        if kind != .source {
            routingNodes[index].audioSourceID = nil
        }
        if kind != .output {
            routingNodes[index].audioOutputUID = nil
        }
        pruneInvalidRoutingConnections()
        syncRoutingOutputNodes()
        restartAudioEngineIfNeeded()
        schedulePersistedStateSave()
    }

    func setEQNodeUsesMainEqualizer(id: RoutingNode.ID, enabled: Bool) {
        guard let index = routingNodes.firstIndex(where: { $0.id == id }),
              routingNodes[index].kind == .equalizer else {
            return
        }

        rememberUndo(.equalizer)
        routingNodes[index].eqUsesMainEqualizer = enabled
        if enabled {
            routingNodes[index].eqMode = mode
            routingNodes[index].eqSelection = selection
            routingNodes[index].eqPreamp = preamp
            routingNodes[index].eqBalance = balance
            routingNodes[index].eqBands = bands
            routingNodes[index].eqAutoGainEnabled = autoGainEnabled
            routingNodes[index].eqManualMode = manualMode
            routingNodes[index].eqManualPreamp = manualPreamp
            routingNodes[index].eqManualBalance = manualBalance
            routingNodes[index].eqManualBands = manualBands
            routingNodes[index].eqManualAutoGainEnabled = manualAutoGainEnabled
        }
        syncRoutingOutputNodes()
        updateAudioEngineRendering()
    }

    func setEQNodeMode(id: RoutingNode.ID, mode newMode: EqualizerMode) {
        rememberUndo(.equalizer)
        updateEQNode(id: id) { node in
            node.eqBands = retargetedBands(for: newMode.frequencies, from: node.eqBands)
            node.eqMode = newMode
            applyAutoGainIfNeeded(to: &node)
            saveManualProfileIfNeeded(for: &node)
        }
    }

    func setEQNodeBandLayout(id: RoutingNode.ID, layout: EqualizerBandLayout) {
        rememberUndo(.equalizer)
        updateEQNode(id: id) { node in
            let currentLayout = bandLayout(for: node.eqMode, bands: node.eqBands)
            switch layout {
            case .bands10:
                node.eqBands = retargetedBands(for: EqualizerMode.basic.frequencies, from: node.eqBands)
                node.eqMode = .basic
            case .bands31:
                node.eqBands = retargetedBands(for: EqualizerMode.expert.frequencies, from: node.eqBands)
                node.eqMode = .expert
            case .custom:
                if currentLayout != .custom {
                    node.eqBands.append(EqualizerBand(
                        frequency: suggestedCustomBandFrequency(in: node.eqBands),
                        gain: 0,
                        q: 0.5,
                        isCustom: true
                    ))
                    sortBands(&node.eqBands)
                    node.eqMode = .advanced
                }
            }
            applyAutoGainIfNeeded(to: &node)
            saveManualProfileIfNeeded(for: &node)
        }
    }

    func applyEQNodeSelection(id: RoutingNode.ID, selection newSelection: EqualizerSelection) {
        rememberUndo(.equalizer)
        updateEQNode(id: id) { node in
            if newSelection == .manual {
                restoreManualProfile(for: &node)
                return
            }

            node.eqSelection = newSelection

            switch newSelection {
            case .manual:
                break
            case .bands31, .bands10, .basic:
                break
            case .flat:
                setAllGains(to: 0, in: &node.eqBands)
            case .bassLift:
                applyPreset(to: &node.eqBands) { frequency in
                    if frequency <= 80 { return 5.0 }
                    if frequency <= 160 { return 3.2 }
                    if frequency >= 8_000 { return 1.2 }
                    return frequency >= 400 && frequency <= 1_250 ? -1.0 : 0
                }
            case .vocalFocus:
                applyPreset(to: &node.eqBands) { frequency in
                    if (800...3_150).contains(frequency) { return 3.0 }
                    if frequency <= 100 { return -2.2 }
                    if frequency >= 10_000 { return 1.0 }
                    return 0
                }
            case .crispAir:
                applyPreset(to: &node.eqBands) { frequency in
                    if frequency >= 6_300 { return 4.0 }
                    if (2_000...5_000).contains(frequency) { return 1.6 }
                    if frequency <= 80 { return -1.0 }
                    return 0
                }
            case .lateNight:
                applyPreset(to: &node.eqBands) { frequency in
                    if frequency <= 80 { return -5.0 }
                    if frequency >= 8_000 { return -3.0 }
                    if (400...2_500).contains(frequency) { return 1.4 }
                    return -1.0
                }
            }
            applyAutoGainIfNeeded(to: &node)
        }
    }

    func setEQNodePreamp(id: RoutingNode.ID, preamp value: Double) {
        rememberEqualizerUndo(persist: false, continuousToken: "node-\(id.uuidString)-preamp")
        updateEQNode(id: id) { node in
            node.eqPreamp = value.clamped(to: -20...20)
            node.eqSelection = .manual
            saveManualProfile(for: &node)
        }
    }

    func setEQNodeBalance(id: RoutingNode.ID, balance value: Double) {
        rememberEqualizerUndo(persist: false, continuousToken: "node-\(id.uuidString)-balance")
        updateEQNode(id: id) { node in
            node.eqBalance = value.clamped(to: -1...1)
            node.eqSelection = .manual
            saveManualProfile(for: &node)
        }
    }

    func setEQNodeAutoGain(id: RoutingNode.ID, enabled: Bool) {
        rememberUndo(.equalizer)
        updateEQNode(id: id) { node in
            node.eqAutoGainEnabled = enabled
            applyAutoGainIfNeeded(to: &node)
            node.eqSelection = .manual
            saveManualProfile(for: &node)
        }
    }

    func setEQNodeBandGain(nodeID: RoutingNode.ID, bandID: EqualizerBand.ID, gain: Double, persist: Bool = true) {
        rememberEqualizerUndo(persist: persist, continuousToken: "node-\(nodeID.uuidString)-band-gain-\(bandID.uuidString)")
        updateEQNodeBand(nodeID: nodeID, bandID: bandID, scheduleSave: persist) { band in
            band.gain = gain.clamped(to: -20...20)
        }
    }

    func setEQNodeBandFrequency(nodeID: RoutingNode.ID, bandID: EqualizerBand.ID, frequency: Double) {
        rememberUndo(.equalizer)
        updateEQNodeBand(nodeID: nodeID, bandID: bandID, sortAfterMutation: true) { band in
            band.frequency = frequency.clamped(to: 20...20_000)
        }
    }

    func setEQNodeBandGraphPosition(
        nodeID: RoutingNode.ID,
        bandID: EqualizerBand.ID,
        frequency: Double,
        gain: Double,
        persist: Bool = true
    ) {
        rememberEqualizerUndo(persist: persist, continuousToken: "node-\(nodeID.uuidString)-band-graph-\(bandID.uuidString)")
        updateEQNodeBand(
            nodeID: nodeID,
            bandID: bandID,
            scheduleSave: persist,
            sortAfterMutation: persist
        ) { band in
            guard band.isEnabled else { return }
            band.frequency = frequency.clamped(to: 20...20_000)
            band.gain = gain.clamped(to: -20...20)
        }
    }

    func setEQNodeBandQ(nodeID: RoutingNode.ID, bandID: EqualizerBand.ID, q: Double, persist: Bool = true) {
        rememberEqualizerUndo(persist: persist, continuousToken: "node-\(nodeID.uuidString)-band-q-\(bandID.uuidString)")
        updateEQNodeBand(nodeID: nodeID, bandID: bandID, scheduleSave: persist) { band in
            band.q = q.clamped(to: 0.1...10)
        }
    }

    func addEQNodeBand(nodeID: RoutingNode.ID) {
        rememberUndo(.equalizer)
        updateEQNode(id: nodeID) { node in
            let frequency = suggestedCustomBandFrequency(in: node.eqBands)
            node.eqBands.append(EqualizerBand(frequency: frequency, gain: 0, q: 0.5, isCustom: true))
            sortBands(&node.eqBands)
            node.eqSelection = .manual
            applyAutoGainIfNeeded(to: &node)
            saveManualProfile(for: &node)
        }
    }

    func flattenActiveEQAsManual() {
        rememberUndo(.equalizer)
        if let nodeID = activeEQNode?.id {
            flattenEQNodeAsManual(id: nodeID)
        } else {
            resetBandsToFlat(&bands)
            preamp = 0
            balance = 0
            selection = .manual
            saveMainManualProfile()
            syncLinkedEQNodes()
            syncRoutingOutputNodes()
            updateAudioEngineRendering()
        }
    }

    func createFlatEQNodeFromActiveEQ() {
        rememberUndo(.routing)
        let sourceBands = activeEQNode?.eqBands ?? bands
        var flatBands = sourceBands
        resetBandsToFlat(&flatBands)

        let eqCount = routingNodes.filter { $0.kind == .equalizer }.count + 1
        let node = RoutingNode(
            title: "Flat EQ \(eqCount)",
            subtitle: "Manual / \(activeEQBandLayoutTitle)",
            kind: .equalizer,
            position: CGPoint(x: 400 + CGFloat((eqCount % 3) * 44), y: 190 + CGFloat((eqCount % 4) * 36)),
            eqMode: activeEQMode,
            eqSelection: .manual,
            eqPreamp: 0,
            eqBalance: activeEQBalance,
            eqBands: flatBands,
            eqUsesMainEqualizer: false,
            eqAutoGainEnabled: activeEQAutoGainEnabled,
            eqManualMode: activeEQMode,
            eqManualPreamp: 0,
            eqManualBalance: activeEQBalance,
            eqManualBands: flatBands,
            eqManualAutoGainEnabled: activeEQAutoGainEnabled
        )
        routingNodes.append(node)
        selectedRoutingNodeID = node.id
        activeEQNodeID = node.id
        syncRoutingOutputNodes()
        schedulePersistedStateSave()
        restartAudioEngineIfNeeded()
        updateAudioEngineRendering()
    }

    func flattenEQNodeAsManual(id: RoutingNode.ID) {
        rememberUndo(.equalizer)
        updateEQNode(id: id) { node in
            resetBandsToFlat(&node.eqBands)
            node.eqPreamp = 0
            node.eqBalance = 0
            node.eqSelection = .manual
            saveManualProfile(for: &node)
        }
    }

    func toggleEQNodeBand(nodeID: RoutingNode.ID, bandID: EqualizerBand.ID) {
        rememberUndo(.equalizer)
        updateEQNodeBand(nodeID: nodeID, bandID: bandID) { band in
            band.isEnabled.toggle()
        }
    }

    func toggleEQNodeStereoLink(nodeID: RoutingNode.ID, bandID: EqualizerBand.ID) {
        rememberUndo(.equalizer)
        updateEQNodeBand(nodeID: nodeID, bandID: bandID) { band in
            band.isStereoLinked.toggle()
        }
    }

    func cycleEQNodeBandShape(nodeID: RoutingNode.ID, bandID: EqualizerBand.ID) {
        rememberUndo(.equalizer)
        updateEQNodeBand(nodeID: nodeID, bandID: bandID) { band in
            switch band.shape {
            case .bell:
                band.shape = .shelf
            case .shelf:
                band.shape = .notch
            case .notch:
                band.shape = .bell
            }
        }
    }

    func setRoutingNodeSource(id: RoutingNode.ID, sourceID: String) {
        guard let index = routingNodes.firstIndex(where: { $0.id == id }),
              routingNodes[index].kind == .source else {
            return
        }

        let source = availableAudioSources.first(where: { $0.id == sourceID }) ?? .systemMix
        rememberUndo(.routing)
        routingNodes[index].audioSourceID = source.id
        routingNodes[index].title = source.title
        routingNodes[index].subtitle = source.subtitle
        schedulePersistedStateSave()
        restartAudioEngineIfNeeded()
    }

    func setRoutingNodeOutput(id: RoutingNode.ID, uid: String?) {
        guard let index = routingNodes.firstIndex(where: { $0.id == id }),
              routingNodes[index].kind == .output else {
            return
        }

        rememberUndo(.routing)
        routingNodes[index].audioOutputUID = uid
        if let uid,
           let device = hardwareOutputDevices.first(where: { $0.uid == uid }) {
            routingNodes[index].title = device.name
            routingNodes[index].subtitle = outputSubtitle(for: device)
        } else {
            routingNodes[index].audioOutputUID = nil
            routingNodes[index].subtitle = "Unassigned device"
        }
        syncRoutingOutputNodes()
        schedulePersistedStateSave()
        restartAudioEngineIfNeeded()
    }

    func resetRoutingGraph() {
        rememberUndo(.routing)
        routingNodes.removeAll()
        routingConnections.removeAll()
        selectedRoutingNodeID = nil
        patchStartNodeID = nil
        seedRoutingGraphIfNeeded()
        schedulePersistedStateSave()
        restartAudioEngineIfNeeded()
    }

    private func startDevicePolling() {
        let timer = Timer(timeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAudioSources()
                self?.refreshAudioDevices()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func startLifecycleRefreshObservers() {
        let notifications: [(NotificationCenter, Notification.Name)] = [
            (NotificationCenter.default, NSApplication.didBecomeActiveNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)
        ]

        lifecycleObservers = notifications.map { center, name in
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshAudioSources()
                    self?.refreshAudioDevices()
                }
            }
            return (center, observer)
        }
    }

    private func startEngineTelemetryPolling() {
        engineTelemetryTimer?.invalidate()
        let hasActiveVisualTelemetry = !visibleGraphicalSurfaceIDs.isEmpty &&
            (soundIndicatorsEnabled || spectrumAnalyzerEnabled)
        let interval: TimeInterval
        if !hasActiveVisualTelemetry {
            interval = 1.0
        } else {
            interval = 1.0 / visualAnalyzerFrameRate
        }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAudioEngineTelemetry()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        engineTelemetryTimer = timer
    }

    private func stopEngineTelemetryPolling() {
        engineTelemetryTimer?.invalidate()
        engineTelemetryTimer = nil
        telemetryStore.reset()
    }

    private func refreshAudioEngineTelemetry() {
        let snapshot = audioEngine.telemetry
        audioEngineTelemetry = snapshot
        if abs(audioEngineSampleRate - snapshot.sampleRate) > 0.5 {
            audioEngineSampleRate = snapshot.sampleRate
        }
        guard !visibleGraphicalSurfaceIDs.isEmpty,
              soundIndicatorsEnabled || spectrumAnalyzerEnabled else {
            return
        }
        telemetryStore.publish(
            snapshot,
            smoothMeters: true,
            forceVisualRefresh: highFrameRateUIEnabled
        )
    }

    private var visualAnalyzerFrameRate: Double {
        highFrameRateUIEnabled ? 60.0 : 30.0
    }

    @discardableResult
    private func ensureSystemDefaultForVirtualCapture() throws -> Bool {
        guard let virtualOutput = pureQVirtualOutputDevice else {
            return false
        }
        let needsSwitch = outputDefaultsNeedChanging(to: virtualOutput.uid)
        let changed = switchSystemDefaultToVirtualOutputForEngine()
        if needsSwitch && !changed && outputDefaultsNeedChanging(to: virtualOutput.uid) {
            throw AudioEngineStartError.virtualOutputSwitchFailed(virtualOutput.name)
        }
        return changed
    }

    @discardableResult
    private func switchSystemDefaultToVirtualOutputForEngine() -> Bool {
        guard let virtualOutput = pureQVirtualOutputDevice else {
            return false
        }

        guard outputDefaultsNeedChanging(to: virtualOutput.uid) else {
            return false
        }

        if preVirtualDefaultOutputUID == nil {
            let currentDefault = [defaultOutputUID, defaultSystemOutputUID]
                .compactMap(\.self)
                .first { $0 != virtualOutput.uid }
            preVirtualDefaultOutputUID = currentDefault
        }

        let changed = audioService.setDefaultOutput(uid: virtualOutput.uid)
        if changed {
            refreshAudioDevices(enforceLock: false)
        }
        return changed
    }

    private func restoreSystemDefaultAfterVirtualCapture() {
        guard let previousUID = preVirtualDefaultOutputUID else {
            return
        }

        preVirtualDefaultOutputUID = nil
        guard outputDefaultsIncludePureQVirtualOutput,
              hardwareOutputDevices.contains(where: { $0.uid == previousUID }) else {
            return
        }

        if audioService.setDefaultOutput(uid: previousUID) {
            refreshAudioDevices(enforceLock: false)
        }
    }

    private func normalizeRoutedHardwareOutputVolumes(for configuration: AudioEngineConfiguration) {
        guard shouldNormalizeHardwareOutputVolumes(for: configuration) else {
            restoreNormalizedHardwareOutputVolumes()
            return
        }

        let hardwareUIDs = Set(hardwareOutputDevices.map(\.uid))
        let activeOutputUIDs = Set(configuration.renderTargets.map(\.outputUID))
            .intersection(hardwareUIDs)

        let inactiveLeasedUIDs = Set(normalizedHardwareOutputVolumeStates.keys)
            .subtracting(activeOutputUIDs)
        for uid in inactiveLeasedUIDs {
            restoreNormalizedHardwareOutputVolume(uid: uid)
        }

        for uid in activeOutputUIDs {
            if normalizedHardwareOutputVolumeStates[uid] == nil,
               let state = audioService.volumeState(uid: uid) {
                normalizedHardwareOutputVolumeStates[uid] = state
            }

            if audioService.muted(uid: uid) {
                _ = audioService.setMute(uid: uid, muted: false)
            }

            let currentScalar = audioService.volumeScalar(uid: uid)
            if currentScalar == nil || (currentScalar ?? 1) < 0.999 {
                _ = audioService.setVolumeScalar(uid: uid, scalar: 1)
            }
        }
    }

    private func shouldNormalizeHardwareOutputVolumes(for configuration: AudioEngineConfiguration) -> Bool {
        outputDefaultsIncludePureQVirtualOutput ||
            (configuration.virtualCaptureUID != nil && configuration.prefersDriverCapture)
    }

    private func restoreNormalizedHardwareOutputVolumes() {
        for uid in Array(normalizedHardwareOutputVolumeStates.keys) {
            restoreNormalizedHardwareOutputVolume(uid: uid)
        }
    }

    private func restoreNormalizedHardwareOutputVolume(uid: String) {
        guard let state = normalizedHardwareOutputVolumeStates.removeValue(forKey: uid) else {
            return
        }
        _ = audioService.restoreVolumeState(state)
    }

    private func outputDefaultsNeedChanging(to uid: String?) -> Bool {
        guard let uid else { return false }
        return defaultOutputUID != uid || defaultSystemOutputUID != uid
    }

    private var outputDefaultsIncludePureQVirtualOutput: Bool {
        guard let virtualOutputUID = pureQVirtualOutputDevice?.uid else {
            return false
        }
        return defaultOutputUID == virtualOutputUID || defaultSystemOutputUID == virtualOutputUID
    }

    private func routedHardwareOutputUIDs() -> Set<String> {
        let nodeByID = Dictionary(uniqueKeysWithValues: routingNodes.map { ($0.id, $0) })
        let sourceIDs = routingNodes.filter { $0.kind == .source }.map(\.id)
        let outputNodeIDs = Set(routingNodes.filter { $0.kind == .output }.map(\.id))
        let adjacency = Dictionary(grouping: routingConnections, by: \.from)
        var outputUIDs = Set<String>()

        func walk(currentID: RoutingNode.ID, visited: Set<RoutingNode.ID>) {
            guard !visited.contains(currentID) else { return }
            if outputNodeIDs.contains(currentID),
               let node = nodeByID[currentID],
               let uid = node.audioOutputUID,
               hardwareOutputDevices.contains(where: { $0.uid == uid }) {
                outputUIDs.insert(uid)
                return
            }

            var nextVisited = visited
            nextVisited.insert(currentID)
            for connection in adjacency[currentID, default: []] {
                walk(currentID: connection.to, visited: nextVisited)
            }
        }

        for sourceID in sourceIDs {
            walk(currentID: sourceID, visited: [])
        }
        return outputUIDs
    }

    private func bandLayout(for mode: EqualizerMode, bands sourceBands: [EqualizerBand]) -> EqualizerBandLayout {
        if mode == .basic, matchesLayout(sourceBands, frequencies: EqualizerMode.basic.frequencies) {
            return .bands10
        }
        if mode == .expert, matchesLayout(sourceBands, frequencies: EqualizerMode.expert.frequencies) {
            return .bands31
        }
        if matchesLayout(sourceBands, frequencies: EqualizerMode.basic.frequencies) {
            return .bands10
        }
        if matchesLayout(sourceBands, frequencies: EqualizerMode.expert.frequencies) {
            return .bands31
        }
        return .custom
    }

    private func matchesLayout(_ sourceBands: [EqualizerBand], frequencies: [Double]) -> Bool {
        let sorted = sortedBands(sourceBands)
        guard sorted.count == frequencies.count,
              !sorted.contains(where: \.isCustom) else {
            return false
        }

        return zip(sorted, frequencies).allSatisfy { band, frequency in
            abs(band.frequency - frequency) < 0.01 && abs(band.slotFrequency - frequency) < 0.01
        }
    }

    private func hasCustomBandConfiguration(_ sourceBands: [EqualizerBand]) -> Bool {
        sourceBands.contains { band in
            band.isCustom || abs(band.frequency - band.slotFrequency) >= 0.01
        }
    }

    private func retargetedBands(for frequencies: [Double], from sourceBands: [EqualizerBand]) -> [EqualizerBand] {
        guard !frequencies.isEmpty else {
            return sortedBands(sourceBands)
        }

        var targetBands = frequencies.map { EqualizerBand(slotFrequency: $0, frequency: $0) }
        if shouldPreserveExactBandsWhenExpanding(from: sourceBands, to: frequencies) {
            for index in targetBands.indices {
                guard let sourceBand = exactBand(at: targetBands[index].frequency, in: sourceBands) else {
                    continue
                }
                copyBandSettings(from: sourceBand, to: &targetBands[index])
            }
        } else {
            retargetBands(&targetBands, from: sourceBands)
        }
        return sortedBands(targetBands)
    }

    private func shouldPreserveExactBandsWhenExpanding(from sourceBands: [EqualizerBand], to frequencies: [Double]) -> Bool {
        guard frequencies.count >= sourceBands.count else {
            return false
        }

        return sourceBands.allSatisfy { sourceBand in
            frequencies.contains { abs($0 - sourceBand.frequency) < 0.01 }
        }
    }

    private func exactBand(at frequency: Double, in sourceBands: [EqualizerBand]) -> EqualizerBand? {
        sourceBands.first { abs($0.frequency - frequency) < 0.01 }
    }

    private func copyBandSettings(from sourceBand: EqualizerBand, to targetBand: inout EqualizerBand) {
        targetBand.gain = sourceBand.gain
        targetBand.q = sourceBand.q
        targetBand.isEnabled = sourceBand.isEnabled
        targetBand.isStereoLinked = sourceBand.isStereoLinked
        targetBand.shape = sourceBand.shape
    }

    private func saveMainManualProfileIfNeeded() {
        if selection == .manual {
            saveMainManualProfile()
        }
    }

    private func saveMainManualProfile() {
        manualMode = mode
        manualPreamp = preamp
        manualBalance = balance
        manualBands = bands
        manualAutoGainEnabled = autoGainEnabled
    }

    private func restoreMainManualProfile() {
        mode = manualMode
        preamp = manualPreamp
        balance = manualBalance
        bands = manualBands
        autoGainEnabled = manualAutoGainEnabled
        selection = .manual
    }

    private func saveManualProfileIfNeeded(for node: inout RoutingNode) {
        if node.eqSelection == .manual {
            saveManualProfile(for: &node)
        }
    }

    private func saveManualProfile(for node: inout RoutingNode) {
        node.eqManualMode = node.eqMode
        node.eqManualPreamp = node.eqPreamp
        node.eqManualBalance = node.eqBalance
        node.eqManualBands = node.eqBands
        node.eqManualAutoGainEnabled = node.eqAutoGainEnabled
    }

    private func restoreManualProfile(for node: inout RoutingNode) {
        node.eqMode = node.eqManualMode
        node.eqPreamp = node.eqManualPreamp
        node.eqBalance = node.eqManualBalance
        node.eqBands = node.eqManualBands
        node.eqAutoGainEnabled = node.eqManualAutoGainEnabled
        node.eqSelection = .manual
    }

    private func suggestedCustomBandFrequency(in sourceBands: [EqualizerBand]) -> Double {
        let existingFrequencies = sourceBands.map(\.frequency)
        let preferredFrequencies: [Double] = [1_000, 1_100, 750, 1_500, 2_200, 3_000, 6_000, 300, 90, 12_000]
        if let preferred = preferredFrequencies.first(where: { candidate in
            !existingFrequencies.contains { abs(log10(max($0, 20)) - log10(candidate)) < 0.018 }
        }) {
            return preferred
        }

        let sorted = existingFrequencies.sorted()
        guard sorted.count >= 2 else { return 1_000 }

        let largestGap = zip(sorted.dropLast(), sorted.dropFirst()).max { lhs, rhs in
            let lhsGap = log10(lhs.1) - log10(lhs.0)
            let rhsGap = log10(rhs.1) - log10(rhs.0)
            return lhsGap < rhsGap
        }
        if let largestGap {
            let midpoint = pow(10, (log10(largestGap.0) + log10(largestGap.1)) / 2)
            return midpoint.clamped(to: 20...20_000)
        }

        return 1_000
    }

    private func sortBands(_ targetBands: inout [EqualizerBand]) {
        targetBands = sortedBands(targetBands)
    }

    private func sortedBands(_ sourceBands: [EqualizerBand]) -> [EqualizerBand] {
        sourceBands.sorted { lhs, rhs in
            if abs(lhs.frequency - rhs.frequency) > 0.001 {
                return lhs.frequency < rhs.frequency
            }
            if lhs.isCustom != rhs.isCustom {
                return !lhs.isCustom
            }
            return lhs.slotFrequency < rhs.slotFrequency
        }
    }

    private func retargetBands(_ targetBands: inout [EqualizerBand], from sourceBands: [EqualizerBand]) {
        guard !sourceBands.isEmpty else { return }
        let sortedSources = sourceBands.sorted { $0.frequency < $1.frequency }

        for index in targetBands.indices {
            let frequency = targetBands[index].frequency
            targetBands[index].gain = interpolatedGain(at: frequency, sources: sortedSources)

            let nearest = nearestBand(to: frequency, in: sortedSources)
            targetBands[index].q = nearest.q
            targetBands[index].shape = nearest.shape
            targetBands[index].isEnabled = nearest.isEnabled
            targetBands[index].isStereoLinked = nearest.isStereoLinked
        }
    }

    private func interpolatedGain(at frequency: Double, sources: [EqualizerBand]) -> Double {
        guard let first = sources.first, let last = sources.last else { return 0 }
        guard frequency > first.frequency else { return first.gain }
        guard frequency < last.frequency else { return last.gain }

        if let exact = sources.first(where: { abs($0.frequency - frequency) < 0.01 }) {
            return exact.gain
        }

        let logFrequency = log10(frequency)
        for pairIndex in 0..<(sources.count - 1) {
            let lower = sources[pairIndex]
            let upper = sources[pairIndex + 1]
            guard lower.frequency <= frequency, frequency <= upper.frequency else {
                continue
            }

            let lowerLog = log10(lower.frequency)
            let upperLog = log10(upper.frequency)
            let fraction = (logFrequency - lowerLog) / max(upperLog - lowerLog, 0.000_001)
            return lower.gain + ((upper.gain - lower.gain) * fraction)
        }

        return nearestBand(to: frequency, in: sources).gain
    }

    private func nearestBand(to frequency: Double, in sourceBands: [EqualizerBand]) -> EqualizerBand {
        sourceBands.min {
            abs(log10($0.frequency) - log10(frequency)) < abs(log10($1.frequency) - log10(frequency))
        } ?? EqualizerBand(frequency: frequency)
    }

    private func setAllGains(to gain: Double) {
        setAllGains(to: gain, in: &bands)
        applyAutoGainIfNeeded()
    }

    private func applyPreset(_ gainForFrequency: (Double) -> Double) {
        applyPreset(to: &bands, gainForFrequency)
        applyAutoGainIfNeeded()
    }

    private func setAllGains(to gain: Double, in targetBands: inout [EqualizerBand]) {
        for index in targetBands.indices {
            targetBands[index].gain = gain
        }
    }

    private func resetBandsToFlat(_ targetBands: inout [EqualizerBand]) {
        for index in targetBands.indices {
            if !targetBands[index].isCustom {
                targetBands[index].frequency = targetBands[index].slotFrequency
            }
            targetBands[index].gain = 0
            targetBands[index].q = 0.5
            targetBands[index].isEnabled = true
            targetBands[index].isStereoLinked = true
            targetBands[index].shape = .bell
        }
    }

    private func applyPreset(to targetBands: inout [EqualizerBand], _ gainForFrequency: (Double) -> Double) {
        for index in targetBands.indices {
            targetBands[index].gain = gainForFrequency(targetBands[index].frequency).clamped(to: -20...20)
        }
    }

    private func applyAutoGainIfNeeded() {
        guard autoGainEnabled else { return }
        preamp = autoPreamp(for: bands)
    }

    private func applyAutoGainIfNeeded(to node: inout RoutingNode) {
        guard node.eqAutoGainEnabled else { return }
        node.eqPreamp = autoPreamp(for: node.eqBands)
    }

    private func autoPreamp(for targetBands: [EqualizerBand]) -> Double {
        let activeBands = targetBands.filter { $0.isEnabled && abs($0.gain) > 0.01 }
        guard !activeBands.isEmpty else {
            return 0
        }

        let minimumFrequency = 20.0
        let maximumFrequency = 20_000.0
        let sampleCount = 160
        let minLog = log10(minimumFrequency)
        let maxLog = log10(maximumFrequency)
        var peakBoost = 0.0

        for sampleIndex in 0..<sampleCount {
            let fraction = Double(sampleIndex) / Double(sampleCount - 1)
            let frequency = pow(10, minLog + ((maxLog - minLog) * fraction))
            let estimatedBoost = activeBands.reduce(0.0) { partialResult, band in
                partialResult + estimatedResponseContribution(from: band, at: frequency)
            }
            peakBoost = max(peakBoost, estimatedBoost)
        }

        return -peakBoost.clamped(to: 0...20)
    }

    private func estimatedResponseContribution(from band: EqualizerBand, at frequency: Double) -> Double {
        let octaveDistance = log2(frequency / band.frequency)
        let width = max(0.10, 1.05 / sqrt(max(0.12, band.q)))

        switch band.shape {
        case .bell:
            return band.gain * exp(-0.5 * pow(octaveDistance / width, 2))
        case .notch:
            return -abs(band.gain) * exp(-0.5 * pow(octaveDistance / max(0.08, width * 0.72), 2))
        case .shelf:
            let slope = max(0.08, width * 0.55)
            let transition = 1 / (1 + exp(-octaveDistance / slope))
            if band.frequency < 1_000 {
                return band.gain * (1 - transition)
            }
            return band.gain * transition
        }
    }

    private func updateBand(id: EqualizerBand.ID, mutate: (inout EqualizerBand) -> Void) {
        guard let index = bands.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutate(&bands[index])
    }

    private func updateEQNode(id: RoutingNode.ID, scheduleSave: Bool = true, mutate: (inout RoutingNode) -> Void) {
        guard let index = routingNodes.firstIndex(where: { $0.id == id }),
              routingNodes[index].kind == .equalizer else {
            return
        }

        ensureEQNodeState(at: index)
        routingNodes[index].eqUsesMainEqualizer = false
        mutate(&routingNodes[index])
        syncRoutingOutputNodes()
        updateAudioEngineRendering(scheduleSave: scheduleSave)
    }

    private func updateEQNodeBand(
        nodeID: RoutingNode.ID,
        bandID: EqualizerBand.ID,
        scheduleSave: Bool = true,
        sortAfterMutation: Bool = false,
        mutate: (inout EqualizerBand) -> Void
    ) {
        updateEQNode(id: nodeID, scheduleSave: scheduleSave) { node in
            guard let bandIndex = node.eqBands.firstIndex(where: { $0.id == bandID }) else {
                return
            }
            mutate(&node.eqBands[bandIndex])
            if sortAfterMutation {
                sortBands(&node.eqBands)
            }
            node.eqSelection = .manual
            if scheduleSave {
                applyAutoGainIfNeeded(to: &node)
                saveManualProfile(for: &node)
            }
        }
    }

    private func ensureEQNodeState(at index: Int) {
        guard routingNodes[index].eqBands.isEmpty else {
            return
        }
        routingNodes[index].eqBands = EqualizerBand.makeStandardBands()
        routingNodes[index].eqMode = .expert
        routingNodes[index].eqSelection = .flat
        routingNodes[index].eqPreamp = 0
        routingNodes[index].eqBalance = 0
        routingNodes[index].eqAutoGainEnabled = true
        routingNodes[index].eqManualMode = .expert
        routingNodes[index].eqManualPreamp = 0
        routingNodes[index].eqManualBalance = 0
        routingNodes[index].eqManualBands = routingNodes[index].eqBands
        routingNodes[index].eqManualAutoGainEnabled = true
    }

    private func syncLinkedEQNodes() {
        for index in routingNodes.indices where routingNodes[index].kind == .equalizer && routingNodes[index].eqUsesMainEqualizer {
            routingNodes[index].eqMode = mode
            routingNodes[index].eqSelection = selection
            routingNodes[index].eqPreamp = preamp
            routingNodes[index].eqBalance = balance
            routingNodes[index].eqBands = bands
            routingNodes[index].eqAutoGainEnabled = autoGainEnabled
            routingNodes[index].eqManualMode = manualMode
            routingNodes[index].eqManualPreamp = manualPreamp
            routingNodes[index].eqManualBalance = manualBalance
            routingNodes[index].eqManualBands = manualBands
            routingNodes[index].eqManualAutoGainEnabled = manualAutoGainEnabled
        }
    }

    private func selectDefaultEQNodeIfNeeded() {
        guard activeEQNode == nil,
              let eqNode = routingNodes.first(where: { $0.kind == .equalizer }) else {
            return
        }
        activeEQNodeID = eqNode.id
    }

    private func integrateLegacyPureQBusNodes() {
        let legacyBusIDs = routingNodes
            .filter {
                ($0.kind == .bus && $0.isProtected && $0.title == "PureQ Bus") ||
                ($0.kind == .guardNode && $0.isProtected)
            }
            .map(\.id)
        guard !legacyBusIDs.isEmpty else { return }

        for busID in legacyBusIDs {
            let incomingIDs = routingConnections
                .filter { $0.to == busID }
                .map(\.from)
            let outgoingIDs = routingConnections
                .filter { $0.from == busID }
                .map(\.to)

            routingConnections.removeAll { $0.from == busID || $0.to == busID }
            for sourceID in incomingIDs {
                for targetID in outgoingIDs where sourceID != targetID {
                    let connection = RoutingConnection(from: sourceID, to: targetID)
                    if isValidRoutingConnection(connection),
                       !routingConnections.contains(where: { $0.from == sourceID && $0.to == targetID }) {
                        routingConnections.append(connection)
                    }
                }
            }
        }

        routingNodes.removeAll { legacyBusIDs.contains($0.id) }
        if let selectedRoutingNodeID, legacyBusIDs.contains(selectedRoutingNodeID) {
            self.selectedRoutingNodeID = nil
        }
        if let patchStartNodeID, legacyBusIDs.contains(patchStartNodeID) {
            self.patchStartNodeID = nil
        }
    }

    private func seedRoutingGraphIfNeeded() {
        guard routingNodes.isEmpty else { return }

        let source = RoutingNode(
            title: "System Mix",
            subtitle: "All macOS app audio",
            kind: .source,
            position: CGPoint(x: 145, y: 150),
            audioSourceID: AudioSourceItem.systemMixID,
            isProtected: true
        )
        let eq = RoutingNode(
            title: "Equalizer",
            subtitle: "\(activeEQBandLayoutTitle) / \(visibleBands.count) bands",
            kind: .equalizer,
            position: CGPoint(x: 400, y: 150),
            isProtected: true,
            eqMode: mode,
            eqSelection: selection,
            eqPreamp: preamp,
            eqBalance: balance,
            eqBands: bands,
            eqUsesMainEqualizer: false
        )
        let output = RoutingNode(
            title: "Output",
            subtitle: "Unassigned device",
            kind: .output,
            position: CGPoint(x: 655, y: 150),
            audioOutputUID: nil
        )

        routingNodes = [source, eq, output]
        routingConnections = [
            RoutingConnection(from: source.id, to: eq.id),
            RoutingConnection(from: eq.id, to: output.id)
        ]
        activeEQNodeID = eq.id
        syncRoutingOutputNodes()
    }

    private func syncRoutingSourceNodes() {
        guard !routingNodes.isEmpty else { return }

        for index in routingNodes.indices where routingNodes[index].kind == .source {
            let sourceID = routingNodes[index].audioSourceID ?? AudioSourceItem.systemMixID
            if let source = availableAudioSources.first(where: { $0.id == sourceID }) {
                setRoutingNodeTitleIfNeeded(at: index, title: source.title)
                setRoutingNodeSubtitleIfNeeded(at: index, subtitle: source.subtitle)
            } else {
                setRoutingNodeSubtitleIfNeeded(at: index, subtitle: "Source unavailable")
            }
        }
    }

    private func syncRoutingOutputNodes() {
        guard !routingNodes.isEmpty else { return }

        for index in routingNodes.indices {
            switch routingNodes[index].kind {
            case .source:
                let sourceID = routingNodes[index].audioSourceID ?? AudioSourceItem.systemMixID
                if let source = availableAudioSources.first(where: { $0.id == sourceID }) {
                    setRoutingNodeTitleIfNeeded(at: index, title: source.title)
                    setRoutingNodeSubtitleIfNeeded(at: index, subtitle: source.subtitle)
                } else {
                    setRoutingNodeSubtitleIfNeeded(at: index, subtitle: "Source unavailable")
                }
            case .equalizer:
                let visibleCount = visibleEQBands(for: routingNodes[index]).count
                let activeCount = routingNodes[index].eqBands.filter { $0.isEnabled && abs($0.gain) > 0.01 }.count
                let linkLabel = routingNodes[index].eqUsesMainEqualizer ? "Main" : "Unique"
                let layoutLabel = bandLayout(for: routingNodes[index].eqMode, bands: routingNodes[index].eqBands).title
                setRoutingNodeSubtitleIfNeeded(
                    at: index,
                    subtitle: "\(linkLabel) / \(layoutLabel) / \(visibleCount) bands / \(activeCount) active"
                )
            case .guardNode:
                setRoutingNodeSubtitleIfNeeded(at: index, subtitle: "Legacy guard")
            case .output:
                if let uid = routingNodes[index].audioOutputUID,
                   let device = hardwareOutputDevices.first(where: { $0.uid == uid }) {
                    setRoutingNodeTitleIfNeeded(at: index, title: device.name)
                    setRoutingNodeSubtitleIfNeeded(at: index, subtitle: outputSubtitle(for: device))
                } else if let uid = routingNodes[index].audioOutputUID,
                          outputDevices.first(where: { $0.uid == uid })?.isPureQVirtualOutput == true {
                    routingNodes[index].audioOutputUID = nil
                    setRoutingNodeTitleIfNeeded(at: index, title: "Output")
                    setRoutingNodeSubtitleIfNeeded(at: index, subtitle: "Choose a hardware device")
                } else if routingNodes[index].audioOutputUID != nil {
                    setRoutingNodeSubtitleIfNeeded(at: index, subtitle: "Disconnected")
                }
            default:
                break
            }
        }

        integrateLegacyPureQBusNodes()
    }

    private func setRoutingNodeTitleIfNeeded(at index: Int, title: String) {
        guard routingNodes.indices.contains(index), routingNodes[index].title != title else { return }
        routingNodes[index].title = title
    }

    private func setRoutingNodeSubtitleIfNeeded(at index: Int, subtitle: String) {
        guard routingNodes.indices.contains(index), routingNodes[index].subtitle != subtitle else { return }
        routingNodes[index].subtitle = subtitle
    }

    private func pruneInvalidRoutingConnections() {
        let existingConnections = routingConnections
        routingConnections = existingConnections.filter { isValidRoutingConnection($0, within: existingConnections) }
    }

    private func isValidRoutingConnection(_ connection: RoutingConnection) -> Bool {
        isValidRoutingConnection(connection, within: routingConnections)
    }

    private func isValidRoutingConnection(_ connection: RoutingConnection, within connections: [RoutingConnection]) -> Bool {
        guard connection.from != connection.to,
              let source = routingNodes.first(where: { $0.id == connection.from }),
              let target = routingNodes.first(where: { $0.id == connection.to }) else {
            return false
        }

        guard source.kind != .output, target.kind != .source else {
            return false
        }

        return !routingPathExists(from: connection.to, to: connection.from, ignoring: connection.id, within: connections)
    }

    private func routingPathExists(
        from startID: RoutingNode.ID,
        to targetID: RoutingNode.ID,
        ignoring ignoredConnectionID: RoutingConnection.ID? = nil,
        within connections: [RoutingConnection]
    ) -> Bool {
        var visited = Set<RoutingNode.ID>()
        var stack = [startID]

        while let currentID = stack.popLast() {
            if currentID == targetID {
                return true
            }
            guard visited.insert(currentID).inserted else {
                continue
            }

            for connection in connections where connection.id != ignoredConnectionID && connection.from == currentID {
                stack.append(connection.to)
            }
        }

        return false
    }

    private func subtitle(for kind: RoutingNodeKind) -> String {
        switch kind {
        case .source: return "Input stream"
        case .bus: return "Stereo bus"
        case .equalizer: return "Unique / Expert / 31 bands / 0 active"
        case .guardNode: return "Legacy guard"
        case .output: return "Device output"
        case .monitor: return "Meter tap"
        }
    }

    private func outputSubtitle(for device: AudioOutputDevice?) -> String {
        guard let device else { return "Unassigned device" }
        let labels = [
            device.isDefaultOutput ? "Default" : nil,
            device.isDefaultSystemOutput ? "System" : nil,
            device.isMuted ? "Muted" : nil,
            "\(device.channelCount) ch"
        ].compactMap(\.self)
        return labels.joined(separator: " / ")
    }

    private var virtualCaptureDeviceForEngine: AudioOutputDevice? {
        guard !audioEngine.processTapsAvailable,
              routingGraphHasRoutableSource,
              let virtualOutput = pureQVirtualOutputDevice else {
            return nil
        }
        if routingGraphUsesSystemMix {
            return virtualOutput
        }
        return virtualOutput
    }

    private var routingGraphHasRoutableSource: Bool {
        let sourceNodes = routingNodes.filter { $0.kind == .source }
        let outputNodeIDs = Set(routingNodes.compactMap { node -> RoutingNode.ID? in
            guard node.kind == .output, node.audioOutputUID != nil else { return nil }
            return node.id
        })
        guard !sourceNodes.isEmpty, !outputNodeIDs.isEmpty else { return false }

        let adjacency = Dictionary(grouping: routingConnections, by: \.from)
        return sourceNodes.contains { node in
            sourceNode(node.id, reachesOutputIn: outputNodeIDs, adjacency: adjacency)
        }
    }

    private var routingGraphUsesSystemMix: Bool {
        let sourceNodes = routingNodes.filter { $0.kind == .source }
        let outputNodeIDs = Set(routingNodes.compactMap { node -> RoutingNode.ID? in
            guard node.kind == .output, node.audioOutputUID != nil else { return nil }
            return node.id
        })
        guard !sourceNodes.isEmpty, !outputNodeIDs.isEmpty else { return false }

        let adjacency = Dictionary(grouping: routingConnections, by: \.from)
        let hasSpecificSourceRoute = sourceNodes.contains { node in
            (node.audioSourceID ?? AudioSourceItem.systemMixID) != AudioSourceItem.systemMixID &&
            sourceNode(node.id, reachesOutputIn: outputNodeIDs, adjacency: adjacency)
        }

        for node in sourceNodes where (node.audioSourceID ?? AudioSourceItem.systemMixID) == AudioSourceItem.systemMixID {
            if hasSpecificSourceRoute && node.isProtected {
                continue
            }
            if sourceNode(node.id, reachesOutputIn: outputNodeIDs, adjacency: adjacency) {
                return true
            }
        }

        return false
    }

    private func sourceNode(
        _ sourceID: RoutingNode.ID,
        reachesOutputIn outputNodeIDs: Set<RoutingNode.ID>,
        adjacency: [RoutingNode.ID: [RoutingConnection]]
    ) -> Bool {
        var visited = Set<RoutingNode.ID>()
        var stack = adjacency[sourceID, default: []].map(\.to)

        while let currentID = stack.popLast() {
            guard visited.insert(currentID).inserted else { continue }
            if outputNodeIDs.contains(currentID) {
                return true
            }
            stack.append(contentsOf: adjacency[currentID, default: []].map(\.to))
        }

        return false
    }

    private func sourceKind(for bundleIdentifier: String) -> AudioSourceKind {
        if bundleIdentifier.contains("Safari") || bundleIdentifier.contains("Chrome") || bundleIdentifier.contains("firefox") {
            return .browser
        }
        if bundleIdentifier.localizedCaseInsensitiveContains("steam") ||
            bundleIdentifier.localizedCaseInsensitiveContains("epic") ||
            bundleIdentifier.localizedCaseInsensitiveContains("game") {
            return .game
        }
        return .application
    }

    private func sourceSystemImage(for bundleIdentifier: String) -> String {
        switch sourceKind(for: bundleIdentifier) {
        case .systemMix:
            return "macwindow.on.rectangle"
        case .application:
            return bundleIdentifier.localizedCaseInsensitiveContains("music") ? "music.note" : "app"
        case .game:
            return "gamecontroller"
        case .browser:
            return "globe"
        }
    }

    private var sourceReadiness: TestReadinessItem {
        let sourceCount = routingNodes.filter { $0.kind == .source }.count
        let individualCount = routingNodes.filter { $0.kind == .source && $0.audioSourceID != AudioSourceItem.systemMixID }.count
        return TestReadinessItem(
            id: "sources",
            title: "Audio Sources",
            detail: "\(sourceCount) source node\(sourceCount == 1 ? "" : "s"), \(individualCount) individual app/game source\(individualCount == 1 ? "" : "s").",
            state: sourceCount > 0 ? .ready : .caution
        )
    }

    private var engineReadiness: TestReadinessItem {
        let status = audioEngineStatus
        let state: TestReadinessState
        switch status.state {
        case .ready:
            state = .ready
        case .partial:
            state = .caution
        case .blocked:
            state = .blocked
        }

        return TestReadinessItem(
            id: "engine",
            title: "Audio Engine",
            detail: status.detail,
            state: state
        )
    }

    private var outputDeviceReadiness: TestReadinessItem {
        if hardwareOutputDevices.isEmpty {
            return TestReadinessItem(
                id: "outputs",
                title: "Audio Outputs",
                detail: "No hardware output devices were discovered. PureQ Virtual Output cannot be used as the render destination.",
                state: .blocked
            )
        }

        let virtualCount = outputDevices.filter(\.isPureQVirtualOutput).count
        return TestReadinessItem(
            id: "outputs",
            title: "Audio Outputs",
            detail: "\(hardwareOutputDevices.count) hardware render output\(hardwareOutputDevices.count == 1 ? "" : "s") available\(virtualCount > 0 ? "; PureQ Virtual Output is available for system capture" : "; PureQ Virtual Output is not installed/loaded").",
            state: virtualCount > 0 ? .ready : .caution
        )
    }

    private var routingGraphReadiness: TestReadinessItem {
        let hasRoute = !routingConnections.isEmpty && routingNodes.contains(where: { $0.kind == .output })
        return TestReadinessItem(
            id: "routing-graph",
            title: "Routing Graph",
            detail: "\(routingNodes.count) nodes / \(routingConnections.count) connections.",
            state: hasRoute ? .ready : .caution
        )
    }

    private var routingLayoutReadiness: TestReadinessItem {
        let overlaps = overlappingRoutingNodePairs()
        if overlaps.isEmpty {
            return TestReadinessItem(
                id: "routing-layout",
                title: "Node Layout",
                detail: "No overlapping nodes detected.",
                state: .ready
            )
        }

        return TestReadinessItem(
            id: "routing-layout",
            title: "Node Layout",
            detail: "\(overlaps.count) overlapping node pair\(overlaps.count == 1 ? "" : "s") detected.",
            state: .caution
        )
    }

    private var driverReadiness: TestReadinessItem {
        let engineStatus = audioEngineStatus
        let bundledDriver = engineStatus.driverBundled
        let installedDriver = engineStatus.driverInstalled

        if bundledDriver || installedDriver {
            return TestReadinessItem(
                id: "driver",
                title: "Audio Driver",
                detail: installedDriver ? "PureQ HAL driver is installed." : "PureQ driver is bundled but not installed.",
                state: installedDriver ? .ready : .caution
            )
        }

        return TestReadinessItem(
            id: "driver",
            title: "Audio Driver",
            detail: engineStatus.processTapsAvailable
                ? "No PureQ HAL driver/helper is present. Process taps can identify app sources, but audible system-wide output still needs a render loop or driver."
                : "No PureQ HAL driver/helper is present, so system-wide EQ DSP is not testable yet.",
            state: engineStatus.processTapsAvailable ? .caution : .blocked
        )
    }

    private func overlappingRoutingNodePairs() -> [(RoutingNode, RoutingNode)] {
        var pairs: [(RoutingNode, RoutingNode)] = []
        let minimumXDistance: CGFloat = 214
        let minimumYDistance: CGFloat = 116

        for firstIndex in routingNodes.indices {
            for secondIndex in routingNodes.indices where secondIndex > firstIndex {
                let first = routingNodes[firstIndex]
                let second = routingNodes[secondIndex]
                if abs(first.position.x - second.position.x) < minimumXDistance,
                   abs(first.position.y - second.position.y) < minimumYDistance {
                    pairs.append((first, second))
                }
            }
        }

        return pairs
    }
}
