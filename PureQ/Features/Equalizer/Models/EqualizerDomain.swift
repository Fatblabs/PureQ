//
//  EqualizerDomain.swift
//  PureQ
//

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

enum EqualizerBandLayout: String, CaseIterable, Identifiable {
    case bands10
    case bands31
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bands10: return "10 Bands"
        case .bands31: return "31 Bands"
        case .custom: return "Custom"
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

enum PureQUndoScope {
    case equalizer
    case routing
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

enum EQClippingRisk: Equatable {
    case safe
    case caution
    case clipping
}

struct EQClippingStatus: Equatable {
    let peakDecibels: Double

    var risk: EQClippingRisk {
        if peakDecibels > 0.05 { return .clipping }
        if peakDecibels > -1.0 { return .caution }
        return .safe
    }

    var headroomDecibels: Double {
        max(0, -peakDecibels)
    }

    var clipAmountDecibels: Double {
        max(0, peakDecibels)
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
    var sourceVolume: Double?
    var sourceMuted: Bool?
    var sourceSoloed: Bool?
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
        sourceVolume: Double? = nil,
        sourceMuted: Bool? = nil,
        sourceSoloed: Bool? = nil,
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
        self.sourceVolume = sourceVolume
        self.sourceMuted = sourceMuted
        self.sourceSoloed = sourceSoloed
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

extension RoutingNode {
    var sourceVolumeValue: Double {
        get { (sourceVolume ?? 1).clamped(to: 0...2) }
        set { sourceVolume = newValue.clamped(to: 0...2) }
    }

    var sourceMutedValue: Bool {
        get { sourceMuted ?? false }
        set { sourceMuted = newValue }
    }

    var sourceSoloedValue: Bool {
        get { sourceSoloed ?? false }
        set { sourceSoloed = newValue }
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
