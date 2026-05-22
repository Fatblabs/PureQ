//
//  StatusFooter.swift
//  PureQ
//

import SwiftUI

struct StatusFooter: View {
    @EnvironmentObject private var model: EqualizerModel
    @Binding var showingConsole: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            footerContent(showDetail: true, showTelemetry: true)
            footerContent(showDetail: false, showTelemetry: true)
            footerContent(showDetail: false, showTelemetry: false)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(red: 0.11, green: 0.12, blue: 0.14))
    }

    private func footerContent(showDetail: Bool, showTelemetry: Bool) -> some View {
        HStack {
            Button {
                showingConsole.toggle()
            } label: {
                Label("Console", systemImage: showingConsole ? "terminal.fill" : "terminal")
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.readinessSummary == .ready ? .secondary : model.readinessSummary.tint)

            Label(model.powerEnabled ? "Processing enabled" : "Bypassed", systemImage: model.powerEnabled ? "checkmark.circle.fill" : "pause.circle.fill")
                .foregroundStyle(model.powerEnabled ? Color.pureQGreen : .secondary)

            Text("\(model.activeEQVisibleBands.count) active controls")
                .foregroundStyle(.secondary)

            Text("Engine: \(model.audioEngineStatus.title)")
                .foregroundStyle(model.audioEngineStatus.state == .ready ? Color.pureQGreen : Color.pureQAmber)

            Text("Render: \(model.audioEngineRunState.title)")
                .foregroundStyle(model.audioEngineRunState == .running ? Color.pureQGreen : .secondary)

            Text(renderModeLabel)
                .foregroundStyle(renderModeTint)

            if showTelemetry {
                TelemetryFooterText(isRunning: model.audioEngineRunState == .running)
            }

            Spacer()

            if showDetail {
                Text(statusDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var statusDetail: String {
        if case .failed = model.audioEngineRunState {
            return model.audioEngineRunState.detail
        }
        return model.audioEngineStatus.detail
    }

    private var renderModeLabel: String {
        return model.audioEngineTakeoverActive ? "Takeover" : "Monitor"
    }

    private var renderModeTint: Color {
        return model.audioEngineTakeoverActive ? Color.pureQAmber : .secondary
    }
}

struct TelemetryFooterText: View {
    @EnvironmentObject private var telemetry: AudioTelemetryStore
    let isRunning: Bool

    var body: some View {
        if isRunning {
            Text(telemetry.telemetry.summary)
                .foregroundStyle(.secondary)
        }
    }
}

