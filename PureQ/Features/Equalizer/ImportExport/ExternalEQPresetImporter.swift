//
//  ExternalEQPresetImporter.swift
//  PureQ
//

import Foundation

struct ExternalEQPresetImportResult {
    let profile: EQProfileSnapshot
    let importedBandCount: Int
    let skippedBandCount: Int
    let unsupportedFilterCount: Int

    var statusMessage: String {
        var parts = ["Imported \(profile.title) (\(importedBandCount) bands)."]
        if skippedBandCount > 0 {
            parts.append("Skipped \(skippedBandCount) out-of-range or duplicate bands.")
        }
        if unsupportedFilterCount > 0 {
            parts.append("Mapped \(unsupportedFilterCount) unsupported filter types to bell bands.")
        }
        return parts.joined(separator: " ")
    }
}

enum ExternalEQPresetImportError: LocalizedError {
    case unsupportedFormat
    case emptyPreset

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "This file is not a supported EQ preset."
        case .emptyPreset:
            return "This EQ preset does not contain any importable bands."
        }
    }
}

enum EqualiserPresetImporter {
    static func importProfile(from data: Data, decoder: JSONDecoder) throws -> ExternalEQPresetImportResult {
        let preset = try decodePreset(from: data, decoder: decoder)
        return try makeImportResult(from: preset)
    }

    private static func decodePreset(from data: Data, decoder: JSONDecoder) throws -> EqualiserPreset {
        if let preset = try? decoder.decode(EqualiserPreset.self, from: data) {
            return preset
        }

        if let presets = try? decoder.decode([EqualiserPreset].self, from: data),
           let preset = presets.first {
            return preset
        }

        throw ExternalEQPresetImportError.unsupportedFormat
    }

    private static func makeImportResult(from preset: EqualiserPreset) throws -> ExternalEQPresetImportResult {
        let canonicalBands = canonicalBands(from: preset.settings)
        var skippedBandCount = canonicalBands.skippedBandCount
        var unsupportedFilterCount = 0
        var importedBands: [EqualizerBand] = []
        var seenFrequencyKeys = Set<Int>()

        for sourceBand in canonicalBands.bands {
            guard sourceBand.frequency >= 20, sourceBand.frequency <= 20_000 else {
                skippedBandCount += 1
                continue
            }

            let frequencyKey = Int((sourceBand.frequency * 100).rounded())
            guard seenFrequencyKeys.insert(frequencyKey).inserted else {
                skippedBandCount += 1
                continue
            }

            let filterMapping = sourceBand.filterType.bandShape
            if filterMapping.wasApproximated {
                unsupportedFilterCount += 1
            }

            importedBands.append(
                EqualizerBand(
                    slotFrequency: sourceBand.frequency,
                    frequency: sourceBand.frequency,
                    gain: sourceBand.gain,
                    q: sourceBand.q,
                    isEnabled: !preset.settings.globalBypass && !sourceBand.bypass,
                    isStereoLinked: canonicalBands.isStereoLinked,
                    shape: filterMapping.shape,
                    isCustom: !EqualizerBand.isStandardFrequency(sourceBand.frequency)
                )
            )
        }

        importedBands.sort { $0.frequency < $1.frequency }

        guard !importedBands.isEmpty else {
            throw ExternalEQPresetImportError.emptyPreset
        }

        let mode = mode(for: importedBands)
        let preamp = preset.settings.inputGain + preset.settings.outputGain
        let title = preset.metadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = EQProfileSnapshot(
            title: title.isEmpty ? "Imported EQ Preset" : title,
            mode: mode,
            selection: .manual,
            preamp: preamp,
            balance: 0,
            autoGainEnabled: false,
            bands: importedBands,
            manualMode: mode,
            manualPreamp: preamp,
            manualBalance: 0,
            manualBands: importedBands,
            manualAutoGainEnabled: false
        )

        return ExternalEQPresetImportResult(
            profile: profile,
            importedBandCount: importedBands.count,
            skippedBandCount: skippedBandCount,
            unsupportedFilterCount: unsupportedFilterCount
        )
    }

    private static func canonicalBands(from settings: EqualiserPresetSettings) -> (
        bands: [EqualiserPresetBand],
        isStereoLinked: Bool,
        skippedBandCount: Int
    ) {
        let leftBands = settings.leftBands.isEmpty ? settings.legacyBands : settings.leftBands
        let rightBands = settings.rightBands.isEmpty ? leftBands : settings.rightBands
        guard !leftBands.isEmpty else {
            return (rightBands, true, 0)
        }

        let channelMode = settings.channelMode.lowercased()
        if channelMode == "linked" || rightBands.isEmpty || leftBands.isAudiblyEquivalent(to: rightBands) {
            return (leftBands, true, 0)
        }

        guard leftBands.count == rightBands.count else {
            return (leftBands, false, rightBands.count)
        }

        let merged = zip(leftBands, rightBands).map { left, right in
            left.merged(with: right)
        }
        return (merged, false, 0)
    }

    private static func mode(for bands: [EqualizerBand]) -> EqualizerMode {
        if bands.matches(frequencies: EqualizerMode.basic.frequencies) {
            return .basic
        }
        return .expert
    }
}

private struct EqualiserPreset: Decodable {
    let version: Int
    let metadata: EqualiserPresetMetadata
    let settings: EqualiserPresetSettings

    private enum CodingKeys: String, CodingKey {
        case version
        case metadata
        case settings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 2
        metadata = try container.decodeIfPresent(EqualiserPresetMetadata.self, forKey: .metadata) ?? .init()
        settings = try container.decode(EqualiserPresetSettings.self, forKey: .settings)
    }
}

private struct EqualiserPresetMetadata: Decodable {
    var name = "Imported EQ Preset"

    private enum CodingKeys: String, CodingKey {
        case name
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Imported EQ Preset"
    }
}

private struct EqualiserPresetSettings: Decodable {
    let globalBypass: Bool
    let inputGain: Double
    let outputGain: Double
    let channelMode: String
    let leftBands: [EqualiserPresetBand]
    let rightBands: [EqualiserPresetBand]
    let legacyBands: [EqualiserPresetBand]

    private enum CodingKeys: String, CodingKey {
        case globalBypass
        case inputGain
        case outputGain
        case channelMode
        case leftBands
        case rightBands
        case bands
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        globalBypass = try container.decodeIfPresent(Bool.self, forKey: .globalBypass) ?? false
        inputGain = try container.decodeIfPresent(Double.self, forKey: .inputGain) ?? 0
        outputGain = try container.decodeIfPresent(Double.self, forKey: .outputGain) ?? 0
        channelMode = try container.decodeIfPresent(String.self, forKey: .channelMode) ?? "linked"
        leftBands = try container.decodeIfPresent([EqualiserPresetBand].self, forKey: .leftBands) ?? []
        rightBands = try container.decodeIfPresent([EqualiserPresetBand].self, forKey: .rightBands) ?? []
        legacyBands = try container.decodeIfPresent([EqualiserPresetBand].self, forKey: .bands) ?? []
    }
}

private struct EqualiserPresetBand: Decodable {
    let frequency: Double
    let q: Double
    let gain: Double
    let filterType: EqualiserFilterType
    let bypass: Bool

    private enum CodingKeys: String, CodingKey {
        case frequency
        case q
        case bandwidth
        case gain
        case filterType
        case bypass
    }

    init(
        frequency: Double,
        q: Double,
        gain: Double,
        filterType: EqualiserFilterType,
        bypass: Bool
    ) {
        self.frequency = frequency
        self.q = q
        self.gain = gain
        self.filterType = filterType
        self.bypass = bypass
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frequency = try container.decode(Double.self, forKey: .frequency)
        gain = try container.decodeIfPresent(Double.self, forKey: .gain) ?? 0
        bypass = try container.decodeIfPresent(Bool.self, forKey: .bypass) ?? false

        if let qValue = try container.decodeIfPresent(Double.self, forKey: .q) {
            q = qValue
        } else if let bandwidth = try container.decodeIfPresent(Double.self, forKey: .bandwidth) {
            q = Self.q(fromBandwidth: bandwidth)
        } else {
            q = 0.5
        }

        if let typeString = try? container.decode(String.self, forKey: .filterType) {
            filterType = EqualiserFilterType(codingKey: typeString)
        } else if let typeValue = try? container.decode(Int.self, forKey: .filterType) {
            filterType = EqualiserFilterType(rawValue: typeValue)
        } else {
            filterType = .parametric
        }
    }

    func merged(with other: EqualiserPresetBand) -> EqualiserPresetBand {
        EqualiserPresetBand(
            frequency: abs(frequency - other.frequency) < 0.01 ? frequency : (frequency + other.frequency) / 2,
            q: (q + other.q) / 2,
            gain: (gain + other.gain) / 2,
            filterType: filterType == other.filterType ? filterType : .parametric,
            bypass: bypass && other.bypass
        )
    }

    func isAudiblyEquivalent(to other: EqualiserPresetBand) -> Bool {
        abs(frequency - other.frequency) < 0.01 &&
            abs(q - other.q) < 0.001 &&
            abs(gain - other.gain) < 0.001 &&
            filterType == other.filterType &&
            bypass == other.bypass
    }

    private static func q(fromBandwidth bandwidth: Double) -> Double {
        guard bandwidth > 0 else { return 0.5 }
        return 1 / (2 * sinh(log(2) * bandwidth / 2))
    }
}

private enum EqualiserFilterType: Equatable {
    case parametric
    case lowPass
    case highPass
    case lowShelf
    case highShelf
    case bandPass
    case notch

    init(codingKey: String) {
        switch codingKey {
        case "Bell":
            self = .parametric
        case "LP", "RLP":
            self = .lowPass
        case "HP", "RHP":
            self = .highPass
        case "LS", "RLS":
            self = .lowShelf
        case "HS", "RHS":
            self = .highShelf
        case "BP":
            self = .bandPass
        case "Notch":
            self = .notch
        default:
            self = .parametric
        }
    }

    init(rawValue: Int) {
        switch rawValue {
        case 1, 7:
            self = .lowPass
        case 2, 8:
            self = .highPass
        case 3, 9:
            self = .lowShelf
        case 4, 10:
            self = .highShelf
        case 5:
            self = .bandPass
        case 6:
            self = .notch
        default:
            self = .parametric
        }
    }

    var bandShape: (shape: BandShape, wasApproximated: Bool) {
        switch self {
        case .parametric:
            return (.bell, false)
        case .lowShelf, .highShelf:
            return (.shelf, false)
        case .notch:
            return (.notch, false)
        case .lowPass, .highPass, .bandPass:
            return (.bell, true)
        }
    }
}

private extension Array where Element == EqualiserPresetBand {
    func isAudiblyEquivalent(to other: [EqualiserPresetBand]) -> Bool {
        guard count == other.count else { return false }
        return zip(self, other).allSatisfy { left, right in
            left.isAudiblyEquivalent(to: right)
        }
    }
}

private extension Array where Element == EqualizerBand {
    func matches(frequencies: [Double]) -> Bool {
        let sortedBands = sorted { $0.frequency < $1.frequency }
        guard sortedBands.count == frequencies.count else {
            return false
        }

        return zip(sortedBands, frequencies).allSatisfy { band, frequency in
            abs(band.frequency - frequency) < 0.01
        }
    }
}
