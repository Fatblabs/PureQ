//
//  AboutWorkspace.swift
//  PureQ
//

import SwiftUI

struct AboutWorkspace: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.below.square.filled.and.square")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.pureQGreen)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("PureQ")
                            .font(.title2.weight(.bold))
                        Text("A local macOS equalizer and node-based audio router for system, app, and output-device workflows.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                    AboutInfoPanel(
                        title: "Audio Path",
                        systemImage: "waveform.path.ecg",
                        detail: "PureQ captures eligible macOS/app audio, applies the selected node EQ chain, then renders to the desired hardware output. EQ nodes can keep unique profiles."
                    )
                    AboutInfoPanel(
                        title: "PureQ Virtual Output",
                        systemImage: "speaker.badge.exclamationmark",
                        detail: "This is a capture/fallback device, not the speaker/headphone destination. On modern macOS, process taps are preferred; the virtual output remains for compatibility and recovery paths."
                    )
                    AboutInfoPanel(
                        title: "Implicit Routing",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        detail: "The node graph is the source of truth. Connected output nodes receive processed audio; disconnected or removed output nodes receive silence."
                    )
                    AboutInfoPanel(
                        title: "Local Processing",
                        systemImage: "desktopcomputer",
                        detail: "Routing, EQ, metering, and output switching run locally through CoreAudio APIs. There is no cloud audio processing path in this app."
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Current Runtime")
                        .font(.headline.weight(.semibold))

                    Label("Engine: \(model.audioEngineStatus.title)", systemImage: model.audioEngineStatus.state == .ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.audioEngineStatus.state == .ready ? Color.pureQGreen : Color.pureQAmber)

                    Label("Render outputs: \(model.routingRenderOutputSummary)", systemImage: "speaker.wave.2.fill")
                        .foregroundStyle(.secondary)

                    Label(model.autoStartEngineEnabled ? "Auto-start is enabled for ready routing graphs." : "Auto-start is disabled; use the console or menu controls to start rendering.", systemImage: model.autoStartEngineEnabled ? "bolt.fill" : "bolt.slash")
                        .foregroundStyle(model.autoStartEngineEnabled ? Color.pureQGreen : .secondary)

                    Text(model.audioEngineStatus.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.pureQPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.pureQStroke, lineWidth: 1)
                )

                Spacer(minLength: 0)
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.pureQBackground)
    }
}

struct AboutInfoPanel: View {
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Color.pureQGreen)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(Color.pureQPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.pureQStroke, lineWidth: 1)
        )
    }
}

