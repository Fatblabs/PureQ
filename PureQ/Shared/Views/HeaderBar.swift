//
//  HeaderBar.swift
//  PureQ
//

import SwiftUI

struct HeaderBar: View {
    @EnvironmentObject private var model: EqualizerModel
    @State private var showingSettings = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullHeader
            compactHeader
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(red: 0.12, green: 0.13, blue: 0.15))
    }

    private var fullHeader: some View {
        HStack(spacing: 10) {
            powerAndSettings

            Spacer(minLength: 8)

            Text("Bands:")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.secondary)

            BandLayoutMenu()
                .frame(width: 150)

            Spacer(minLength: 8)

            Button {
                model.refreshAudioDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(IconButtonStyle(size: 34))
            .help("Refresh audio outputs")

            Button {
                NSApplication.shared.keyWindow?.miniaturize(nil)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(IconButtonStyle(size: 34))
            .help("Minimize")
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 8) {
            powerAndSettings

            Spacer(minLength: 4)

            BandLayoutMenu()
                .frame(width: 132)

            Spacer(minLength: 4)

            Button {
                model.refreshAudioDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(IconButtonStyle(size: 32))
            .help("Refresh audio outputs")

            Button {
                NSApplication.shared.keyWindow?.miniaturize(nil)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(IconButtonStyle(size: 32))
            .help("Minimize")
        }
    }

    private var powerAndSettings: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $model.powerEnabled)
                .toggleStyle(PowerToggleStyle())
                .help(model.powerEnabled ? "Disable equalizer" : "Enable equalizer")

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
            }
            .buttonStyle(IconButtonStyle(size: 34))
            .help("Settings")
            .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                SettingsPopover()
                    .environmentObject(model)
            }
        }
    }
}

struct SettingsPopover: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.headline.weight(.semibold))

            Toggle("Power", isOn: $model.powerEnabled)
                .toggleStyle(.switch)

            Toggle("Auto-start engine", isOn: $model.autoStartEngineEnabled)
                .toggleStyle(.switch)
                .help("Start rendering automatically when the routing graph is ready.")

            Toggle("Auto preamp", isOn: Binding(get: {
                model.activeEQAutoGainEnabled
            }, set: { enabled in
                model.setActiveEQAutoGain(enabled)
            }))
            .toggleStyle(.switch)

            Toggle("Smooth visualizers", isOn: $model.highFrameRateUIEnabled)
                .toggleStyle(.switch)
                .help("Use full-rate FFT and meter updates while visual tools are visible.")

            BandLayoutMenu()

            Picker("Preset", selection: Binding(get: {
                model.activeEQSelection
            }, set: { selection in
                model.applyActiveEQSelection(selection)
            })) {
                ForEach(EqualizerSelection.profileOptions) { selection in
                    Text(selection.title).tag(selection)
                }
            }

            Button("Refresh Outputs") {
                model.refreshAudioDevices()
            }
        }
        .padding(16)
        .frame(width: 260)
    }
}

