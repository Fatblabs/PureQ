//
//  DebugWorkspace.swift
//  PureQ
//

import AppKit
import Combine
import SwiftUI

struct DebugWorkspace: View {
    @EnvironmentObject private var model: EqualizerModel
    @State private var reportText = ""
    @State private var lastGeneratedAt: Date?
    @State private var copyAcknowledgementUntil = Date.distantPast

    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle("Debug mode", isOn: $model.debugModeEnabled)
                    .toggleStyle(.switch)
                    .font(.callout.weight(.semibold))

                Divider()
                    .frame(height: 24)
                    .overlay(Color.pureQStroke)

                statusPill

                Spacer()

                Button {
                    refreshReport()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(RouteToolbarButtonStyle())
                .disabled(!model.debugModeEnabled)

                Button {
                    copyReportToPasteboard()
                } label: {
                    Label(copyButtonTitle, systemImage: "doc.on.doc")
                }
                .buttonStyle(RouteToolbarButtonStyle())
                .disabled(reportText.isEmpty)

                Button {
                    reportText = ""
                    lastGeneratedAt = nil
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(RouteToolbarButtonStyle())
                .disabled(reportText.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(red: 0.11, green: 0.12, blue: 0.14))

            Divider()
                .overlay(Color.pureQStroke)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $reportText)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    .scrollContentBackground(.hidden)
                    .background(Color.pureQBackground)
                    .padding(10)

                if reportText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: model.debugModeEnabled ? "doc.text.magnifyingglass" : "power")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(model.debugModeEnabled ? Color.pureQGreen : .secondary)

                        Text(model.debugModeEnabled ? "Waiting for snapshot..." : "Debug mode is off.")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.82))

                        Text(model.debugModeEnabled ? "The next refresh will populate this console." : "Turn it on manually when you want a diagnostic snapshot.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(28)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.pureQBackground)
        .onAppear {
            if model.debugModeEnabled {
                refreshReport()
            }
        }
        .onChange(of: model.debugModeEnabled) { _, isEnabled in
            if isEnabled {
                refreshReport()
            } else {
                reportText = ""
                lastGeneratedAt = nil
            }
        }
        .onReceive(refreshTimer) { _ in
            guard model.debugModeEnabled else { return }
            refreshReport()
        }
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            Image(systemName: model.debugModeEnabled ? "checkmark.circle.fill" : "pause.circle")
                .foregroundStyle(model.debugModeEnabled ? Color.pureQGreen : .secondary)
            Text(statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(model.debugModeEnabled ? Color.pureQGreen : .secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Color.pureQControl, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.pureQStroke, lineWidth: 1)
        )
    }

    private var statusText: String {
        guard model.debugModeEnabled else {
            return "Manual"
        }
        guard let lastGeneratedAt else {
            return "Waiting"
        }
        return "Updated \(lastGeneratedAt.formatted(date: .omitted, time: .standard))"
    }

    private var copyButtonTitle: String {
        Date() < copyAcknowledgementUntil ? "Copied" : "Copy"
    }

    private func refreshReport() {
        reportText = model.makeDebugReport()
        lastGeneratedAt = Date()
    }

    private func copyReportToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reportText, forType: .string)
        copyAcknowledgementUntil = Date().addingTimeInterval(1.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if Date() >= copyAcknowledgementUntil {
                copyAcknowledgementUntil = .distantPast
            }
        }
    }
}

#Preview {
    let model = EqualizerModel()
    DebugWorkspace()
        .environmentObject(model)
        .environmentObject(model.telemetryStore)
}
