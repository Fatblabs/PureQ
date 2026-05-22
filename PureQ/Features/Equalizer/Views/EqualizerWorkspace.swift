//
//  EqualizerWorkspace.swift
//  PureQ
//

import SwiftUI

struct EqualizerWorkspace: View {
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                EQTargetBar()
                PresetBar()
                EqualizerGraphHost()
                    .layoutPriority(2)
                PreampRow()
                BandScroller()
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EqualizerGraphHost: View {
    @EnvironmentObject private var model: EqualizerModel
    @EnvironmentObject private var telemetryStore: AudioTelemetryStore

    var body: some View {
        GeometryReader { proxy in
            let graphSize = graphSize(for: proxy.size)
            let contentWidth = graphSize.width + 58

            ScrollView(.horizontal, showsIndicators: contentWidth > proxy.size.width) {
                HStack(alignment: .top, spacing: 10) {
                    Spacer(minLength: 0)
                    graph(size: graphSize)
                    GraphToolToggles()
                        .padding(.top, 2)
                    Spacer(minLength: 0)
                }
                .frame(minWidth: max(proxy.size.width, contentWidth + 24), alignment: .center)
                .padding(.top, 10)
            }
            .scrollDisabled(contentWidth <= proxy.size.width)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(
            minHeight: max(245, 310 * CGFloat(model.graphHeightScale)),
            idealHeight: max(310, 445 * CGFloat(model.graphHeightScale)),
            maxHeight: max(360, 555 * CGFloat(model.graphHeightScale))
        )
        .background(Color.pureQBackground)
    }

    private func graph(size: CGSize) -> some View {
        EqualizerGraph(
            bands: model.activeEQGraphBands,
            preamp: model.activeEQPreamp,
            responseSampleRate: model.audioEngineSampleRate,
            spectrumLevels: model.spectrumAnalyzerEnabled ? telemetryStore.telemetry.spectrumLevels : [],
            bandEditingEnabled: model.graphBandEditingEnabled,
            onBandPositionChange: { id, frequency, gain in
                model.setActiveEQBandGraphPosition(id: id, frequency: frequency, gain: gain, persist: false)
            },
            onBandPositionCommit: { id, frequency, gain in
                model.setActiveEQBandGraphPosition(id: id, frequency: frequency, gain: gain, persist: true)
            }
        )
        .frame(width: size.width, height: size.height)
    }

    private func graphSize(for availableSize: CGSize) -> CGSize {
        let height = (availableSize.height - 28).clamped(to: 220...720)
        let baseWidth = min(max(height * 1.55, 565), 1_026)
        let width = (baseWidth * CGFloat(model.graphWidthScale)).clamped(to: 420...1_800)
        return CGSize(width: width, height: height)
    }
}

struct GraphToolToggles: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 7) {
                buttons
            }

            HStack(spacing: 7) {
                buttons
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        GraphScaleButton()
        GraphToggleButton(
            isEnabled: $model.spectrumAnalyzerEnabled,
            title: "FFT",
            systemImage: "waveform.path.ecg",
            help: "Toggle FFT spectrum analyzer"
        )
        GraphToggleButton(
            isEnabled: $model.soundIndicatorsEnabled,
            title: "Meters",
            systemImage: "chart.bar.fill",
            help: "Toggle band activity indicators"
        )
        GraphToggleButton(
            isEnabled: $model.graphBandEditingEnabled,
            title: "Drag",
            systemImage: "hand.draw",
            help: "Drag enabled EQ points on the graph"
        )
    }
}

struct GraphScaleButton: View {
    @EnvironmentObject private var model: EqualizerModel
    @State private var showingPopover = false

    private var isCustomized: Bool {
        abs(model.graphWidthScale - 1) > 0.001 || abs(model.graphHeightScale - 1) > 0.001
    }

    var body: some View {
        Button {
            showingPopover.toggle()
        } label: {
            Label("Size", systemImage: "arrow.up.left.and.arrow.down.right")
                .labelStyle(.iconOnly)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(IconButtonStyle(size: 34, active: isCustomized))
        .help("Adjust graph size")
        .popover(isPresented: $showingPopover, arrowEdge: .trailing) {
            GraphScalePopover()
                .environmentObject(model)
        }
    }
}

struct GraphScalePopover: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Graph Size")
                .font(.headline.weight(.semibold))

            GraphScaleSlider(
                title: "Width",
                value: Binding(
                    get: { model.graphWidthScale },
                    set: { model.setGraphWidthScale($0) }
                )
            )

            GraphScaleSlider(
                title: "Height",
                value: Binding(
                    get: { model.graphHeightScale },
                    set: { model.setGraphHeightScale($0) }
                )
            )

            Button("Reset") {
                model.resetGraphScale()
            }
            .buttonStyle(PillButtonStyle(active: false))
        }
        .padding(14)
        .frame(width: 250)
        .background(Color.pureQBackground)
    }
}

private struct GraphScaleSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
            }

            Slider(value: $value, in: 0.75...1.65, step: 0.05)
                .tint(Color.pureQGreen)
        }
    }
}

struct GraphToggleButton: View {
    @Binding var isEnabled: Bool
    let title: String
    let systemImage: String
    let help: String

    var body: some View {
        Button {
            isEnabled.toggle()
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(IconButtonStyle(size: 34, active: isEnabled))
        .help(help)
    }
}
