//
//  ContentView.swift
//  PureQ
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let pureQEQProfile = UTType(filenameExtension: "pureqeq") ?? .json
}

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case equalizer = "Equalizer"
    case routing = "Routing"
    case about = "About"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .equalizer: return "slider.horizontal.3"
        case .routing: return "point.topleft.down.curvedto.point.bottomright.up"
        case .about: return "info.circle"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: EqualizerModel
    @State private var selectedWorkspace: WorkspaceTab = .equalizer
    @State private var showingConsole = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            WorkspaceSwitcher(selectedWorkspace: $selectedWorkspace)

            Group {
                switch selectedWorkspace {
                case .equalizer:
                    EqualizerWorkspace()
                case .routing:
                    RoutingWorkspace()
                case .about:
                    AboutWorkspace()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showingConsole {
                ReadinessConsole(isPresented: $showingConsole)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            StatusFooter(showingConsole: $showingConsole)
        }
        .frame(minWidth: 760, minHeight: 620)
        .background(Color.pureQBackground)
        .foregroundStyle(.white.opacity(0.88))
        .background(ClickOutsideEditableTextFieldObserver())
        .onChange(of: model.readinessSummary) { _, newValue in
            if newValue == .blocked {
                showingConsole = true
            }
        }
        .onChange(of: model.audioEngineRunState) { _, newValue in
            if case .failed = newValue {
                showingConsole = true
            }
        }
    }
}

struct ClickOutsideEditableTextFieldObserver: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.installIfNeeded()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.installIfNeeded()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        private var monitor: Any?

        func installIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                guard let window = event.window,
                      let contentView = window.contentView else {
                    return event
                }

                let point = contentView.convert(event.locationInWindow, from: nil)
                let hitView = contentView.hitTest(point)
                if hitView?.isInsideEditableTextInput != true {
                    window.endEditing(for: nil)
                    window.makeFirstResponder(nil)
                }
                return event
            }
        }

        func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            remove()
        }
    }
}

private extension NSView {
    var isInsideEditableTextInput: Bool {
        var view: NSView? = self
        while let currentView = view {
            if let textField = currentView as? NSTextField, textField.isEditable {
                return true
            }
            if currentView is NSTextView {
                return true
            }
            view = currentView.superview
        }
        return false
    }
}

struct WorkspaceSwitcher: View {
    @Binding var selectedWorkspace: WorkspaceTab

    var body: some View {
        HStack(spacing: 12) {
            Picker("Workspace", selection: $selectedWorkspace) {
                ForEach(WorkspaceTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 284)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(red: 0.10, green: 0.11, blue: 0.13))
    }
}

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
                        title: "Output Lock",
                        systemImage: "lock.shield",
                        detail: "The lock keeps macOS pointed at the intended hardware output and suppresses unwanted fallback outputs when the selected device disappears."
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

                    Label("Render output: \(model.selectedOutputName)", systemImage: "speaker.wave.2.fill")
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

struct ReadinessConsole: View {
    @EnvironmentObject private var model: EqualizerModel
    @Binding var isPresented: Bool

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
    }

    private var consoleItems: [TestReadinessItem] {
        let actionable = model.readinessItems.filter { $0.state != .ready }
        return actionable.isEmpty ? model.readinessItems : actionable
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

struct EqualizerWorkspace: View {
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                OutputLockStrip()
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

    var body: some View {
        GeometryReader { proxy in
            let graphSize = graphSize(for: proxy.size)
            HStack {
                Spacer(minLength: 12)
                EqualizerGraph(bands: model.activeEQGraphBands, preamp: model.activeEQPreamp)
                    .pureQHardwareAccelerated(model.highFrameRateUIEnabled)
                    .frame(width: graphSize.width, height: graphSize.height)
                Spacer(minLength: 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 8)
        }
        .frame(minHeight: 230, idealHeight: 330, maxHeight: 410)
        .background(Color.pureQBackground)
    }

    private func graphSize(for availableSize: CGSize) -> CGSize {
        let height = min(max(availableSize.height - 16, 220), 360)
        let width = min(max(height * 1.55, 420), min(availableSize.width - 24, 760))
        return CGSize(width: max(width, 320), height: height)
    }
}

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

            Label(model.lockStatus.title, systemImage: model.lockStatus.systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(model.lockStatus.tint)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)

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

            Image(systemName: model.lockStatus.systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(model.lockStatus.tint)
                .help(model.lockStatus.title)

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

            Toggle("Output lock", isOn: $model.outputLockEnabled)
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

            Toggle("Processed takeover", isOn: Binding(get: {
                model.processedTakeoverEnabled
            }, set: { enabled in
                model.setProcessedTakeover(enabled)
            }))
            .toggleStyle(.switch)
            .help("Mute the tapped original source and listen to PureQ's rendered EQ path.")

            Toggle("60 fps UI", isOn: $model.highFrameRateUIEnabled)
                .toggleStyle(.switch)
                .help("Use isolated 60 fps meter polling without repainting the whole app.")

            if model.audioEngineTakeoverActive && !model.processedTakeoverEnabled {
                Label("Auto takeover is active because macOS and PureQ are rendering to the same output.", systemImage: "speaker.slash.fill")
                    .font(.caption)
                    .foregroundStyle(Color.pureQAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

struct OutputLockStrip: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullStrip
            compactStrip
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.pureQPanel)
    }

    private var fullStrip: some View {
        HStack(spacing: 10) {
            Label("Render Output", systemImage: model.outputLockEnabled ? "lock.fill" : "lock.open")
                .font(.callout.weight(.semibold))
                .foregroundStyle(model.outputLockEnabled ? Color.pureQGreen : .secondary)
                .frame(width: 116, alignment: .leading)

            Picker("Desired output", selection: Binding(get: {
                model.selectedOutputUID ?? ""
            }, set: { uid in
                model.selectedOutputUID = uid.isEmpty ? nil : uid
            })) {
                if let selectedUID = model.selectedOutputUID,
                   !model.hardwareOutputDevices.contains(where: { $0.uid == selectedUID }) {
                    Text("\(model.selectedOutputName) (disconnected)").tag(selectedUID)
                }

                if model.hardwareOutputDevices.isEmpty {
                    Text("No hardware outputs").tag("")
                } else {
                    ForEach(model.hardwareOutputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            }
            .labelsHidden()
            .frame(width: 226)

            Toggle("Lock", isOn: $model.outputLockEnabled)
                .toggleStyle(.switch)
                .font(.callout.weight(.semibold))

            Divider()
                .frame(height: 24)
                .overlay(Color.pureQStroke)

            Label("System: \(model.defaultOutputName)", systemImage: "speaker.wave.2.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text(model.lockMessage)
                .font(.callout)
                .foregroundStyle(model.lockStatus.tint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var compactStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: model.outputLockEnabled ? "lock.fill" : "lock.open")
                .font(.callout.weight(.semibold))
                .foregroundStyle(model.outputLockEnabled ? Color.pureQGreen : .secondary)

            Picker("Desired output", selection: Binding(get: {
                model.selectedOutputUID ?? ""
            }, set: { uid in
                model.selectedOutputUID = uid.isEmpty ? nil : uid
            })) {
                if let selectedUID = model.selectedOutputUID,
                   !model.hardwareOutputDevices.contains(where: { $0.uid == selectedUID }) {
                    Text("\(model.selectedOutputName) (disconnected)").tag(selectedUID)
                }

                if model.hardwareOutputDevices.isEmpty {
                    Text("No hardware outputs").tag("")
                } else {
                    ForEach(model.hardwareOutputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            }
            .labelsHidden()
            .frame(width: 210)

            Toggle("Lock", isOn: $model.outputLockEnabled)
                .toggleStyle(.switch)
                .font(.caption.weight(.semibold))

            Spacer(minLength: 4)

            Text(model.lockStatus.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(model.lockStatus.tint)
                .lineLimit(1)
        }
    }
}

struct EQTargetBar: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullBar
            compactBar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(red: 0.13, green: 0.14, blue: 0.16))
    }

    private var fullBar: some View {
        HStack(spacing: 10) {
            Label("EQ Target", systemImage: "slider.horizontal.3")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 116, alignment: .leading)

            Picker("EQ target", selection: Binding(get: {
                model.activeEQNode?.id
            }, set: { nodeID in
                model.setActiveEQNode(id: nodeID)
            })) {
                Text("Main Equalizer").tag(RoutingNode.ID?.none)
                ForEach(model.eqRoutingNodes) { node in
                    Text(node.title).tag(Optional(node.id))
                }
            }
            .labelsHidden()
            .frame(width: 226)

            if model.activeEQNode != nil {
                Label("Unique Profile", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.pureQGreen)

                Button {
                    model.copyMainEqualizerToActiveNode()
                } label: {
                    Label("Copy Main", systemImage: "doc.on.doc")
                }
                .buttonStyle(RouteToolbarButtonStyle())
                .help("Copy the main equalizer profile into this EQ node")
            }

            profileFileMenu(labelStyle: .titleAndIcon)

            Divider()
                .frame(height: 24)
                .overlay(Color.pureQStroke)

            Text(model.activeEQTitle)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)

            Text(model.activeEQProfileSummary)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let message = model.eqFileMessage {
                Text(message)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.pureQGreen)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
    }

    private var compactBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("EQ target", selection: Binding(get: {
                model.activeEQNode?.id
            }, set: { nodeID in
                model.setActiveEQNode(id: nodeID)
            })) {
                Text("Main Equalizer").tag(RoutingNode.ID?.none)
                ForEach(model.eqRoutingNodes) { node in
                    Text(node.title).tag(Optional(node.id))
                }
            }
            .labelsHidden()
            .frame(width: 210)

            if model.activeEQNode != nil {
                Button {
                    model.copyMainEqualizerToActiveNode()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(IconButtonStyle(size: 30))
                .help("Copy the main equalizer profile into this EQ node")
            }

            profileFileMenu(labelStyle: .iconOnly)

            Spacer(minLength: 4)

            Text(model.activeEQTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func profileFileMenu(labelStyle: EQProfileFileMenuLabelStyle) -> some View {
        switch labelStyle {
        case .titleAndIcon:
            Menu {
                profileFileMenuItems
            } label: {
                Label("EQ File", systemImage: "doc.badge.gearshape")
            }
            .buttonStyle(RouteToolbarButtonStyle())
            .help("Import or export the selected EQ profile")
        case .iconOnly:
            Menu {
                profileFileMenuItems
            } label: {
                Image(systemName: "doc.badge.gearshape")
            }
            .buttonStyle(IconButtonStyle(size: 30))
            .help("Import or export the selected EQ profile")
        }
    }

    @ViewBuilder
    private var profileFileMenuItems: some View {
        Button {
            importProfile()
        } label: {
            Label("Import EQ Profile...", systemImage: "square.and.arrow.down")
        }

        Button {
            exportProfile()
        } label: {
            Label("Export EQ Profile...", systemImage: "square.and.arrow.up")
        }
    }

    private func exportProfile() {
        let panel = NSSavePanel()
        panel.title = "Export PureQ EQ Profile"
        panel.nameFieldStringValue = "\(sanitizedFileName(model.activeEQTitle)).pureqeq"
        panel.allowedContentTypes = [.pureQEQProfile, .json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try model.exportActiveEQProfile(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.title = "Import PureQ EQ Profile"
        panel.allowedContentTypes = [.pureQEQProfile, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try model.importEQProfile(from: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func sanitizedFileName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let sanitized = name
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "PureQ EQ Profile" : sanitized
    }
}

private enum EQProfileFileMenuLabelStyle {
    case titleAndIcon
    case iconOnly
}

struct RoutingWorkspace: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        VStack(spacing: 0) {
            RoutingToolbar()

            HStack(spacing: 0) {
                EditableRoutingCanvas()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                RoutingInspector()
                    .frame(width: 318)
            }
        }
        .background(Color.pureQBackground)
    }
}

private enum RoutingNodeCardMetrics {
    static let width: CGFloat = 214
    static let height: CGFloat = 116
    static let halfWidth: CGFloat = width / 2
    static let halfHeight: CGFloat = height / 2
}

struct RoutingToolbar: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.availableAudioSources) { source in
                    Button {
                        model.addSourceRoutingNode(sourceID: source.id)
                    } label: {
                        Label(source.title, systemImage: source.systemImage)
                    }
                }
            } label: {
                Label("Source", systemImage: "music.note.list")
            }
            .buttonStyle(RouteToolbarButtonStyle())

            Menu {
                ForEach(RoutingNodeKind.allCases.filter { $0 != .source && $0 != .output && $0 != .monitor }) { kind in
                    Button {
                        model.addRoutingNode(kind: kind)
                    } label: {
                        Label(kind.title, systemImage: kind.systemImage)
                    }
                }
            } label: {
                Label("Processor", systemImage: "plus")
            }
            .buttonStyle(RouteToolbarButtonStyle())

            Menu {
                Button {
                    model.addOutputRoutingNode(uid: nil)
                } label: {
                    Label("Unassigned", systemImage: "speaker.wave.2")
                }
                Divider()
                ForEach(model.hardwareOutputDevices) { device in
                    Button(device.name) {
                        model.addOutputRoutingNode(uid: device.uid)
                    }
                }
            } label: {
                Label("Output", systemImage: "speaker.wave.2.fill")
            }
            .buttonStyle(RouteToolbarButtonStyle())

            Button {
                if let id = model.selectedRoutingNodeID {
                    model.disconnectRoutingNode(id: id)
                }
            } label: {
                Image(systemName: "link.slash")
            }
            .buttonStyle(IconButtonStyle(size: 34))
            .disabled(model.selectedRoutingNodeID == nil)
            .help("Disconnect selected node")

            Button {
                model.resetRoutingGraph()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(IconButtonStyle(size: 34))
            .help("Reset routing graph")

            Spacer()

            Label("\(model.routingNodes.count) nodes", systemImage: "square.stack.3d.up")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)

            Label("\(model.routingConnections.count) links", systemImage: "link")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)

            Divider()
                .frame(height: 24)
                .overlay(Color.pureQStroke)

            Label(model.lockStatus.title, systemImage: model.lockStatus.systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(model.lockStatus.tint)

            Toggle("Lock", isOn: $model.outputLockEnabled)
                .toggleStyle(.switch)
                .font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.pureQPanel)
    }
}

struct EditableRoutingCanvas: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        GeometryReader { proxy in
            let nodeMaxX = model.routingNodes
                .map { $0.position.x + RoutingNodeCardMetrics.halfWidth + 72 }
                .max() ?? 1_180
            let nodeMaxY = model.routingNodes
                .map { $0.position.y + RoutingNodeCardMetrics.halfHeight + 72 }
                .max() ?? 620
            let canvasSize = CGSize(
                width: max(proxy.size.width, 1_180, nodeMaxX),
                height: max(proxy.size.height, 620, nodeMaxY)
            )

            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                ZStack {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.selectedRoutingNodeID = nil
                            model.patchStartNodeID = nil
                        }

                    EditableRoutingWireCanvas(canvasSize: canvasSize)
                        .pureQHardwareAccelerated(model.highFrameRateUIEnabled)
                        .allowsHitTesting(false)

                    ForEach(model.routingNodes) { node in
                        EditableRoutingNodeCard(node: node, canvasSize: canvasSize)
                            .frame(width: RoutingNodeCardMetrics.width, height: RoutingNodeCardMetrics.height)
                            .position(node.position)
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .background(Color.pureQBackground)
                .coordinateSpace(name: "routingCanvas")
            }
            .background(Color.pureQBackground)
        }
    }
}

struct EditableRoutingWireCanvas: View {
    @EnvironmentObject private var model: EqualizerModel
    let canvasSize: CGSize

    var body: some View {
        Canvas { context, size in
            drawGrid(in: size, context: &context)

            for connection in model.routingConnections {
                guard let source = model.routingNodes.first(where: { $0.id == connection.from }),
                      let target = model.routingNodes.first(where: { $0.id == connection.to }) else {
                    continue
                }
                let endpoints = connectionEndpoints(from: source, to: target)
                drawConnection(
                    from: endpoints.start,
                    to: endpoints.end,
                    color: wireColor(from: source, to: target),
                    context: &context
                )
            }

            if let patchStartID = model.patchStartNodeID,
               let patchNode = model.routingNodes.first(where: { $0.id == patchStartID }) {
                let start = CGPoint(x: patchNode.position.x + RoutingNodeCardMetrics.halfWidth, y: patchNode.position.y)
                let end = CGPoint(x: min(size.width - 34, start.x + 128), y: start.y)
                drawConnection(from: start, to: end, color: Color.pureQAmber, dashed: true, context: &context)
            }
        }
    }

    private func connectionEndpoints(from source: RoutingNode, to target: RoutingNode) -> (start: CGPoint, end: CGPoint) {
        let dx = target.position.x - source.position.x
        let dy = target.position.y - source.position.y

        if abs(dy) > abs(dx), abs(dx) < RoutingNodeCardMetrics.width * 0.85 {
            let verticalDirection: CGFloat = dy >= 0 ? 1 : -1
            return (
                CGPoint(x: source.position.x, y: source.position.y + RoutingNodeCardMetrics.halfHeight * verticalDirection),
                CGPoint(x: target.position.x, y: target.position.y - RoutingNodeCardMetrics.halfHeight * verticalDirection)
            )
        }

        let horizontalDirection: CGFloat = dx >= 0 ? 1 : -1
        return (
            CGPoint(x: source.position.x + RoutingNodeCardMetrics.halfWidth * horizontalDirection, y: source.position.y),
            CGPoint(x: target.position.x - RoutingNodeCardMetrics.halfWidth * horizontalDirection, y: target.position.y)
        )
    }

    private func drawGrid(in size: CGSize, context: inout GraphicsContext) {
        let spacing: CGFloat = 24
        var path = Path()

        stride(from: CGFloat(0), through: size.width, by: spacing).forEach { x in
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }

        stride(from: CGFloat(0), through: size.height, by: spacing).forEach { y in
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }

        context.stroke(path, with: .color(.white.opacity(0.035)), lineWidth: 1)
    }

    private func drawConnection(
        from start: CGPoint,
        to end: CGPoint,
        color: Color,
        dashed: Bool = false,
        context: inout GraphicsContext
    ) {
        var path = Path()
        path.move(to: start)

        if abs(end.y - start.y) > abs(end.x - start.x) {
            let direction: CGFloat = end.y >= start.y ? 1 : -1
            let controlOffset = min(max(abs(end.y - start.y) * 0.42, 72), 170)
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x, y: start.y + (controlOffset * direction)),
                control2: CGPoint(x: end.x, y: end.y - (controlOffset * direction))
            )
        } else {
            let direction: CGFloat = end.x >= start.x ? 1 : -1
            let controlOffset = min(max(abs(end.x - start.x) * 0.42, 96), 210)
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x + (controlOffset * direction), y: start.y),
                control2: CGPoint(x: end.x - (controlOffset * direction), y: end.y)
            )
        }

        context.stroke(
            path,
            with: .color(.black.opacity(0.34)),
            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round, dash: dashed ? [7, 6] : [])
        )
        context.stroke(
            path,
            with: .color(color.opacity(dashed ? 0.88 : 0.72)),
            style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round, dash: dashed ? [7, 6] : [])
        )
    }

    private func wireColor(from source: RoutingNode, to target: RoutingNode) -> Color {
        if source.kind == .guardNode || target.kind == .guardNode {
            return model.outputLockEnabled ? model.lockStatus.tint : .white.opacity(0.48)
        }
        if target.kind == .output,
           target.audioOutputUID == model.selectedOutputUID {
            return Color.pureQGreen
        }
        return .white.opacity(0.50)
    }
}

struct EditableRoutingNodeCard: View {
    @EnvironmentObject private var model: EqualizerModel
    let node: RoutingNode
    let canvasSize: CGSize
    @State private var dragOffset: CGSize?
    @State private var liveDragTranslation: CGSize = .zero

    var body: some View {
        ZStack {
            HStack {
                port
                    .offset(x: -10)
                Spacer()
                port
                    .offset(x: 10)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: nodeIcon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(nodeColor)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.title)
                            .font(.callout.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Text(node.subtitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }

                    Spacer(minLength: 4)

                    Text(node.kind.title)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(nodeColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(nodeColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }

                HStack(spacing: 7) {
                    Button {
                        model.patchRoutingNode(id: node.id)
                    } label: {
                        Image(systemName: model.patchStartNodeID == node.id ? "link.circle.fill" : "link")
                    }
                    .buttonStyle(MiniIconButtonStyle(active: model.patchStartNodeID == node.id))
                    .help("Patch node")

                    Button {
                        model.disconnectRoutingNode(id: node.id)
                    } label: {
                        Image(systemName: "link.slash")
                    }
                    .buttonStyle(MiniIconButtonStyle())
                    .help("Disconnect node")

                    if node.kind == .equalizer {
                        Button {
                            model.setActiveEQNode(id: node.id)
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .buttonStyle(MiniIconButtonStyle(active: model.activeEQNode?.id == node.id))
                        .help("Set EQ tab target")
                    }

                    if node.kind == .output, node.audioOutputUID != nil {
                        Button {
                            model.routeToOutputNode(id: node.id)
                        } label: {
                            Image(systemName: node.audioOutputUID == model.selectedOutputUID ? "checkmark.circle.fill" : "target")
                        }
                        .buttonStyle(MiniIconButtonStyle(active: node.audioOutputUID == model.selectedOutputUID))
                        .help("Set desired output")
                    }

                    Spacer(minLength: 4)

                    Text(connectionSummary)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)

                    Button {
                        model.removeRoutingNode(id: node.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(MiniIconButtonStyle())
                    .help("Remove node")
                }
            }
            .padding(11)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(nodeBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: model.selectedRoutingNodeID == node.id ? 1.8 : 1)
        )
        .shadow(color: .black.opacity(model.selectedRoutingNodeID == node.id ? 0.38 : 0.22), radius: 8, y: 4)
        .offset(liveDragTranslation)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .gesture(dragGesture)
        .onTapGesture {
            model.selectRoutingNode(id: node.id)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("routingCanvas"))
            .onChanged { value in
                if dragOffset == nil {
                    dragOffset = CGSize(
                        width: node.position.x - value.location.x,
                        height: node.position.y - value.location.y
                    )
                    model.selectRoutingNode(id: node.id)
                }

                let offset = dragOffset ?? .zero
                let targetPosition = clampedPosition(
                    CGPoint(x: value.location.x + offset.width, y: value.location.y + offset.height)
                )
                liveDragTranslation = CGSize(
                    width: targetPosition.x - node.position.x,
                    height: targetPosition.y - node.position.y
                )
            }
            .onEnded { _ in
                let finalPosition = CGPoint(
                    x: node.position.x + liveDragTranslation.width,
                    y: node.position.y + liveDragTranslation.height
                )
                model.moveRoutingNode(id: node.id, to: finalPosition, in: canvasSize)
                dragOffset = nil
                liveDragTranslation = .zero
            }
    }

    private func clampedPosition(_ position: CGPoint) -> CGPoint {
        CGPoint(
            x: position.x.clamped(to: 118...max(118, canvasSize.width - 118)),
            y: position.y.clamped(to: 72...max(72, canvasSize.height - 72))
        )
    }

    private var nodeColor: Color {
        if node.kind == .guardNode {
            return model.outputLockEnabled ? model.lockStatus.tint : node.kind.accent
        }
        if node.kind == .output,
           node.audioOutputUID == model.selectedOutputUID {
            return Color.pureQGreen
        }
        return node.kind.accent
    }

    private var nodeBackground: Color {
        model.selectedRoutingNodeID == node.id ? Color(red: 0.16, green: 0.18, blue: 0.20) : Color.pureQControl
    }

    private var nodeIcon: String {
        if node.kind == .source,
           let sourceID = node.audioSourceID,
           let source = model.availableAudioSources.first(where: { $0.id == sourceID }) {
            return source.systemImage
        }
        return node.kind.systemImage
    }

    private var borderColor: Color {
        if model.patchStartNodeID == node.id { return Color.pureQAmber }
        if model.selectedRoutingNodeID == node.id { return nodeColor }
        return Color.pureQStroke
    }

    private var connectionSummary: String {
        let incoming = model.routingConnections.filter { $0.to == node.id }.count
        let outgoing = model.routingConnections.filter { $0.from == node.id }.count
        return "\(incoming) in / \(outgoing) out"
    }

    private var port: some View {
        Circle()
            .fill(Color.pureQBackground)
            .frame(width: 13, height: 13)
            .overlay(Circle().stroke(borderColor.opacity(0.86), lineWidth: 2))
    }
}

struct RoutingInspector: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let node {
                    inspectorSection("Selected", systemImage: node.kind.systemImage) {
                        TextField("Name", text: Binding(get: {
                            node.title
                        }, set: { newTitle in
                            model.renameRoutingNode(id: node.id, title: newTitle)
                        }))
                        .textFieldStyle(.roundedBorder)

                        Picker("Type", selection: Binding(get: {
                            node.kind
                        }, set: { kind in
                            model.setRoutingNodeKind(id: node.id, kind: kind)
                        })) {
                            ForEach(RoutingNodeKind.allCases.filter { node.kind == .monitor || $0 != .monitor }) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                    }

                    if node.kind == .source {
                        inspectorSection("Source", systemImage: "music.note.list") {
                            Picker("Source", selection: Binding(get: {
                                node.audioSourceID ?? AudioSourceItem.systemMixID
                            }, set: { sourceID in
                                model.setRoutingNodeSource(id: node.id, sourceID: sourceID)
                            })) {
                                ForEach(model.availableAudioSources) { source in
                                    Text(source.title).tag(source.id)
                                }
                            }
                        }
                    }

                    if node.kind == .output {
                        inspectorSection("Output", systemImage: "speaker.wave.2.fill") {
                            Picker("Device", selection: Binding(get: {
                                node.audioOutputUID ?? ""
                            }, set: { uid in
                                model.setRoutingNodeOutput(id: node.id, uid: uid.isEmpty ? nil : uid)
                            })) {
                                Text("Unassigned").tag("")
                                ForEach(model.hardwareOutputDevices) { device in
                                    Text(device.name).tag(device.uid)
                                }
                            }

                            if node.audioOutputUID != nil {
                                Button {
                                    model.routeToOutputNode(id: node.id)
                                } label: {
                                    Label("Set Desired", systemImage: "target")
                                }
                                .buttonStyle(RouteActionButtonStyle(active: node.audioOutputUID == model.selectedOutputUID))
                            }
                        }
                    }

                    if node.kind == .equalizer {
                        inspectorSection("EQ Profile", systemImage: "slider.horizontal.3") {
                            HStack {
                                Label("Unique", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(Color.pureQGreen)
                                Spacer()
                                Text(eqSummary(for: node))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption.weight(.semibold))

                            Button {
                                model.setActiveEQNode(id: node.id)
                            } label: {
                                Label("Set EQ Target", systemImage: "slider.horizontal.3")
                            }
                            .buttonStyle(RouteActionButtonStyle(active: model.activeEQNode?.id == node.id))

                            Button {
                                model.setActiveEQNode(id: node.id)
                                model.copyMainEqualizerToActiveNode()
                            } label: {
                                Label("Copy Main", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(RouteActionButtonStyle(active: false))
                        }
                    }

                    inspectorSection("Links", systemImage: "link") {
                        HStack(spacing: 8) {
                            Text(connectionSummary(for: node))
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        Button {
                            model.patchRoutingNode(id: node.id)
                        } label: {
                            Label(model.patchStartNodeID == node.id ? "Cancel Patch" : "Patch", systemImage: "link")
                        }
                        .buttonStyle(RouteActionButtonStyle(active: model.patchStartNodeID == node.id))

                        Button {
                            model.disconnectRoutingNode(id: node.id)
                        } label: {
                            Label("Disconnect", systemImage: "link.slash")
                        }
                        .buttonStyle(RouteActionButtonStyle(active: false))
                    }

                    Button(role: .destructive) {
                        model.removeRoutingNode(id: node.id)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .padding(.top, 2)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("No Selection", systemImage: "cursorarrow.click")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            Label("\(model.routingNodes.count)", systemImage: "square.stack.3d.up")
                            Label("\(model.routingConnections.count)", systemImage: "link")
                        }
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.pureQPanel)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.pureQStroke)
                .frame(width: 1)
        }
    }

    private var node: RoutingNode? {
        guard let selectedID = model.selectedRoutingNodeID else { return nil }
        return model.routingNodes.first(where: { $0.id == selectedID })
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pureQControl.opacity(0.78), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.pureQStroke, lineWidth: 1)
        )
    }

    private func connectionSummary(for node: RoutingNode) -> String {
        let incoming = model.routingConnections.filter { $0.to == node.id }.count
        let outgoing = model.routingConnections.filter { $0.from == node.id }.count
        return "\(incoming) input / \(outgoing) output"
    }

    private func eqSummary(for node: RoutingNode) -> String {
        let activeCount = node.eqBands.filter { $0.isEnabled && abs($0.gain) > 0.01 }.count
        return "\(node.eqMode.rawValue), \(activeCount) active"
    }
}

struct RouteActionButtonStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(active ? Color.pureQGreen : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(active ? Color.pureQGreen.opacity(0.15) : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(active ? Color.pureQGreen.opacity(0.48) : Color.pureQStroke, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct PresetBar: View {
    @EnvironmentObject private var model: EqualizerModel
    @State private var showingManualFlattenConfirmation = false
    @State private var showingPresetFlattenOptions = false

    var body: some View {
        HStack(spacing: 14) {
            Button {
                model.applyActiveEQSelection(.manual)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(IconButtonStyle(size: 34))
            .help("Manual editing")

            Button {
                if model.activeEQSelection == .manual {
                    showingManualFlattenConfirmation = true
                } else {
                    showingPresetFlattenOptions = true
                }
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(IconButtonStyle(size: 34))
            .help("Flatten EQ")

            BandLayoutMenu()
                .frame(width: 132)

            Menu {
                ForEach(EqualizerSelection.profileOptions) { selection in
                    Button(selection.title) {
                        model.applyActiveEQSelection(selection)
                    }
                }
            } label: {
                HStack {
                    Spacer()
                    Text(model.activeEQSelection.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                    Spacer()
                    VStack(spacing: -2) {
                        Image(systemName: "triangle.fill")
                            .font(.system(size: 10))
                        Image(systemName: "triangle.fill")
                            .font(.system(size: 10))
                            .rotationEffect(.degrees(180))
                    }
                    .foregroundStyle(Color.pureQGreen)
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Color.pureQControl, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.pureQStroke, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)

            Button {
                model.applyActiveEQSelection(.bassLift)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(IconButtonStyle(size: 34))
            .help("Add a Bass Lift preset")

            Button {
                model.outputLockEnabled.toggle()
            } label: {
                Image(systemName: "headphones")
            }
            .buttonStyle(IconButtonStyle(size: 34, active: model.outputLockEnabled))
            .help("Toggle output lock")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.17, green: 0.18, blue: 0.20))
        .confirmationDialog("Flatten Manual EQ?", isPresented: $showingManualFlattenConfirmation, titleVisibility: .visible) {
            Button("Flatten Manual EQ", role: .destructive) {
                model.flattenActiveEQAsManual()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This erases the current manual gains, custom frequencies, Q values, and shapes for the selected EQ.")
        }
        .confirmationDialog("Flatten Preset EQ?", isPresented: $showingPresetFlattenOptions, titleVisibility: .visible) {
            Button("Create New Flat EQ Node") {
                model.createFlatEQNodeFromActiveEQ()
            }
            Button("Switch To Manual And Flatten", role: .destructive) {
                model.flattenActiveEQAsManual()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can keep the current preset intact and work on a new flat EQ node, or replace this selected EQ with a flat manual profile.")
        }
    }
}

struct EqualizerGraph: View {
    let bands: [EqualizerBand]
    let preamp: Double

    private let minimumFrequency = 20.0
    private let maximumFrequency = 20_000.0
    private let minimumDB = -20.0
    private let maximumDB = 20.0

    var body: some View {
        Canvas { context, size in
            let plot = CGRect(x: 54, y: 18, width: max(size.width - 108, 10), height: max(size.height - 56, 10))

            drawGrid(in: plot, context: &context)
            drawCurve(in: plot, context: &context)
        }
        .background(Color.pureQBackground)
    }

    private func drawGrid(in plot: CGRect, context: inout GraphicsContext) {
        let majorFrequencies: [Double] = [20, 40, 100, 200, 400, 1_000, 2_000, 4_000, 10_000, 20_000]
        let majorDB: [Double] = [-20, -10, 0, 10, 20]

        for db in majorDB {
            let y = yPosition(for: db, in: plot)
            var path = Path()
            path.move(to: CGPoint(x: plot.minX, y: y))
            path.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(path, with: .color(db == 0 ? .white.opacity(0.70) : .white.opacity(0.13)), lineWidth: db == 0 ? 2 : 1)

            let label = "\(Int(db))dB"
            context.draw(
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.58)),
                at: CGPoint(x: plot.minX - 30, y: y),
                anchor: .center
            )
            context.draw(
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.58)),
                at: CGPoint(x: plot.maxX + 30, y: y),
                anchor: .center
            )
        }

        for frequency in EqualizerBand.standardFrequencies {
            let x = xPosition(for: frequency, in: plot)
            var path = Path()
            path.move(to: CGPoint(x: x, y: plot.minY))
            path.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 1)
        }

        for frequency in majorFrequencies {
            let x = xPosition(for: frequency, in: plot)
            var path = Path()
            path.move(to: CGPoint(x: x, y: plot.minY))
            path.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(path, with: .color(.white.opacity(0.13)), lineWidth: 1.2)

            context.draw(
                Text(shortFrequencyLabel(frequency)).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.58)),
                at: CGPoint(x: x, y: plot.maxY + 22),
                anchor: .center
            )
        }
    }

    private func drawCurve(in plot: CGRect, context: inout GraphicsContext) {
        let sampleCount = 420
        let sampleFrequencies = (0..<sampleCount).map { index in
            let fraction = Double(index) / Double(sampleCount - 1)
            return pow(10, log10(minimumFrequency) + (log10(maximumFrequency) - log10(minimumFrequency)) * fraction)
        }
        let activeBands = bands.filter { $0.isEnabled }
        let baselineDB = preamp.clamped(to: minimumDB...maximumDB)

        let adjustedBands = activeBands.filter { abs($0.gain) > 0.05 }
        let shouldShowIndividualResponses = adjustedBands.count <= 8

        if shouldShowIndividualResponses {
            for band in adjustedBands {
            let color = bandColor(for: band.frequency)
            var strokePath = Path()

            for (index, frequency) in sampleFrequencies.enumerated() {
                let response = (baselineDB + responseContribution(from: band, at: frequency)).clamped(to: minimumDB...maximumDB)
                let point = CGPoint(x: xPosition(for: frequency, in: plot), y: yPosition(for: response, in: plot))

                if index == 0 {
                    strokePath.move(to: point)
                } else {
                    strokePath.addLine(to: point)
                }
            }

                context.stroke(strokePath, with: .color(color.opacity(0.34)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }

        var combinedPath = Path()
        for (index, frequency) in sampleFrequencies.enumerated() {
            let summedBands = activeBands.reduce(0.0) { partialResult, band in
                partialResult + responseContribution(from: band, at: frequency)
            }
            let combinedDB = (preamp + summedBands).clamped(to: minimumDB...maximumDB)
            let point = CGPoint(x: xPosition(for: frequency, in: plot), y: yPosition(for: combinedDB, in: plot))

            if index == 0 {
                combinedPath.move(to: point)
            } else {
                combinedPath.addLine(to: point)
            }
        }

        context.stroke(combinedPath, with: .color(.white.opacity(0.74)), style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))

        for band in adjustedBands {
            let point = CGPoint(
                x: xPosition(for: band.frequency, in: plot),
                y: yPosition(for: (preamp + band.gain).clamped(to: minimumDB...maximumDB), in: plot)
            )
            context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(bandColor(for: band.frequency)))
        }
    }

    private func responseContribution(from band: EqualizerBand, at frequency: Double) -> Double {
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

    private func xPosition(for frequency: Double, in rect: CGRect) -> CGFloat {
        let minLog = log10(minimumFrequency)
        let maxLog = log10(maximumFrequency)
        let fraction = (log10(frequency) - minLog) / (maxLog - minLog)
        return rect.minX + rect.width * CGFloat(fraction)
    }

    private func yPosition(for db: Double, in rect: CGRect) -> CGFloat {
        let fraction = (maximumDB - db) / (maximumDB - minimumDB)
        return rect.minY + rect.height * CGFloat(fraction)
    }

    private func shortFrequencyLabel(_ frequency: Double) -> String {
        if frequency >= 1_000 {
            let value = frequency / 1_000
            return value.rounded() == value ? "\(Int(value))K" : String(format: "%.1fK", value)
        }
        return "\(Int(frequency))"
    }

    private func bandColor(for frequency: Double) -> Color {
        let fraction = ((log10(frequency) - log10(minimumFrequency)) / (log10(maximumFrequency) - log10(minimumFrequency))).clamped(to: 0...1)
        return Color(hue: 0.04 + fraction * 0.22, saturation: 0.96, brightness: 1.0)
    }
}

struct PreampRow: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                preampControls
                Divider()
                    .frame(height: 30)
                BalanceControl(
                    value: model.activeEQBalance,
                    onChange: { model.setActiveEQBalance($0) }
                )
                .frame(width: 330)
            }

            VStack(spacing: 8) {
                preampControls
                BalanceControl(
                    value: model.activeEQBalance,
                    onChange: { model.setActiveEQBalance($0) }
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(red: 0.18, green: 0.19, blue: 0.21))
    }

    private var preampControls: some View {
        HStack(spacing: 10) {
            Text("Preamp:")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.pureQControl, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Slider(value: Binding(get: {
                model.activeEQPreamp
            }, set: { value in
                model.setActiveEQPreamp(value)
            }), in: -20...20)
            .tint(Color.pureQGreen)

            Text(String(format: "%.1fdB", model.activeEQPreamp))
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(width: 82)
                .padding(.vertical, 4)
                .background(Color.pureQControl, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Toggle("Auto", isOn: Binding(get: {
                model.activeEQAutoGainEnabled
            }, set: { enabled in
                model.setActiveEQAutoGain(enabled)
            }))
            .toggleStyle(.checkbox)
            .font(.callout.weight(.semibold))
            .help("Automatically lower preamp to offset the largest enabled boost")
        }
    }
}

struct BalanceControl: View {
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        VStack(spacing: 3) {
            Text("Balance")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("Left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                BandValueField(
                    value: leftPercent,
                    range: 0...100,
                    suffix: "%",
                    decimals: 0,
                    compact: true,
                    onCommit: { percent in
                        onChange(((100 - percent) / 100).clamped(to: -1...1))
                    }
                )
                .frame(width: 52)

                Slider(value: Binding(get: {
                    value
                }, set: { newValue in
                    onChange(newValue)
                }), in: -1...1)
                .tint(Color.pureQGreen)
                .frame(minWidth: 90)

                BandValueField(
                    value: rightPercent,
                    range: 0...100,
                    suffix: "%",
                    decimals: 0,
                    compact: true,
                    onCommit: { percent in
                        onChange((-(100 - percent) / 100).clamped(to: -1...1))
                    }
                )
                .frame(width: 52)

                Text("Right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var leftPercent: Double {
        value <= 0 ? 100 : (1 - value).clamped(to: 0...1) * 100
    }

    private var rightPercent: Double {
        value >= 0 ? 100 : (1 + value).clamped(to: 0...1) * 100
    }
}

struct BandLayoutMenu: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        Menu {
            Button("10 Bands") {
                model.setActiveEQMode(.basic)
            }
            Button("31 Bands") {
                model.setActiveEQMode(.expert)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.vertical.3")
                Text(model.activeEQBandLayoutTitle)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.bold))
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white.opacity(0.86))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.pureQControl, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.pureQStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .help("Switch band layout while matching the current curve")
    }
}

struct BandScroller: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 8) {
                ForEach(model.activeEQVisibleBands) { band in
                    BandStrip(
                        band: band,
                        width: 74,
                        onFrequencyChange: { model.setActiveEQBandFrequency(id: band.id, frequency: $0) },
                        onGainChange: { model.setActiveEQBandGain(id: band.id, gain: $0, persist: false) },
                        onGainCommit: { model.setActiveEQBandGain(id: band.id, gain: $0, persist: true) },
                        onQChange: { model.setActiveEQBandQ(id: band.id, q: $0, persist: false) },
                        onQCommit: { model.setActiveEQBandQ(id: band.id, q: $0, persist: true) },
                        onToggleEnabled: { model.toggleActiveEQBand(id: band.id) },
                        onToggleStereoLink: { model.toggleActiveEQStereoLink(id: band.id) },
                        onCycleShape: { model.cycleActiveEQShape(id: band.id) }
                    )
                }

                AddBandStrip(width: 74) {
                    model.addActiveEQBand()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(minHeight: 342, idealHeight: 356, maxHeight: 382)
        .background(Color(red: 0.17, green: 0.18, blue: 0.20))
    }
}

struct BandStrip: View {
    let band: EqualizerBand
    let width: CGFloat
    let onFrequencyChange: (Double) -> Void
    let onGainChange: (Double) -> Void
    let onGainCommit: (Double) -> Void
    let onQChange: (Double) -> Void
    let onQCommit: (Double) -> Void
    let onToggleEnabled: () -> Void
    let onToggleStereoLink: () -> Void
    let onCycleShape: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Button(action: onToggleEnabled) {
                    Image(systemName: band.isEnabled ? "checkmark" : "xmark")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(MiniToggleButtonStyle(active: band.isEnabled))
                .help(band.isEnabled ? "Disable band" : "Enable band")

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(colorForBand)
                    .frame(width: 19, height: 19)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(.black.opacity(0.45), lineWidth: 2)
                    )
            }

            Button(action: onToggleStereoLink) {
                Image(systemName: band.isStereoLinked ? "speaker.wave.2.fill" : "speaker.wave.1")
            }
            .buttonStyle(PillButtonStyle(active: band.isStereoLinked))
            .help("Toggle stereo link")

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
                .frame(height: 154)
                .opacity(band.isEnabled ? 1 : 0.36)

            BandValueField(
                value: band.gain,
                range: -20...20,
                suffix: "dB",
                decimals: 1,
                compact: true,
                onCommit: onGainCommit
            )

            QDial(value: band.q, onChange: onQChange, onEditingEnded: onQCommit)
                .frame(height: 54)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .frame(width: width, height: 344)
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

struct AddBandStrip: View {
    let width: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(Color.pureQGreen.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.pureQGreen.opacity(0.45), lineWidth: 1)
                    )

                Text("Add")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.82))
            }
            .frame(width: width, height: 344)
            .background(Color(red: 0.18, green: 0.19, blue: 0.21), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.pureQGreen.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
            )
        }
        .buttonStyle(.plain)
        .help("Add a custom EQ band")
    }
}

struct BandValueField: View {
    let value: Double
    let range: ClosedRange<Double>
    var prefix: String = ""
    let suffix: String
    let decimals: Int
    var compact = false
    let onCommit: (Double) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 2) {
            if !prefix.isEmpty {
                Text(prefix)
                    .font((compact ? Font.caption2 : Font.caption).weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font((compact ? Font.caption2 : Font.caption).monospacedDigit().weight(.bold))
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
                .onSubmit(commit)

            if !suffix.isEmpty {
                Text(suffix)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .padding(.horizontal, compact ? 4 : 5)
        .padding(.vertical, compact ? 1 : 2)
        .frame(maxWidth: .infinity, minHeight: compact ? 18 : 20)
        .background(Color.pureQControl, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isFocused ? Color.pureQGreen.opacity(0.72) : .clear, lineWidth: 1)
        )
        .onAppear {
            updateText(from: value)
        }
        .onChange(of: value) { _, newValue in
            guard !isFocused else { return }
            updateText(from: newValue)
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                text = trimmedNumberText(from: text)
            } else {
                commit()
            }
        }
    }

    private func commit() {
        let candidate = trimmedNumberText(from: text)
        guard let parsedValue = Double(candidate) else {
            updateText(from: value)
            return
        }
        let clampedValue = parsedValue.clamped(to: range)
        onCommit(clampedValue)
        updateText(from: clampedValue)
    }

    private func updateText(from value: Double) {
        if decimals == 0 {
            text = String(format: "%.0f", value)
        } else {
            text = String(format: "%.\(decimals)f", value)
        }
    }

    private func trimmedNumberText(from text: String) -> String {
        let allowed = Set("0123456789.-")
        var result = text.filter { allowed.contains($0) }
        if result.filter({ $0 == "-" }).count > 1 {
            result.removeAll { $0 == "-" }
            result = "-" + result
        }
        if let minusIndex = result.firstIndex(of: "-"), minusIndex != result.startIndex {
            result.remove(at: minusIndex)
            result.insert("-", at: result.startIndex)
        }
        if let firstDecimal = result.firstIndex(of: ".") {
            let afterDecimal = result.index(after: firstDecimal)..<result.endIndex
            result.replaceSubrange(afterDecimal, with: result[afterDecimal].filter { $0 != "." })
        }
        return result
    }
}

struct VerticalFader: View {
    @EnvironmentObject private var telemetry: AudioTelemetryStore
    let value: Double
    let range: ClosedRange<Double>
    let meterFrequency: Double
    let isEnabled: Bool
    let onChange: (Double) -> Void
    let onEditingEnded: (Double) -> Void
    @State private var dragValue: Double?
    @State private var lastSentAt = 0.0

    var body: some View {
        GeometryReader { proxy in
            let knobHeight = 27.0
            let knobWidth = 27.0
            let trackHeight = max(proxy.size.height - knobHeight, 1)
            let effectiveValue = dragValue ?? value
            let activity = telemetry.bandActivityLevel(for: meterFrequency)
            let fraction = (effectiveValue - range.lowerBound) / (range.upperBound - range.lowerBound)
            let knobY = trackHeight * (1 - fraction)
            let meterFraction = CGFloat(activity.clamped(to: 0...1))
            let meterHeight = max(0, (proxy.size.height - 16) * meterFraction)
            let meterY = proxy.size.height - 8 - (meterHeight / 2)
            let markerY = proxy.size.height - 8 - ((proxy.size.height - 16) * meterFraction)
            let meterColor = activity > 0.84 ? Color.red : Color.pureQGreen

            ZStack(alignment: .top) {
                ForEach(0..<13, id: \.self) { tick in
                    let tickFraction = CGFloat(tick) / 12.0
                    Capsule()
                        .fill(Color.pureQGreen.opacity(tick == 6 ? 0.88 : 0.66))
                        .frame(width: tick == 6 ? 28 : 20, height: 2)
                        .position(x: proxy.size.width / 2, y: 8 + (proxy.size.height - 16) * tickFraction)
                }

                ForEach([0.25, 0.5, 0.75], id: \.self) { guide in
                    Capsule()
                        .fill(.white.opacity(0.08))
                        .frame(width: 28, height: 1)
                        .position(x: proxy.size.width / 2, y: proxy.size.height * guide)
                }

                Capsule()
                    .fill(Color.pureQControl)
                    .frame(width: 8, height: proxy.size.height)
                    .overlay(
                        Capsule()
                            .stroke(.black.opacity(0.35), lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity, alignment: .center)

                if activity > 0.025 {
                    Capsule()
                        .fill(meterColor.opacity(isEnabled ? 0.48 : 0.14))
                        .frame(width: 6, height: meterHeight)
                        .position(x: proxy.size.width / 2, y: meterY)
                }

                if activity > 0.12 {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(meterColor.opacity(isEnabled ? 0.76 : 0.22))
                        .frame(width: 9, height: 3)
                        .position(x: proxy.size.width / 2 + 9, y: markerY)
                }

                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.pureQControl)
                    .frame(width: knobWidth, height: knobHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.pureQStroke, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                    .offset(y: knobY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let y = min(max(gesture.location.y - knobHeight / 2, 0), trackHeight)
                        let newFraction = 1 - (y / trackHeight)
                        let newValue = range.lowerBound + newFraction * (range.upperBound - range.lowerBound)
                        dragValue = newValue
                        sendThrottled(newValue)
                    }
                    .onEnded { _ in
                        if let dragValue {
                            onEditingEnded(dragValue)
                        }
                        self.dragValue = nil
                        lastSentAt = 0
                    }
            )
        }
    }

    private func sendThrottled(_ newValue: Double) {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastSentAt >= (1.0 / 45.0) else { return }
        lastSentAt = now
        onChange(newValue)
    }
}

struct QDial: View {
    let value: Double
    let onChange: (Double) -> Void
    let onEditingEnded: (Double) -> Void
    @State private var dragStartValue: Double?
    @State private var dragValue: Double?
    @State private var lastSentAt = 0.0

    var body: some View {
        let effectiveValue = dragValue ?? value

        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(Color.pureQGreen.opacity(0.92))
                    .overlay(Circle().stroke(Color.pureQGreen.opacity(0.55), lineWidth: 5))
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)

                Capsule()
                    .fill(Color.pureQControl)
                    .frame(width: 3, height: 15)
                    .offset(y: -6)
                    .rotationEffect(.degrees(angle(for: effectiveValue)))
            }
            .frame(width: 30, height: 30)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragStartValue == nil {
                            dragStartValue = value
                        }
                        let delta = Double(gesture.translation.width - gesture.translation.height) * 0.015
                        let newValue = ((dragStartValue ?? value) + delta).clamped(to: 0.1...10)
                        dragValue = newValue
                        sendThrottled(newValue)
                    }
                    .onEnded { _ in
                        if let dragValue {
                            onEditingEnded(dragValue)
                        }
                        dragStartValue = nil
                        dragValue = nil
                        lastSentAt = 0
                    }
            )

            BandValueField(
                value: effectiveValue,
                range: 0.1...10,
                prefix: "Q:",
                suffix: "",
                decimals: 3,
                compact: true,
                onCommit: onEditingEnded
            )
        }
    }

    private func angle(for value: Double) -> Double {
        let fraction = (value - 0.1) / (10 - 0.1)
        return -135 + fraction * 270
    }

    private func sendThrottled(_ newValue: Double) {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastSentAt >= (1.0 / 45.0) else { return }
        lastSentAt = now
        onChange(newValue)
    }
}

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
        if model.outputLockEnabled && model.audioEngineTakeoverActive {
            return "Locked Tap"
        }
        if model.outputLockEnabled && model.pureQVirtualOutputDevice != nil {
            return "Virtual"
        }
        return model.audioEngineTakeoverActive ? "Takeover" : "Monitor"
    }

    private var renderModeTint: Color {
        if model.outputLockEnabled {
            return model.audioEngineTakeoverActive ? Color.pureQAmber : Color.pureQGreen
        }
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

struct MenuBarView: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("PureQ", systemImage: model.menuBarSystemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(model.lockStatus.tint)
                Spacer()
                Toggle("", isOn: $model.powerEnabled)
                    .toggleStyle(PowerToggleStyle())
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Desired Output")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("Desired Output", selection: Binding(get: {
                    model.selectedOutputUID ?? ""
                }, set: { uid in
                    model.selectedOutputUID = uid.isEmpty ? nil : uid
                })) {
                    if let selectedUID = model.selectedOutputUID,
                       !model.hardwareOutputDevices.contains(where: { $0.uid == selectedUID }) {
                        Text("\(model.selectedOutputName) (disconnected)").tag(selectedUID)
                    }
                    ForEach(model.hardwareOutputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()

                Toggle("Lock output", isOn: $model.outputLockEnabled)
                    .toggleStyle(.switch)
            }

            Divider()

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

            Text(model.lockMessage)
                .font(.caption)
                .foregroundStyle(model.lockStatus.tint)
                .lineLimit(2)

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
        .frame(width: 360)
    }
}

struct PowerToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(configuration.isOn ? Color.pureQGreen.opacity(0.22) : Color.black.opacity(0.25))
                .frame(width: 54, height: 28)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(configuration.isOn ? Color.pureQGreen : Color(red: 0.09, green: 0.10, blue: 0.12))
                        .frame(width: 20, height: 20)
                        .padding(4)
                        .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.pureQStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

struct RouteToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white.opacity(0.86))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.pureQControl, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.pureQStroke, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct IconButtonStyle: ButtonStyle {
    let size: CGFloat
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(active ? Color.pureQGreen : .white.opacity(0.82))
            .frame(width: size, height: size)
            .background(active ? Color.pureQGreen.opacity(0.16) : Color.pureQControl, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.pureQStroke, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

struct MiniIconButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(active ? Color.pureQGreen : .white.opacity(0.72))
            .frame(width: 23, height: 23)
            .background(active ? Color.pureQGreen.opacity(0.16) : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(active ? Color.pureQGreen.opacity(0.48) : Color.pureQStroke, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

struct MiniToggleButtonStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? Color.pureQGreen : .secondary)
            .frame(width: 22, height: 22)
            .background(Color.pureQControl, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.pureQStroke, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

struct PillButtonStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(active ? Color.pureQGreen : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(Color.pureQControl, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.pureQStroke, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private extension View {
    func pureQHardwareAccelerated(_ enabled: Bool) -> some View {
        _ = enabled
        return self
    }
}

#Preview {
    let model = EqualizerModel()
    ContentView()
        .environmentObject(model)
        .environmentObject(model.telemetryStore)
}
