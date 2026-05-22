//
//  MenuBarView.swift
//  PureQ
//

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: EqualizerModel

    private let popoverWidth: CGFloat = 430
    private let popoverHeight: CGFloat = 640

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("PureQ", systemImage: model.menuBarSystemImage)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.pureQGreen)
                        Spacer()
                        Toggle("", isOn: $model.powerEnabled)
                            .toggleStyle(PowerToggleStyle())
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Preset")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(model.activeEQSelection.title)
                                .foregroundStyle(.secondary)
                        }

                        Picker("Preset", selection: Binding(get: {
                            model.activeEQSelection
                        }, set: { selection in
                            model.applyActiveEQSelection(selection)
                        })) {
                            ForEach(EqualizerSelection.profileOptions) { selection in
                                Text(selection.title).tag(selection)
                            }
                        }
                        .labelsHidden()

                        BandLayoutMenu()

                        Slider(value: Binding(get: {
                            model.activeEQPreamp
                        }, set: { value in
                            model.setActiveEQPreamp(value)
                        }), in: -20...20) {
                            Text("Preamp")
                        }
                        .tint(Color.pureQGreen)

                        Toggle("Auto preamp", isOn: Binding(get: {
                            model.activeEQAutoGainEnabled
                        }, set: { enabled in
                            model.setActiveEQAutoGain(enabled)
                        }))
                        .toggleStyle(.switch)
                    }

                    MenuBarEQBandPanel()

                    HStack {
                        Button("Refresh") {
                            model.refreshAudioDevices()
                        }
                        Spacer()
                        Button("Open PureQ") {
                            PureQWindowController.shared.showMainWindow()
                        }
                        .keyboardShortcut("o")
                    }
                }
                .padding(16)
            }
        }
        .frame(width: popoverWidth, height: popoverHeight)
        .background(Color.pureQBackground)
    }
}

struct MenuBarEQBandPanel: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EqualizerGraph(
                bands: model.activeEQGraphBands,
                preamp: model.activeEQPreamp,
                responseSampleRate: model.audioEngineSampleRate,
                spectrumLevels: []
            )
                .frame(height: 148)
                .background(Color.pureQBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.pureQStroke, lineWidth: 1)
                )

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 7) {
                    ForEach(model.activeEQVisibleBands) { band in
                        MenuBarBandStrip(
                            band: band,
                            onFrequencyChange: { model.setActiveEQBandFrequency(id: band.id, frequency: $0) },
                            onGainChange: { model.setActiveEQBandGain(id: band.id, gain: $0, persist: false) },
                            onGainCommit: { model.setActiveEQBandGain(id: band.id, gain: $0, persist: true) },
                            onQCommit: { model.setActiveEQBandQ(id: band.id, q: $0, persist: true) },
                            onToggleEnabled: { model.toggleActiveEQBand(id: band.id) },
                            onCycleShape: { model.cycleActiveEQShape(id: band.id) }
                        )
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 4)
            }
            .frame(height: 230)
        }
    }
}

struct MenuBarBandStrip: View {
    let band: EqualizerBand
    let onFrequencyChange: (Double) -> Void
    let onGainChange: (Double) -> Void
    let onGainCommit: (Double) -> Void
    let onQCommit: (Double) -> Void
    let onToggleEnabled: () -> Void
    let onCycleShape: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Button(action: onToggleEnabled) {
                    Image(systemName: band.isEnabled ? "checkmark" : "xmark")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(MiniToggleButtonStyle(active: band.isEnabled))
                .help(band.isEnabled ? "Disable band" : "Enable band")

                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(colorForBand)
                    .frame(width: 17, height: 17)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(.black.opacity(0.45), lineWidth: 1.5)
                    )
            }

            Button(action: onCycleShape) {
                Image(systemName: band.shape.systemImage)
            }
            .buttonStyle(PillButtonStyle(active: true))
            .help("Cycle filter shape")

            BandValueField(
                value: band.frequency,
                range: 20...20_000,
                suffix: "Hz",
                decimals: band.frequency >= 1_000 ? 0 : 1,
                compact: true,
                onCommit: onFrequencyChange
            )

            VerticalFader(
                value: band.gain,
                range: -20...20,
                meterFrequency: band.frequency,
                isEnabled: band.isEnabled,
                onChange: onGainChange,
                onEditingEnded: onGainCommit
            )
            .frame(height: 104)
            .opacity(band.isEnabled ? 1 : 0.36)

            BandValueField(
                value: band.gain,
                range: -20...20,
                suffix: "dB",
                decimals: 1,
                compact: true,
                onCommit: onGainCommit
            )

            BandValueField(
                value: band.q,
                range: 0.1...10,
                prefix: "Q:",
                suffix: "",
                decimals: 3,
                compact: true,
                onCommit: onQCommit
            )
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 6)
        .frame(width: 62, height: 222)
        .background(Color(red: 0.20, green: 0.21, blue: 0.23), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.pureQStroke, lineWidth: 1)
        )
    }

    private var colorForBand: Color {
        let fraction = min(max((log10(band.frequency) - log10(20)) / (log10(20_000) - log10(20)), 0), 1)
        return Color(hue: 0.04 + fraction * 0.12, saturation: 0.95, brightness: 1.0)
    }
}
