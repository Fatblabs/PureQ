//
//  EqualizerModel.swift
//  PureQ
//

import AppKit
import Combine
import Foundation
import SwiftUI

enum EqualizerMode: String, CaseIterable, Identifiable, Codable {
    case basic = "Basic"
    case advanced = "Advanced"
    case expert = "Expert"

    var id: String { rawValue }

    var frequencies: [Double] {
        switch self {
        case .basic:
            return [32, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
        case .advanced:
            return [25, 40, 63, 100, 160, 250, 400, 630, 1_000, 1_600, 2_500, 4_000, 6_300, 10_000, 16_000]
        case .expert:
            return EqualizerBand.standardFrequencies
        }
    }
}

enum EqualizerSelection: String, CaseIterable, Identifiable, Codable {
    case manual
    case bands31
    case bands10
    case basic
    case flat
    case bassLift
    case vocalFocus
    case crispAir
    case lateNight

    var id: String { rawValue }

    static let profileOptions: [EqualizerSelection] = [
        .manual,
        .flat,
        .bassLift,
        .vocalFocus,
        .crispAir,
        .lateNight
    ]

    var title: String {
        switch self {
        case .manual: return "Manual"
        case .bands31: return "31 Bands"
        case .bands10: return "10 Bands"
        case .basic: return "Basic"
        case .flat: return "Flat"
        case .bassLift: return "Bass Lift"
        case .vocalFocus: return "Vocal Focus"
        case .crispAir: return "Crisp Air"
        case .lateNight: return "Late Night"
        }
    }
}

enum BandShape: String, CaseIterable, Identifiable, Codable {
    case bell
    case shelf
    case notch

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .bell: return "alternatingcurrent"
        case .shelf: return "chart.line.uptrend.xyaxis"
        case .notch: return "line.3.horizontal.decrease"
        }
    }
}

struct EqualizerBand: Identifiable, Equatable, Codable {
    let id: UUID
    let slotFrequency: Double
    var frequency: Double
    var gain: Double
    var q: Double
    var isEnabled: Bool
    var isStereoLinked: Bool
    var shape: BandShape
    var isCustom: Bool

    init(
        slotFrequency: Double? = nil,
        frequency: Double,
        gain: Double = 0,
        q: Double = 0.5,
        isEnabled: Bool = true,
        isStereoLinked: Bool = true,
        shape: BandShape = .bell,
        isCustom: Bool = false
    ) {
        self.id = UUID()
        self.slotFrequency = slotFrequency ?? frequency
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.isEnabled = isEnabled
        self.isStereoLinked = isStereoLinked
        self.shape = shape
        self.isCustom = isCustom
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case slotFrequency
        case frequency
        case gain
        case q
        case isEnabled
        case isStereoLinked
        case shape
        case isCustom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        frequency = try container.decode(Double.self, forKey: .frequency)
        slotFrequency = try container.decodeIfPresent(Double.self, forKey: .slotFrequency) ?? frequency
        gain = try container.decodeIfPresent(Double.self, forKey: .gain) ?? 0
        q = try container.decodeIfPresent(Double.self, forKey: .q) ?? 0.5
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isStereoLinked = try container.decodeIfPresent(Bool.self, forKey: .isStereoLinked) ?? true
        shape = try container.decodeIfPresent(BandShape.self, forKey: .shape) ?? .bell
        isCustom = try container.decodeIfPresent(Bool.self, forKey: .isCustom) ?? !Self.isStandardFrequency(slotFrequency)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(slotFrequency, forKey: .slotFrequency)
        try container.encode(frequency, forKey: .frequency)
        try container.encode(gain, forKey: .gain)
        try container.encode(q, forKey: .q)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isStereoLinked, forKey: .isStereoLinked)
        try container.encode(shape, forKey: .shape)
        try container.encode(isCustom, forKey: .isCustom)
    }

    static let standardFrequencies: [Double] = [
        20, 25, 32, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630,
        800, 1_000, 1_250, 1_600, 2_000, 2_500, 3_150, 4_000, 5_000, 6_300, 8_000,
        10_000, 12_500, 16_000, 20_000
    ]

    static func makeStandardBands() -> [EqualizerBand] {
        standardFrequencies.map { EqualizerBand(frequency: $0) }
    }

    static func isStandardFrequency(_ frequency: Double) -> Bool {
        standardFrequencies.contains { abs($0 - frequency) < 0.01 }
    }

    static func label(for frequency: Double) -> String {
        if frequency >= 1_000 {
            let value = frequency / 1_000
            if value.rounded() == value {
                return "\(Int(value))KHz"
            }
            return String(format: "%.1fKHz", value)
        }
        return "\(Int(frequency.rounded()))Hz"
    }
}

enum OutputLockStatus {
    case unlocked
    case locked
    case guarding
    case needsAttention

    var title: String {
        switch self {
        case .unlocked: return "Unlocked"
        case .locked: return "Locked"
        case .guarding: return "Guarding"
        case .needsAttention: return "Needs attention"
        }
    }

    var systemImage: String {
        switch self {
        case .unlocked: return "speaker.wave.2"
        case .locked: return "lock.fill"
        case .guarding: return "speaker.slash.fill"
        case .needsAttention: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .unlocked: return .secondary
        case .locked: return Color.pureQGreen
        case .guarding: return Color.pureQAmber
        case .needsAttention: return Color.pureQOrange
        }
    }
}

enum AudioSourceKind: String, CaseIterable, Identifiable, Codable {
    case systemMix = "System Mix"
    case application = "Application"
    case game = "Game"
    case browser = "Browser"

    var id: String { rawValue }
}

struct AudioSourceItem: Identifiable, Equatable {
    static let systemMixID = "source.system-mix"
    static let gameSourceID = "source.games"

    let id: String
    let title: String
    let bundleIdentifier: String?
    var processIdentifier: pid_t?
    let kind: AudioSourceKind
    let systemImage: String
    var isRunning: Bool

    init(
        id: String,
        title: String,
        bundleIdentifier: String?,
        processIdentifier: pid_t? = nil,
        kind: AudioSourceKind,
        systemImage: String,
        isRunning: Bool
    ) {
        self.id = id
        self.title = title
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.kind = kind
        self.systemImage = systemImage
        self.isRunning = isRunning
    }

    var subtitle: String {
        switch kind {
        case .systemMix:
            return "All macOS app audio"
        case .application:
            return isRunning ? "Running app" : "Application source"
        case .game:
            return isRunning ? "Running game/app" : "Game or custom app"
        case .browser:
            return isRunning ? "Running browser" : "Browser source"
        }
    }

    static let systemMix = AudioSourceItem(
        id: systemMixID,
        title: "System Mix",
        bundleIdentifier: nil,
        kind: .systemMix,
        systemImage: "macwindow.on.rectangle",
        isRunning: true
    )

    static let commonSources: [AudioSourceItem] = [
        AudioSourceItem(id: "com.apple.Music", title: "Apple Music", bundleIdentifier: "com.apple.Music", kind: .application, systemImage: "music.note", isRunning: false),
        AudioSourceItem(id: "com.apple.Safari", title: "Safari", bundleIdentifier: "com.apple.Safari", kind: .browser, systemImage: "safari", isRunning: false),
        AudioSourceItem(id: "com.google.Chrome", title: "Google Chrome", bundleIdentifier: "com.google.Chrome", kind: .browser, systemImage: "globe", isRunning: false),
        AudioSourceItem(id: "com.spotify.client", title: "Spotify", bundleIdentifier: "com.spotify.client", kind: .application, systemImage: "music.quarternote.3", isRunning: false),
        AudioSourceItem(id: "org.videolan.vlc", title: "VLC", bundleIdentifier: "org.videolan.vlc", kind: .application, systemImage: "play.rectangle", isRunning: false),
        AudioSourceItem(id: gameSourceID, title: "Games", bundleIdentifier: nil, kind: .game, systemImage: "gamecontroller", isRunning: false)
    ]
}

enum RoutingNodeKind: String, CaseIterable, Identifiable, Codable {
    case source = "Source"
    case bus = "Bus"
    case equalizer = "EQ"
    case guardNode = "Guard"
    case output = "Output"
    case monitor = "Monitor"

    var id: String { rawValue }

    var title: String { rawValue }

    var systemImage: String {
        switch self {
        case .source: return "macwindow"
        case .bus: return "switch.2"
        case .equalizer: return "slider.horizontal.3"
        case .guardNode: return "lock.shield"
        case .output: return "speaker.wave.2.fill"
        case .monitor: return "waveform"
        }
    }

    var accent: Color {
        switch self {
        case .source: return .white.opacity(0.62)
        case .bus, .equalizer: return Color.pureQGreen
        case .guardNode: return Color.pureQAmber
        case .output: return Color(red: 0.30, green: 0.70, blue: 0.90)
        case .monitor: return Color(red: 0.86, green: 0.54, blue: 0.93)
        }
    }
}

enum TestReadinessState: Equatable {
    case ready
    case caution
    case blocked

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .caution: return "Check"
        case .blocked: return "Blocked"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ready: return Color.pureQGreen
        case .caution: return Color.pureQAmber
        case .blocked: return Color.pureQOrange
        }
    }
}

struct TestReadinessItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let state: TestReadinessState
}

struct RoutingNode: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    var subtitle: String
    var kind: RoutingNodeKind
    var position: CGPoint
    var audioSourceID: String?
    var audioOutputUID: String?
    var isProtected: Bool
    var eqMode: EqualizerMode
    var eqSelection: EqualizerSelection
    var eqPreamp: Double
    var eqBalance: Double
    var eqBands: [EqualizerBand]
    var eqUsesMainEqualizer: Bool
    var eqAutoGainEnabled: Bool
    var eqManualMode: EqualizerMode
    var eqManualPreamp: Double
    var eqManualBalance: Double
    var eqManualBands: [EqualizerBand]
    var eqManualAutoGainEnabled: Bool

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String,
        kind: RoutingNodeKind,
        position: CGPoint,
        audioSourceID: String? = nil,
        audioOutputUID: String? = nil,
        isProtected: Bool = false,
        eqMode: EqualizerMode = .expert,
        eqSelection: EqualizerSelection = .flat,
        eqPreamp: Double = 0,
        eqBalance: Double = 0,
        eqBands: [EqualizerBand] = EqualizerBand.makeStandardBands(),
        eqUsesMainEqualizer: Bool = false,
        eqAutoGainEnabled: Bool = true,
        eqManualMode: EqualizerMode? = nil,
        eqManualPreamp: Double? = nil,
        eqManualBalance: Double? = nil,
        eqManualBands: [EqualizerBand]? = nil,
        eqManualAutoGainEnabled: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.position = position
        self.audioSourceID = audioSourceID
        self.audioOutputUID = audioOutputUID
        self.isProtected = isProtected
        self.eqMode = eqMode
        self.eqSelection = eqSelection
        self.eqPreamp = eqPreamp
        self.eqBalance = eqBalance
        self.eqBands = eqBands
        self.eqUsesMainEqualizer = eqUsesMainEqualizer
        self.eqAutoGainEnabled = eqAutoGainEnabled
        self.eqManualMode = eqManualMode ?? eqMode
        self.eqManualPreamp = eqManualPreamp ?? eqPreamp
        self.eqManualBalance = eqManualBalance ?? eqBalance
        self.eqManualBands = eqManualBands ?? eqBands
        self.eqManualAutoGainEnabled = eqManualAutoGainEnabled ?? eqAutoGainEnabled
    }
}

struct RoutingConnection: Identifiable, Equatable, Codable {
    let id: UUID
    var from: RoutingNode.ID
    var to: RoutingNode.ID

    init(id: UUID = UUID(), from: RoutingNode.ID, to: RoutingNode.ID) {
        self.id = id
        self.from = from
        self.to = to
    }
}

struct EQProfileSnapshot: Equatable, Codable {
    var title: String
    var mode: EqualizerMode
    var selection: EqualizerSelection
    var preamp: Double
    var balance: Double
    var autoGainEnabled: Bool
    var bands: [EqualizerBand]
    var manualMode: EqualizerMode
    var manualPreamp: Double
    var manualBalance: Double
    var manualBands: [EqualizerBand]
    var manualAutoGainEnabled: Bool
}

struct EQProfileFile: Equatable, Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var appName: String
    var exportedAt: Date
    var profile: EQProfileSnapshot

    init(profile: EQProfileSnapshot) {
        schemaVersion = Self.currentSchemaVersion
        appName = "PureQ"
        exportedAt = Date()
        self.profile = profile
    }
}

struct PureQSessionSnapshot: Equatable, Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var savedAt: Date
    var mainProfile: EQProfileSnapshot
    var routingNodes: [RoutingNode]
    var routingConnections: [RoutingConnection]
    var activeEQNodeID: RoutingNode.ID?

    init(
        mainProfile: EQProfileSnapshot,
        routingNodes: [RoutingNode],
        routingConnections: [RoutingConnection],
        activeEQNodeID: RoutingNode.ID?
    ) {
        schemaVersion = Self.currentSchemaVersion
        savedAt = Date()
        self.mainProfile = mainProfile
        self.routingNodes = routingNodes
        self.routingConnections = routingConnections
        self.activeEQNodeID = activeEQNodeID
    }

    static func == (lhs: PureQSessionSnapshot, rhs: PureQSessionSnapshot) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion &&
            lhs.mainProfile == rhs.mainProfile &&
            lhs.routingNodes == rhs.routingNodes &&
            lhs.routingConnections == rhs.routingConnections &&
            lhs.activeEQNodeID == rhs.activeEQNodeID
    }
}

enum EQProfileFileError: LocalizedError {
    case unsupportedVersion(Int)
    case emptyProfile

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "This EQ file uses unsupported schema version \(version)."
        case .emptyProfile:
            return "This EQ file does not contain any bands."
        }
    }
}

private enum PureQPersistenceStore {
    static let appSupportDirectoryURL = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0].appendingPathComponent("PureQ", isDirectory: true)
    static let sessionSnapshotURL = appSupportDirectoryURL.appendingPathComponent("LastSession.pureqsession.json")

    static func writeSessionSnapshot(_ snapshot: PureQSessionSnapshot) throws {
        try FileManager.default.createDirectory(
            at: appSupportDirectoryURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: sessionSnapshotURL, options: .atomic)
    }
}

@MainActor
final class AudioTelemetryStore: ObservableObject {
    @Published private(set) var telemetry: AudioEngineTelemetry = .empty

    private var smoothedBandLevels = Array(repeating: 0.0, count: EqualizerBand.standardFrequencies.count)
    private var meterIndexByRoundedFrequency: [Int: Int] = [:]
    private var lastPublishTime = 0.0

    func reset() {
        smoothedBandLevels = Array(repeating: 0.0, count: EqualizerBand.standardFrequencies.count)
        meterIndexByRoundedFrequency.removeAll(keepingCapacity: true)
        lastPublishTime = 0
        telemetry = .empty
    }

    func publish(_ snapshot: AudioEngineTelemetry, smoothMeters: Bool) {
        let levels = smoothedLevels(from: snapshot.bandLevels, smoothMeters: smoothMeters)
        let next = AudioEngineTelemetry(
            capturedFrames: snapshot.capturedFrames,
            renderedFrames: snapshot.renderedFrames,
            underrunFrames: snapshot.underrunFrames,
            bufferedFrames: snapshot.bufferedFrames,
            inputCallbacks: snapshot.inputCallbacks,
            renderCallbacks: snapshot.renderCallbacks,
            bandLevels: levels
        )

        guard shouldPublish(next) else { return }
        telemetry = next
    }

    func bandActivityLevel(for frequency: Double) -> Double {
        let cacheKey = Int(frequency.rounded())
        let index: Int

        if let cachedIndex = meterIndexByRoundedFrequency[cacheKey] {
            index = cachedIndex
        } else if let nearestIndex = EqualizerBand.standardFrequencies.indices.min(by: { lhs, rhs in
            let lhsDistance = abs(log10(EqualizerBand.standardFrequencies[lhs]) - log10(frequency))
            let rhsDistance = abs(log10(EqualizerBand.standardFrequencies[rhs]) - log10(frequency))
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

    private func shouldPublish(_ next: AudioEngineTelemetry) -> Bool {
        let levelsChanged = bandLevelsChangedSignificantly(next.bandLevels)
        let countersChanged = telemetry.capturedFrames != next.capturedFrames ||
            telemetry.renderedFrames != next.renderedFrames ||
            telemetry.underrunFrames != next.underrunFrames ||
            telemetry.bufferedFrames != next.bufferedFrames ||
            telemetry.inputCallbacks != next.inputCallbacks ||
            telemetry.renderCallbacks != next.renderCallbacks

        guard levelsChanged || countersChanged else { return false }

        let now = Date.timeIntervalSinceReferenceDate
        if levelsChanged || now - lastPublishTime >= 0.25 {
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
}

@MainActor
final class EqualizerModel: ObservableObject {
    let telemetryStore = AudioTelemetryStore()

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
    @Published var highFrameRateUIEnabled = false {
        didSet {
            if audioEngineRunState == .running {
                startEngineTelemetryPolling()
            }
        }
    }
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
    @Published var processedTakeoverEnabled = false {
        didSet {
            restartAudioEngineIfNeeded()
        }
    }
    @Published private(set) var bands = EqualizerBand.makeStandardBands()

    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published private(set) var defaultOutputUID: String?
    @Published private(set) var defaultSystemOutputUID: String?
    @Published private(set) var availableAudioSources: [AudioSourceItem] = [AudioSourceItem.systemMix] + AudioSourceItem.commonSources
    @Published var selectedOutputUID: String? {
        didSet {
            if let selectedOutputUID,
               let device = outputDevices.first(where: { $0.uid == selectedOutputUID }) {
                setSelectedOutputNameIfNeeded(device.name)
            }
            applySelectedOutputAsSystemDefaultIfNeeded()
            if outputLockEnabled {
                enforceOutputLock()
            } else if lockStatus != .needsAttention {
                lockStatus = .unlocked
                lockMessage = "Output lock is off."
            }
            syncRoutingOutputNodes()
            restartAudioEngineIfNeeded()
        }
    }
    @Published var outputLockEnabled = false {
        didSet {
            if outputLockEnabled {
                enforceOutputLock()
                syncRoutingOutputNodes()
            } else {
                releaseSuppressedOutputs()
                restoreSystemDefaultToRenderOutput()
                lockStatus = .unlocked
                lockMessage = "Output lock is off."
                syncRoutingOutputNodes()
            }
            restartAudioEngineIfNeeded()
        }
    }
    @Published private(set) var lockStatus: OutputLockStatus = .unlocked
    @Published private(set) var lockMessage = "Output lock is off."
    @Published private(set) var selectedOutputName = "No output selected"
    @Published var routingNodes: [RoutingNode] = []
    @Published var routingConnections: [RoutingConnection] = []
    @Published var selectedRoutingNodeID: RoutingNode.ID?
    @Published var activeEQNodeID: RoutingNode.ID?
    @Published var patchStartNodeID: RoutingNode.ID?
    @Published private(set) var eqFileMessage: String?
    @Published private(set) var audioEngineRunState: AudioEngineRunState = .stopped
    private(set) var audioEngineTelemetry: AudioEngineTelemetry = .empty

    private let audioService = AudioOutputService()
    private let audioEngine = AudioEngineService()
    private let persistenceQueue = DispatchQueue(label: "PureQ.Persistence", qos: .utility)
    private var pollTimer: Timer?
    private var engineTelemetryTimer: Timer?
    private var autoStartWorkItem: DispatchWorkItem?
    private var persistenceWorkItem: DispatchWorkItem?
    private var persistenceSaveToken: UUID?
    private var lastQueuedSessionSnapshot: PureQSessionSnapshot?
    private var lastWrittenSessionSnapshot: PureQSessionSnapshot?
    private var isRestoringPersistentState = false
    private var lastAutoStartFailureSignature: String?
    private var isStartingAudioEngine = false
    private var manualStopSuppressesAutoStart = false
    private var suppressedOutputUIDs = Set<String>()
    private var isApplyingSelectedOutputDefault = false
    private var manualMode: EqualizerMode = .expert
    private var manualPreamp: Double = 0
    private var manualBalance: Double = 0
    private var manualBands = EqualizerBand.makeStandardBands()
    private var manualAutoGainEnabled = true

    var visibleBands: [EqualizerBand] {
        let visibleFrequencies = Set(mode.frequencies)
        return sortedBands(bands.filter { visibleFrequencies.contains($0.slotFrequency) || $0.isCustom })
    }

    func visibleEQBands(for node: RoutingNode) -> [EqualizerBand] {
        let visibleFrequencies = Set(node.eqMode.frequencies)
        return sortedBands(node.eqBands.filter { visibleFrequencies.contains($0.slotFrequency) || $0.isCustom })
    }

    func bandActivityLevel(for frequency: Double) -> Double {
        telemetryStore.bandActivityLevel(for: frequency)
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
        bandLayoutTitle(for: activeEQMode)
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
        return "\(activeEQNode.eqMode.rawValue) / \(activeCount) active / \(autoLabel)"
    }

    var hardwareOutputDevices: [AudioOutputDevice] {
        outputDevices.filter { !$0.isPureQVirtualOutput }
    }

    var pureQVirtualOutputDevice: AudioOutputDevice? {
        outputDevices.first(where: \.isPureQVirtualOutput)
    }

    var selectedOutput: AudioOutputDevice? {
        guard let selectedOutputUID else { return nil }
        return hardwareOutputDevices.first(where: { $0.uid == selectedOutputUID })
    }

    var defaultOutputName: String {
        outputDevices.first(where: { $0.uid == defaultOutputUID })?.name ?? "Unknown output"
    }

    var menuBarSystemImage: String {
        if outputLockEnabled && lockStatus == .guarding {
            return "speaker.slash.fill"
        }
        if outputLockEnabled {
            return "lock.fill"
        }
        return powerEnabled ? "slider.horizontal.3" : "power"
    }

    var readinessItems: [TestReadinessItem] {
        [
            sourceReadiness,
            engineReadiness,
            outputDeviceReadiness,
            selectedOutputReadiness,
            outputLockReadiness,
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
        let renderOutput = renderOutputDevice
        let virtualCapture = virtualCaptureDeviceForEngine
        return audioEngine.makeConfiguration(
            enabled: powerEnabled,
            bands: bands,
            preamp: preamp,
            balance: balance,
            sources: availableAudioSources,
            nodes: routingNodes,
            connections: routingConnections,
            outputUID: renderOutput?.uid,
            outputName: renderOutput?.name ?? selectedOutputName,
            virtualCaptureUID: virtualCapture?.uid,
            virtualCaptureName: virtualCapture?.name,
            processedTakeoverEnabled: audioEngineTakeoverActive
        )
    }

    var audioEngineStatus: AudioEngineStatus {
        audioEngine.evaluate(audioEngineConfiguration)
    }

    var canStartAudioEngine: Bool {
        audioEngineStatus.state != .blocked && renderOutputDevice != nil
    }

    var audioEngineTakeoverActive: Bool {
        if outputLockEnabled {
            return audioEngine.processTapsAvailable
        }

        if processedTakeoverEnabled {
            return true
        }

        guard let renderOutputUID = renderOutputDevice?.uid else {
            return false
        }
        return defaultOutputUID == renderOutputUID || defaultSystemOutputUID == renderOutputUID
    }

    init() {
        refreshAudioSources()
        refreshAudioDevices(enforceLock: false)
        if !restorePersistedSessionIfAvailable() {
            seedRoutingGraphIfNeeded()
        }
        startDevicePolling()
        scheduleAutoStartIfNeeded()
    }

    deinit {
        pollTimer?.invalidate()
        engineTelemetryTimer?.invalidate()
        autoStartWorkItem?.cancel()
        persistenceWorkItem?.cancel()
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
        let file = try decoder.decode(EQProfileFile.self, from: data)
        guard file.schemaVersion <= EQProfileFile.currentSchemaVersion else {
            throw EQProfileFileError.unsupportedVersion(file.schemaVersion)
        }
        let profile = try sanitizedProfile(file.profile)
        applyProfileToActiveEQ(profile)
        eqFileMessage = "Imported \(profile.title)."
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
            sanitizedNode.eqBands = sanitizedBands(node.eqBands)
            sanitizedNode.eqManualBands = sanitizedBands(node.eqManualBands.isEmpty ? node.eqBands : node.eqManualBands)
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

        let cleanedBands = sanitizedBands(profile.bands)
        let cleanedManualBands = sanitizedBands(profile.manualBands.isEmpty ? profile.bands : profile.manualBands)
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

    func setMode(_ newMode: EqualizerMode) {
        mode = newMode
        applyAutoGainIfNeeded()
        saveMainManualProfileIfNeeded()
        syncLinkedEQNodes()
        syncRoutingOutputNodes()
        updateAudioEngineRendering()
    }

    func applySelection(_ newSelection: EqualizerSelection) {
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
        preamp = value.clamped(to: -20...20)
        selection = .manual
        saveMainManualProfile()
        syncLinkedEQNodes()
        updateAudioEngineRendering()
    }

    func setBalance(_ value: Double) {
        balance = value.clamped(to: -1...1)
        selection = .manual
        saveMainManualProfile()
        syncLinkedEQNodes()
        updateAudioEngineRendering()
    }

    func setAutoGain(_ enabled: Bool) {
        autoGainEnabled = enabled
        applyAutoGainIfNeeded()
        selection = .manual
        saveMainManualProfile()
        syncLinkedEQNodes()
        updateAudioEngineRendering()
    }

    func setBandGain(id: EqualizerBand.ID, gain: Double, persist: Bool = true) {
        updateBand(id: id) { band in
            band.gain = gain.clamped(to: -20...20)
        }
        selection = .manual
        applyAutoGainIfNeeded()
        saveMainManualProfile()
        syncLinkedEQNodes()
        updateAudioEngineRendering(scheduleSave: persist)
    }

    func setBandFrequency(id: EqualizerBand.ID, frequency: Double) {
        updateBand(id: id) { band in
            band.frequency = frequency.clamped(to: 20...20_000)
        }
        sortBands(&bands)
        selection = .manual
        saveMainManualProfile()
        syncLinkedEQNodes()
        updateAudioEngineRendering()
    }

    func setBandQ(id: EqualizerBand.ID, q: Double, persist: Bool = true) {
        updateBand(id: id) { band in
            band.q = q.clamped(to: 0.1...10)
        }
        selection = .manual
        saveMainManualProfile()
        syncLinkedEQNodes()
        updateAudioEngineRendering(scheduleSave: persist)
    }

    func addBand() {
        let frequency = suggestedCustomBandFrequency(in: bands)
        bands.append(EqualizerBand(frequency: frequency, gain: 0, q: 0.5, isCustom: true))
        sortBands(&bands)
        selection = .manual
        saveMainManualProfile()
        syncLinkedEQNodes()
        updateAudioEngineRendering()
    }

    func toggleBand(id: EqualizerBand.ID) {
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
        updateBand(id: id) { band in
            band.isStereoLinked.toggle()
        }
        selection = .manual
        saveMainManualProfile()
        syncLinkedEQNodes()
        updateAudioEngineRendering()
    }

    func cycleShape(id: EqualizerBand.ID) {
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

    func setProcessedTakeover(_ enabled: Bool) {
        processedTakeoverEnabled = enabled
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

        if let selectedOutputUID,
           let device = hardwareOutputDevices.first(where: { $0.uid == selectedOutputUID }) {
            setSelectedOutputNameIfNeeded(device.name)
        } else if let selectedOutputUID,
                  outputDevices.first(where: { $0.uid == selectedOutputUID })?.isPureQVirtualOutput == true {
            setSelectedOutputUIDIfNeeded(preferredHardwareOutputDevice?.uid)
            setSelectedOutputNameIfNeeded(preferredHardwareOutputDevice?.name ?? "No hardware output selected")
        } else if !outputLockEnabled {
            setSelectedOutputUIDIfNeeded(preferredHardwareOutputDevice?.uid)
            if let selectedOutputUID = self.selectedOutputUID,
               let device = hardwareOutputDevices.first(where: { $0.uid == selectedOutputUID }) {
                setSelectedOutputNameIfNeeded(device.name)
            } else {
                setSelectedOutputNameIfNeeded("No hardware output selected")
            }
        }

        if !outputLockEnabled && outputDefaultsIncludePureQVirtualOutput {
            restoreSystemDefaultToRenderOutput()
            return
        }

        if enforceLock {
            enforceOutputLock()
        }
        syncRoutingOutputNodes()
        if previousTakeoverActive != audioEngineTakeoverActive {
            restartAudioEngineIfNeeded()
        } else {
            scheduleAutoStartIfNeeded()
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
        refreshAudioDevices(enforceLock: outputLockEnabled)
        selectDefaultEQNodeIfNeeded()

        let virtualCapture = virtualCaptureDeviceForEngine
        let switchedDefaultToVirtual = virtualCapture != nil ? switchSystemDefaultToVirtualOutputForEngine() : false
        do {
            try audioEngine.startRendering(
                configuration: audioEngineConfiguration,
                outputDeviceID: renderOutputDevice?.audioObjectID,
                captureDeviceID: virtualCapture?.audioObjectID
            )
            lastAutoStartFailureSignature = nil
            setAudioEngineRunState(audioEngine.runState)
            refreshAudioEngineTelemetry()
            startEngineTelemetryPolling()
        } catch {
            if switchedDefaultToVirtual {
                restoreSystemDefaultToRenderOutput()
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
        setAudioEngineRunState(audioEngine.runState)
        stopEngineTelemetryPolling()
        refreshAudioEngineTelemetry()
        if !outputLockEnabled {
            restoreSystemDefaultToRenderOutput()
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
        audioEngine.updateRendering(configuration: audioEngineConfiguration)
        setAudioEngineRunState(audioEngine.runState)
        refreshAudioEngineTelemetry()
    }

    private func setAudioEngineRunState(_ newValue: AudioEngineRunState) {
        guard audioEngineRunState != newValue else { return }
        audioEngineRunState = newValue
    }

    private func setSelectedOutputUIDIfNeeded(_ newValue: String?) {
        guard selectedOutputUID != newValue else { return }
        selectedOutputUID = newValue
    }

    private func setSelectedOutputNameIfNeeded(_ newValue: String) {
        guard selectedOutputName != newValue else { return }
        selectedOutputName = newValue
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
            nodeSignature,
            connectionSignature
        ].joined(separator: "#")
    }

    func enforceOutputLock() {
        guard outputLockEnabled else {
            lockStatus = .unlocked
            lockMessage = "Output lock is off."
            return
        }

        guard let selectedOutputUID else {
            lockStatus = .needsAttention
            lockMessage = "Choose an output to lock."
            return
        }

        if outputDevices.first(where: { $0.uid == selectedOutputUID })?.isPureQVirtualOutput == true {
            lockStatus = .needsAttention
            lockMessage = "Choose speakers/headphones as the render output. PureQ Virtual Output is the system capture output."
            return
        }

        let targetAvailable = hardwareOutputDevices.contains(where: { $0.uid == selectedOutputUID })
        if audioEngine.processTapsAvailable {
            if targetAvailable {
                let changedDefault = outputDefaultsNeedChanging(to: selectedOutputUID)
                let madeDefault = changedDefault ? audioService.setDefaultOutput(uid: selectedOutputUID) : true
                _ = audioService.setMute(uid: selectedOutputUID, muted: false)
                releaseSuppressedOutputs()

                if changedDefault && !madeDefault {
                    lockStatus = .needsAttention
                    lockMessage = "Could not switch macOS back to \(selectedOutputName)."
                } else {
                    lockStatus = .locked
                    lockMessage = "Locked to \(selectedOutputName). PureQ is using process-tap takeover."
                }

                if changedDefault {
                    refreshAudioDevices(enforceLock: false)
                }
                return
            }

            let defaultUIDs = activeOutputDefaultUIDs.filter { $0 != selectedOutputUID }
            guard !defaultUIDs.isEmpty else {
                lockStatus = .guarding
                lockMessage = "Waiting for \(selectedOutputName) to reconnect."
                return
            }

            var failedUIDs: [String] = []
            for uid in defaultUIDs {
                if audioService.setMute(uid: uid, muted: true) {
                    suppressedOutputUIDs.insert(uid)
                } else {
                    failedUIDs.append(uid)
                }
            }

            if failedUIDs.isEmpty {
                lockStatus = .guarding
                lockMessage = "Muted undesired output until \(selectedOutputName) reconnects."
                refreshAudioDevices(enforceLock: false)
            } else {
                let failedName = outputDevices.first(where: { $0.uid == failedUIDs[0] })?.name ?? "the current output"
                lockStatus = .needsAttention
                lockMessage = "\(failedName) does not expose a mute control."
            }
            return
        }

        if let virtualOutput = pureQVirtualOutputDevice {
            let changedDefault = outputDefaultsNeedChanging(to: virtualOutput.uid)
            let madeDefault = changedDefault ? audioService.setDefaultOutput(uid: virtualOutput.uid) : true

            if targetAvailable {
                _ = audioService.setMute(uid: selectedOutputUID, muted: false)
            }
            releaseSuppressedOutputs()

            if changedDefault && !madeDefault {
                lockStatus = .needsAttention
                lockMessage = "Could not switch macOS to PureQ Virtual Output."
            } else if targetAvailable {
                lockStatus = .locked
                lockMessage = "System output is PureQ Virtual Output; rendering to \(selectedOutputName)."
            } else {
                lockStatus = .guarding
                lockMessage = "System output is held on PureQ Virtual Output until \(selectedOutputName) reconnects."
            }

            if changedDefault && madeDefault {
                refreshAudioDevices(enforceLock: false)
            }
            return
        }

        if targetAvailable {
            let changedDefault = outputDefaultsNeedChanging(to: selectedOutputUID)
            let madeDefault = changedDefault ? audioService.setDefaultOutput(uid: selectedOutputUID) : true
            _ = audioService.setMute(uid: selectedOutputUID, muted: false)
            releaseSuppressedOutputs()

            if changedDefault && !madeDefault {
                lockStatus = .needsAttention
                lockMessage = "Could not switch macOS back to \(selectedOutputName)."
            } else {
                lockStatus = .locked
                lockMessage = "Locked to \(selectedOutputName)."
            }

            if changedDefault {
                refreshAudioDevices(enforceLock: false)
            }
            return
        }

        guard let defaultOutputUID, defaultOutputUID != selectedOutputUID else {
            lockStatus = .guarding
            lockMessage = "Waiting for \(selectedOutputName) to reconnect."
            return
        }

        let muted = audioService.setMute(uid: defaultOutputUID, muted: true)
        if muted {
            suppressedOutputUIDs.insert(defaultOutputUID)
            lockStatus = .guarding
            lockMessage = "Muted \(defaultOutputName) until \(selectedOutputName) reconnects."
            refreshAudioDevices(enforceLock: false)
        } else {
            lockStatus = .needsAttention
            lockMessage = "\(defaultOutputName) does not expose a mute control."
        }
    }

    func addSourceRoutingNode(sourceID: String) {
        let source = availableAudioSources.first(where: { $0.id == sourceID }) ?? .systemMix
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

    func addRoutingNode(kind: RoutingNodeKind) {
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

    func addOutputRoutingNode(uid: String?) {
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
        selectedRoutingNodeID = node.id
        restartAudioEngineIfNeeded()
        schedulePersistedStateSave()
    }

    func removeRoutingNode(id: RoutingNode.ID) {
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
        routingConnections.removeAll { $0.from == id || $0.to == id }
        restartAudioEngineIfNeeded()
        schedulePersistedStateSave()
    }

    func renameRoutingNode(id: RoutingNode.ID, title: String) {
        guard let index = routingNodes.firstIndex(where: { $0.id == id }) else { return }
        routingNodes[index].title = title.isEmpty ? routingNodes[index].kind.title : title
        schedulePersistedStateSave()
    }

    func setRoutingNodeKind(id: RoutingNode.ID, kind: RoutingNodeKind) {
        guard let index = routingNodes.firstIndex(where: { $0.id == id }) else {
            return
        }

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
        updateEQNode(id: id) { node in
            node.eqMode = newMode
            applyAutoGainIfNeeded(to: &node)
            saveManualProfileIfNeeded(for: &node)
        }
    }

    func applyEQNodeSelection(id: RoutingNode.ID, selection newSelection: EqualizerSelection) {
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
        updateEQNode(id: id) { node in
            node.eqPreamp = value.clamped(to: -20...20)
            node.eqSelection = .manual
            saveManualProfile(for: &node)
        }
    }

    func setEQNodeBalance(id: RoutingNode.ID, balance value: Double) {
        updateEQNode(id: id) { node in
            node.eqBalance = value.clamped(to: -1...1)
            node.eqSelection = .manual
            saveManualProfile(for: &node)
        }
    }

    func setEQNodeAutoGain(id: RoutingNode.ID, enabled: Bool) {
        updateEQNode(id: id) { node in
            node.eqAutoGainEnabled = enabled
            applyAutoGainIfNeeded(to: &node)
            node.eqSelection = .manual
            saveManualProfile(for: &node)
        }
    }

    func setEQNodeBandGain(nodeID: RoutingNode.ID, bandID: EqualizerBand.ID, gain: Double, persist: Bool = true) {
        updateEQNodeBand(nodeID: nodeID, bandID: bandID, scheduleSave: persist) { band in
            band.gain = gain.clamped(to: -20...20)
        }
    }

    func setEQNodeBandFrequency(nodeID: RoutingNode.ID, bandID: EqualizerBand.ID, frequency: Double) {
        updateEQNodeBand(nodeID: nodeID, bandID: bandID, sortAfterMutation: true) { band in
            band.frequency = frequency.clamped(to: 20...20_000)
        }
    }

    func setEQNodeBandQ(nodeID: RoutingNode.ID, bandID: EqualizerBand.ID, q: Double, persist: Bool = true) {
        updateEQNodeBand(nodeID: nodeID, bandID: bandID, scheduleSave: persist) { band in
            band.q = q.clamped(to: 0.1...10)
        }
    }

    func addEQNodeBand(nodeID: RoutingNode.ID) {
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
        updateEQNode(id: id) { node in
            resetBandsToFlat(&node.eqBands)
            node.eqPreamp = 0
            node.eqBalance = 0
            node.eqSelection = .manual
            saveManualProfile(for: &node)
        }
    }

    func toggleEQNodeBand(nodeID: RoutingNode.ID, bandID: EqualizerBand.ID) {
        updateEQNodeBand(nodeID: nodeID, bandID: bandID) { band in
            band.isEnabled.toggle()
        }
    }

    func toggleEQNodeStereoLink(nodeID: RoutingNode.ID, bandID: EqualizerBand.ID) {
        updateEQNodeBand(nodeID: nodeID, bandID: bandID) { band in
            band.isStereoLinked.toggle()
        }
    }

    func cycleEQNodeBandShape(nodeID: RoutingNode.ID, bandID: EqualizerBand.ID) {
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

    func routeToOutputNode(id: RoutingNode.ID) {
        guard let node = routingNodes.first(where: { $0.id == id }),
              node.kind == .output,
              let uid = node.audioOutputUID,
              hardwareOutputDevices.contains(where: { $0.uid == uid }) else {
            return
        }
        selectedOutputUID = uid
        syncRoutingOutputNodes()
        schedulePersistedStateSave()
    }

    func resetRoutingGraph() {
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

    private func startEngineTelemetryPolling() {
        engineTelemetryTimer?.invalidate()
        let interval = highFrameRateUIEnabled ? (1.0 / 60.0) : (1.0 / 18.0)
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
        telemetryStore.publish(snapshot, smoothMeters: highFrameRateUIEnabled)
    }

    private func applySelectedOutputAsSystemDefaultIfNeeded() {
        guard !outputLockEnabled,
              !isApplyingSelectedOutputDefault,
              let selectedOutputUID,
              hardwareOutputDevices.contains(where: { $0.uid == selectedOutputUID }),
              outputDefaultsNeedChanging(to: selectedOutputUID) else {
            return
        }

        isApplyingSelectedOutputDefault = true
        defer { isApplyingSelectedOutputDefault = false }

        if audioService.setDefaultOutput(uid: selectedOutputUID) {
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
            if let device = hardwareOutputDevices.first(where: { $0.uid == selectedOutputUID }) {
                setSelectedOutputNameIfNeeded(device.name)
            }
            lockStatus = .unlocked
            lockMessage = "System output switched to \(selectedOutputName)."
        } else {
            lockStatus = .needsAttention
            lockMessage = "Could not switch macOS to \(selectedOutputName)."
        }
    }

    @discardableResult
    private func switchSystemDefaultToVirtualOutputForEngine() -> Bool {
        guard !audioEngine.processTapsAvailable else {
            return false
        }

        guard let virtualOutput = pureQVirtualOutputDevice else {
            return false
        }

        guard outputDefaultsNeedChanging(to: virtualOutput.uid) else {
            return false
        }

        let changed = audioService.setDefaultOutput(uid: virtualOutput.uid)
        if changed {
            refreshAudioDevices(enforceLock: false)
            lockMessage = "System output is PureQ Virtual Output; rendering to \(selectedOutputName)."
            if outputLockEnabled {
                lockStatus = .locked
            }
        }
        return changed
    }

    private func restoreSystemDefaultToRenderOutput() {
        guard let selectedOutputUID,
              hardwareOutputDevices.contains(where: { $0.uid == selectedOutputUID }),
              outputDefaultsIncludePureQVirtualOutput else {
            return
        }

        if audioService.setDefaultOutput(uid: selectedOutputUID) {
            refreshAudioDevices(enforceLock: false)
            lockStatus = outputLockEnabled ? lockStatus : .unlocked
            lockMessage = outputLockEnabled ? lockMessage : "Output lock is off."
        }
    }

    private func releaseSuppressedOutputs(except retainedUID: String? = nil) {
        for uid in suppressedOutputUIDs where uid != retainedUID {
            _ = audioService.setMute(uid: uid, muted: false)
        }
        suppressedOutputUIDs = suppressedOutputUIDs.filter { $0 == retainedUID }
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

    private var activeOutputDefaultUIDs: Set<String> {
        Set([defaultOutputUID, defaultSystemOutputUID].compactMap(\.self))
    }

    private func bandLayoutTitle(for mode: EqualizerMode) -> String {
        switch mode {
        case .basic:
            return "10 Bands"
        case .advanced:
            return "15 Bands"
        case .expert:
            return "31 Bands"
        }
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
            applyAutoGainIfNeeded(to: &node)
            saveManualProfile(for: &node)
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
        let bus = RoutingNode(title: "PureQ Bus", subtitle: "Stereo bus", kind: .bus, position: CGPoint(x: 400, y: 150), isProtected: true)
        let eq = RoutingNode(
            title: "Equalizer",
            subtitle: "\(mode.rawValue) / \(visibleBands.count) bands",
            kind: .equalizer,
            position: CGPoint(x: 655, y: 150),
            isProtected: true,
            eqMode: mode,
            eqSelection: selection,
            eqPreamp: preamp,
            eqBalance: balance,
            eqBands: bands,
            eqUsesMainEqualizer: false
        )
        let guardNode = RoutingNode(title: "Output Guard", subtitle: lockStatus.title, kind: .guardNode, position: CGPoint(x: 910, y: 150), isProtected: true)

        routingNodes = [source, bus, eq, guardNode]
        routingConnections = [
            RoutingConnection(from: source.id, to: bus.id),
            RoutingConnection(from: bus.id, to: eq.id),
            RoutingConnection(from: eq.id, to: guardNode.id)
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
                setRoutingNodeSubtitleIfNeeded(
                    at: index,
                    subtitle: "\(linkLabel) / \(routingNodes[index].eqMode.rawValue) / \(visibleCount) bands / \(activeCount) active"
                )
            case .guardNode:
                setRoutingNodeSubtitleIfNeeded(at: index, subtitle: lockStatus.title)
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

        let outputUID = renderOutputDevice?.uid
        guard let outputUID else { return }

        if !routingNodes.contains(where: { $0.audioOutputUID == outputUID }) {
            addOutputRoutingNode(uid: outputUID)
        }

        guard let guardNode = routingNodes.first(where: { $0.kind == .guardNode }),
              let outputNode = routingNodes.first(where: { $0.audioOutputUID == outputUID }) else {
            return
        }

        if !routingConnections.contains(where: { $0.from == guardNode.id && $0.to == outputNode.id }) {
            let connection = RoutingConnection(from: guardNode.id, to: outputNode.id)
            if isValidRoutingConnection(connection) {
                routingConnections.append(connection)
            }
        }
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
        case .guardNode: return lockStatus.title
        case .output: return "Device output"
        case .monitor: return "Meter tap"
        }
    }

    private func outputSubtitle(for device: AudioOutputDevice?) -> String {
        guard let device else { return "Unassigned device" }
        let labels = [
            device.uid == selectedOutputUID ? "Desired" : nil,
            device.isDefaultOutput ? "Default" : nil,
            device.isDefaultSystemOutput ? "System" : nil,
            device.isMuted ? "Muted" : nil,
            "\(device.channelCount) ch"
        ].compactMap(\.self)
        return labels.joined(separator: " / ")
    }

    private var preferredHardwareOutputDevice: AudioOutputDevice? {
        if let defaultOutputUID,
           let defaultHardwareOutput = hardwareOutputDevices.first(where: { $0.uid == defaultOutputUID }) {
            return defaultHardwareOutput
        }
        return hardwareOutputDevices.first
    }

    private var renderOutputDevice: AudioOutputDevice? {
        if let selectedOutput {
            return selectedOutput
        }
        if outputLockEnabled && selectedOutputUID != nil {
            return nil
        }
        return preferredHardwareOutputDevice
    }

    private var virtualCaptureDeviceForEngine: AudioOutputDevice? {
        guard outputLockEnabled, !audioEngine.processTapsAvailable else {
            return nil
        }
        return pureQVirtualOutputDevice
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

    private var selectedOutputReadiness: TestReadinessItem {
        guard selectedOutputUID != nil else {
            return TestReadinessItem(
                id: "selected-output",
                title: "Desired Output",
                detail: "Choose an output before testing output lock.",
                state: .caution
            )
        }

        if let selectedOutputUID,
           outputDevices.first(where: { $0.uid == selectedOutputUID })?.isPureQVirtualOutput == true {
            return TestReadinessItem(
                id: "selected-output",
                title: "Desired Output",
                detail: "PureQ Virtual Output is the system capture output. Choose speakers, headphones, or another hardware output for rendering.",
                state: .blocked
            )
        }

        return TestReadinessItem(
            id: "selected-output",
            title: "Desired Output",
            detail: "Render target: \(selectedOutputName)",
            state: selectedOutput == nil ? .caution : .ready
        )
    }

    private var outputLockReadiness: TestReadinessItem {
        TestReadinessItem(
            id: "output-lock",
            title: "Output Lock",
            detail: outputLockEnabled ? lockMessage : "Toggle Lock to keep macOS on the desired hardware output and mute unwanted fallback outputs.",
            state: outputLockEnabled ? (lockStatus == .needsAttention ? .caution : .ready) : .caution
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

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

extension Color {
    static let pureQBackground = Color(red: 0.09, green: 0.10, blue: 0.12)
    static let pureQPanel = Color(red: 0.15, green: 0.16, blue: 0.18)
    static let pureQControl = Color(red: 0.10, green: 0.11, blue: 0.13)
    static let pureQStroke = Color.white.opacity(0.10)
    static let pureQGreen = Color(red: 0.34, green: 0.64, blue: 0.51)
    static let pureQAmber = Color(red: 0.98, green: 0.75, blue: 0.10)
    static let pureQOrange = Color(red: 1.00, green: 0.34, blue: 0.08)
}
