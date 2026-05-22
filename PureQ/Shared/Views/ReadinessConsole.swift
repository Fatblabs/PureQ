//
//  ReadinessConsole.swift
//  PureQ
//

import SwiftUI

struct ReadinessConsole: View {
    @EnvironmentObject private var model: EqualizerModel
    @Binding var isPresented: Bool
    @State private var showingDriverUninstallConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: model.readinessSummary.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(model.readinessSummary.tint)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Readiness Console")
                        .font(.headline.weight(.semibold))
                    Text(consoleSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Toggle("Auto-start", isOn: $model.autoStartEngineEnabled)
                    .toggleStyle(.switch)
                    .font(.caption.weight(.semibold))

                Button {
                    model.refreshAudioDevices()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(RouteToolbarButtonStyle())

                if model.audioEngineStatus.driverBundled || model.audioEngineStatus.driverInstalled {
                    Menu {
                        Button {
                            model.installBundledAudioDriver()
                        } label: {
                            Label(driverInstallButtonTitle, systemImage: "externaldrive.badge.plus")
                        }
                        .disabled(model.driverInstallInProgress || !model.audioEngineStatus.driverBundled)

                        if model.audioEngineStatus.driverInstalled {
                            Button(role: .destructive) {
                                showingDriverUninstallConfirmation = true
                            } label: {
                                Label("Uninstall Driver", systemImage: "trash")
                            }
                            .disabled(model.driverInstallInProgress)
                        }
                    } label: {
                        Label("Driver", systemImage: model.driverInstallInProgress ? "hourglass" : "externaldrive")
                    }
                    .menuStyle(.button)
                    .buttonStyle(RouteToolbarButtonStyle())
                    .disabled(model.driverInstallInProgress && !model.audioEngineStatus.driverInstalled)
                    .help("Install, repair, or remove the bundled PureQ HAL audio driver")
                }

                Button {
                    if model.audioEngineRunState == .running {
                        model.stopAudioEngine()
                    } else {
                        model.startAudioEngine()
                    }
                } label: {
                    Label(
                        model.audioEngineRunState == .running ? "Stop Engine" : "Start Engine",
                        systemImage: model.audioEngineRunState == .running ? "stop.fill" : "play.fill"
                    )
                }
                .buttonStyle(RouteToolbarButtonStyle())
                .disabled(!model.canStartAudioEngine && model.audioEngineRunState != .running)

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(size: 32))
                .help("Close console")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            if let driverInstallMessage = model.driverInstallMessage {
                HStack(spacing: 8) {
                    Image(systemName: model.driverInstallInProgress ? "hourglass" : "info.circle")
                        .foregroundStyle(model.driverInstallInProgress ? Color.pureQAmber : Color.pureQGreen)
                    Text(driverInstallMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            Divider()
                .overlay(Color.pureQStroke)

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 8) {
                    ForEach(consoleItems) { item in
                        ReadinessConsoleRow(item: item)
                    }
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 218)
        .background(Color(red: 0.09, green: 0.10, blue: 0.12))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.pureQStroke)
                .frame(height: 1)
        }
        .confirmationDialog("Uninstall PureQ Audio Driver?", isPresented: $showingDriverUninstallConfirmation, titleVisibility: .visible) {
            Button("Uninstall Driver", role: .destructive) {
                model.uninstallAudioDriver()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes PureQ.driver from /Library/Audio/Plug-Ins/HAL and restarts CoreAudio.")
        }
    }

    private var consoleItems: [TestReadinessItem] {
        let actionable = model.readinessItems.filter { $0.state != .ready }
        return actionable.isEmpty ? model.readinessItems : actionable
    }

    private var driverInstallButtonTitle: String {
        if model.driverInstallInProgress {
            return "Working"
        }
        return model.audioEngineStatus.driverInstalled ? "Repair Driver" : "Install Driver"
    }

    private var consoleSummary: String {
        switch model.readinessSummary {
        case .ready:
            return model.audioEngineStatus.detail
        case .caution:
            return "Configuration is usable, but one or more items should be checked."
        case .blocked:
            return "PureQ cannot start until the blocked item is fixed."
        }
    }
}

struct ReadinessCard: View {
    let item: TestReadinessItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.state.systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(item.state.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.title)
                        .font(.headline.weight(.semibold))
                    Spacer()
                    Text(item.state.title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(item.state.tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(item.state.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                Text(item.detail)
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
                .stroke(item.state.tint.opacity(0.35), lineWidth: 1)
        )
    }
}
struct ReadinessConsoleRow: View {
    let item: TestReadinessItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.state.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(item.state.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.title)
                        .font(.callout.weight(.semibold))
                    Text(item.state.title)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(item.state.tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(item.state.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Spacer()
                }

                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.pureQPanel.opacity(0.72), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(item.state.tint.opacity(0.24), lineWidth: 1)
        )
    }
}

